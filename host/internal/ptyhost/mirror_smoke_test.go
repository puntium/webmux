package ptyhost

// Smoke test for the libghostty mirror (toolchain engineer). It proves the
// bindings link and documents the snapshot behavior the pty host relies on.
// Keep it; extend it as the mirror grows.

import (
	"bytes"
	"fmt"
	"strings"
	"testing"

	"go.mitchellh.com/libghostty"
)

func newMirror(t *testing.T, opts ...libghostty.TerminalOption) *libghostty.Terminal {
	t.Helper()
	base := []libghostty.TerminalOption{
		libghostty.WithSize(80, 24),
		libghostty.WithMaxScrollbackLines(5000),
	}
	term, err := libghostty.NewTerminal(append(base, opts...)...)
	if err != nil {
		t.Fatalf("NewTerminal: %v", err)
	}
	t.Cleanup(term.Close)
	return term
}

func snapshotOpts() []libghostty.FormatterOption {
	return []libghostty.FormatterOption{
		libghostty.WithFormatterFormat(libghostty.FormatterFormatVT),
		libghostty.WithFormatterExtraModes(true),
		libghostty.WithFormatterExtraCursor(true),
		libghostty.WithFormatterExtraStyle(true),
		libghostty.WithFormatterExtraHyperlink(true),
		libghostty.WithFormatterExtraScrollingRegion(true),
		libghostty.WithFormatterExtraKittyKeyboard(true),
	}
}

func format(t *testing.T, term *libghostty.Terminal, opts ...libghostty.FormatterOption) []byte {
	t.Helper()
	f, err := libghostty.NewFormatter(term, opts...)
	if err != nil {
		t.Fatalf("NewFormatter: %v", err)
	}
	defer f.Close()
	out, err := f.Format()
	if err != nil {
		t.Fatalf("Format: %v", err)
	}
	return out
}

func countLines(b []byte) int { return bytes.Count(b, []byte("\n")) + 1 }

func TestMirrorSmoke(t *testing.T) {
	var titles []string
	term := newMirror(t, libghostty.WithTitleChanged(func(tt *libghostty.Terminal) {
		s, err := tt.Title() // read the new title inside (or after) the callback
		if err != nil {
			t.Errorf("Title: %v", err)
		}
		titles = append(titles, s)
	}))

	var in bytes.Buffer
	for i := 1; i <= 200; i++ {
		fmt.Fprintf(&in, "line %d\r\n", i)
	}
	in.WriteString("\x1b]2;hello title\x07")
	in.WriteString("\x1b[?2004h\x1b[31mred\x1b[0m prompt$ ")
	if _, err := term.Write(in.Bytes()); err != nil {
		t.Fatal(err)
	}

	total, _ := term.TotalRows()
	sb, _ := term.ScrollbackRows()
	t.Logf("TotalRows=%d ScrollbackRows=%d titles=%q", total, sb, titles)
	if len(titles) != 1 || titles[0] != "hello title" {
		t.Errorf("title callback: got %q", titles)
	}

	// 1. Default formatter (no selection).
	def := format(t, term, snapshotOpts()...)
	hasFirst := bytes.Contains(def, []byte("line 1\r\n")) || bytes.Contains(def, []byte("line 1\n"))
	t.Logf("VT default: %d bytes, %d lines, contains 'line 1' (history): %v, contains 'line 200': %v",
		len(def), countLines(def), hasFirst, bytes.Contains(def, []byte("line 200")))
	t.Logf("VT default head: %q", head(def, 200))
	t.Logf("VT default tail: %q", tail(def, 200))

	// 2. Explicit selection covering screen (history + active) start→end.
	cols, _ := term.Cols()
	start, err := term.GridRef(libghostty.Point{Tag: libghostty.PointTagScreen, X: 0, Y: 0})
	if err != nil {
		t.Fatalf("GridRef start: %v", err)
	}
	end, err := term.GridRef(libghostty.Point{Tag: libghostty.PointTagScreen, X: cols - 1, Y: uint32(total - 1)})
	if err != nil {
		t.Fatalf("GridRef end: %v", err)
	}
	sel := &libghostty.Selection{Start: *start, End: *end}
	withSel := format(t, term, append(snapshotOpts(), libghostty.WithFormatterSelection(sel))...)
	t.Logf("VT with screen selection: %d bytes, %d lines, contains 'line 1': %v",
		len(withSel), countLines(withSel), bytes.Contains(withSel, []byte("line 1\r")) || bytes.Contains(withSel, []byte("line 1\n")))

	// 3. Plain, for a readable line count.
	plain := format(t, term, libghostty.WithFormatterFormat(libghostty.FormatterFormatPlain))
	t.Logf("Plain default: %d lines, first line %q", countLines(plain), strings.SplitN(string(plain), "\n", 2)[0])

	if !bytes.Contains(def, []byte("\x1b[38;5;1mred\x1b[0m prompt$ ")) {
		t.Errorf("styled prompt missing from VT snapshot")
	}
	if !hasFirst {
		t.Errorf("default VT snapshot does not include scrollback history")
	}

	// 4. Round trip: replay the snapshot into a fresh terminal and compare plain text.
	replay := newMirror(t)
	replay.Write(def)
	rp := format(t, replay, libghostty.WithFormatterFormat(libghostty.FormatterFormatPlain))
	if !bytes.Equal(rp, plain) {
		t.Errorf("replayed plain text differs: %d vs %d bytes\n%q", len(rp), len(plain), tail(rp, 200))
	}
	x0, _ := term.CursorX()
	y0, _ := term.CursorY()
	x1, _ := replay.CursorX()
	y1, _ := replay.CursorY()
	t.Logf("cursor original=(%d,%d) replay=(%d,%d)", x0, y0, x1, y1)
	if x0 != x1 || y0 != y1 {
		t.Errorf("cursor mismatch after replay")
	}
	bp, _ := replay.Mode(libghostty.ModeBracketedPaste)
	t.Logf("bracketed paste restored by ExtraModes: %v", bp)
}

func head(b []byte, n int) []byte {
	if len(b) < n {
		return b
	}
	return b[:n]
}

func tail(b []byte, n int) []byte {
	if len(b) < n {
		return b
	}
	return b[len(b)-n:]
}

// TestMirrorAltScreen documents what the default formatter does while a
// full-screen app (vim, less) is on the alternate screen.
func TestMirrorAltScreen(t *testing.T) {
	term := newMirror(t)
	var in bytes.Buffer
	for i := 1; i <= 50; i++ {
		fmt.Fprintf(&in, "primary %d\r\n", i)
	}
	in.WriteString("\x1b[?1049h\x1b[HALT SCREEN")
	term.Write(in.Bytes())
	out := format(t, term, snapshotOpts()...)
	t.Logf("alt: %d bytes, has primary history: %v, has alt text: %v, has ?1049h: %v",
		len(out), bytes.Contains(out, []byte("primary 1\r")), bytes.Contains(out, []byte("ALT SCREEN")),
		bytes.Contains(out, []byte("\x1b[?1049h")))
	t.Logf("alt head: %q", head(out, 120))
}

func TestMirrorResize(t *testing.T) {
	term := newMirror(t)
	if err := term.Resize(100, 30, 0, 0); err != nil { // pixel sizes unknown: 0 is accepted
		t.Fatalf("Resize: %v", err)
	}
	c, _ := term.Cols()
	r, _ := term.Rows()
	if c != 100 || r != 30 {
		t.Fatalf("size after resize = %dx%d", c, r)
	}
	term.Reset()
}
