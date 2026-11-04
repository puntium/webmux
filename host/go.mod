module webmux/host

go 1.26.0

// Pins: go.mitchellh.com/libghostty must reference the same Ghostty commit as
// GHOSTTY_COMMIT in build.sh (its CMakeLists.txt GIT_TAG). Bump them together.
// Do not run `go mod tidy` during the build-out (see docs/native-host.md).
require (
	github.com/coder/websocket v1.8.15
	github.com/creack/pty v1.1.24
	github.com/fsnotify/fsnotify v1.10.1
	github.com/google/uuid v1.6.0
	go.mitchellh.com/libghostty v0.0.0-20261021212106-df1957cbff56
)

require golang.org/x/sys v0.13.0 // indirect
