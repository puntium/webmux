// Package server is the Go port of server.js: a thin, restartable API
// bridge — a small JSON-over-HTTP surface plus WebSocket termination.
//
// The frontend is NOT served from here — the Electron client ships it and
// loads it locally; only /api/* and /ws cross the wire. The ptys themselves
// live in a separate long-lived pty host daemon reached over a named unix
// socket, so restarting this server never kills a shell. The host is
// spawned on demand at startup (detached) and stops only on
// `webmux-host ptyhost shutdown` or an explicit kill.
//
// The HTTP server listens on a unix socket (no TCP): filesystem permissions
// (0600 in the 0700 runtime dir) are the whole access story, so only this
// user can connect. The Electron client reaches it via an SSH forward —
// `ssh -L 127.0.0.1:<port>:<socket> host` — making sshd the only remote way
// in. Because the client's pages live on their own webmux:// origin, every
// response carries a permissive CORS header — the socket perms and sshd are
// the access control, the browser's origin checks add nothing here.
package server

import (
	"errors"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/fsnotify/fsnotify"

	"webmux/host/internal/protocol"
)

// Server holds what server.js keeps in module globals.
type Server struct {
	hostName    string // which pty host this server fronts (WEBMUX_PTYHOST)
	httpSock    string // where this HTTP server listens
	devSocket   bool   // WEBMUX_SOCKET set: no advert
	home        string
	payloadHash string
	routeTable  []route

	pasteMu      sync.Mutex
	pasteDir     string
	pasteWatcher *fsnotify.Watcher
	pasteSeq     int64
	openSeq      int64

	clientsMu sync.Mutex
	clients   map[*wsClient]struct{}            // every attached browser socket
	bySession map[string]map[*wsClient]struct{} // session id -> sockets, for targeted delivery

	ln      net.Listener
	httpSrv *http.Server
	quit    chan struct{}
	quitOne sync.Once
}

// readPayloadHash: deployed payloads carry a PAYLOAD_HASH file stamped by
// deploy/build-payload.js next to the binary; the Electron client compares
// it against the payload it ships to decide whether to push an update. A dev
// build has no such file and reports 'dev', which never matches.
func readPayloadHash() string {
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

// newServer reads the config (env vars only — a deployed payload has no
// config file, and dev runs can export the same variables).
func newServer() (*Server, error) {
	s := &Server{
		payloadHash: readPayloadHash(),
		clients:     map[*wsClient]struct{}{},
		bySession:   map[string]map[*wsClient]struct{}{},
		quit:        make(chan struct{}),
	}
	// Which pty host this server fronts. Different names → independent hosts
	// (own socket, own sessions), so several webmux instances can coexist.
	s.hostName = os.Getenv("WEBMUX_PTYHOST")
	if s.hostName == "" {
		s.hostName = protocol.DefaultName
	}
	// Where this HTTP server listens: next to the pty host's socket in the
	// runtime dir (0700), named after the host so instances don't collide.
	// WEBMUX_SOCKET overrides the path.
	if ws := os.Getenv("WEBMUX_SOCKET"); ws != "" {
		abs, err := filepath.Abs(ws)
		if err != nil {
			return nil, err
		}
		s.httpSock, s.devSocket = abs, true
	} else {
		dir, err := protocol.RunDir()
		if err != nil {
			return nil, err
		}
		s.httpSock = filepath.Join(dir, s.hostName+".http.sock")
	}
	s.home = os.Getenv("HOME")
	if s.home == "" {
		s.home, _ = os.UserHomeDir()
	}
	// Per-user default paste dir; start() adopts whatever the host advertises.
	s.pasteDir = filepath.Join(os.TempDir(), "webmux-pastes-"+protocol.Username())
	s.routeTable = s.routes()
	return s, nil
}

// hostControl is a control-plane command to the pty host. If the host is
// gone (crashed or explicitly shut down while we were up), respawn it once
// and retry so the web UI self-heals instead of erroring until a restart.
func (s *Server) hostControl(msg map[string]any) (map[string]any, error) {
	r, err := protocol.Control(s.hostName, msg, 0)
	if err == nil {
		return r, nil
	}
	if _, err := protocol.EnsureHost(s.hostName); err != nil {
		return nil, err
	}
	return protocol.Control(s.hostName, msg, 0)
}

// errAlreadyListening is the "another webmux server" exit-1 condition.
type errAlreadyListening struct{ sock string }

func (e errAlreadyListening) Error() string {
	return fmt.Sprintf("another webmux server is already listening on %s", e.sock)
}

// start brings the server up: pty host, paste dir, watch connection, then
// the listener and advert. It returns once the socket accepts connections.
func (s *Server) start() error {
	// Spawn (or adopt) the pty host before accepting clients. It runs
	// detached, so it — and every shell in it — outlives this server.
	pong, err := protocol.EnsureHost(s.hostName)
	if err != nil {
		return err
	}
	fmt.Printf("pty host '%s' up (pid %s, %s session(s))\n", s.hostName, jsString(pong["pid"]), jsString(pong["sessions"]))
	// Sessions inherit WEBMUX_CLIPBOARD_DIR from the host at creation, so the
	// slot/spool dir follows the host's advert, not this payload's default.
	s.initPasteDir(pong["pasteDir"])
	go s.watchHostEvents()

	ln, err := s.listen()
	if err != nil {
		return err
	}
	s.ln = ln
	_ = os.Chmod(s.httpSock, 0o600) // dir is 0700 already; belt and braces

	s.httpSrv = &http.Server{
		Handler:           s,
		ReadHeaderTimeout: 60 * time.Second, // node's headersTimeout
		IdleTimeout:       5 * time.Second,  // node's keepAliveTimeout
	}
	go func() {
		if err := s.httpSrv.Serve(ln); err != nil && !errors.Is(err, http.ErrServerClosed) {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
	}()

	// Advert for the deploy flow (remote start and the Electron client's push
	// logic): which payload is running, as which pid, speaking which pty-host
	// protocol, listening where. It lives at a fixed home-relative location
	// because the socket path embeds the uid behind $XDG_RUNTIME_DIR, which
	// the client can't compute. A WEBMUX_SOCKET run is a dev server on a
	// private socket and must not claim the instance's advert: once it exits,
	// the starter would trust its dead pid, leave the real deployed server
	// holding the canonical socket, and fail to start.
	if s.devSocket {
		fmt.Printf("webmux listening on %s (pty host '%s', WEBMUX_SOCKET set: advert not written)\n", s.httpSock, s.hostName)
		return nil
	}
	advertDir := filepath.Join(s.home, ".webmux")
	if err := os.MkdirAll(advertDir, 0o700); err != nil {
		return err
	}
	advert := jsonBytes(map[string]any{
		"socket":      s.httpSock,
		"payloadHash": s.payloadHash,
		"protocol":    protocol.Protocol,
		"pid":         os.Getpid(),
		"startedAt":   time.Now().UnixMilli(),
	})
	if err := os.WriteFile(filepath.Join(advertDir, s.hostName+".json"), append(advert, '\n'), 0o600); err != nil {
		return err
	}
	fmt.Printf("webmux listening on %s (pty host '%s')\n", s.httpSock, s.hostName)
	return nil
}

// listen with the same stale-socket dance as the pty host: if the socket
// file exists, defer to a live server, or clear the leftover of a dead one
// and retry.
func (s *Server) listen() (net.Listener, error) {
	for {
		ln, err := net.Listen("unix", s.httpSock)
		if err == nil {
			// We unlink explicitly on shutdown; a Close from tests must not
			// race a successor server for the path either way.
			ln.(*net.UnixListener).SetUnlinkOnClose(false)
			return ln, nil
		}
		if !errors.Is(err, syscall.EADDRINUSE) {
			return nil, err
		}
		if probe, perr := net.Dial("unix", s.httpSock); perr == nil {
			probe.Close()
			return nil, errAlreadyListening{s.httpSock}
		}
		_ = os.Remove(s.httpSock)
	}
}

// close stops everything started by start (tests; Main just exits).
func (s *Server) close() {
	s.quitOne.Do(func() { close(s.quit) })
	if s.httpSrv != nil {
		_ = s.httpSrv.Close()
	}
	s.clientsMu.Lock()
	for c := range s.clients {
		c.teardown()
	}
	s.clientsMu.Unlock()
	s.pasteMu.Lock()
	if s.pasteWatcher != nil {
		s.pasteWatcher.Close()
		s.pasteWatcher = nil
	}
	s.pasteMu.Unlock()
	_ = os.Remove(s.httpSock)
}

// Main runs `webmux-host serve`.
func Main(args []string) int {
	s, err := newServer()
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	// Install the handlers first so a signal during startup still cleans up.
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
	if err := s.start(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	<-sig
	_ = os.Remove(s.httpSock)
	return 0
}

// watchHostEvents keeps one long-lived watch connection to the pty host,
// fanning session-level events (currently title changes) out to every
// browser socket. This is what keeps background tabs' titles live: their
// tiles have no websocket of their own, so title events ride along on
// whichever sockets are open and the client routes them by session id.
// Reconnects with a delay if the host goes away (nudging it back up first,
// in case nothing else has).
func (s *Server) watchHostEvents() {
	for {
		if conn, err := protocol.Connect(s.hostName); err == nil {
			done := make(chan struct{})
			go func() {
				select {
				case <-s.quit:
					conn.Close()
				case <-done:
				}
			}()
			if protocol.WriteFrame(conn, map[string]any{"cmd": "watch"}) == nil {
				lr := protocol.NewLineReader(conn)
				for {
					line, err := lr.Next()
					if err != nil {
						break
					}
					s.broadcast(line)
				}
			}
			close(done)
			conn.Close()
		}
		select {
		case <-s.quit:
			return
		case <-time.After(time.Second):
		}
		if pong, err := protocol.EnsureHost(s.hostName); err == nil {
			s.initPasteDir(pong["pasteDir"]) // a respawned host may advertise a new dir
		}
	}
}

// broadcast sends a frame to every attached browser socket.
func (s *Server) broadcast(frame []byte) {
	s.clientsMu.Lock()
	defer s.clientsMu.Unlock()
	for c := range s.clients {
		c.send(frame)
	}
}
