// Package start is the webmux remote starter — runs ON THE TARGET HOST, as
// `webmux-host start --name <instance>` from inside an extracted payload
// directory (~/.webmux/dist/payload/<hash>/webmux-host). Port of
// deploy/remote-start.js; keep the two in step.
//
// Idempotent "make this payload the running server" step:
//   - if the advert (~/.webmux/<name>.json) says this exact payload is
//     already running, do nothing;
//   - otherwise stop the old server (never the pty host — sessions live
//     there and survive the swap) and start `webmux-host serve` detached;
//   - wait for the new server's advert, then print it.
//
// Output contract: the LAST line on stdout is a single JSON object,
//
//	{ ok: true, action: 'reuse'|'started', advert: {...} }  or
//	{ ok: false, error: '...', logTail: '...' }
//
// The client tolerates shell-profile noise before it by parsing the last
// parseable line. Exit code 0 iff ok.
//
// The old server may be the legacy node payload (server.js) or a native one
// (webmux-host serve): both are recognized, so the first native deploy onto
// a host running the node payload replaces the node server.
package start

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync/atomic"
	"syscall"
	"time"

	"webmux/host/internal/protocol"
)

// Seams for tests. Production values mirror remote-start.js.
var (
	// executable returns the running binary's path (symlinks resolved); the
	// payload dir is its directory.
	executable = func() (string, error) {
		exe, err := os.Executable()
		if err != nil {
			return "", err
		}
		if r, err := filepath.EvalSymlinks(exe); err == nil {
			exe = r
		}
		return exe, nil
	}
	// serveCommand builds the server process to spawn.
	serveCommand = func(exe string) *exec.Cmd { return exec.Command(exe, "serve") }
	// procRoot is where pid cmdlines/environs are read from.
	procRoot = "/proc"
	// homeDir is the user's home (~/.webmux lives under it).
	homeDir = func() string {
		if h, err := os.UserHomeDir(); err == nil {
			return h
		}
		return os.Getenv("HOME")
	}
	stdout io.Writer = os.Stdout

	pollAttempts = 200
	pollInterval = 150 * time.Millisecond
)

var validName = regexp.MustCompile(`^[A-Za-z0-9._-]+$`)

// advert is ~/.webmux/<name>.json as server.js / server writes it. raw is
// echoed back verbatim (compacted) in the result, like the JS re-stringify.
type advert struct {
	raw         json.RawMessage
	Socket      string
	PayloadHash string
	Pid         int
}

type starter struct {
	name       string
	advertFile string
	logFile    string
	myHash     string
	payloadDir string
	exe        string
}

// failure carries a fail() message up to Main.
type failure struct{ msg string }

func (f failure) Error() string { return f.msg }

// Main implements `webmux-host start [--name X]`.
func Main(args []string) int {
	name := protocol.DefaultName
	for i := 0; i < len(args); i++ {
		if args[i] == "--name" {
			i++
			if i < len(args) {
				name = args[i]
			} else {
				name = ""
			}
		} else if strings.HasPrefix(args[i], "--name=") {
			name = strings.TrimPrefix(args[i], "--name=")
		}
	}

	webmuxDir := filepath.Join(homeDir(), ".webmux")
	s := &starter{
		name:       name,
		advertFile: filepath.Join(webmuxDir, name+".json"),
		logFile:    filepath.Join(webmuxDir, name+".server.log"),
	}

	if !validName.MatchString(name) {
		return s.fail(fmt.Sprintf("invalid instance name '%s'", name))
	}

	exe, err := executable()
	if err == nil {
		s.exe = exe
		s.payloadDir = filepath.Dir(exe)
		if b, err := os.ReadFile(filepath.Join(s.payloadDir, "PAYLOAD_HASH")); err == nil {
			s.myHash = strings.TrimSpace(string(b))
		}
	}
	if s.myHash == "" {
		return s.fail("payload is missing PAYLOAD_HASH — not a built payload?")
	}

	res, err := s.run(webmuxDir)
	if err != nil {
		return s.fail(err.Error())
	}
	printJSON(res)
	return 0
}

type okResult struct {
	OK     bool            `json:"ok"`
	Action string          `json:"action"`
	Advert json.RawMessage `json:"advert"`
}

type failResult struct {
	OK      bool   `json:"ok"`
	Error   string `json:"error"`
	LogTail string `json:"logTail"`
}

func printJSON(v any) {
	var b bytes.Buffer
	enc := json.NewEncoder(&b)
	enc.SetEscapeHTML(false) // match JSON.stringify
	_ = enc.Encode(v)
	_, _ = stdout.Write(b.Bytes())
}

func (s *starter) fail(msg string) int {
	logTail := ""
	if b, err := os.ReadFile(s.logFile); err == nil {
		lines := strings.Split(string(b), "\n")
		if len(lines) > 15 {
			lines = lines[len(lines)-15:]
		}
		logTail = strings.Join(lines, "\n")
	} // no log yet
	printJSON(failResult{OK: false, Error: msg, LogTail: logTail})
	return 1
}

func (s *starter) readAdvert() *advert {
	b, err := os.ReadFile(s.advertFile)
	if err != nil {
		return nil
	}
	var raw json.RawMessage
	if err := json.Unmarshal(b, &raw); err != nil {
		return nil
	}
	var fields map[string]any
	_ = json.Unmarshal(raw, &fields) // non-objects: all fields stay zero
	a := &advert{}
	var c bytes.Buffer
	if json.Compact(&c, raw) == nil {
		a.raw = c.Bytes()
	} else {
		a.raw = raw
	}
	a.Socket, _ = fields["socket"].(string)
	a.PayloadHash, _ = fields["payloadHash"].(string)
	if p, ok := fields["pid"].(float64); ok && p == float64(int(p)) {
		a.Pid = int(p)
	}
	return a
}

// pidAlive is process.kill(pid, 0). Non-positive pids are never "alive":
// kill(0|-n, 0) would address process groups.
func pidAlive(pid int) bool {
	if pid <= 0 {
		return false
	}
	return syscall.Kill(pid, 0) == nil
}

// cmdlineArgs splits a /proc/<pid>/cmdline blob into argv.
func cmdlineArgs(raw []byte) []string {
	return strings.Split(strings.TrimRight(string(raw), "\x00"), "\x00")
}

// isNodeServer: the legacy node server, `node …/server.js`.
func isNodeServer(argv []string) bool {
	return strings.Contains(strings.Join(argv, " "), "server.js")
}

// isNativeServer: `…/webmux-host … serve` (argv[0] is the binary, or an
// interpreter followed by it, e.g. when the binary is a script in tests).
func isNativeServer(argv []string) bool {
	for i, a := range argv {
		if strings.Contains(filepath.Base(a), "webmux-host") {
			for _, b := range argv[i+1:] {
				if b == "serve" {
					return true
				}
			}
			return false
		}
	}
	return false
}

// isWebmuxServerCmdline is pidIsWebmuxServer's cmdline test.
func isWebmuxServerCmdline(argv []string) bool {
	return isNodeServer(argv) || isNativeServer(argv)
}

// isInstanceServer is serversForInstance's per-pid test: a webmux server
// (node server.js with "webmux" in its cmdline, or webmux-host serve) whose
// WEBMUX_PTYHOST is name (default when absent/empty) and which is not a dev
// run on its own WEBMUX_SOCKET.
func isInstanceServer(argv []string, environ []byte, name string) bool {
	joined := strings.Join(argv, " ")
	node := isNodeServer(argv) && strings.Contains(joined, "webmux")
	if !node && !isNativeServer(argv) {
		return false
	}
	env := strings.Split(string(environ), "\x00")
	inst := "default"
	for _, e := range env {
		if strings.HasPrefix(e, "WEBMUX_PTYHOST=") {
			inst = strings.TrimPrefix(e, "WEBMUX_PTYHOST=")
			break
		}
	}
	if inst == "" {
		inst = "default"
	}
	if inst != name {
		return false
	}
	for _, e := range env {
		if strings.HasPrefix(e, "WEBMUX_SOCKET=") {
			return false // dev run on its own socket
		}
	}
	return true
}

// Guard against pid reuse before killing anything: on Linux, only treat the
// advertised pid as ours if its cmdline is a webmux server (node server.js or
// webmux-host serve). Where /proc doesn't exist (future macOS targets),
// liveness is the best we can do.
func pidIsWebmuxServer(pid int) bool {
	if !pidAlive(pid) {
		return false
	}
	raw, err := os.ReadFile(filepath.Join(procRoot, strconv.Itoa(pid), "cmdline"))
	if err != nil {
		return true // no /proc — trust the advert
	}
	return isWebmuxServerCmdline(cmdlineArgs(raw))
}

func (s *starter) stopOldServer(a *advert) {
	if a == nil || a.Pid == 0 || !pidIsWebmuxServer(a.Pid) {
		return
	}
	stopPid(a.Pid)
}

func socketAnswers(sockPath string) bool {
	if sockPath == "" {
		return false
	}
	c, err := net.DialTimeout("unix", sockPath, 2*time.Second)
	if err != nil {
		return false
	}
	c.Close()
	return true
}

// The socket the server listens on for this instance when WEBMUX_SOCKET is
// not set — mirrors protocol.RunDir and the server's HTTP socket.
func (s *starter) canonicalSocket() (string, error) {
	dir, err := protocol.RunDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, s.name+".http.sock"), nil
}

// Pids of live webmux servers (ours) whose WEBMUX_PTYHOST is this instance —
// found through /proc, so Linux only; elsewhere the advert is the only
// source of truth. Covers the case where the advert points at a server that
// is gone (or at a dev run on another socket) while an older deployed server
// still holds the canonical socket: starting a new one would hit EADDRINUSE
// and exit, and the connect would fail forever.
func (s *starter) serversForInstance() []int {
	var pids []int
	entries, err := os.ReadDir(procRoot)
	if err != nil {
		return pids
	}
	self := os.Getpid()
	for _, ent := range entries {
		pid, err := strconv.Atoi(ent.Name())
		if err != nil || pid <= 0 || pid == self {
			continue
		}
		raw, err := os.ReadFile(filepath.Join(procRoot, ent.Name(), "cmdline"))
		if err != nil {
			continue // not ours to read, or gone
		}
		argv := cmdlineArgs(raw)
		if !isNodeServer(argv) && !isNativeServer(argv) {
			continue
		}
		environ, err := os.ReadFile(filepath.Join(procRoot, ent.Name(), "environ"))
		if err != nil {
			continue
		}
		if isInstanceServer(argv, environ, s.name) {
			pids = append(pids, pid)
		}
	}
	return pids
}

func stopPid(pid int) {
	if pid <= 0 {
		return
	}
	if syscall.Kill(pid, syscall.SIGTERM) != nil {
		return
	}
	for i := 0; i < 30 && pidAlive(pid); i++ {
		time.Sleep(100 * time.Millisecond)
	}
	if pidAlive(pid) {
		_ = syscall.Kill(pid, syscall.SIGKILL) // raced
		for i := 0; i < 10 && pidAlive(pid); i++ {
			time.Sleep(100 * time.Millisecond)
		}
	}
}

func (s *starter) run(webmuxDir string) (*okResult, error) {
	a := s.readAdvert()
	if a != nil && a.PayloadHash == s.myHash && pidIsWebmuxServer(a.Pid) && socketAnswers(a.Socket) {
		return &okResult{OK: true, Action: "reuse", Advert: a.raw}, nil
	}

	s.stopOldServer(a)

	// Whatever the advert said, nothing of ours may be left holding the
	// canonical socket — the new server has to bind it.
	canon, err := s.canonicalSocket()
	if err != nil {
		return nil, err
	}
	if socketAnswers(canon) {
		for _, pid := range s.serversForInstance() {
			stopPid(pid)
		}
		if socketAnswers(canon) {
			return nil, failure{fmt.Sprintf("another process is listening on %s and could not be identified as a webmux server", canon)}
		}
	}

	if err := os.MkdirAll(webmuxDir, 0o700); err != nil {
		return nil, err
	}
	log, err := os.OpenFile(s.logFile, os.O_WRONLY|os.O_CREATE|os.O_APPEND, 0o666)
	if err != nil {
		return nil, err
	}
	short := s.myHash
	if len(short) > 12 {
		short = short[:12]
	}
	fmt.Fprintf(log, "\n--- remote-start %s payload %s ---\n",
		time.Now().UTC().Format("2006-01-02T15:04:05.000Z"), short)
	cmd := serveCommand(s.exe)
	cmd.Dir = s.payloadDir
	cmd.Env = append(os.Environ(), "WEBMUX_PTYHOST="+s.name) // last one wins
	cmd.Stdin = nil                                          // /dev/null
	cmd.Stdout = log
	cmd.Stderr = log
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	err = cmd.Start()
	log.Close()
	if err != nil {
		return nil, err
	}
	// Reap the child if it dies while we wait, so pidAlive sees it gone
	// (node's libuv does this implicitly; an unreaped zombie still "exists").
	var exited atomic.Bool
	go func() { _ = cmd.Wait(); exited.Store(true) }()
	childAlive := func() bool { return !exited.Load() && pidAlive(cmd.Process.Pid) }

	// The server writes its advert once it is listening (and it first has to
	// spawn/adopt the pty host, which can take a few seconds on a slow board).
	for i := 0; i < pollAttempts; i++ {
		time.Sleep(pollInterval)
		a := s.readAdvert()
		if a != nil && a.PayloadHash == s.myHash && pidAlive(a.Pid) && socketAnswers(a.Socket) {
			return &okResult{OK: true, Action: "started", Advert: a.raw}, nil
		}
		if !childAlive() {
			if a2 := s.readAdvert(); a2 == nil || a2.PayloadHash != s.myHash {
				return nil, failure{"server exited during startup"}
			}
		}
	}
	return nil, failure{"server did not come up within 30s"}
}
