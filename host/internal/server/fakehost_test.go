package server

import (
	"encoding/json"
	"fmt"
	"net"
	"os"
	"sync"
	"testing"

	"webmux/host/internal/protocol"
)

// TestMain guards against protocol.EnsureHost re-executing this test binary
// as `<exe> ptyhost --name X` (it would run the whole suite recursively).
func TestMain(m *testing.M) {
	if len(os.Args) > 1 && os.Args[1] == "ptyhost" {
		os.Exit(3)
	}
	os.Exit(m.Run())
}

// fakeHost speaks the pty-host newline-JSON protocol (ptyhost.js header):
// ping/list/create/kill/attach/watch.
type fakeHost struct {
	t        *testing.T
	name     string
	pasteDir string
	ln       net.Listener

	mu       sync.Mutex
	sessions []string
	nextID   int
	attached map[string][]net.Conn
	watchers []net.Conn
	inputs   chan fakeInput
	snapPid  int
}

type fakeInput struct {
	session string
	line    string
}

// snapshotFrame is what the fake sends first on attach; the browser must
// receive it byte-identical (note the non-canonical spacing and key order).
func (f *fakeHost) snapshotFrame(id string) string {
	return fmt.Sprintf(`{"type":"snapshot","data":"\u001b[1mhi\u001b[0m é ✓\r\n","cols":80,"rows":24,"title":"t <x>","pid":%d, "session":%q}`, f.snapPid, id)
}

func startFakeHost(t *testing.T, name, pasteDir string) *fakeHost {
	t.Helper()
	sock, err := protocol.SocketPath(name)
	if err != nil {
		t.Fatal(err)
	}
	os.Remove(sock)
	ln, err := net.Listen("unix", sock)
	if err != nil {
		t.Fatal(err)
	}
	f := &fakeHost{t: t, name: name, pasteDir: pasteDir, ln: ln,
		attached: map[string][]net.Conn{}, inputs: make(chan fakeInput, 64), snapPid: 999999999}
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go f.serve(c)
		}
	}()
	t.Cleanup(f.stop)
	return f
}

func (f *fakeHost) stop() {
	f.ln.Close()
	f.mu.Lock()
	defer f.mu.Unlock()
	for _, cs := range f.attached {
		for _, c := range cs {
			c.Close()
		}
	}
	for _, c := range f.watchers {
		c.Close()
	}
}

func (f *fakeHost) serve(c net.Conn) {
	lr := protocol.NewLineReader(c)
	line, err := lr.Next()
	if err != nil {
		c.Close()
		return
	}
	var msg map[string]any
	if json.Unmarshal(line, &msg) != nil {
		c.Close()
		return
	}
	reply := func(v any) { protocol.WriteFrame(c, v); c.Close() }
	f.mu.Lock()
	switch msg["cmd"] {
	case "ping":
		n := len(f.sessions)
		f.mu.Unlock()
		reply(map[string]any{"ok": true, "name": f.name, "pid": os.Getpid(), "sessions": n, "pasteDir": f.pasteDir})
	case "list":
		list := []map[string]any{}
		for _, id := range f.sessions {
			list = append(list, map[string]any{"id": id, "cols": 80, "rows": 24, "title": "", "createdAt": 1730000000123, "clients": len(f.attached[id]), "pid": 4242})
		}
		f.mu.Unlock()
		reply(map[string]any{"ok": true, "sessions": list})
	case "create":
		f.nextID++
		id := fmt.Sprintf("s%d-%v-%v", f.nextID, msg["cols"], msg["rows"])
		f.sessions = append(f.sessions, id)
		f.mu.Unlock()
		reply(map[string]any{"ok": true, "id": id})
	case "kill":
		found := false
		for i, id := range f.sessions {
			if id == msg["session"] {
				f.sessions = append(f.sessions[:i], f.sessions[i+1:]...)
				found = true
				break
			}
		}
		f.mu.Unlock()
		if found {
			reply(map[string]any{"ok": true})
		} else {
			reply(map[string]any{"ok": false, "error": "no such session"})
		}
	case "watch":
		f.watchers = append(f.watchers, c)
		f.mu.Unlock()
	case "attach":
		id, _ := msg["session"].(string)
		f.attached[id] = append(f.attached[id], c)
		f.mu.Unlock()
		c.Write([]byte(f.snapshotFrame(id) + "\n"))
		for {
			l, err := lr.Next()
			if err != nil {
				return
			}
			f.inputs <- fakeInput{id, string(l)}
		}
	default:
		f.mu.Unlock()
		reply(map[string]any{"ok": false, "error": "unknown command"})
	}
}

// closeSession sends exit to the session's attached clients and closes them.
func (f *fakeHost) closeSession(id string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	for _, c := range f.attached[id] {
		c.Write([]byte(`{"type":"exit","exitCode":0}` + "\n"))
		c.Close()
	}
	delete(f.attached, id)
}

func (f *fakeHost) pushWatch(line string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	for _, c := range f.watchers {
		c.Write([]byte(line + "\n"))
	}
}

func (f *fakeHost) watcherCount() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.watchers)
}
