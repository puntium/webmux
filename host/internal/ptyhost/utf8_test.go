package ptyhost

import (
	"encoding/json"
	"net"
	"strings"
	"testing"
	"unicode/utf8"

	"go.mitchellh.com/libghostty"
	"webmux/host/internal/protocol"
)

func TestSplitUTF8(t *testing.T) {
	cases := []struct{ in, complete, tail string }{
		{"", "", ""},
		{"abc", "abc", ""},
		{"a€", "a€", ""},
		{"a\xe2", "a", "\xe2"},
		{"a\xe2\x82", "a", "\xe2\x82"},
		{"\xf0\x9f\x98", "", "\xf0\x9f\x98"},
		{"x\xf0\x9f", "x", "\xf0\x9f"},
		{"x😀", "x😀", ""},
		{"bad\x82", "bad\x82", ""}, // stray continuation: complete (invalid)
		{"bad\xff", "bad\xff", ""}, // invalid byte: complete
		{"\x82\x82\x82\x82", "\x82\x82\x82\x82", ""},
		{"\xe2a", "\xe2a", ""}, // broken sequence followed by ASCII: nothing to wait for
	}
	for _, c := range cases {
		gc, gt := splitUTF8([]byte(c.in))
		if string(gc) != c.complete || string(gt) != c.tail {
			t.Errorf("splitUTF8(%q) = %q, %q; want %q, %q", c.in, gc, gt, c.complete, c.tail)
		}
	}
}

// TestUTF8StreamEverySplit feeds a mixed string split at every byte offset
// (and byte by byte) and checks the concatenated output is the original and
// every emitted piece is valid UTF-8.
func TestUTF8StreamEverySplit(t *testing.T) {
	src := "a€b😀cé—z"
	for cut := 0; cut <= len(src); cut++ {
		var u utf8Stream
		got := u.push([]byte(src[:cut]))
		got2 := u.push([]byte(src[cut:]))
		if !utf8.ValidString(got) || !utf8.ValidString(got2) || got+got2+u.flush() != src {
			t.Errorf("cut %d: %q + %q", cut, got, got2)
		}
	}
	var u utf8Stream
	var all strings.Builder
	for i := 0; i < len(src); i++ {
		p := u.push([]byte{src[i]})
		if !utf8.ValidString(p) {
			t.Fatalf("invalid piece %q", p)
		}
		all.WriteString(p)
	}
	if all.String() != src {
		t.Fatalf("byte-by-byte = %q", all.String())
	}
	// An incomplete tail at end of stream is flushed (U+FFFD once encoded).
	u = utf8Stream{}
	if p := u.push([]byte("x\xe2\x82")); p != "x" || u.flush() != "\xe2\x82" {
		t.Fatalf("flush")
	}
}

// TestSessionOutputSplitChar drives the real session output path (mirror
// write + output frame) with a 3-byte character split across two pty reads:
// the client gets intact text, and the mirror got the raw bytes at once.
func TestSessionOutputSplitChar(t *testing.T) {
	term := newMirror(t)
	s := &Session{id: "x", d: &Daemon{}, term: term, clients: map[*client]struct{}{}}
	a, b := net.Pipe()
	defer a.Close()
	c := newClient(b)
	defer c.kill()
	s.clients[c] = struct{}{}

	frames := make(chan string, 8)
	go func() {
		lr := protocol.NewLineReader(a)
		for {
			line, err := lr.Next()
			if err != nil {
				close(frames)
				return
			}
			var m map[string]any
			json.Unmarshal(line, &m)
			frames <- m["data"].(string)
		}
	}()

	euro := "€" // e2 82 ac
	s.output([]byte("price: " + euro[:1]))
	if got := <-frames; got != "price: " {
		t.Fatalf("first frame %q", got)
	}
	// The mirror has the lead byte already; the cell is not complete yet.
	s.output([]byte(euro[1:] + "5"))
	if got := <-frames; got != "€5" {
		t.Fatalf("second frame %q", got)
	}
	plain := format(t, term, libghostty.WithFormatterFormat(libghostty.FormatterFormatPlain))
	if !strings.Contains(string(plain), "price: €5") {
		t.Fatalf("mirror text %q", plain)
	}
	// A chunk that is only a partial character produces no frame at all.
	s.output([]byte("\xf0\x9f"))
	s.output([]byte("\x98\x80!"))
	if got := <-frames; got != "😀!" {
		t.Fatalf("emoji frame %q", got)
	}
}
