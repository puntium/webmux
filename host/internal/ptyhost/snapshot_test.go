package ptyhost

import (
	"bytes"
	"fmt"
	"testing"

	"go.mitchellh.com/libghostty"
)

func plainText(t *testing.T, term *libghostty.Terminal) []byte {
	t.Helper()
	return format(t, term, libghostty.WithFormatterFormat(libghostty.FormatterFormatPlain))
}

func cursorOf(t *testing.T, term *libghostty.Terminal) [2]uint16 {
	t.Helper()
	x, _ := term.CursorX()
	y, _ := term.CursorY()
	return [2]uint16{x, y}
}

var checkedModes = []libghostty.Mode{
	libghostty.ModeBracketedPaste, libghostty.ModeCursorVisible, libghostty.ModeDECCKM,
	libghostty.ModeSGRMouse, libghostty.ModeButtonMouse, libghostty.ModeAltScreenSave,
	libghostty.ModeAltScreen, libghostty.ModeAltScreenLegacy, libghostty.ModeFocusEvent,
}

func modesOf(t *testing.T, term *libghostty.Terminal) []bool {
	t.Helper()
	var out []bool
	for _, m := range checkedModes {
		v, err := term.Mode(m)
		if err != nil {
			t.Fatalf("Mode: %v", err)
		}
		out = append(out, v)
	}
	return out
}

// TestSnapshotPrimary: the snapshot of a primary-screen session replays to
// the same text (incl. scrollback), cursor and modes.
func TestSnapshotPrimary(t *testing.T) {
	term := newMirror(t)
	var in bytes.Buffer
	for i := 1; i <= 200; i++ {
		fmt.Fprintf(&in, "line %d\r\n", i)
	}
	in.WriteString("\x1b[?2004h\x1b[1;32mgreen\x1b[0m $ ")
	term.Write(in.Bytes())
	snap, err := snapshot(term)
	if err != nil {
		t.Fatal(err)
	}
	t.Logf("snapshot %d bytes", len(snap))
	replay := newMirror(t)
	replay.Write(snap)
	if !bytes.Equal(plainText(t, replay), plainText(t, term)) {
		t.Errorf("plain text differs")
	}
	if cursorOf(t, replay) != cursorOf(t, term) {
		t.Errorf("cursor differs")
	}
	if fmt.Sprint(modesOf(t, replay)) != fmt.Sprint(modesOf(t, term)) {
		t.Errorf("modes differ")
	}
}

// TestSnapshotAltScreen proves the alt-screen snapshot (primary from a
// clone, ?1049h, alt) restores BOTH screens: replayed into a fresh terminal,
// the alt screen, its cursor and the modes match the mirror; after both then
// leave the alt screen (?1049l), the primary screen with its scrollback and
// the restored cursor match too. It also proves the live mirror is not
// modified by taking the snapshot.
func TestSnapshotAltScreen(t *testing.T) {
	for _, enter := range []string{"\x1b[?1049h", "\x1b[?1047h", "\x1b[?47h"} {
		t.Run(fmt.Sprintf("%q", enter), func(t *testing.T) {
			term := newMirror(t)
			var in bytes.Buffer
			for i := 1; i <= 100; i++ {
				fmt.Fprintf(&in, "primary %d\r\n", i)
			}
			in.WriteString("\x1b[31mprompt$ vim")
			in.WriteString(enter)
			in.WriteString("\x1b[?2004h\x1b[?1h\x1b[?1002h\x1b[?1006h\x1b[?25l\x1b[H\x1b[2J")
			for i := 1; i <= 23; i++ {
				fmt.Fprintf(&in, "\x1b[%d;1H\x1b[34m~\x1b[0m alt row %d", i, i)
			}
			in.WriteString("\x1b[24;1H\x1b[7m-- INSERT --\x1b[0m\x1b[5;12H\x1b[1m")
			term.Write(in.Bytes())

			before := plainText(t, term)
			beforeCur := cursorOf(t, term)
			beforeModes := modesOf(t, term)

			snap, err := snapshot(term)
			if err != nil {
				t.Fatal(err)
			}
			// The live mirror is untouched.
			if !bytes.Equal(plainText(t, term), before) || cursorOf(t, term) != beforeCur ||
				fmt.Sprint(modesOf(t, term)) != fmt.Sprint(beforeModes) {
				t.Fatalf("snapshot modified the live mirror")
			}
			if again, _ := snapshot(term); !bytes.Equal(again, snap) {
				t.Fatalf("snapshot not repeatable")
			}
			if !bytes.Contains(snap, []byte("primary 1\r\n")) {
				t.Fatalf("primary scrollback missing from alt-screen snapshot")
			}
			if bytes.Count(snap, []byte("\x1b[?1049h")) != 1 {
				t.Fatalf("want exactly one ?1049h, snapshot: %q", head(snap, 300))
			}

			replay := newMirror(t)
			replay.Write(snap)
			if s, _ := replay.ActiveScreen(); s != libghostty.ScreenAlternate {
				t.Fatalf("replay not on alt screen")
			}
			if got := plainText(t, replay); !bytes.Equal(got, before) {
				t.Errorf("alt text differs:\n%q\nvs\n%q", got, before)
			}
			if cursorOf(t, replay) != beforeCur {
				t.Errorf("alt cursor %v vs %v", cursorOf(t, replay), beforeCur)
			}
			// Mode flags: the replay always enters via 1049 (as xterm's
			// SerializeAddon does), so compare everything but the alt flags.
			rm, om := modesOf(t, replay), beforeModes
			for i, m := range checkedModes {
				if m == libghostty.ModeAltScreenSave || m == libghostty.ModeAltScreen || m == libghostty.ModeAltScreenLegacy {
					continue
				}
				if rm[i] != om[i] {
					t.Errorf("mode %d: replay %v mirror %v", m.Value(), rm[i], om[i])
				}
			}

			// Leave the alt screen the way the app would and compare the
			// primary screens.
			exit := map[string]string{"\x1b[?1049h": "\x1b[?1049l", "\x1b[?1047h": "\x1b[?1047l", "\x1b[?47h": "\x1b[?47l"}[enter]
			term.Write([]byte(exit))
			replay.Write([]byte("\x1b[?1049l"))
			p1, p2 := plainText(t, term), plainText(t, replay)
			if !bytes.Equal(p1, p2) {
				t.Errorf("primary differs after exit:\n%q\nvs\n%q", tail(p2, 200), tail(p1, 200))
			}
			if enter == "\x1b[?1049h" && cursorOf(t, term) != cursorOf(t, replay) {
				t.Errorf("restored primary cursor %v vs %v", cursorOf(t, replay), cursorOf(t, term))
			}
			// Text written after exit lands with the same pen/position.
			term.Write([]byte("after"))
			replay.Write([]byte("after"))
			if !bytes.Equal(format(t, term, snapshotOpts()...), format(t, replay, snapshotOpts()...)) && enter == "\x1b[?1049h" {
				t.Errorf("VT state differs after exit+write")
			}
		})
	}
}
