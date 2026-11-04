# libghostty Go bindings: cheat sheet for the port

Module `go.mitchellh.com/libghostty v0.0.0-20261021212106-df1957cbff56`
(Ghostty `f54340ad77814fe319d136e5e915d6a48de8dd23`). Signatures below are
copied from the bindings source in `$(go env GOMODCACHE)/go.mitchellh.com/libghostty@.../`
(`terminal.go`, `terminal_data.go`, `terminal_opt.go`, `formatter.go`,
`build_info.go`, `point.go`, `kitty_graphics.go`, `mode.go`). Read those
files for anything not listed. `internal/ptyhost/mirror_smoke_test.go` is a
working example of everything here.

## Building / testing

```
./build.sh --libs                  # once: builds host/third_party/ghostty-vt/<triple>
nix develop ./host -c go test ./...  # (from the repo root) native cgo env is preset by the shell
./build.sh --host-only             # host/dist/webmux-host-linux-x64
./build.sh                         # both static binaries
```

The dev shell exports `CGO_ENABLED=1`, `CC="zig cc -target x86_64-linux-musl"`,
`PKG_CONFIG_PATH=<host>/third_party/ghostty-vt/<triple>/share/pkgconfig` and
`GOFLAGS=-tags=osusergo,netgo`. The bindings link via
`#cgo pkg-config: --static libghostty-vt-static` (build tag `dynamic` would
switch to the shared lib; we never use it). Outside that shell, cgo
packages that import libghostty will not build.

## Terminal

```go
func NewTerminal(opts ...TerminalOption) (*Terminal, error) // WithSize is required
func (t *Terminal) Close()                                   // idempotent; frees C state + cgo.Handle

func WithSize(cols, rows uint16) TerminalOption
func WithMaxScrollbackLines(lines uint) TerminalOption       // we use 5000
func WithMaxScrollbackBytes(bytes uint) TerminalOption
func WithTitleChanged(fn TitleChangedFn) TerminalOption
func WithWritePty(fn WritePtyFn) TerminalOption              // NOT used in stage 1 (client answers queries)
func WithResizePullScrollback(enabled bool) TerminalOption   // default true
func WithTitleReport(enabled bool) TerminalOption            // CSI 21 t replies, default off

func (t *Terminal) VTWrite(data []byte)                      // feed pty output; never errors
func (t *Terminal) Write(p []byte) (int, error)              // io.Writer wrapper around VTWrite
func (t *Terminal) VTWriteUntil(data []byte, boundaries TerminalBoundary) (TerminalWriteStop, error)
func (t *Terminal) Resize(cols, rows uint16, cellWidthPx, cellHeightPx uint32) error // 0,0 px is fine
func (t *Terminal) Reset()                                   // RIS; keeps dimensions

func (t *Terminal) Title() (string, error)                   // copied string, "" if unset
func (t *Terminal) Cols() (uint16, error)
func (t *Terminal) Rows() (uint16, error)
func (t *Terminal) CursorX() (uint16, error)                 // 0-indexed, active area
func (t *Terminal) CursorY() (uint16, error)
func (t *Terminal) TotalRows() (uint, error)                 // active screen incl. scrollback
func (t *Terminal) ScrollbackRows() (uint, error)
func (t *Terminal) ActiveScreen() (TerminalScreen, error)    // primary vs alternate
func (t *Terminal) Mode(mode Mode) (bool, error)             // e.g. ModeBracketedPaste
func (t *Terminal) KittyKeyboardFlags() (KittyKeyFlags, error)
func (t *Terminal) SetEffectTitleChanged(fn TitleChangedFn)  // set/clear on a live terminal (nil clears)
```

Callback types:

```go
type TitleChangedFn func(t *Terminal)          // fired on OSC 0 / OSC 2; read the value with t.Title()
type WritePtyFn func(t *Terminal, data []byte) // data valid only during the call
```

Title: the callback carries no value. Call `t.Title()` inside the callback
(a getter, allowed) or right after `VTWrite` returns. Smoke test:
`ESC ] 2 ; hello title BEL` fires the callback once and `Title()` returns
`"hello title"`.

## Thread-safety and callbacks (from the `Terminal` doc comment)

- "stateful, not safe for concurrent use, and not reentrant. Serialize all
  calls that access a terminal", including getters, `Resize`, `Close`, and
  formatters/grid refs derived from it.
- Effect callbacks run synchronously inside `VTWrite`/`Resize`/`Reset` on the
  calling goroutine (they are cgo C→Go callbacks). They must NOT call
  `VTWrite`/`VTWriteUntil` on the same terminal. Getters (`Title()`) are fine.
  Do not block in them (no channel sends that could wait on the owner
  goroutine itself: you ARE the owner goroutine at that point). Record the
  title and broadcast after `VTWrite` returns, or send to a buffered/
  non-blocking fan-out.
- The callback closure keeps Go references; `Close()` releases the
  `cgo.Handle`. Always `Close()` the terminal when the session ends.

## Formatter (the snapshot)

```go
func NewFormatter(t *Terminal, opts ...FormatterOption) (*Formatter, error) // borrows t; t must outlive it
func (f *Formatter) Format() ([]byte, error)          // Go copy of the output
func (f *Formatter) FormatString() (string, error)
func (f *Formatter) FormatBuf(buf []byte) (int, error)
func (f *Formatter) WriteTo(w io.Writer) (int64, error)
func (f *Formatter) Close()

type FormatterFormat int
const FormatterFormatPlain, FormatterFormatVT, FormatterFormatHTML  // default Plain!

func WithFormatterFormat(f FormatterFormat) FormatterOption
func WithFormatterTrim(trim bool) FormatterOption      // trailing whitespace; VT+trim=false keeps blank rows
func WithFormatterUnwrap(unwrap bool) FormatterOption
func WithFormatterSelection(sel *Selection) FormatterOption // nil = entire active screen (incl. history)
func WithFormatterExtraModes(v bool) FormatterOption   // CSI h/l for non-default modes
func WithFormatterExtraCursor(v bool) FormatterOption  // final CUP
func WithFormatterExtraStyle(v bool) FormatterOption   // current SGR
func WithFormatterExtraHyperlink(v bool) FormatterOption
func WithFormatterExtraScrollingRegion(v bool) FormatterOption
func WithFormatterExtraKittyKeyboard(v bool) FormatterOption
func WithFormatterExtraKeyboard(v bool) FormatterOption   // modifyOtherKeys
func WithFormatterExtraPalette(v bool) FormatterOption    // OSC 4
func WithFormatterExtraTabstops(v bool) FormatterOption
func WithFormatterExtraPwd(v bool) FormatterOption        // OSC 7
func WithFormatterExtraProtection(v bool) FormatterOption // DECSCA
func WithFormatterExtraCharsets(v bool) FormatterOption
```

A formatter reads the terminal's current state on every `Format()` call, so
one formatter per session can be kept and reused (still serialized with the
terminal).

Snapshot recipe (doc's extras), verified in the smoke test:

```go
f, _ := libghostty.NewFormatter(term,
    libghostty.WithFormatterFormat(libghostty.FormatterFormatVT),
    libghostty.WithFormatterExtraModes(true),
    libghostty.WithFormatterExtraCursor(true),
    libghostty.WithFormatterExtraStyle(true),
    libghostty.WithFormatterExtraHyperlink(true),
    libghostty.WithFormatterExtraScrollingRegion(true),
    libghostty.WithFormatterExtraKittyKeyboard(true))
data, _ := f.Format()
```

Findings (80x24, 5000 lines scrollback, 200 lines + a styled prompt):
- With NO selection the VT output already includes the full scrollback:
  201 lines, starts at `line 1`, rows joined with `\r\n`; an explicit
  history→end selection produces byte-identical output. No selection needed.
- Output starts with the mode extras (`ESC[?2004h`), ends with
  `ESC[24;13H ESC[0m` (cursor CUP relative to the active area, then style).
  Replaying it into a fresh 80x24 terminal reproduces the plain text, cursor
  and bracketed-paste mode exactly.
- Colors are emitted as `ESC[38;5;1m` (palette index), not `ESC[31m`.
- The title is NOT in the output (send it in the snapshot frame, as today).
- ALTERNATE SCREEN: while an app is on the alt screen the formatter emits
  only `ESC[?1049h` + the alt screen; the primary screen's scrollback is NOT
  included (xterm's SerializeAddon emits primary + `?1049h` + alt). There is
  no formatter option to pick the screen.

## Selections / points (only if you need them)

```go
type Point struct { Tag PointTag; X uint16; Y uint32 }
const PointTagActive, PointTagViewport, PointTagScreen, PointTagHistory
func (t *Terminal) GridRef(point Point) (*GridRef, error)  // borrowed; invalid after next mutation
type Selection struct { Start GridRef; End GridRef; Rectangle bool }
```

## Build info

```go
func GetBuildInfo() (BuildInfo, error)
type BuildInfo struct {
    SIMD, KittyGraphics, TmuxControlMode bool
    Optimize OptimizeMode // OptimizeDebug | OptimizeReleaseSafe | OptimizeReleaseSmall | OptimizeReleaseFast
    VersionString string; VersionMajor, VersionMinor, VersionPatch uint; VersionPre, VersionBuild string
}
```

Current build: `libghostty-vt 0.1.0-dev optimize=release-fast simd=true kitty-graphics=true tmux-control=false`.

## Errors

Fallible calls return `*libghostty.Error` (`result.go`, has `.Result`, works
with `errors.Is`).
