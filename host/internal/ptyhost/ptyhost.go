// Package ptyhost is the Go port of ptyhost.js: the small long-lived daemon
// that owns the ptys.
//
// The web server is a thin restartable proxy; this process holds every
// session's pty plus its libghostty-vt mirror, so shells and full screen
// state survive web server restarts.
//
// It listens on a named unix socket ($XDG_RUNTIME_DIR/webmux/<name>.sock)
// and speaks newline-delimited JSON mirroring the WebSocket message types
// ~1:1. Multiple hosts can run side by side under different names.
//
// Lifecycle: started on demand by the server (detached, so killing the web
// server leaves it running) or standalone via `webmux-host ptyhost [--name X]`.
// It exits only on an explicit `webmux-host ptyhost shutdown [--name X]`,
// SIGTERM/SIGINT, or kill — never because a web server went away.
//
// Protocol (the first line of each connection picks the mode):
//
//	{cmd:'ping'}               → {ok, name, pid, sessions, pasteDir}
//	{cmd:'list'}               → {ok, sessions: [{id, cols, rows, title, createdAt, clients, pid}]}
//	{cmd:'create', cols, rows} → {ok, id}
//	{cmd:'kill', session}      → {ok} after killing that session's pty
//	{cmd:'shutdown'}           → {ok}, then all ptys are killed and the daemon exits
//	{cmd:'attach', session}    → switches to streaming: snapshot/output/title/exit
//	                             out, input/resize in; closing the connection detaches
//	{cmd:'watch'}              → switches to streaming session-level events for ALL
//	                             sessions: {type:'session-title', session, title}
package ptyhost

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"net"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"

	"webmux/host/internal/protocol"
)

// ErrAlreadyRunning is returned by Listen when a live daemon owns the socket.
var ErrAlreadyRunning = errors.New("pty host already running")

// Daemon is one pty host instance.
type Daemon struct {
	name     string
	sockPath string
	pasteDir string
	shimDir  string

	// Log receives the log lines ptyhost.js prints with console.log/error.
	Log    io.Writer
	ErrLog io.Writer

	ln       net.Listener
	mu       sync.Mutex
	sessions map[string]*Session
	order    []string // creation order, for list (a JS Map iterates in insertion order)
	watchers map[*client]struct{}
	quit     chan struct{}
	quitOnce sync.Once
}

// New prepares a daemon for the named instance (socket path, paste dir,
// shims dir). It does not listen yet.
func New(name string) (*Daemon, error) {
	sock, err := protocol.SocketPath(name)
	if err != nil {
		return nil, err
	}
	d := &Daemon{
		name:     name,
		sockPath: sock,
		// Per-user: /tmp is shared, and a plain 'webmux-pastes' would be
		// owned by whichever user's webmux touched it first — every other
		// user's clipboard writes then fail with EACCES (and their pastes
		// would be world-readable).
		pasteDir: filepath.Join(os.TempDir(), "webmux-pastes-"+protocol.Username()),
		Log:      os.Stdout,
		ErrLog:   os.Stderr,
		sessions: map[string]*Session{},
		watchers: map[*client]struct{}{},
		quit:     make(chan struct{}),
	}
	return d, nil
}

// SocketPath is where the daemon listens.
func (d *Daemon) SocketPath() string { return d.sockPath }

// PasteDir is the WEBMUX_CLIPBOARD_DIR of this host's sessions.
func (d *Daemon) PasteDir() string { return d.pasteDir }

func (d *Daemon) logf(format string, a ...any) { fmt.Fprintf(d.Log, format+"\n", a...) }

// findShimDir: the payload's shims/ next to the running binary; in a dev
// checkout (`go run`, `go test`, host/dist/) the repo's shims/, found by
// walking up from the executable and then from the cwd.
func findShimDir() (dir, how string) {
	exe, err := os.Executable()
	if err == nil {
		if r, err := filepath.EvalSymlinks(exe); err == nil {
			exe = r
		}
		next := filepath.Join(filepath.Dir(exe), "shims")
		if isDir(next) {
			return next, "next to the binary"
		}
	}
	var starts []string
	if exe != "" {
		starts = append(starts, filepath.Dir(exe))
	}
	if wd, err := os.Getwd(); err == nil {
		starts = append(starts, wd)
	}
	for _, start := range starts {
		for d := start; ; d = filepath.Dir(d) {
			cand := filepath.Join(d, "shims")
			if fileExists(filepath.Join(cand, "xdg-open")) {
				return cand, "dev checkout"
			}
			if filepath.Dir(d) == d {
				break
			}
		}
	}
	if exe != "" {
		return filepath.Join(filepath.Dir(exe), "shims"), "MISSING"
	}
	return "shims", "MISSING"
}

func isDir(p string) bool {
	st, err := os.Stat(p)
	return err == nil && st.IsDir()
}

func fileExists(p string) bool {
	_, err := os.Stat(p)
	return err == nil
}

// Listen creates the paste dir and binds the socket, with the EADDRINUSE
// dance: a live daemon on the socket → ErrAlreadyRunning; a stale file left
// by a dead one is removed and the listen retried.
func (d *Daemon) Listen() error {
	if err := os.MkdirAll(d.pasteDir, 0o700); err != nil {
		return err
	}
	var how string
	d.shimDir, how = findShimDir()
	d.logf("shims: %s (%s)", d.shimDir, how)
	ln, err := net.Listen("unix", d.sockPath)
	if err != nil && errors.Is(err, syscall.EADDRINUSE) {
		// Socket file exists: defer to a live daemon, or clear a stale file
		// left by a dead one and retry.
		if _, perr := protocol.Control(d.name, map[string]any{"cmd": "ping"}, 0); perr == nil {
			fmt.Fprintf(d.ErrLog, "pty host '%s' is already running at %s\n", d.name, d.sockPath)
			return ErrAlreadyRunning
		}
		_ = os.Remove(d.sockPath)
		ln, err = net.Listen("unix", d.sockPath)
	}
	if err != nil {
		return err
	}
	if ul, ok := ln.(*net.UnixListener); ok {
		ul.SetUnlinkOnClose(false) // we unlink ourselves, only on shutdown
	}
	d.ln = ln
	d.logf("webmux pty host '%s' (pid %d) listening on %s", d.name, os.Getpid(), d.sockPath)
	return nil
}

// Serve accepts connections until Shutdown. It returns nil after a shutdown.
func (d *Daemon) Serve() error {
	for {
		conn, err := d.ln.Accept()
		if err != nil {
			if errors.Is(err, net.ErrClosed) {
				<-d.quit // Shutdown closed the listener; let it finish
				return nil
			}
			var ne net.Error
			if errors.As(err, &ne) && ne.Timeout() {
				continue
			}
			return err
		}
		go d.handleConn(conn)
	}
}

// Done is closed once Shutdown has run.
func (d *Daemon) Done() <-chan struct{} { return d.quit }

// Shutdown kills every pty, stops listening and unlinks the socket.
func (d *Daemon) Shutdown() {
	d.quitOnce.Do(func() {
		d.mu.Lock()
		sessions := make([]*Session, 0, len(d.sessions))
		for _, s := range d.sessions {
			sessions = append(sessions, s)
		}
		d.mu.Unlock()
		for _, s := range sessions {
			if !s.do(s.hangup) {
				continue // already exiting on its own
			}
		}
		// Give the sessions a moment to reap their shells (bounded: a shell
		// that ignores SIGHUP still lost its tty and the daemon goes anyway).
		deadline := time.After(2 * time.Second)
	wait:
		for _, s := range sessions {
			select {
			case <-s.done:
			case <-deadline:
				break wait
			}
		}
		_ = os.Remove(d.sockPath)
		if d.ln != nil {
			_ = d.ln.Close()
		}
		close(d.quit)
	})
}

// Run is the daemon: listen, serve, and stop on shutdown or SIGTERM/SIGINT.
// SIGHUP is ignored (survive terminal hangup when started from a shell by
// hand; explicit shutdown/kill is the only intended way to stop a host). It
// is handled rather than SIG_IGN'd so the sessions' shells don't inherit an
// ignored SIGHUP.
func Run(name string) error {
	d, err := New(name)
	if err != nil {
		return err
	}
	return d.run()
}

func (d *Daemon) run() error {
	if err := d.Listen(); err != nil {
		return err
	}
	sigs := make(chan os.Signal, 4)
	signal.Notify(sigs, syscall.SIGTERM, syscall.SIGINT, syscall.SIGHUP)
	defer signal.Stop(sigs)
	go func() {
		for {
			select {
			case sig := <-sigs:
				if sig == syscall.SIGHUP {
					continue
				}
				d.Shutdown()
				return
			case <-d.quit:
				return
			}
		}
	}()
	return d.Serve()
}

// ---------------------------------------------------------------------------
// Sessions and watchers
// ---------------------------------------------------------------------------

func (d *Daemon) getSession(id string) *Session {
	d.mu.Lock()
	defer d.mu.Unlock()
	return d.sessions[id]
}

func (d *Daemon) removeSession(s *Session) {
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.sessions[s.id] == s {
		delete(d.sessions, s.id)
		for i, id := range d.order {
			if id == s.id {
				d.order = append(d.order[:i:i], d.order[i+1:]...)
				break
			}
		}
	}
}

func (d *Daemon) broadcastWatchers(v any) {
	b, err := protocol.Marshal(v)
	if err != nil {
		return
	}
	d.mu.Lock()
	defer d.mu.Unlock()
	for c := range d.watchers {
		c.enqueue(b)
	}
}

// ---------------------------------------------------------------------------
// Connections
// ---------------------------------------------------------------------------

func (d *Daemon) handleConn(conn net.Conn) {
	c := newClient(conn)
	var attached *Session
	defer func() {
		// Peer closed (or vanished): detach.
		if attached != nil {
			attached.do(func() { attached.detach(c) })
		}
		d.mu.Lock()
		delete(d.watchers, c)
		d.mu.Unlock()
		c.kill()
	}()
	lr := protocol.NewLineReader(conn)
	first := true
	for {
		line, err := lr.Next()
		if err != nil {
			return
		}
		var msg any
		if json.Unmarshal(line, &msg) != nil {
			continue // unparseable lines are ignored (and don't count as the first)
		}
		m, _ := msg.(map[string]any)
		if first {
			first = false
			attached = d.handleCommand(c, m)
			continue
		}
		if attached == nil || m == nil {
			continue
		}
		switch m["type"] {
		case "input":
			if data, ok := m["data"].(string); ok {
				attached.do(func() { attached.inputData(data) })
			}
		case "resize":
			cols, ok1 := jsInt(m["cols"])
			rows, ok2 := jsInt(m["rows"])
			if ok1 && ok2 { // Number.isInteger: non-integers are ignored
				attached.do(func() { attached.resize(cols, rows) })
			}
		}
	}
}

// jsInt is Number.isInteger for a decoded JSON value.
func jsInt(v any) (int, bool) {
	f, ok := v.(float64)
	if !ok || math.IsInf(f, 0) || math.IsNaN(f) || f != math.Trunc(f) {
		return 0, false
	}
	if f > 1e9 {
		f = 1e9
	} else if f < -1e9 {
		f = -1e9
	}
	return int(f), true
}

// createDim is `msg.cols || default`: a falsy value (missing, 0, null, "")
// takes the default. Unlike ptyhost.js (which handed anything truthy to
// node-pty unchecked) non-numbers also take the default, and the size is
// clamped like resize so it always fits the pty and the mirror.
func createDim(v any, def, lo, hi int) int {
	f, ok := v.(float64)
	if !ok || f == 0 || math.IsNaN(f) {
		return def
	}
	if math.IsInf(f, 0) {
		f = math.Copysign(float64(hi), f)
	}
	n := int(math.Max(-1e9, math.Min(1e9, math.Trunc(f))))
	return max(lo, min(hi, n))
}

// jsStringify renders a JSON value as JSON.stringify would, for the
// unknown-cmd message (undefined when the key is missing).
func jsStringify(v any, present bool) string {
	if !present {
		return "undefined"
	}
	b, err := protocol.Marshal(v)
	if err != nil {
		return "undefined"
	}
	return strings.TrimSuffix(string(b), "\n")
}

// handleCommand handles a connection's first line. It returns the session
// when the connection switched to attach mode.
func (d *Daemon) handleCommand(c *client, m map[string]any) *Session {
	cmd, present := m["cmd"]
	name, _ := cmd.(string)
	if _, isStr := cmd.(string); !isStr {
		name = "" // falls through to unknown cmd
	}
	switch name {
	case "ping":
		// pasteDir tells the web server where this host's sessions expect
		// the clipboard slot and open-url spool (WEBMUX_CLIPBOARD_DIR), so a
		// newly deployed server stays consistent with sessions created
		// before a paste-dir change.
		d.mu.Lock()
		n := len(d.sessions)
		d.mu.Unlock()
		c.send(orderedObj{
			{"ok", true}, {"name", d.name}, {"pid", os.Getpid()}, {"sessions", n}, {"pasteDir", d.pasteDir},
		})
		c.end()
	case "list":
		d.mu.Lock()
		list := make([]*Session, 0, len(d.order))
		for _, id := range d.order {
			list = append(list, d.sessions[id])
		}
		d.mu.Unlock()
		descs := make([]orderedObj, 0, len(list))
		for _, s := range list {
			descs = append(descs, s.describe())
		}
		c.send(orderedObj{{"ok", true}, {"sessions", descs}})
		c.end()
	case "create":
		cols := createDim(m["cols"], 80, 2, 500)
		rows := createDim(m["rows"], 24, 2, 300)
		s, err := newSession(d, cols, rows)
		if err != nil {
			// ptyhost.js would have crashed on a spawn failure; report it.
			fmt.Fprintf(d.ErrLog, "session create failed: %v\n", err)
			c.send(orderedObj{{"ok", false}, {"error", err.Error()}})
			c.end()
			break
		}
		d.mu.Lock()
		d.sessions[s.id] = s
		d.order = append(d.order, s.id)
		d.mu.Unlock()
		d.logf("session %s created (%dx%d)", s.id, cols, rows)
		c.send(orderedObj{{"ok", true}, {"id", s.id}})
		c.end()
	case "kill":
		id, _ := m["session"].(string)
		s := d.getSession(id)
		if s == nil {
			c.send(orderedObj{{"ok", false}, {"error", "not found"}})
			c.end()
			break
		}
		// SIGHUP; the child's exit triggers the exit broadcast + teardown.
		s.do(s.kill)
		d.removeSession(s)
		c.send(orderedObj{{"ok", true}})
		c.end()
	case "shutdown":
		d.mu.Lock()
		n := len(d.sessions)
		d.mu.Unlock()
		d.logf("shutdown requested; killing %d session(s)", n)
		c.send(orderedObj{{"ok", true}})
		c.end()
		go func() {
			// Let the reply flush before the ptys and the socket go away.
			<-c.flushed()
			d.Shutdown()
		}()
	case "attach":
		id, _ := m["session"].(string)
		s := d.getSession(id)
		if s == nil || !s.do(func() { s.attach(c) }) {
			c.send(orderedObj{{"type", "error"}, {"message", "no such session"}})
			c.end()
			return nil
		}
		return s
	case "watch":
		d.mu.Lock()
		d.watchers[c] = struct{}{}
		d.mu.Unlock()
	default:
		c.send(orderedObj{{"ok", false}, {"error", "unknown cmd " + jsStringify(cmd, present)}})
		c.end()
	}
	return nil
}
