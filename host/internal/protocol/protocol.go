// Package protocol is the Go port of ptyhost-client.js: pty-host socket
// naming, newline-delimited JSON framing, one-shot control commands and
// spawn-on-demand. It is shared by the server, the pty host and the starter,
// and must stay free of pty/libghostty imports.
package protocol

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"regexp"
	"syscall"
	"time"
)

// DefaultName is the pty host instance name used when none is given.
const DefaultName = "default"

// Protocol is the pty-host control protocol version. Version 1 keeps the
// historical unversioned socket name; versions > 1 add a ".v<N>" suffix so a
// newer server spawns a fresh host beside an old one. Keep in sync with
// ptyhost-client.js.
const Protocol = 1

// DefaultTimeout is Control's reply timeout when none is given (as in JS).
const DefaultTimeout = 5 * time.Second

var validName = regexp.MustCompile(`^[A-Za-z0-9._-]+$`)

// ValidateName reports whether name is an acceptable pty host name.
func ValidateName(name string) error {
	if !validName.MatchString(name) {
		return fmt.Errorf("invalid pty host name '%s' (allowed: letters, digits, . _ -)", name)
	}
	return nil
}

// Username returns the current user's login name (os.userInfo().username).
func Username() string {
	if u, err := user.Current(); err == nil && u.Username != "" {
		return u.Username
	}
	if u := os.Getenv("USER"); u != "" {
		return u
	}
	return fmt.Sprint(os.Getuid())
}

// RunDir returns the private runtime dir holding the sockets and logs,
// creating it (mode 0700) if needed: $XDG_RUNTIME_DIR/webmux, else
// $TMPDIR/webmux-<user>.
func RunDir() (string, error) {
	var dir string
	if x := os.Getenv("XDG_RUNTIME_DIR"); x != "" {
		dir = filepath.Join(x, "webmux")
	} else {
		dir = filepath.Join(os.TempDir(), "webmux-"+Username())
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return "", err
	}
	return dir, nil
}

// SocketPath returns the unix socket path of the named pty host.
func SocketPath(name string) (string, error) {
	if err := ValidateName(name); err != nil {
		return "", err
	}
	dir, err := RunDir()
	if err != nil {
		return "", err
	}
	suffix := ""
	if Protocol > 1 {
		suffix = fmt.Sprintf(".v%d", Protocol)
	}
	return filepath.Join(dir, name+suffix+".sock"), nil
}

// LogPath returns the log file the spawned pty host writes to.
func LogPath(name string) (string, error) {
	dir, err := RunDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, name+".log"), nil
}

// LineReader splits a byte stream into newline-delimited frames. Frames are
// returned raw (without the newline) so they can be forwarded verbatim;
// empty lines are skipped, like readLines in ptyhost-client.js. There is no
// line length limit (snapshots can be many MB).
type LineReader struct {
	r *bufio.Reader
}

// NewLineReader wraps r (typically a net.Conn).
func NewLineReader(r io.Reader) *LineReader {
	return &LineReader{r: bufio.NewReaderSize(r, 64*1024)}
}

// Next returns the next non-empty line. The returned slice is owned by the
// caller. At end of stream it returns io.EOF; an unterminated trailing
// fragment is discarded, as the JS reader does.
func (l *LineReader) Next() ([]byte, error) {
	for {
		line, err := l.r.ReadBytes('\n')
		if err != nil {
			if errors.Is(err, io.EOF) {
				return nil, io.EOF
			}
			return nil, err
		}
		line = line[:len(line)-1]
		if len(line) > 0 {
			return line, nil
		}
	}
}

// Marshal encodes v as one frame: JSON followed by '\n'. HTML escaping is
// disabled so output matches JSON.stringify more closely ('<' stays '<').
func Marshal(v any) ([]byte, error) {
	var b bytes.Buffer
	enc := json.NewEncoder(&b)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(v); err != nil {
		return nil, err
	}
	return b.Bytes(), nil
}

// WriteFrame marshals v and writes it with a single Write call. Callers that
// write to the same conn from several goroutines must still serialize.
func WriteFrame(w io.Writer, v any) error {
	b, err := Marshal(v)
	if err != nil {
		return err
	}
	_, err = w.Write(b)
	return err
}

// WriteLine writes an already-encoded frame (e.g. one returned by
// LineReader.Next) followed by '\n', in a single Write call.
func WriteLine(w io.Writer, line []byte) error {
	buf := make([]byte, 0, len(line)+1)
	buf = append(append(buf, line...), '\n')
	_, err := w.Write(buf)
	return err
}

// Connect dials the named pty host's socket.
func Connect(name string) (net.Conn, error) {
	p, err := SocketPath(name)
	if err != nil {
		return nil, err
	}
	return net.Dial("unix", p)
}

// Control sends one command and returns the single JSON reply. JSON numbers
// decode as float64. timeout <= 0 means DefaultTimeout.
func Control(name string, msg any, timeout time.Duration) (map[string]any, error) {
	if timeout <= 0 {
		timeout = DefaultTimeout
	}
	conn, err := Connect(name)
	if err != nil {
		return nil, err
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(timeout))
	if err := WriteFrame(conn, msg); err != nil {
		return nil, err
	}
	line, err := NewLineReader(conn).Next()
	if err != nil {
		var ne net.Error
		if errors.As(err, &ne) && ne.Timeout() {
			return nil, fmt.Errorf("pty host '%s': timed out waiting for reply", name)
		}
		return nil, err
	}
	var reply map[string]any
	if err := json.Unmarshal(line, &reply); err != nil {
		return nil, err
	}
	return reply, nil
}

// EnsureHost pings the named host, spawning `<this executable> ptyhost
// --name <name>` if it is not running. The daemon runs in its own session
// (setsid) with stdin from /dev/null and stdout/stderr appended to
// LogPath(name), so it outlives this process. Polls ping for up to 5 s.
func EnsureHost(name string) (map[string]any, error) {
	ping := map[string]any{"cmd": "ping"}
	if pong, err := Control(name, ping, 0); err == nil {
		return pong, nil
	}
	sock, err := SocketPath(name)
	if err != nil {
		return nil, err
	}
	_ = os.Remove(sock) // stale socket from a dead host
	logPath, err := LogPath(name)
	if err != nil {
		return nil, err
	}
	exe, err := os.Executable()
	if err != nil {
		return nil, err
	}
	log, err := os.OpenFile(logPath, os.O_WRONLY|os.O_CREATE|os.O_APPEND, 0o644)
	if err != nil {
		return nil, err
	}
	cmd := exec.Command(exe, "ptyhost", "--name", name)
	cmd.Stdin = nil // /dev/null
	cmd.Stdout = log
	cmd.Stderr = log
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	err = cmd.Start()
	log.Close()
	if err != nil {
		return nil, err
	}
	// Reap the child if it ever exits while we are alive (no zombies).
	go func() { _ = cmd.Wait() }()
	for i := 0; i < 50; i++ {
		time.Sleep(100 * time.Millisecond)
		if pong, err := Control(name, ping, 0); err == nil {
			return pong, nil
		}
	}
	return nil, fmt.Errorf("pty host '%s' failed to start — see %s", name, logPath)
}
