// Command webmux-host is the native webmux server payload: pty host daemon,
// HTTP/WS server and remote starter in one static binary. This file only
// dispatches subcommands; see docs/native-host.md.
package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"go.mitchellh.com/libghostty"

	"webmux/host/internal/ptyhost"
	"webmux/host/internal/server"
	"webmux/host/internal/start"
)

const usage = `usage:
  webmux-host ptyhost [--name X] [ping|list|shutdown]
  webmux-host serve
  webmux-host start [--name X]
  webmux-host version
`

func main() {
	if len(os.Args) < 2 {
		fmt.Fprint(os.Stderr, usage)
		os.Exit(2)
	}
	args := os.Args[2:]
	switch os.Args[1] {
	case "ptyhost":
		os.Exit(ptyhost.Main(args))
	case "serve":
		os.Exit(server.Main(args))
	case "start":
		os.Exit(start.Main(args))
	case "version", "--version", "-v":
		os.Exit(version())
	case "help", "--help", "-h":
		fmt.Print(usage)
	default:
		fmt.Fprintf(os.Stderr, "webmux-host: unknown command %q\n%s", os.Args[1], usage)
		os.Exit(2)
	}
}

// payloadHash reads PAYLOAD_HASH next to the executable, else "dev".
func payloadHash() string {
	exe, err := os.Executable()
	if err != nil {
		return "dev"
	}
	if r, err := filepath.EvalSymlinks(exe); err == nil {
		exe = r
	}
	b, err := os.ReadFile(filepath.Join(filepath.Dir(exe), "PAYLOAD_HASH"))
	if err != nil {
		return "dev"
	}
	if h := strings.TrimSpace(string(b)); h != "" {
		return h
	}
	return "dev"
}

func version() int {
	fmt.Println(payloadHash())
	bi, err := libghostty.GetBuildInfo()
	if err != nil {
		fmt.Fprintln(os.Stderr, "libghostty build info:", err)
		return 1
	}
	opt := map[libghostty.OptimizeMode]string{
		libghostty.OptimizeDebug:        "debug",
		libghostty.OptimizeReleaseSafe:  "release-safe",
		libghostty.OptimizeReleaseSmall: "release-small",
		libghostty.OptimizeReleaseFast:  "release-fast",
	}[bi.Optimize]
	fmt.Printf("libghostty-vt %s optimize=%s simd=%v kitty-graphics=%v tmux-control=%v\n",
		bi.VersionString, opt, bi.SIMD, bi.KittyGraphics, bi.TmuxControlMode)
	return 0
}
