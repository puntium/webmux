package protocol

import (
	"io"
	"net"
	"path/filepath"
	"strings"
	"testing"
	"testing/iotest"
	"time"
)

func TestSocketPath(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("XDG_RUNTIME_DIR", dir)
	for _, ok := range []string{"default", "a.b_c-1", "X", "..", "-"} {
		p, err := SocketPath(ok)
		if err != nil {
			t.Fatalf("SocketPath(%q): %v", ok, err)
		}
		if want := filepath.Join(dir, "webmux", ok+".sock"); p != want {
			t.Fatalf("SocketPath(%q) = %q, want %q", ok, p, want)
		}
	}
	for _, bad := range []string{"", "a/b", "a b", "ä", "a\n", "x:y"} {
		if _, err := SocketPath(bad); err == nil {
			t.Fatalf("SocketPath(%q) accepted", bad)
		} else if !strings.Contains(err.Error(), "invalid pty host name") {
			t.Fatalf("unexpected error %v", err)
		}
	}
	if lp, _ := LogPath("default"); lp != filepath.Join(dir, "webmux", "default.log") {
		t.Fatalf("LogPath = %q", lp)
	}
}

func TestLineReader(t *testing.T) {
	big := strings.Repeat("x", 300000)
	in := "\n{\"a\":1}\n\n{\"b\":\"" + big + "\"}\n{\"c\":3}\npartial"
	// OneByteReader exercises frames split across arbitrary chunk boundaries.
	lr := NewLineReader(iotest.OneByteReader(strings.NewReader(in)))
	want := []string{`{"a":1}`, `{"b":"` + big + `"}`, `{"c":3}`}
	for i, w := range want {
		got, err := lr.Next()
		if err != nil {
			t.Fatalf("line %d: %v", i, err)
		}
		if string(got) != w {
			t.Fatalf("line %d: got %.40q", i, got)
		}
	}
	if _, err := lr.Next(); err != io.EOF {
		t.Fatalf("want EOF, got %v", err)
	}
}

func TestMarshal(t *testing.T) {
	b, _ := Marshal(map[string]any{"type": "output", "data": "<a&b>\x1b"})
	if string(b) != `{"data":"<a&b>\u001b","type":"output"}`+"\n" {
		t.Fatalf("got %q", b)
	}
}

func TestControl(t *testing.T) {
	t.Setenv("XDG_RUNTIME_DIR", t.TempDir())
	sock, _ := SocketPath("t")
	ln, err := net.Listen("unix", sock)
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	go func() {
		c, err := ln.Accept()
		if err != nil {
			return
		}
		defer c.Close()
		line, _ := NewLineReader(c).Next()
		if string(line) == `{"cmd":"ping"}` {
			c.Write([]byte(`{"type":"pong","protocol":1}` + "\n"))
		}
	}()
	reply, err := Control("t", map[string]any{"cmd": "ping"}, time.Second)
	if err != nil {
		t.Fatal(err)
	}
	if reply["type"] != "pong" || reply["protocol"] != float64(1) {
		t.Fatalf("reply %v", reply)
	}
	if _, err := Control("nobody", map[string]any{"cmd": "ping"}, time.Second); err == nil {
		t.Fatal("expected error for missing host")
	}
}
