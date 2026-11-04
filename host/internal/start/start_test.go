package start

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"webmux/host/internal/protocol"
)

// The test binary doubles as a fake `webmux-host serve` when START_FAKE_SERVE
// is set (the real server package may not exist yet). Modes:
//
//	serve        listen on the canonical socket, write the advert, run until SIGTERM
//	stubborn     like serve but ignores SIGTERM (needs SIGKILL)
//	die          print to stderr and exit 3
//	hang         never listen; run until SIGTERM
//
// FAKE_NO_ADVERT=1 skips the advert (an old server that lost its advert).
// Every fake writes its pid into $FAKE_PIDDIR so tests can clean up, and
// exits on its own after 60 s regardless.
func TestMain(m *testing.M) {
	if mode := os.Getenv("START_FAKE_SERVE"); mode != "" {
		os.Exit(fakeServe(mode))
	}
	os.Exit(m.Run())
}

func fakeServe(mode string) int {
	if d := os.Getenv("FAKE_PIDDIR"); d != "" {
		_ = os.WriteFile(filepath.Join(d, strconv.Itoa(os.Getpid())), nil, 0o600)
	}
	go func() { time.Sleep(60 * time.Second); os.Exit(9) }()
	sigs := make(chan os.Signal, 1)
	if mode == "stubborn" {
		signal.Ignore(syscall.SIGTERM)
	} else {
		signal.Notify(sigs, syscall.SIGTERM, syscall.SIGINT)
	}
	switch mode {
	case "die":
		fmt.Fprintln(os.Stderr, "boom: fake server failing on purpose")
		return 3
	case "hang":
		fmt.Println("hanging")
		<-sigs
		return 0
	}
	name := os.Getenv("WEBMUX_PTYHOST")
	if name == "" {
		name = "default"
	}
	dir, err := protocol.RunDir()
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	sock := filepath.Join(dir, name+".http.sock")
	_ = os.Remove(sock)
	ln, err := net.Listen("unix", sock)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			c.Close()
		}
	}()
	if os.Getenv("FAKE_NO_ADVERT") == "" {
		ad := filepath.Join(os.Getenv("HOME"), ".webmux")
		_ = os.MkdirAll(ad, 0o700)
		b, _ := json.Marshal(map[string]any{
			"socket": sock, "payloadHash": os.Getenv("FAKE_HASH"), "protocol": 1,
			"pid": os.Getpid(), "startedAt": time.Now().UnixMilli(),
		})
		_ = os.WriteFile(filepath.Join(ad, name+".json"), append(b, '\n'), 0o600)
	}
	fmt.Printf("fake webmux listening on %s\n", sock)
	if mode == "stubborn" {
		select {}
	}
	<-sigs
	ln.Close()
	return 0
}

type env struct {
	t       *testing.T
	home    string
	payload string
	pidDir  string
	name    string
}

func setup(t *testing.T, name, hash string) *env {
	t.Helper()
	// Short root: unix socket paths are limited to 108 bytes, and the nix
	// shell's TMPDIR plus t.TempDir()'s test-name component overflow that.
	root, err := os.MkdirTemp("/tmp", "wmstart")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(root) })
	e := &env{t: t, home: filepath.Join(root, "home"), payload: filepath.Join(root, "payload"),
		pidDir: filepath.Join(root, "pids"), name: name}
	for _, d := range []string{e.home, e.payload, e.pidDir, filepath.Join(root, "run")} {
		if err := os.MkdirAll(d, 0o700); err != nil {
			t.Fatal(err)
		}
	}
	t.Setenv("HOME", e.home)
	t.Setenv("XDG_RUNTIME_DIR", filepath.Join(root, "run"))
	t.Setenv("FAKE_PIDDIR", e.pidDir)
	t.Setenv("START_FAKE_SERVE", "serve")
	t.Setenv("FAKE_NO_ADVERT", "")
	t.Setenv("WEBMUX_SOCKET", "")
	os.Unsetenv("WEBMUX_SOCKET")
	if hash != "" {
		e.setHash(hash)
	}

	oldExe, oldServe, oldOut := executable, serveCommand, stdout
	oldAttempts, oldInterval := pollAttempts, pollInterval
	exe := filepath.Join(e.payload, "webmux-host")
	executable = func() (string, error) { return exe, nil }
	serveCommand = func(exe string) *exec.Cmd {
		cmd := exec.Command(os.Args[0])
		cmd.Args = []string{exe, "serve"} // /proc cmdline: …/webmux-host serve
		return cmd
	}
	t.Cleanup(func() {
		executable, serveCommand, stdout = oldExe, oldServe, oldOut
		pollAttempts, pollInterval = oldAttempts, oldInterval
		ents, _ := os.ReadDir(e.pidDir)
		for _, ent := range ents {
			if pid, err := strconv.Atoi(ent.Name()); err == nil {
				_ = syscall.Kill(pid, syscall.SIGKILL)
			}
		}
	})
	return e
}

func (e *env) setHash(h string) {
	e.t.Setenv("FAKE_HASH", h)
	if err := os.WriteFile(filepath.Join(e.payload, "PAYLOAD_HASH"), []byte(h+"\n"), 0o644); err != nil {
		e.t.Fatal(err)
	}
}

type result struct {
	OK      bool   `json:"ok"`
	Action  string `json:"action"`
	Error   string `json:"error"`
	LogTail string `json:"logTail"`
	Advert  struct {
		Socket      string `json:"socket"`
		PayloadHash string `json:"payloadHash"`
		Protocol    int    `json:"protocol"`
		Pid         int    `json:"pid"`
		StartedAt   int64  `json:"startedAt"`
	} `json:"advert"`
}

func (e *env) run(args ...string) (result, int) {
	e.t.Helper()
	var out bytes.Buffer
	stdout = &out
	code := Main(args)
	lines := strings.Split(strings.TrimRight(out.String(), "\n"), "\n")
	var r result
	if err := json.Unmarshal([]byte(lines[len(lines)-1]), &r); err != nil {
		e.t.Fatalf("last stdout line is not JSON: %q", out.String())
	}
	if (code == 0) != r.OK {
		e.t.Fatalf("exit code %d disagrees with ok=%v: %s", code, r.OK, out.String())
	}
	return r, code
}

func (e *env) canonical() string {
	return filepath.Join(os.Getenv("XDG_RUNTIME_DIR"), "webmux", e.name+".http.sock")
}

// spawnOld starts a fake server directly (not via Main), e.g. one that looks
// like the legacy node payload. It is reaped in the background.
func (e *env) spawnOld(mode string, argv []string, extraEnv ...string) int {
	e.t.Helper()
	cmd := exec.Command(os.Args[0])
	cmd.Args = argv
	cmd.Stderr = os.Stderr
	cmd.Env = append(os.Environ(), append([]string{"START_FAKE_SERVE=" + mode, "WEBMUX_PTYHOST=" + e.name}, extraEnv...)...)
	if err := cmd.Start(); err != nil {
		e.t.Fatal(err)
	}
	go cmd.Wait()
	waitFor(e.t, func() bool { return socketAnswers(e.canonical()) })
	return cmd.Process.Pid
}

func waitFor(t *testing.T, cond func() bool) {
	t.Helper()
	for i := 0; i < 100; i++ {
		if cond() {
			return
		}
		time.Sleep(50 * time.Millisecond)
	}
	t.Fatal("condition not met within 5s")
}

func TestStartedThenReuse(t *testing.T) {
	e := setup(t, "inst1", "abcdef0123456789")
	r, code := e.run("--name", "inst1")
	if code != 0 || r.Action != "started" {
		t.Fatalf("first start: %+v", r)
	}
	if r.Advert.PayloadHash != "abcdef0123456789" || r.Advert.Socket != e.canonical() || !pidAlive(r.Advert.Pid) {
		t.Fatalf("bad advert: %+v", r.Advert)
	}
	log, _ := os.ReadFile(filepath.Join(e.home, ".webmux", "inst1.server.log"))
	if !strings.Contains(string(log), "\n--- remote-start ") || !strings.Contains(string(log), " payload abcdef012345 ---\n") {
		t.Fatalf("log header missing: %q", log)
	}
	if !strings.Contains(string(log), "fake webmux listening") {
		t.Fatalf("server stdout not in log: %q", log)
	}
	// The child must run in the payload dir with WEBMUX_PTYHOST=<name>.
	cwd, _ := os.Readlink(fmt.Sprintf("/proc/%d/cwd", r.Advert.Pid))
	if cwd != e.payload {
		t.Fatalf("child cwd %q, want %q", cwd, e.payload)
	}
	environ, _ := os.ReadFile(fmt.Sprintf("/proc/%d/environ", r.Advert.Pid))
	if !bytes.Contains(environ, []byte("\x00WEBMUX_PTYHOST=inst1\x00")) {
		t.Fatal("child env lacks WEBMUX_PTYHOST=inst1")
	}
	stat, _ := os.ReadFile(fmt.Sprintf("/proc/%d/stat", r.Advert.Pid))
	fields := strings.Fields(string(stat[bytes.LastIndexByte(stat, ')')+2:]))
	if sid, _ := strconv.Atoi(fields[3]); sid != r.Advert.Pid { // state ppid pgrp session
		t.Fatalf("child not a session leader (sid %d)", sid)
	}

	r2, code := e.run("--name=inst1")
	if code != 0 || r2.Action != "reuse" || r2.Advert.Pid != r.Advert.Pid {
		t.Fatalf("second start should reuse pid %d: %+v", r.Advert.Pid, r2)
	}
}

func TestNewPayloadReplacesOldServer(t *testing.T) {
	e := setup(t, "inst2", "1111111111111111")
	r1, _ := e.run("--name", "inst2")
	if r1.Action != "started" {
		t.Fatalf("%+v", r1)
	}
	e.setHash("2222222222222222")
	r2, code := e.run("--name", "inst2")
	if code != 0 || r2.Action != "started" || r2.Advert.PayloadHash != "2222222222222222" {
		t.Fatalf("%+v", r2)
	}
	if r2.Advert.Pid == r1.Advert.Pid || pidAlive(r1.Advert.Pid) {
		t.Fatalf("old server %d not stopped (new %d)", r1.Advert.Pid, r2.Advert.Pid)
	}
}

func TestStubbornOldServerIsKilled(t *testing.T) {
	e := setup(t, "inst2b", "3333333333333333")
	t.Setenv("FAKE_HASH", "old-hash")
	old := e.spawnOld("stubborn", []string{filepath.Join(e.payload, "webmux-host"), "serve"})
	waitFor(t, func() bool { _, err := os.Stat(filepath.Join(e.home, ".webmux", "inst2b.json")); return err == nil })
	t.Setenv("FAKE_HASH", "3333333333333333")
	r, code := e.run("--name", "inst2b")
	if code != 0 || r.Action != "started" || pidAlive(old) {
		t.Fatalf("%+v (old alive=%v)", r, pidAlive(old))
	}
}

func TestStaleAdvertWithDeadPid(t *testing.T) {
	e := setup(t, "inst3", "4444444444444444")
	dead := exec.Command("true")
	if err := dead.Run(); err != nil {
		t.Fatal(err)
	}
	_ = os.MkdirAll(filepath.Join(e.home, ".webmux"), 0o700)
	b, _ := json.Marshal(map[string]any{"socket": e.canonical(), "payloadHash": "4444444444444444",
		"protocol": 1, "pid": dead.Process.Pid, "startedAt": 1})
	_ = os.WriteFile(filepath.Join(e.home, ".webmux", "inst3.json"), b, 0o600)
	r, code := e.run("--name", "inst3")
	if code != 0 || r.Action != "started" || r.Advert.Pid == dead.Process.Pid {
		t.Fatalf("%+v", r)
	}
}

func TestLegacyNodeServerOnCanonicalSocketIsStopped(t *testing.T) {
	e := setup(t, "inst4", "5555555555555555")
	// An old node payload holding the socket, with no advert of its own.
	old := e.spawnOld("serve", []string{"node", "/home/u/.webmux/dist/payload/old/server.js"}, "FAKE_NO_ADVERT=1")
	if !pidIsWebmuxServer(old) {
		t.Fatal("node-style server not recognized via /proc")
	}
	// A dev node server of the same instance on its own socket must be spared.
	spared := exec.Command(os.Args[0])
	spared.Args = []string{"node", "/src/webmux/server.js"}
	spared.Env = append(os.Environ(), "START_FAKE_SERVE=hang", "WEBMUX_PTYHOST=inst4", "WEBMUX_SOCKET=/tmp/x.sock")
	if err := spared.Start(); err != nil {
		t.Fatal(err)
	}
	go spared.Wait()
	t.Cleanup(func() { _ = spared.Process.Kill() })

	r, code := e.run("--name", "inst4")
	if code != 0 || r.Action != "started" {
		t.Fatalf("%+v", r)
	}
	if pidAlive(old) {
		t.Fatal("legacy node server still alive")
	}
	if !pidAlive(spared.Process.Pid) {
		t.Fatal("WEBMUX_SOCKET dev server was stopped")
	}
}

func TestUnidentifiedListenerFails(t *testing.T) {
	e := setup(t, "inst5", "6666666666666666")
	dir, _ := protocol.RunDir()
	ln, err := net.Listen("unix", filepath.Join(dir, "inst5.http.sock"))
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			c.Close()
		}
	}()
	r, code := e.run("--name", "inst5")
	want := fmt.Sprintf("another process is listening on %s and could not be identified as a webmux server", e.canonical())
	if code != 1 || r.Error != want || r.LogTail != "" {
		t.Fatalf("%+v", r)
	}
}

func TestServerExitsDuringStartup(t *testing.T) {
	e := setup(t, "inst6", "7777777777777777")
	t.Setenv("START_FAKE_SERVE", "die")
	r, code := e.run("--name", "inst6")
	if code != 1 || r.Error != "server exited during startup" {
		t.Fatalf("%+v", r)
	}
	if !strings.Contains(r.LogTail, "boom: fake server failing on purpose") || !strings.Contains(r.LogTail, "--- remote-start ") {
		t.Fatalf("logTail: %q", r.LogTail)
	}
}

func TestLogTailIsLast15Lines(t *testing.T) {
	e := setup(t, "inst6b", "7777777777777777")
	t.Setenv("START_FAKE_SERVE", "die")
	_ = os.MkdirAll(filepath.Join(e.home, ".webmux"), 0o700)
	var pre strings.Builder
	for i := 0; i < 40; i++ {
		fmt.Fprintf(&pre, "old line %d\n", i)
	}
	_ = os.WriteFile(filepath.Join(e.home, ".webmux", "inst6b.server.log"), []byte(pre.String()), 0o600)
	r, _ := e.run("--name", "inst6b")
	lines := strings.Split(r.LogTail, "\n")
	if len(lines) != 15 || lines[len(lines)-1] != "" || !strings.HasPrefix(lines[len(lines)-2], "boom") {
		t.Fatalf("logTail: %q", r.LogTail)
	}
}

func TestServerNeverComesUp(t *testing.T) {
	e := setup(t, "inst7", "8888888888888888")
	t.Setenv("START_FAKE_SERVE", "hang")
	pollAttempts, pollInterval = 5, 20*time.Millisecond
	r, code := e.run("--name", "inst7")
	if code != 1 || r.Error != "server did not come up within 30s" || !strings.Contains(r.LogTail, "hanging") {
		t.Fatalf("%+v", r)
	}
}

func TestInvalidName(t *testing.T) {
	e := setup(t, "x", "9999999999999999")
	r, code := e.run("--name", "../evil")
	if code != 1 || r.Error != "invalid instance name '../evil'" {
		t.Fatalf("%+v", r)
	}
}

func TestMissingPayloadHash(t *testing.T) {
	e := setup(t, "inst8", "")
	r, code := e.run("--name", "inst8")
	if code != 1 || r.Error != "payload is missing PAYLOAD_HASH — not a built payload?" {
		t.Fatalf("%+v", r)
	}
	_ = os.WriteFile(filepath.Join(e.payload, "PAYLOAD_HASH"), []byte("  \n"), 0o644)
	if r, _ := e.run("--name", "inst8"); r.Error != "payload is missing PAYLOAD_HASH — not a built payload?" {
		t.Fatalf("blank hash: %+v", r)
	}
}

func TestDefaultName(t *testing.T) {
	e := setup(t, "default", "aaaaaaaaaaaaaaaa")
	r, code := e.run()
	if code != 0 || r.Action != "started" || filepath.Base(r.Advert.Socket) != "default.http.sock" {
		t.Fatalf("%+v", r)
	}
}

func TestCmdlineMatchers(t *testing.T) {
	cases := []struct {
		cmdline      string
		server, inst bool // pidIsWebmuxServer cmdline test; serversForInstance cmdline test
	}{
		{"node\x00/home/u/.webmux/dist/payload/abc/server.js\x00", true, true},
		{"/usr/bin/node\x00server.js\x00", true, false}, // no "webmux" in cmdline
		{"/home/u/.webmux/dist/payload/abc/webmux-host\x00serve\x00", true, true},
		{"/bin/sh\x00/tmp/webmux-host\x00serve\x00", true, true},
		{"/home/u/.webmux/dist/payload/abc/webmux-host\x00ptyhost\x00--name\x00default\x00", false, false},
		{"node\x00/home/u/.webmux/dist/payload/abc/ptyhost.js\x00--name\x00default\x00", false, false},
		{"/usr/bin/serve\x00webmux-host\x00", false, false},
		{"vim\x00notes\x00", false, false},
	}
	for _, c := range cases {
		argv := cmdlineArgs([]byte(c.cmdline))
		if got := isWebmuxServerCmdline(argv); got != c.server {
			t.Errorf("isWebmuxServerCmdline(%q) = %v", c.cmdline, got)
		}
		if got := isInstanceServer(argv, []byte("PATH=/bin\x00"), "default"); got != c.inst {
			t.Errorf("isInstanceServer(%q, default) = %v", c.cmdline, got)
		}
	}
}

func TestEnvironMatchers(t *testing.T) {
	argv := []string{"node", "/x/webmux/server.js"}
	cases := []struct {
		environ, name string
		want          bool
	}{
		{"PATH=/bin\x00", "default", true},
		{"PATH=/bin\x00", "work", false},
		{"WEBMUX_PTYHOST=\x00", "default", true},
		{"WEBMUX_PTYHOST=work\x00HOME=/h\x00", "work", true},
		{"WEBMUX_PTYHOST=work\x00", "default", false},
		{"WEBMUX_PTYHOST=work\x00WEBMUX_SOCKET=/tmp/dev.sock\x00", "work", false},
		{"WEBMUX_PTYHOST=work2\x00", "work", false},
	}
	for _, c := range cases {
		if got := isInstanceServer(argv, []byte(c.environ), c.name); got != c.want {
			t.Errorf("isInstanceServer(env %q, %s) = %v", c.environ, c.name, got)
		}
	}
}

// serversForInstance and pidIsWebmuxServer against a synthetic /proc.
func TestFakeProc(t *testing.T) {
	root := t.TempDir()
	write := func(pid int, cmdline, environ string) {
		d := filepath.Join(root, strconv.Itoa(pid))
		_ = os.MkdirAll(d, 0o755)
		_ = os.WriteFile(filepath.Join(d, "cmdline"), []byte(cmdline), 0o644)
		_ = os.WriteFile(filepath.Join(d, "environ"), []byte(environ), 0o644)
	}
	write(101, "node\x00/h/.webmux/dist/payload/a/server.js\x00", "WEBMUX_PTYHOST=work\x00")
	write(102, "/h/.webmux/dist/payload/b/webmux-host\x00serve\x00", "WEBMUX_PTYHOST=work\x00")
	write(103, "/h/.webmux/dist/payload/b/webmux-host\x00ptyhost\x00--name\x00work\x00", "WEBMUX_PTYHOST=work\x00")
	write(104, "node\x00/h/.webmux/dist/payload/a/server.js\x00", "WEBMUX_PTYHOST=other\x00")
	write(105, "node\x00/src/webmux/server.js\x00", "WEBMUX_PTYHOST=work\x00WEBMUX_SOCKET=/tmp/s\x00")
	write(os.Getpid(), "/h/webmux-host\x00serve\x00", "WEBMUX_PTYHOST=work\x00") // self is skipped
	_ = os.MkdirAll(filepath.Join(root, "self"), 0o755)

	old := procRoot
	procRoot = root
	defer func() { procRoot = old }()

	s := &starter{name: "work"}
	got := fmt.Sprint(s.serversForInstance())
	if got != "[101 102]" {
		t.Fatalf("serversForInstance = %s, want [101 102]", got)
	}

	// pidIsWebmuxServer: our (live) pid with a server cmdline → true; with a
	// pty host cmdline → false; with no /proc entry → trust liveness.
	if !pidIsWebmuxServer(os.Getpid()) {
		t.Error("live pid with webmux-host serve cmdline not recognized")
	}
	write(os.Getpid(), "/h/webmux-host\x00ptyhost\x00", "")
	if pidIsWebmuxServer(os.Getpid()) {
		t.Error("pty host recognized as server")
	}
	_ = os.RemoveAll(filepath.Join(root, strconv.Itoa(os.Getpid())))
	if !pidIsWebmuxServer(os.Getpid()) {
		t.Error("without /proc entry, liveness should be trusted")
	}
	if pidIsWebmuxServer(0) || pidIsWebmuxServer(-1) {
		t.Error("non-positive pids must not count")
	}
}
