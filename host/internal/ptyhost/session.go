package ptyhost

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/creack/pty"
	"github.com/google/uuid"
	"go.mitchellh.com/libghostty"
)

const scrollback = 5000

// Session is one pty plus its libghostty mirror. The mirror is not
// thread-safe, so a single owner goroutine (run) serializes everything that
// touches it or the session's client set: pty output (mirror write +
// fan-out), attach (snapshot), input, resize, kill and teardown. Other
// goroutines hand it closures through do().
type Session struct {
	id        string
	createdAt int64 // ms since epoch, like Date.now()
	d         *Daemon
	cmd       *exec.Cmd
	ptmx      *os.File
	pid       int

	ops    chan func()
	data   chan []byte   // pty reads, from the reader goroutine
	waited chan int      // exit code, from the waiter goroutine
	done   chan struct{} // closed when the owner has torn the session down
	input  *inputQueue   // pty writes happen off the owner (see inputQueue)

	// Owner-only.
	term     *libghostty.Terminal
	clients  map[*client]struct{}
	utf8     utf8Stream
	titleHit bool

	// Read by describe() from other goroutines; written by the owner.
	mu       sync.Mutex
	cols     int
	rows     int
	title    string
	nclients int
}

// buildEnv reproduces ptyhost.js's session environment exactly.
func buildEnv(shimDir, pasteDir, id string) []string {
	env := map[string]string{}
	var order []string
	for _, kv := range os.Environ() {
		k, v, ok := strings.Cut(kv, "=")
		if !ok {
			continue
		}
		if _, seen := env[k]; !seen {
			order = append(order, k)
		}
		env[k] = v
	}
	set := func(k, v string) {
		if _, seen := env[k]; !seen {
			order = append(order, k)
		}
		env[k] = v
	}
	display := os.Getenv("DISPLAY")
	if display == "" {
		display = ":0"
	}
	// Shimmed xclip/xsel serve the browser clipboard to CLIs like Claude
	// Code. DISPLAY is faked so clipboard readers don't bail early on a
	// headless host (real X clients would fail anyway).
	set("PATH", shimDir+":"+os.Getenv("PATH"))
	set("WEBMUX_CLIPBOARD_DIR", pasteDir)
	// Lets the xdg-open shim route URLs back to the client that is
	// actually viewing this session (see shims/xdg-open).
	set("WEBMUX_SESSION", id)
	// Programs that consult $BROWSER directly (and the real xdg-open
	// script's own fallback chain) land on the same shim.
	set("BROWSER", filepath.Join(shimDir, "xdg-open"))
	set("DISPLAY", display)
	// The host may itself run under tmux; hide that from sessions so a
	// nested `tmux` starts cleanly and CLIs don't adapt to a mux they can't
	// actually see.
	delete(env, "TMUX")
	delete(env, "TMUX_PANE")
	if env["TERM_PROGRAM"] == "tmux" {
		delete(env, "TERM_PROGRAM")
		delete(env, "TERM_PROGRAM_VERSION")
	}
	// node-pty sets TERM from its `name` option.
	set("TERM", "xterm-256color")
	out := make([]string, 0, len(order))
	for _, k := range order {
		if v, ok := env[k]; ok {
			out = append(out, k+"="+v)
		}
	}
	return out
}

func shellCommand() string {
	if s := os.Getenv("SHELL_CMD"); s != "" {
		return s
	}
	if s := os.Getenv("SHELL"); s != "" {
		return s
	}
	return "bash"
}

func newSession(d *Daemon, cols, rows int) (*Session, error) {
	s := &Session{
		id:        uuid.NewString(), // v4: stable across web server restarts, never collides
		createdAt: time.Now().UnixMilli(),
		d:         d,
		ops:       make(chan func()),
		data:      make(chan []byte, 16),
		waited:    make(chan int, 1),
		done:      make(chan struct{}),
		clients:   map[*client]struct{}{},
		cols:      cols,
		rows:      rows,
	}
	term, err := libghostty.NewTerminal(
		libghostty.WithSize(uint16(cols), uint16(rows)),
		libghostty.WithMaxScrollbackLines(scrollback),
		// Track OSC 0/2 titles on the mirror so they survive disconnects
		// (the snapshot doesn't carry the title). The callback runs inside
		// VTWrite on the owner goroutine: only note it; the owner reads
		// Title() and broadcasts after VTWrite returns.
		libghostty.WithTitleChanged(func(*libghostty.Terminal) { s.titleHit = true }),
	)
	if err != nil {
		return nil, err
	}
	s.term = term

	cmd := exec.Command(shellCommand())
	cmd.Env = buildEnv(d.shimDir, d.pasteDir, s.id)
	cmd.Dir = os.Getenv("HOME") // empty = inherit cwd, like node-pty without cwd
	ptmx, err := pty.StartWithSize(cmd, &pty.Winsize{Cols: uint16(cols), Rows: uint16(rows)})
	if err != nil {
		term.Close()
		return nil, err
	}
	if pf, err := pollable(ptmx); err == nil {
		ptmx = pf
	} else {
		d.logf("session %s: pty stays blocking: %v", s.id, err)
	}
	s.cmd, s.ptmx, s.pid = cmd, ptmx, cmd.Process.Pid
	s.input = newInputQueue(ptmx)

	go s.reader()
	go s.waiter()
	go s.run()
	return s, nil
}

func (s *Session) reader() {
	defer close(s.data)
	for {
		buf := make([]byte, 32*1024)
		n, err := s.ptmx.Read(buf)
		if n > 0 {
			select {
			case s.data <- buf[:n]:
			case <-s.done:
				return
			}
		}
		if err != nil {
			return // EIO once every slave fd is closed, or the master was closed
		}
	}
}

// waiter reaps the child. exitCode follows node-pty: WEXITSTATUS for a
// normal exit, and 0 when the child was killed by a signal (node-pty reports
// the signal separately in `signal`, which ptyhost.js never forwarded, so
// the client has always seen 0 there; keeping it means "[session exited: 0]"
// after a kill, exactly as before).
func (s *Session) waiter() {
	err := s.cmd.Wait()
	code := 0
	var ee *exec.ExitError
	if errors.As(err, &ee) {
		if ws, ok := ee.Sys().(syscall.WaitStatus); ok && ws.Exited() {
			code = ws.ExitStatus()
		}
	}
	s.waited <- code
}

// do runs f on the owner goroutine and waits for it. It returns false if the
// session is already gone.
func (s *Session) do(f func()) bool {
	fin := make(chan struct{})
	select {
	case s.ops <- func() { f(); close(fin) }:
		<-fin
		return true
	case <-s.done:
		return false
	}
}

func (s *Session) run() {
	data := s.data
	for {
		select {
		case b, ok := <-data:
			if !ok {
				data = nil // pty EOF; the exit status follows from the waiter
				continue
			}
			s.output(b)
		case f := <-s.ops:
			f()
		case code := <-s.waited:
			s.drain(data)
			s.finish(code)
			return
		}
	}
}

// drain delivers output still buffered in the pty after the child exited
// (node-pty also flushes before onExit). Bounded: a background job may hold
// the slave open forever.
func (s *Session) drain(data chan []byte) {
	if data == nil {
		return
	}
	timeout := time.After(time.Second)
	for {
		select {
		case b, ok := <-data:
			if !ok {
				return
			}
			s.output(b)
		case f := <-s.ops:
			f()
		case <-timeout:
			return
		}
	}
}

func (s *Session) output(b []byte) {
	s.term.VTWrite(b) // keep the mirror current (raw bytes, in order)
	if str := s.utf8.push(b); str != "" {
		frame := outputFrame{"output", str}
		for c := range s.clients {
			c.send(frame)
		}
	}
	if s.titleHit {
		s.titleHit = false
		title, err := s.term.Title()
		if err == nil {
			s.setTitle(title)
		}
	}
}

func (s *Session) setTitle(title string) {
	s.mu.Lock()
	changed := title != s.title
	s.title = title
	s.mu.Unlock()
	if !changed {
		return
	}
	for c := range s.clients {
		c.send(orderedObj{{"type", "title"}, {"title", title}})
	}
	s.d.broadcastWatchers(orderedObj{{"type", "session-title"}, {"session", s.id}, {"title", title}})
}

// attach runs on the owner: replay the accumulated state so the client
// renders exactly what the session looks like right now, then stream. pid
// rides along for the web server's foreground-process detection (paste
// routing).
func (s *Session) attach(c *client) {
	data, err := snapshot(s.term)
	if err != nil {
		s.d.logf("session %s: snapshot failed: %v", s.id, err)
	}
	s.mu.Lock()
	cols, rows, title := s.cols, s.rows, s.title
	s.nclients++
	s.mu.Unlock()
	c.send(orderedObj{
		{"type", "snapshot"},
		{"data", string(data)},
		{"cols", cols},
		{"rows", rows},
		{"title", title},
		{"pid", s.pid},
	})
	s.clients[c] = struct{}{}
}

func (s *Session) detach(c *client) {
	if _, ok := s.clients[c]; !ok {
		return
	}
	delete(s.clients, c)
	s.mu.Lock()
	s.nclients--
	s.mu.Unlock()
}

// inputData forwards client keystrokes to the pty (queued, see inputQueue).
func (s *Session) inputData(data string) { s.input.push([]byte(data)) }

// resize clamps like ptyhost.js and applies mirror first, then pty.
func (s *Session) resize(cols, rows int) {
	cols = max(2, min(500, cols))
	rows = max(2, min(300, rows))
	s.mu.Lock()
	s.cols, s.rows = cols, rows
	s.mu.Unlock()
	if err := s.term.Resize(uint16(cols), uint16(rows), 0, 0); err != nil {
		s.d.logf("session %s: mirror resize: %v", s.id, err)
	}
	if err := setWinsize(s.ptmx, cols, rows); err != nil {
		s.d.logf("session %s: pty resize: %v", s.id, err)
	}
}

// kill is node-pty's pty.kill(): SIGHUP to the child. The exit broadcast
// and teardown follow from the waiter when the child is gone.
func (s *Session) kill() {
	if s.cmd.Process != nil {
		_ = s.cmd.Process.Signal(syscall.SIGHUP)
	}
}

// hangup is used on daemon shutdown: SIGHUP and close the master (what
// process exit did for node), so every process on the tty gets the hangup.
func (s *Session) hangup() {
	s.kill()
	_ = s.ptmx.Close()
}

func (s *Session) describe() orderedObj {
	s.mu.Lock()
	defer s.mu.Unlock()
	return orderedObj{
		{"id", s.id},
		{"cols", s.cols},
		{"rows", s.rows},
		{"title", s.title},
		{"createdAt", s.createdAt},
		{"clients", s.nclients},
		{"pid", s.pid},
	}
}

// finish: exit frame to attached clients, their sockets ended, session
// removed, mirror freed.
func (s *Session) finish(code int) {
	if rest := s.utf8.flush(); rest != "" {
		for c := range s.clients {
			c.send(outputFrame{"output", rest})
		}
	}
	for c := range s.clients {
		c.send(orderedObj{{"type", "exit"}, {"exitCode", code}})
		c.end()
	}
	s.clients = map[*client]struct{}{}
	s.mu.Lock()
	s.nclients = 0
	s.mu.Unlock()
	s.d.removeSession(s)
	s.input.close()
	_ = s.ptmx.Close()
	s.term.Close()
	s.d.logf("session %s exited (%d)", s.id, code)
	close(s.done)
}

// inputQueue writes to the pty master on its own goroutine, in order. A
// blocking write on the owner could deadlock: the child blocks writing
// output the owner isn't draining while the owner blocks writing input the
// child isn't reading (node-pty's writes are async for the same reason).
type inputQueue struct {
	mu     sync.Mutex
	cond   *sync.Cond
	q      [][]byte
	closed bool
}

func newInputQueue(w *os.File) *inputQueue {
	iq := &inputQueue{}
	iq.cond = sync.NewCond(&iq.mu)
	go func() {
		for {
			iq.mu.Lock()
			for len(iq.q) == 0 && !iq.closed {
				iq.cond.Wait()
			}
			if iq.closed {
				iq.mu.Unlock()
				return
			}
			b := iq.q[0]
			iq.q = iq.q[1:]
			iq.mu.Unlock()
			if _, err := w.Write(b); err != nil {
				return
			}
		}
	}()
	return iq
}

func (iq *inputQueue) push(b []byte) {
	iq.mu.Lock()
	if !iq.closed {
		iq.q = append(iq.q, b)
		iq.cond.Signal()
	}
	iq.mu.Unlock()
}

func (iq *inputQueue) close() {
	iq.mu.Lock()
	iq.closed = true
	iq.q = nil
	iq.cond.Signal()
	iq.mu.Unlock()
}

func (s *Session) String() string { return fmt.Sprintf("session %s", s.id) }
