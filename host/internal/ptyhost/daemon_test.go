package ptyhost

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"webmux/host/internal/protocol"
)

type logWriter struct{ t *testing.T }

func (w logWriter) Write(p []byte) (int, error) {
	w.t.Logf("daemon: %s", bytes.TrimRight(p, "\n"))
	return len(p), nil
}

// startDaemon runs a daemon in-process on a private XDG_RUNTIME_DIR, with
// HOME/TMPDIR inside it and a plain `sh` as the shell (no rc files, no
// fancy prompt).
func startDaemon(t *testing.T, name string) *Daemon {
	t.Helper()
	dir, err := os.MkdirTemp("", "wmpt")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	home := filepath.Join(dir, "home")
	os.Mkdir(home, 0o700)
	t.Setenv("XDG_RUNTIME_DIR", dir)
	t.Setenv("TMPDIR", dir)
	t.Setenv("HOME", home)
	t.Setenv("SHELL_CMD", "sh")
	t.Setenv("ENV", "")
	t.Setenv("PS1", "$ ")
	t.Setenv("TMUX", "/tmp/fake,1,0")
	d, err := New(name)
	if err != nil {
		t.Fatal(err)
	}
	d.Log, d.ErrLog = logWriter{t}, logWriter{t}
	if err := d.Listen(); err != nil {
		t.Fatal(err)
	}
	served := make(chan error, 1)
	go func() { served <- d.Serve() }()
	t.Cleanup(func() {
		d.Shutdown()
		if err := <-served; err != nil {
			t.Errorf("Serve: %v", err)
		}
	})
	return d
}

type tconn struct {
	t  *testing.T
	c  net.Conn
	lr *protocol.LineReader
}

func dial(t *testing.T, name string, first any) *tconn {
	t.Helper()
	c, err := protocol.Connect(name)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { c.Close() })
	tc := &tconn{t: t, c: c, lr: protocol.NewLineReader(c)}
	if first != nil {
		tc.send(first)
	}
	return tc
}

func (tc *tconn) send(v any) {
	tc.t.Helper()
	if err := protocol.WriteFrame(tc.c, v); err != nil {
		tc.t.Fatal(err)
	}
}

// raw returns the next frame line, or nil and the error.
func (tc *tconn) raw(timeout time.Duration) ([]byte, error) {
	_ = tc.c.SetReadDeadline(time.Now().Add(timeout))
	return tc.lr.Next()
}

func (tc *tconn) next() map[string]any {
	tc.t.Helper()
	line, err := tc.raw(10 * time.Second)
	if err != nil {
		tc.t.Fatalf("read frame: %v", err)
	}
	var m map[string]any
	if err := json.Unmarshal(line, &m); err != nil {
		tc.t.Fatalf("bad frame %q: %v", line, err)
	}
	return m
}

// until reads frames until pred matches one, returning it and all output
// data seen on the way.
func (tc *tconn) until(what string, pred func(map[string]any, string) bool) (map[string]any, string) {
	tc.t.Helper()
	var out strings.Builder
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		line, err := tc.raw(time.Until(deadline))
		if err != nil {
			tc.t.Fatalf("waiting for %s: %v; output so far %q", what, err, out.String())
		}
		var m map[string]any
		if err := json.Unmarshal(line, &m); err != nil {
			tc.t.Fatalf("bad frame %q", line)
		}
		if m["type"] == "output" {
			out.WriteString(m["data"].(string))
		}
		if pred(m, out.String()) {
			return m, out.String()
		}
	}
	tc.t.Fatalf("timed out waiting for %s; output %q", what, out.String())
	return nil, ""
}

func (tc *tconn) waitOutput(sub string) string {
	tc.t.Helper()
	_, out := tc.until(fmt.Sprintf("output %q", sub), func(_ map[string]any, out string) bool {
		return strings.Contains(out, sub)
	})
	return out
}

func control(t *testing.T, name string, msg any) map[string]any {
	t.Helper()
	res, err := protocol.Control(name, msg, 0)
	if err != nil {
		t.Fatalf("control %v: %v", msg, err)
	}
	return res
}

func rawReply(t *testing.T, name string, msg any) string {
	t.Helper()
	line, err := rawControl(name, msg)
	if err != nil {
		t.Fatalf("control %v: %v", msg, err)
	}
	return string(line)
}

func TestDaemonEndToEnd(t *testing.T) {
	const name = "t1"
	d := startDaemon(t, name)

	// ping: exact key order of ptyhost.js, pasteDir present and created.
	ping := rawReply(t, name, map[string]any{"cmd": "ping"})
	want := fmt.Sprintf(`{"ok":true,"name":"t1","pid":%d,"sessions":0,"pasteDir":%q}`, os.Getpid(), d.PasteDir())
	if ping != want {
		t.Fatalf("ping = %s\nwant   %s", ping, want)
	}
	if st, err := os.Stat(d.PasteDir()); err != nil || !st.IsDir() || st.Mode().Perm() != 0o700 {
		t.Fatalf("paste dir: %v %v", st, err)
	}

	// create with defaults.
	cr := control(t, name, map[string]any{"cmd": "create"})
	id, _ := cr["id"].(string)
	if cr["ok"] != true || len(id) != 36 || id[14] != '4' {
		t.Fatalf("create = %v", cr)
	}

	// list: describe() fields, in order.
	list := rawReply(t, name, map[string]any{"cmd": "list"})
	if !strings.HasPrefix(list, `{"ok":true,"sessions":[{"id":"`+id+`","cols":80,"rows":24,"title":"","createdAt":`) ||
		!strings.Contains(list, `,"clients":0,"pid":`) {
		t.Fatalf("list = %s", list)
	}

	// watcher for session-title events.
	watch := dial(t, name, map[string]any{"cmd": "watch"})

	// attach: snapshot frame first, with every field, in order.
	at := dial(t, name, map[string]any{"cmd": "attach", "session": id})
	line, err := at.raw(10 * time.Second)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.HasPrefix(line, []byte(`{"type":"snapshot","data":"`)) {
		t.Fatalf("first attach frame: %.200s", line)
	}
	var snap map[string]any
	json.Unmarshal(line, &snap)
	if snap["cols"] != 80.0 || snap["rows"] != 24.0 || snap["title"] != "" || snap["pid"] == nil {
		t.Fatalf("snapshot fields: %v", snap)
	}
	if !bytes.Contains(line, []byte(`"title":"","pid":`)) {
		t.Fatalf("snapshot key order: %.300s", line)
	}

	// The session env follows ptyhost.js.
	at.send(map[string]any{"type": "input", "data": `echo "E[$TERM|$WEBMUX_SESSION|${TMUX-unset}|$DISPLAY]"` + "\r"})
	at.waitOutput("E[xterm-256color|" + id + "|unset|")

	// input → output.
	at.send(map[string]any{"type": "input", "data": "printf 'hello\\n'\r"})
	at.waitOutput("hello\r\n")

	// history: seq 1 200, then a re-attach snapshot carries the scrollback.
	at.send(map[string]any{"type": "input", "data": "seq 1 200; echo SEQ-\"\"DONE\r"})
	at.waitOutput("SEQ-DONE\r\n")
	at2 := dial(t, name, map[string]any{"cmd": "attach", "session": id})
	s2 := at2.next()
	data := s2["data"].(string)
	if s2["type"] != "snapshot" || !strings.Contains(data, "\r\n1\r\n2\r\n3\r\n") || !strings.Contains(data, "\r\n200\r\n") {
		t.Fatalf("re-attach snapshot lacks history: %q", data[:min(len(data), 400)])
	}
	if n := control(t, name, map[string]any{"cmd": "list"})["sessions"].([]any)[0].(map[string]any)["clients"]; n != 2.0 {
		t.Fatalf("clients = %v", n)
	}
	at2.c.Close()

	// resize: ignored when not integral, applied (mirror, then pty) otherwise.
	at.send(map[string]any{"type": "resize", "cols": 90.5, "rows": 30})
	at.send(map[string]any{"type": "resize", "cols": 100, "rows": 30})
	at.send(map[string]any{"type": "input", "data": "stty size\r"})
	at.waitOutput("30 100\r\n")
	desc := control(t, name, map[string]any{"cmd": "list"})["sessions"].([]any)[0].(map[string]any)
	if desc["cols"] != 100.0 || desc["rows"] != 30.0 || desc["clients"] != 1.0 {
		t.Fatalf("after resize: %v", desc)
	}
	at.send(map[string]any{"type": "resize", "cols": 1, "rows": 1000})
	at.send(map[string]any{"type": "input", "data": "stty size\r"})
	at.waitOutput("300 2\r\n")
	at.send(map[string]any{"type": "resize", "cols": 100, "rows": 30})

	// title: title frame to attached clients, session-title to watchers;
	// repeating the same title is not re-broadcast. (A title frame follows
	// the output frame of the same chunk, so count up to a later marker.)
	at.send(map[string]any{"type": "input", "data": `printf '\033]2;T\007'; printf '\033]2;T\007'; echo TIT""LED` + "\r"})
	titles := 0
	countUntil := func(marker string) {
		at.until(marker, func(m map[string]any, out string) bool {
			if m["type"] == "title" {
				if m["title"] != "T" {
					t.Fatalf("title frame %v", m)
				}
				titles++
			}
			return strings.Contains(out, marker+"\r\n")
		})
	}
	countUntil("TITLED")
	at.send(map[string]any{"type": "input", "data": `printf '\033]2;T\007'; echo MAR""KER` + "\r"})
	countUntil("MARKER")
	at.send(map[string]any{"type": "input", "data": `echo MARK""ER2` + "\r"})
	countUntil("MARKER2")
	if titles != 1 {
		t.Fatalf("got %d title frames", titles)
	}
	wl, err := watch.raw(10 * time.Second)
	if err != nil || string(wl) != `{"type":"session-title","session":"`+id+`","title":"T"}` {
		t.Fatalf("watch frame %q %v", wl, err)
	}
	if s := control(t, name, map[string]any{"cmd": "list"})["sessions"].([]any)[0].(map[string]any); s["title"] != "T" {
		t.Fatalf("list title %v", s["title"])
	}
	at3 := dial(t, name, map[string]any{"cmd": "attach", "session": id})
	if s3 := at3.next(); s3["title"] != "T" || s3["cols"] != 100.0 || s3["rows"] != 30.0 {
		t.Fatalf("snapshot after title/resize: title=%v %vx%v", s3["title"], s3["cols"], s3["rows"])
	}

	// exit 7 → {type:'exit', exitCode:7} to every attached client, then EOF;
	// the session is gone.
	at.send(map[string]any{"type": "input", "data": "exit 7\r"})
	for _, c := range []*tconn{at, at3} {
		ex, _ := c.until("exit", func(m map[string]any, _ string) bool { return m["type"] == "exit" })
		if ex["exitCode"] != 7.0 {
			t.Fatalf("exit frame %v", ex)
		}
		if _, err := c.raw(5 * time.Second); !errors.Is(err, io.EOF) {
			t.Fatalf("expected EOF after exit, got %v", err)
		}
	}
	if n := len(control(t, name, map[string]any{"cmd": "list"})["sessions"].([]any)); n != 0 {
		t.Fatalf("sessions after exit: %d", n)
	}
	if got := rawReply(t, name, map[string]any{"cmd": "attach", "session": id}); got != `{"type":"error","message":"no such session"}` {
		t.Fatalf("attach gone session: %s", got)
	}

	// kill: unknown → not found; known → ok, attached client sees exit.
	if got := rawReply(t, name, map[string]any{"cmd": "kill", "session": "nope"}); got != `{"ok":false,"error":"not found"}` {
		t.Fatalf("kill unknown: %s", got)
	}
	cr = control(t, name, map[string]any{"cmd": "create", "cols": 120, "rows": 40})
	id2 := cr["id"].(string)
	at4 := dial(t, name, map[string]any{"cmd": "attach", "session": id2})
	if s := at4.next(); s["cols"] != 120.0 || s["rows"] != 40.0 {
		t.Fatalf("create size: %v", s)
	}
	if got := rawReply(t, name, map[string]any{"cmd": "kill", "session": id2}); got != `{"ok":true}` {
		t.Fatalf("kill: %s", got)
	}
	at4.until("exit after kill", func(m map[string]any, _ string) bool { return m["type"] == "exit" })
	if n := len(control(t, name, map[string]any{"cmd": "list"})["sessions"].([]any)); n != 0 {
		t.Fatalf("sessions after kill: %d", n)
	}

	// unknown commands.
	if got := rawReply(t, name, map[string]any{"cmd": "bogus"}); got != `{"ok":false,"error":"unknown cmd \"bogus\""}` {
		t.Fatalf("unknown cmd: %s", got)
	}
	if got := rawReply(t, name, map[string]any{"foo": 1}); got != `{"ok":false,"error":"unknown cmd undefined"}` {
		t.Fatalf("missing cmd: %s", got)
	}
	// Garbage first line is ignored; the next line is still the command.
	g := dial(t, name, nil)
	g.c.Write([]byte("not json\n{\"cmd\":\"ping\"}\n"))
	if m := g.next(); m["ok"] != true || m["name"] != name {
		t.Fatalf("ping after garbage: %v", m)
	}

	// A peer that vanishes mid-stream must not hurt the daemon.
	cr = control(t, name, map[string]any{"cmd": "create"})
	id3 := cr["id"].(string)
	for i := 0; i < 5; i++ {
		c := dial(t, name, map[string]any{"cmd": "attach", "session": id3})
		c.send(map[string]any{"type": "input", "data": "seq 1 3000\r"})
		c.c.Close()
	}
	at5 := dial(t, name, map[string]any{"cmd": "attach", "session": id3})
	at5.next()
	at5.send(map[string]any{"type": "input", "data": "echo STILL-\"\"ALIVE\r"})
	at5.waitOutput("STILL-ALIVE\r\n")

	// shutdown via the CLI: reply, then ptys killed, socket unlinked.
	var out, errb bytes.Buffer
	if code := cli(name, "list", &out, &errb); code != 0 || !strings.Contains(out.String(), id3+"  80x24  clients=1  pid=") {
		t.Fatalf("cli list: %d %q %q", code, out.String(), errb.String())
	}
	out.Reset()
	if code := cli(name, "shutdown", &out, &errb); code != 0 || out.String() != "pty host 't1' shut down\n" {
		t.Fatalf("cli shutdown: %d %q", code, out.String())
	}
	select {
	case <-d.Done():
	case <-time.After(5 * time.Second):
		t.Fatal("daemon did not shut down")
	}
	if _, err := os.Stat(d.SocketPath()); !os.IsNotExist(err) {
		t.Fatalf("socket not unlinked: %v", err)
	}
	// The pty went away too: the shell got its hangup and the attached
	// client sees the exit.
	at5.until("exit after shutdown", func(m map[string]any, _ string) bool { return m["type"] == "exit" })
	out.Reset()
	errb.Reset()
	if code := cli(name, "ping", &out, &errb); code != 1 ||
		errb.String() != fmt.Sprintf("no pty host 't1' running (socket: %s)\n", d.SocketPath()) {
		t.Fatalf("cli ping after shutdown: %d %q", code, errb.String())
	}
}

func TestDaemonCLIAndAddrInUse(t *testing.T) {
	const name = "t2"
	d := startDaemon(t, name)
	var out, errb bytes.Buffer
	if code := cli(name, "ping", &out, &errb); code != 0 || !strings.HasPrefix(out.String(), `{"ok":true,"name":"t2","pid":`) ||
		!strings.Contains(out.String(), `"pasteDir":`) {
		t.Fatalf("cli ping: %d %q", code, out.String())
	}
	out.Reset()
	if code := cli(name, "list", &out, &errb); code != 0 || out.String() != "(no sessions on pty host 't2')\n" {
		t.Fatalf("cli list: %d %q", code, out.String())
	}
	if code := Main([]string{"--name", name, "bogus"}); code != 2 {
		t.Fatalf("usage exit = %d", code)
	}

	// A second daemon on a live socket refuses to start.
	d2, _ := New(name)
	d2.Log, d2.ErrLog = logWriter{t}, logWriter{t}
	if err := d2.Listen(); !errors.Is(err, ErrAlreadyRunning) {
		t.Fatalf("second Listen: %v", err)
	}

	// A stale socket file (no listener) is cleared and reused.
	stale, _ := New("t2stale")
	stale.Log, stale.ErrLog = logWriter{t}, logWriter{t}
	// A real dead socket: bind and close without unlinking.
	ul, err := net.ListenUnix("unix", &net.UnixAddr{Name: stale.SocketPath(), Net: "unix"})
	if err != nil {
		t.Fatal(err)
	}
	ul.SetUnlinkOnClose(false)
	ul.Close()
	if err := stale.Listen(); err != nil {
		t.Fatalf("Listen over stale socket: %v", err)
	}
	go stale.Serve()
	if m := control(t, "t2stale", map[string]any{"cmd": "ping"}); m["ok"] != true {
		t.Fatalf("stale daemon ping %v", m)
	}
	stale.Shutdown()
	_ = d
}
