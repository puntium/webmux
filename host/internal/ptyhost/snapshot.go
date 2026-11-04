package ptyhost

import (
	"bytes"
	"regexp"

	"go.mitchellh.com/libghostty"
)

// snapshotFormatterOpts is the reattach snapshot recipe: VT output with the
// state extras the xterm SerializeAddon also restores (modes, cursor, pen,
// hyperlink, scrolling region) plus the Kitty keyboard flags, untrimmed. With
// no selection the formatter covers the whole active screen INCLUDING its
// scrollback (see mirror_smoke_test.go), so no selection is needed.
func snapshotFormatterOpts() []libghostty.FormatterOption {
	return []libghostty.FormatterOption{
		libghostty.WithFormatterFormat(libghostty.FormatterFormatVT),
		libghostty.WithFormatterTrim(false),
		libghostty.WithFormatterExtraModes(true),
		libghostty.WithFormatterExtraCursor(true),
		libghostty.WithFormatterExtraStyle(true),
		libghostty.WithFormatterExtraHyperlink(true),
		libghostty.WithFormatterExtraScrollingRegion(true),
		libghostty.WithFormatterExtraKittyKeyboard(true),
	}
}

func formatTerminal(t *libghostty.Terminal) ([]byte, error) {
	f, err := libghostty.NewFormatter(t, snapshotFormatterOpts()...)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	return f.Format()
}

// leadingModes matches the run of mode sequences (CSI [?] Pn h|l) the
// formatter's ExtraModes emits before any screen content. Screen content
// itself never starts with an h/l-final CSI (it uses SGR, CUF, CRLF, OSC 8).
var leadingModes = regexp.MustCompile(`^(?:\x1b\[\??[0-9]+[hl])*`)

// altSeparator sits between the primary and alternate parts of an
// alternate-screen snapshot. ?1049h on replay saves the primary cursor (the
// one the primary part ended with: the cursor the app will restore on exit)
// and switches to a cleared alt screen; xterm's SerializeAddon emits the
// same `?1049h ESC[H`. The formatter's alt content is relative to the
// top-left (it begins with CRLFs, not a CUP), hence the home; the SGR reset
// and the hyperlink close keep the primary part's trailing pen/link from
// bleeding into the first unstyled alt cells (the alt part re-emits its own
// pen and link at its end).
const altSeparator = "\x1b[?1049h\x1b[H\x1b[0m\x1b]8;;\x1b\\"

// snapshot serializes the mirror for a reattaching client
// (`term.reset(); term.write(data)` on the xterm.js side). Must run on the
// session's owner goroutine.
//
// Primary screen: the formatter output as is.
//
// Alternate screen: libghostty's formatter only ever formats the ACTIVE
// screen (formatter.zig: "If you want to emit data for a specific screen
// switch to that screen in the terminal prior to using this"), which would
// drop the primary screen and its scrollback while vim/less is up; xterm's
// SerializeAddon emits primary, then `?1049h`, then alt. Switching the live
// mirror with ?47l/?47h is NOT sound (mode 47 copies the cursor between the
// screens, ends the alt cursor's hyperlink and leaves the 47 mode flag set),
// so instead the primary is formatted from a disposable CLONE: the mirror is
// encoded with libghostty's binary snapshot, decoded into a fresh Terminal
// (no effect callbacks, so nothing can reach the pty), the clone leaves the
// alt screen exactly as the app eventually will (?1049l restores the saved
// cursor; 1047/47 are left with their own resets), and its primary screen is
// formatted. The live mirror is only read. The alt part is the live mirror's
// own output with its leading ?1049h removed (the separator already entered
// the alt screen; a second ?1049h would re-save the cursor at home).
func snapshot(t *libghostty.Terminal) ([]byte, error) {
	scr, err := t.ActiveScreen()
	if err != nil || scr != libghostty.ScreenAlternate {
		return formatTerminal(t)
	}
	alt, err := formatTerminal(t)
	if err != nil {
		return nil, err
	}
	primary, err := formatPrimaryFromClone(t)
	if err != nil {
		// Degrade to xterm-less fidelity rather than failing the attach:
		// the alt screen alone (what the app is showing) is still correct.
		return alt, nil
	}
	modes := leadingModes.Find(alt)
	rest := alt[len(modes):]
	modes = bytes.ReplaceAll(modes, []byte("\x1b[?1049h"), nil)
	out := make([]byte, 0, len(primary)+len(altSeparator)+len(alt))
	out = append(out, primary...)
	out = append(out, altSeparator...)
	out = append(out, modes...)
	out = append(out, rest...)
	return out, nil
}

func formatPrimaryFromClone(t *libghostty.Terminal) ([]byte, error) {
	enc, err := t.Snapshot()
	if err != nil {
		return nil, err
	}
	dec, err := libghostty.NewSnapshotDecoderBytes(enc)
	if err != nil {
		return nil, err
	}
	clone, err := dec.Decode()
	dec.Close()
	if err != nil {
		return nil, err
	}
	defer clone.Close()
	var exit []byte
	if on, _ := clone.Mode(libghostty.ModeAltScreenSave); on {
		exit = append(exit, "\x1b[?1049l"...)
	}
	if on, _ := clone.Mode(libghostty.ModeAltScreen); on {
		exit = append(exit, "\x1b[?1047l"...)
	}
	if on, _ := clone.Mode(libghostty.ModeAltScreenLegacy); on {
		exit = append(exit, "\x1b[?47l"...)
	}
	if len(exit) == 0 { // on the alt screen with no alt mode set: should not happen
		exit = []byte("\x1b[?47l")
	}
	clone.VTWrite(exit)
	if scr, err := clone.ActiveScreen(); err != nil || scr != libghostty.ScreenPrimary {
		return nil, errNotPrimary
	}
	return formatTerminal(clone)
}

type snapshotError string

func (e snapshotError) Error() string { return string(e) }

const errNotPrimary = snapshotError("clone did not return to the primary screen")
