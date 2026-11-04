package server

import (
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"github.com/fsnotify/fsnotify"
)

// Pasted images land in the paste dir. The latest one is also written to
// the "clipboard" slot that the xclip/xsel shims serve, so clipboard-reading
// CLIs (Claude Code) see it natively. Must match the pty host's paste dir
// (it exports WEBMUX_CLIPBOARD_DIR into sessions) — so start() adopts
// whatever dir the host's ping advertises; the per-user default only covers
// hosts old enough not to advertise one. Per-user because /tmp is shared: a
// fixed name is owned by whichever user's webmux touched it first, and every
// other user's writes then fail with EACCES.
var pasteExt = map[string]string{
	"image/png":  "png",
	"image/jpeg": "jpg",
	"image/gif":  "gif",
	"image/webp": "webp",
	"image/bmp":  "bmp",
}

func (s *Server) currentPasteDir() string {
	s.pasteMu.Lock()
	defer s.pasteMu.Unlock()
	return s.pasteDir
}

// newPasteFile names the next paste file: paste-<ms>-<seq>.<ext>.
func (s *Server) newPasteFile(ext string) string {
	s.pasteMu.Lock()
	seq := s.pasteSeq
	s.pasteSeq++
	dir := s.pasteDir
	s.pasteMu.Unlock()
	return filepath.Join(dir, fmt.Sprintf("paste-%d-%d.%s", time.Now().UnixMilli(), seq, ext))
}

// foregroundCmdline is the command line of the process in the foreground of
// a session's terminal (tpgid of the shell's controlling tty, via /proc).
// The shell pid comes from the pty host's snapshot frame; host and server
// share a machine, so /proc is readable directly.
func foregroundCmdline(pid string) string {
	if pid == "" {
		pid = "0" // session.pid is 0 until the snapshot arrives
	}
	stat, err := os.ReadFile("/proc/" + pid + "/stat")
	if err != nil {
		return ""
	}
	st := string(stat)
	rest := st[min(strings.LastIndexByte(st, ')')+2, len(st)):]
	fields := strings.Split(rest, " ")
	if len(fields) <= 5 {
		return ""
	}
	cmd, err := os.ReadFile("/proc/" + fields[5] + "/cmdline")
	if err != nil {
		return ""
	}
	return strings.TrimSpace(strings.ReplaceAll(string(cmd), "\x00", " "))
}

func isClaudeForeground(pid string) bool {
	argv := strings.Split(foregroundCmdline(pid), " ")
	for _, a := range argv[:min(2, len(argv))] {
		if strings.HasPrefix(jsBasename(a), "claude") {
			return true
		}
	}
	return false
}

// writeClipboardSlot updates the clipboard slot the xclip/xsel shims serve.
// Returns the decoded image and its extension, or ok=false if the payload
// isn't a supported image or the slot can't be written — never fails hard:
// clipboard syncs arrive on every window focus, and an unwritable slot (e.g.
// a paste dir owned by another user) must not take the server down.
func (s *Server) writeClipboardSlot(mime, data any) (buf []byte, ext string, ok bool) {
	m, _ := mime.(string)
	ext = pasteExt[m]
	d, isStr := data.(string)
	if ext == "" || !isStr {
		return nil, "", false
	}
	buf = decodeBase64(d)
	dir := s.currentPasteDir()
	slot := filepath.Join(dir, "clipboard")
	if err := os.WriteFile(slot, buf, 0o666); err != nil {
		fmt.Fprintf(os.Stderr, "clipboard slot write failed (%s): %s\n", slot, nodeErrString(err))
		return nil, "", false
	}
	if err := os.WriteFile(filepath.Join(dir, "clipboard.mime"), []byte(m), 0o666); err != nil {
		fmt.Fprintf(os.Stderr, "clipboard slot write failed (%s): %s\n", slot, nodeErrString(err))
		return nil, "", false
	}
	return buf, ext, true
}

func (s *Server) handlePaste(w http.ResponseWriter, r *http.Request, _ reqURL, _ []string) error {
	body, err := readJSONBody(w, r)
	if err != nil {
		return err
	}
	if err := body.destructure("mime"); err != nil {
		return err
	}
	m, _ := body.get("mime").(string)
	ext := pasteExt[m]
	data, isStr := body.get("data").(string)
	if ext == "" || !isStr {
		sendJSON(w, 400, map[string]any{"error": "expected { mime: image/*, data: base64 }"})
		return nil
	}
	file := s.newPasteFile(ext)
	if err := os.WriteFile(file, decodeBase64(data), 0o666); err != nil {
		sendJSON(w, 500, map[string]any{"error": nodeErrString(err)})
		return nil
	}
	sendJSON(w, 200, map[string]any{"path": file})
	return nil
}

// ---------------------------------------------------------------------------
// Browser-open spool (xdg-open & friends). No browser exists on this
// headless host, so the shims drop "open-*" files into the paste dir (line
// 1: session id, line 2: URL) instead of opening anything. We watch the dir,
// claim each file by rename (several webmux servers may share the spool),
// and forward the URL to the browser client as an 'open-url' message — the
// client shows an open/copy chooser.
// ---------------------------------------------------------------------------

var httpURL = regexp.MustCompile(`^https?://`)

func (s *Server) processOpenSpool(dir string) {
	ents, err := os.ReadDir(dir)
	if err != nil {
		return
	}
	for _, e := range ents {
		n := e.Name()
		if !strings.HasPrefix(n, "open-") {
			continue
		}
		claimed := filepath.Join(dir, ".claimed-"+n)
		if os.Rename(filepath.Join(dir, n), claimed) != nil {
			continue // lost the claim race
		}
		raw, err := os.ReadFile(claimed)
		if err != nil {
			continue
		}
		_ = os.Remove(claimed)
		lines := strings.Split(decodeUTF8(raw), "\n")
		sid := lines[0]
		if len(lines) < 2 || !httpURL.MatchString(lines[1]) {
			continue
		}
		url := lines[1]
		s.pasteMu.Lock()
		id := fmt.Sprintf("open-%d-%d", time.Now().UnixMilli(), s.openSeq)
		s.openSeq++
		s.pasteMu.Unlock()
		frame := jsonBytes(map[string]any{"type": "open-url", "url": url, "id": id})
		// Deliver to the session the opener ran in when known
		// (WEBMUX_SESSION, exported by the pty host); otherwise broadcast —
		// every tab's socket gets the frame, so the client dedupes by id.
		s.clientsMu.Lock()
		targets := s.bySession[sid]
		if len(targets) == 0 {
			targets = s.clients
		}
		for c := range targets {
			c.send(frame)
		}
		s.clientsMu.Unlock()
	}
}

// initPasteDir adopts a paste dir (the pty host's advertised one, or our
// default) and starts watching its spool. Called at startup and again if
// the host is respawned with a different dir; failures are logged, not
// fatal — pastes degrade, terminals keep working.
func (s *Server) initPasteDir(advertised any) {
	// A host old enough not to advertise a dir used the fixed shared one, and
	// its sessions' WEBMUX_CLIPBOARD_DIR still points there — follow it (slot
	// writes there can fail for a second user; that's logged, not fatal).
	dir, _ := advertised.(string)
	if dir == "" {
		dir = filepath.Join(os.TempDir(), "webmux-pastes")
	}
	s.pasteMu.Lock()
	defer s.pasteMu.Unlock()
	if dir != s.pasteDir {
		s.pasteDir = dir
	} else if s.pasteWatcher != nil {
		return // same dir, already watching
	}
	if s.pasteWatcher != nil {
		s.pasteWatcher.Close()
		s.pasteWatcher = nil
	}
	fail := func(err error) {
		fmt.Fprintf(os.Stderr, "paste dir unusable (%s): %s\n", dir, nodeErrString(err))
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		fail(err)
		return
	}
	// Spool files left over from before this server started are stale
	// requests; popping them up now would be surprising. Drop them (each on
	// its own — in a shared legacy dir some may belong to another user).
	ents, err := os.ReadDir(dir)
	if err != nil {
		fail(err)
		return
	}
	for _, e := range ents {
		if n := e.Name(); strings.HasPrefix(n, "open-") || strings.HasPrefix(n, ".claimed-open-") {
			_ = os.Remove(filepath.Join(dir, n))
		}
	}
	w, err := fsnotify.NewWatcher()
	if err != nil {
		fail(err)
		return
	}
	if err := w.Add(dir); err != nil {
		w.Close()
		fail(err)
		return
	}
	s.pasteWatcher = w
	go func() {
		for {
			select {
			case _, ok := <-w.Events:
				if !ok {
					return
				}
				s.processOpenSpool(dir)
			case _, ok := <-w.Errors:
				if !ok {
					return
				}
			}
		}
	}()
}

func writeFile(p string, b []byte) error { return os.WriteFile(p, b, 0o666) }

func logErr(format string, a ...any) { fmt.Fprintf(os.Stderr, format+"\n", a...) }
