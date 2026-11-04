package server

import (
	"archive/zip"
	"bufio"
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
)

type env struct {
	t      *testing.T
	root   string
	home   string
	paste  string
	sock   string
	host   *fakeHost
	srv    *Server
	client *http.Client
}

func setup(t *testing.T) *env {
	t.Helper()
	root, err := os.MkdirTemp("", "wmsrv")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(root) })
	e := &env{t: t, root: root, home: filepath.Join(root, "home"), paste: filepath.Join(root, "pastes"), sock: filepath.Join(root, "http.sock")}
	os.MkdirAll(e.home, 0o700)
	os.MkdirAll(filepath.Join(root, "run"), 0o700)
	os.MkdirAll(filepath.Join(root, "tmp"), 0o700)
	t.Setenv("XDG_RUNTIME_DIR", filepath.Join(root, "run"))
	t.Setenv("HOME", e.home)
	t.Setenv("TMPDIR", filepath.Join(root, "tmp"))
	name := fmt.Sprintf("fake-%d", time.Now().UnixNano())
	t.Setenv("WEBMUX_PTYHOST", name)
	t.Setenv("WEBMUX_SOCKET", e.sock)
	e.host = startFakeHost(t, name, e.paste)

	s, err := newServer()
	if err != nil {
		t.Fatal(err)
	}
	if err := s.start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(s.close)
	e.srv = s
	e.client = &http.Client{Transport: &http.Transport{
		DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
			var d net.Dialer
			return d.DialContext(ctx, "unix", e.sock)
		},
	}}
	// the watch connection is up once the fake has registered it
	waitFor(t, func() bool { return e.host.watcherCount() > 0 })
	return e
}

func waitFor(t *testing.T, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for !cond() {
		if time.Now().After(deadline) {
			t.Fatal("timed out waiting for condition")
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func (e *env) do(method, path string, body io.Reader) (*http.Response, []byte) {
	e.t.Helper()
	req, _ := http.NewRequest(method, "http://webmux"+path, body)
	res, err := e.client.Do(req)
	if err != nil {
		e.t.Fatal(err)
	}
	defer res.Body.Close()
	b, _ := io.ReadAll(res.Body)
	return res, b
}

func (e *env) jsonDo(method, path string, body any, want int) map[string]any {
	e.t.Helper()
	var r io.Reader
	if body != nil {
		if s, ok := body.(string); ok {
			r = strings.NewReader(s)
		} else {
			b, _ := json.Marshal(body)
			r = bytes.NewReader(b)
		}
	}
	res, b := e.do(method, path, r)
	if res.StatusCode != want {
		e.t.Fatalf("%s %s: status %d, want %d (%s)", method, path, res.StatusCode, want, b)
	}
	if res.Header.Get("Access-Control-Allow-Origin") != "*" {
		e.t.Fatalf("%s %s: missing CORS header", method, path)
	}
	var out map[string]any
	if err := json.Unmarshal(b, &out); err != nil {
		e.t.Fatalf("%s %s: bad JSON %q", method, path, b)
	}
	return out
}

func q(p string) string { return url.QueryEscape(p) }

func TestHealthCORSAndNotFound(t *testing.T) {
	e := setup(t)
	h := e.jsonDo("GET", "/", nil, 200)
	if h["ok"] != true || h["server"] != "webmux" || h["payloadHash"] != "dev" || h["ptyhost"] != e.srv.hostName {
		t.Fatalf("health: %v", h)
	}
	res, b := e.do("OPTIONS", "/api/sessions", nil)
	if res.StatusCode != 204 || len(b) != 0 ||
		res.Header.Get("Access-Control-Allow-Origin") != "*" ||
		res.Header.Get("Access-Control-Allow-Methods") != "GET, POST, DELETE, OPTIONS" ||
		res.Header.Get("Access-Control-Allow-Headers") != "Content-Type" ||
		res.Header.Get("Access-Control-Max-Age") != "600" {
		t.Fatalf("OPTIONS: %d %v", res.StatusCode, res.Header)
	}
	if nf := e.jsonDo("GET", "/nope", nil, 404); nf["error"] != "not found" {
		t.Fatal(nf)
	}
	e.jsonDo("PUT", "/api/sessions", nil, 404)
	if bad := e.jsonDo("POST", "/api/sessions", "{nope", 400); bad["error"] != "invalid JSON body" {
		t.Fatal(bad)
	}
	if r := e.jsonDo("POST", "/api/paste", "null", 500); !strings.Contains(r["error"].(string), "destructure") {
		t.Fatal(r)
	}
	if r := e.jsonDo("POST", "/api/paste", map[string]any{"mime": "text/plain", "data": "x"}, 400); r["error"] != "expected { mime: image/*, data: base64 }" {
		t.Fatal(r)
	}
	// JSON_LIMIT: 30 MB
	big := bytes.Repeat([]byte("a"), jsonLimit+10)
	req, _ := http.NewRequest("POST", "http://webmux/api/paste", bytes.NewReader(big))
	if res, err := e.client.Do(req); err == nil {
		if res.StatusCode != 413 {
			t.Fatalf("oversized body: %d", res.StatusCode)
		}
		res.Body.Close()
	}
}

func TestSessionsRoundTrip(t *testing.T) {
	e := setup(t)
	res, b := e.do("GET", "/api/sessions", nil)
	if res.StatusCode != 200 || string(b) != "[]" {
		t.Fatalf("empty list: %d %s", res.StatusCode, b)
	}
	c := e.jsonDo("POST", "/api/sessions", map[string]any{"cols": 100, "rows": 0}, 201)
	id := c["id"].(string)
	if id != "s1-100-24" { // rows || 24
		t.Fatalf("create id %q", id)
	}
	e.jsonDo("POST", "/api/sessions", nil, 201) // empty body → {} → 80x24
	_, b = e.do("GET", "/api/sessions", nil)
	var list []map[string]any
	json.Unmarshal(b, &list)
	if len(list) != 2 || list[0]["id"] != id || list[1]["id"] != "s2-80-24" || list[0]["createdAt"] != float64(1730000000123) {
		t.Fatalf("list: %s", b)
	}
	if r := e.jsonDo("DELETE", "/api/sessions/"+id, nil, 200); r["ok"] != true {
		t.Fatal(r)
	}
	if r := e.jsonDo("DELETE", "/api/sessions/"+id, nil, 404); r["error"] != "no such session" {
		t.Fatal(r)
	}
	if r := e.jsonDo("DELETE", "/api/sessions/%E0%A4", nil, 502); r["error"] != "URI malformed" {
		t.Fatal(r)
	}
}

func dialWS(t *testing.T, e *env, session string) *websocket.Conn {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	c, _, err := websocket.Dial(ctx, "ws://webmux/ws?session="+session, &websocket.DialOptions{
		HTTPClient: e.client,
		HTTPHeader: http.Header{"Origin": []string{"webmux://app"}},
	})
	if err != nil {
		t.Fatal(err)
	}
	c.SetReadLimit(-1)
	t.Cleanup(func() { c.CloseNow() })
	return c
}

func readWS(t *testing.T, c *websocket.Conn) []byte {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	typ, b, err := c.Read(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if typ != websocket.MessageText {
		t.Fatalf("message type %v", typ)
	}
	return b
}

// readWSType skips frames until one of the given type arrives.
func readWSType(t *testing.T, c *websocket.Conn, typ string) map[string]any {
	t.Helper()
	for {
		var m map[string]any
		json.Unmarshal(readWS(t, c), &m)
		if m["type"] == typ {
			return m
		}
	}
}

func nextInput(t *testing.T, f *fakeHost) fakeInput {
	t.Helper()
	select {
	case in := <-f.inputs:
		return in
	case <-time.After(5 * time.Second):
		t.Fatal("no input reached the host")
	}
	return fakeInput{}
}

func TestWebSocketAttach(t *testing.T) {
	e := setup(t)
	ws := dialWS(t, e, "abc")
	if got, want := string(readWS(t, ws)), e.host.snapshotFrame("abc"); got != want {
		t.Fatalf("snapshot not verbatim:\n got %s\nwant %s", got, want)
	}
	ctx := context.Background()
	ws.Write(ctx, websocket.MessageText, []byte(`{"type":"input","data":"ls\r"}`))
	if in := nextInput(t, e.host); in.session != "abc" || in.line != `{"type":"input","data":"ls\r"}` {
		t.Fatalf("input: %+v", in)
	}
	ws.Write(ctx, websocket.MessageText, []byte(`{"type":"resize", "cols": 120,`+"\n"+` "rows": 40, "x": 1}`))
	if in := nextInput(t, e.host); in.line != `{"type":"resize","cols":120,"rows":40}` {
		t.Fatalf("resize: %+v", in)
	}
	ws.Write(ctx, websocket.MessageText, []byte(`not json`))
	ws.Write(ctx, websocket.MessageText, []byte(`null`))

	// session-title from the watch connection fans out verbatim
	title := `{"type":"session-title","session":"other","title":"vim"}`
	e.host.pushWatch(title)
	if got := string(readWS(t, ws)); got != title {
		t.Fatalf("session-title: %s", got)
	}

	// host closes → exit frame delivered, then the browser socket closes
	e.host.closeSession("abc")
	if got := string(readWS(t, ws)); got != `{"type":"exit","exitCode":0}` {
		t.Fatalf("exit: %s", got)
	}
	rctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	if _, _, err := ws.Read(rctx); websocket.CloseStatus(err) != websocket.StatusNormalClosure {
		t.Fatalf("expected normal close, got %v", err)
	}
	waitFor(t, func() bool {
		e.srv.clientsMu.Lock()
		defer e.srv.clientsMu.Unlock()
		return len(e.srv.clients) == 0
	})
}

func TestBrowserCloseClosesHostConn(t *testing.T) {
	e := setup(t)
	ws := dialWS(t, e, "x1")
	readWS(t, ws)
	ws.Close(websocket.StatusNormalClosure, "")
	waitFor(t, func() bool {
		e.srv.clientsMu.Lock()
		defer e.srv.clientsMu.Unlock()
		return len(e.srv.clients) == 0
	})
	// the fake's attach read loop ends when the server drops the conn
	e.host.mu.Lock()
	c := e.host.attached["x1"][0]
	e.host.mu.Unlock()
	c.SetReadDeadline(time.Now().Add(5 * time.Second))
	if _, err := c.Read(make([]byte, 1)); err == nil {
		// the fake's own goroutine may have consumed EOF first; a read
		// error of any kind (EOF, closed) is what we want
		t.Fatal("host conn still open")
	}
}

func TestOpenURLSpool(t *testing.T) {
	e := setup(t)
	a := dialWS(t, e, "sa")
	b := dialWS(t, e, "sb")
	readWS(t, a)
	readWS(t, b)
	spool := func(name, content string) {
		tmp := filepath.Join(e.paste, ".tmp-"+name)
		os.WriteFile(tmp, []byte(content), 0o600)
		os.Rename(tmp, filepath.Join(e.paste, name))
	}
	spool("open-1", "sb\nhttps://example.com/x\n")
	m := readWSType(t, b, "open-url")
	if m["url"] != "https://example.com/x" || !strings.HasPrefix(m["id"].(string), "open-") {
		t.Fatal(m)
	}
	// unknown session → broadcast to everyone; non-http URLs are dropped
	spool("open-2", "nobody\nfile:///etc/passwd\n")
	spool("open-3", "nobody\nhttp://example.org\n")
	if m := readWSType(t, a, "open-url"); m["url"] != "http://example.org" {
		t.Fatal(m)
	}
	if m := readWSType(t, b, "open-url"); m["url"] != "http://example.org" {
		t.Fatal(m)
	}
	waitFor(t, func() bool {
		ents, _ := os.ReadDir(e.paste)
		for _, en := range ents {
			if strings.Contains(en.Name(), "open-") {
				return false
			}
		}
		return true
	})
}

func TestPasteImage(t *testing.T) {
	e := setup(t)
	ws := dialWS(t, e, "p1")
	readWS(t, ws)
	img := []byte("\x89PNG\r\n\x1a\nfake")
	msg, _ := json.Marshal(map[string]any{"type": "paste-image", "mime": "image/png", "data": base64.StdEncoding.EncodeToString(img)})
	ws.Write(context.Background(), websocket.MessageText, msg)
	res := readWSType(t, ws, "paste-result")
	if res["mode"] != "path" { // the fake pid is no real shell
		t.Fatal(res)
	}
	p := res["path"].(string)
	if !strings.HasPrefix(p, e.paste+"/paste-") || !strings.HasSuffix(p, ".png") {
		t.Fatal(p)
	}
	if got, _ := os.ReadFile(p); !bytes.Equal(got, img) {
		t.Fatal("paste file content")
	}
	if got, _ := os.ReadFile(filepath.Join(e.paste, "clipboard")); !bytes.Equal(got, img) {
		t.Fatal("clipboard slot content")
	}
	if got, _ := os.ReadFile(filepath.Join(e.paste, "clipboard.mime")); string(got) != "image/png" {
		t.Fatal("clipboard.mime")
	}
	in := nextInput(t, e.host)
	var f map[string]any
	json.Unmarshal([]byte(in.line), &f)
	if f["type"] != "input" || f["data"] != "'"+p+"' " {
		t.Fatalf("typed path: %s", in.line)
	}

	// clipboard-sync: slot only, nothing typed
	sync, _ := json.Marshal(map[string]any{"type": "clipboard-sync", "mime": "image/gif", "data": "R0lG"})
	ws.Write(context.Background(), websocket.MessageText, sync)
	waitFor(t, func() bool {
		b, _ := os.ReadFile(filepath.Join(e.paste, "clipboard.mime"))
		return string(b) == "image/gif"
	})
	select {
	case in := <-e.host.inputs:
		t.Fatalf("clipboard-sync typed something: %s", in.line)
	case <-time.After(100 * time.Millisecond):
	}

	// HTTP paste
	r := e.jsonDo("POST", "/api/paste", map[string]any{"mime": "image/jpeg", "data": "/9j/"}, 200)
	if got, _ := os.ReadFile(r["path"].(string)); !bytes.Equal(got, []byte{0xff, 0xd8, 0xff}) {
		t.Fatal(r)
	}
}

func TestFsListPreviewRaw(t *testing.T) {
	e := setup(t)
	d := filepath.Join(e.root, "tree")
	os.MkdirAll(filepath.Join(d, "Beta"), 0o755)
	os.MkdirAll(filepath.Join(d, "alpha"), 0o755)
	os.WriteFile(filepath.Join(d, "b.txt"), []byte("hello\nwörld"), 0o644)
	os.WriteFile(filepath.Join(d, "A.bin"), []byte{1, 2, 0, 3}, 0o644)
	os.WriteFile(filepath.Join(d, "_x"), nil, 0o644)
	os.Symlink(filepath.Join(d, "alpha"), filepath.Join(d, "link"))
	os.Symlink(filepath.Join(d, "missing"), filepath.Join(d, "broken"))

	l := e.jsonDo("GET", "/api/fs/list?path="+q(d), nil, 200)
	var names []string
	for _, x := range l["entries"].([]any) {
		m := x.(map[string]any)
		s := m["name"].(string) + ":" + m["type"].(string)
		if m["symlink"] == true {
			s += ":l"
		}
		names = append(names, s)
	}
	want := "alpha:dir Beta:dir link:dir:l _x:file A.bin:file b.txt:file broken:file:l"
	if strings.Join(names, " ") != want || l["path"] != d || l["truncated"] != false {
		t.Fatalf("list: %v", l)
	}
	if r := e.jsonDo("GET", "/api/fs/list?path="+q(d+"/nope"), nil, 400); r["error"] != "ENOENT" {
		t.Fatal(r)
	}
	if r := e.jsonDo("GET", "/api/fs/list?path=~", nil, 200); r["path"] != e.home {
		t.Fatal(r)
	}

	p := e.jsonDo("GET", "/api/fs/preview?path="+q(d+"/b.txt"), nil, 200)
	if p["kind"] != "text" || p["content"] != "hello\nwörld" || p["truncated"] != false || p["size"] != float64(12) || p["mtime"].(float64) < 1e12 {
		t.Fatal(p)
	}
	if p := e.jsonDo("GET", "/api/fs/preview?path="+q(d+"/A.bin"), nil, 200); p["kind"] != "binary" {
		t.Fatal(p)
	}
	if p := e.jsonDo("GET", "/api/fs/preview?path="+q(d+"/alpha"), nil, 200); p["kind"] != "other" {
		t.Fatal(p)
	}
	// zip: listing in archive order
	var zb bytes.Buffer
	zw := zip.NewWriter(&zb)
	for _, n := range []string{"z/", "z/b.txt", "a.txt", "ünï.txt"} {
		w, _ := zw.Create(n)
		if !strings.HasSuffix(n, "/") {
			w.Write([]byte(strings.Repeat("x", len(n))))
		}
	}
	zw.SetComment("comment")
	zw.Close()
	os.WriteFile(filepath.Join(d, "t.jar"), zb.Bytes(), 0o644)
	z := e.jsonDo("GET", "/api/fs/preview?path="+q(d+"/t.jar"), nil, 200)
	ents, _ := json.Marshal(z["entries"])
	if z["kind"] != "zip" || z["count"] != float64(4) || z["truncated"] != false ||
		string(ents) != `[{"dir":true,"name":"z/","size":0},{"dir":false,"name":"z/b.txt","size":7},{"dir":false,"name":"a.txt","size":5},{"dir":false,"name":"ünï.txt","size":9}]` {
		t.Fatalf("zip: %v %s", z, ents)
	}
	// a .zip that isn't one falls back to the binary/text verdict
	os.WriteFile(filepath.Join(d, "fake.zip"), []byte(strings.Repeat("not a zip at all ", 3)), 0o644)
	if p := e.jsonDo("GET", "/api/fs/preview?path="+q(d+"/fake.zip"), nil, 200); p["kind"] != "text" {
		t.Fatal(p)
	}
	os.WriteFile(filepath.Join(d, "pic.PNG"), []byte{0x89, 0}, 0o644)
	if p := e.jsonDo("GET", "/api/fs/preview?path="+q(d+"/pic.PNG"), nil, 200); p["kind"] != "image" {
		t.Fatal(p)
	}

	res, b := e.do("GET", "/api/fs/raw?path="+q(d+"/pic.PNG"), nil)
	if res.StatusCode != 200 || res.Header.Get("Content-Type") != "image/png" || res.Header.Get("Content-Length") != "2" || !bytes.Equal(b, []byte{0x89, 0}) || res.Header.Get("Access-Control-Allow-Origin") != "*" {
		t.Fatalf("raw: %d %v", res.StatusCode, res.Header)
	}
	os.WriteFile(filepath.Join(d, `ü "q".txt`), []byte("x"), 0o644)
	res, _ = e.do("GET", "/api/fs/raw?download=1&path="+q(d+`/ü "q".txt`), nil)
	if cd := res.Header.Get("Content-Disposition"); res.Header.Get("Content-Type") != "application/octet-stream" ||
		cd != `attachment; filename="_ _q_.txt"; filename*=UTF-8''%C3%BC%20%22q%22.txt` {
		t.Fatalf("download: %q", cd)
	}
	if r := e.jsonDo("GET", "/api/fs/raw?path="+q(d), nil, 400); r["error"] != "not a file" {
		t.Fatal(r)
	}
}

func TestFsUploadRenameDelete(t *testing.T) {
	e := setup(t)
	d := filepath.Join(e.root, "up")
	os.MkdirAll(d, 0o755)
	up := func(name, body string) string {
		res, b := e.do("POST", "/api/fs/upload?dir="+q(d)+"&name="+q(name), strings.NewReader(body))
		if res.StatusCode != 200 {
			t.Fatalf("upload %s: %d %s", name, res.StatusCode, b)
		}
		var m map[string]any
		json.Unmarshal(b, &m)
		return m["name"].(string)
	}
	if n := up("a.txt", "1"); n != "a.txt" {
		t.Fatal(n)
	}
	if n := up("a.txt", "2"); n != "a (1).txt" {
		t.Fatal(n)
	}
	if n := up("a.txt", "3"); n != "a (2).txt" {
		t.Fatal(n)
	}
	if n := up(".bashrc", "x"); n != ".bashrc" {
		t.Fatal(n)
	}
	if n := up(".bashrc", "x"); n != ".bashrc (1)" {
		t.Fatal(n)
	}
	if n := up("dir/./sub//f.txt", "deep"); n != "dir/sub/f.txt" {
		t.Fatal(n)
	}
	if n := up("dir/sub/f.txt", "deep2"); n != "dir/sub/f (1).txt" {
		t.Fatal(n)
	}
	if n := up("", "anon"); n != "file" {
		t.Fatal(n)
	}
	if b, _ := os.ReadFile(filepath.Join(d, "dir/sub/f.txt")); string(b) != "deep" {
		t.Fatal(string(b))
	}
	res, b := e.do("POST", "/api/fs/upload?dir="+q(d)+"&name=x%2F..%2Fy", strings.NewReader("z"))
	if res.StatusCode != 400 || !strings.Contains(string(b), "invalid name") {
		t.Fatal(string(b))
	}

	if r := e.jsonDo("POST", "/api/fs/rename", map[string]any{"path": d + "/a.txt", "name": "b.txt"}, 200); r["ok"] != true || r["name"] != "b.txt" {
		t.Fatal(r)
	}
	if r := e.jsonDo("POST", "/api/fs/rename", map[string]any{"path": d + "/b.txt", "name": "a (1).txt"}, 400); r["error"] != "name already taken" {
		t.Fatal(r)
	}
	if r := e.jsonDo("POST", "/api/fs/rename", map[string]any{"path": d + "/b.txt", "name": "x/y"}, 400); r["error"] != "invalid name" {
		t.Fatal(r)
	}
	if r := e.jsonDo("POST", "/api/fs/rename", map[string]any{"path": d + "/nope", "name": "z"}, 400); r["error"] != "ENOENT" {
		t.Fatal(r)
	}
	if !exists(filepath.Join(d, "b.txt")) || exists(filepath.Join(d, "a.txt")) {
		t.Fatal("rename did not happen")
	}

	if r := e.jsonDo("POST", "/api/fs/delete", map[string]any{"path": d + "/dir"}, 200); r["ok"] != true || exists(d+"/dir") {
		t.Fatal(r)
	}
	if r := e.jsonDo("POST", "/api/fs/delete", map[string]any{"path": d + "/dir"}, 400); r["error"] != "ENOENT" {
		t.Fatal(r)
	}
	for _, p := range []any{"/", "~", nil, 5} {
		if r := e.jsonDo("POST", "/api/fs/delete", map[string]any{"path": p}, 400); r["error"] != "refusing to delete that" {
			t.Fatal(p, r)
		}
	}
}

func TestFsWatch(t *testing.T) {
	e := setup(t)
	d := filepath.Join(e.root, "w")
	os.MkdirAll(d, 0o755)
	req, _ := http.NewRequest("GET", "http://webmux/api/fs/watch?path="+q(d), nil)
	res, err := e.client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	if res.Header.Get("Content-Type") != "text/event-stream" || res.Header.Get("Access-Control-Allow-Origin") != "*" {
		t.Fatal(res.Header)
	}
	events := make(chan string, 16)
	go func() {
		sc := bufio.NewScanner(res.Body)
		var ev string
		for sc.Scan() {
			l := sc.Text()
			if strings.HasPrefix(l, "event: ") {
				ev = l[7:]
			} else if strings.HasPrefix(l, "data: ") {
				events <- ev + " " + l[6:]
			}
		}
		close(events)
	}()
	next := func() string {
		select {
		case ev := <-events:
			return ev
		case <-time.After(5 * time.Second):
			t.Fatal("no SSE event")
		}
		return ""
	}
	pathJSON, _ := json.Marshal(d)
	if ev := next(); ev != `ready {"path":`+string(pathJSON)+`}` {
		t.Fatal(ev)
	}
	// a burst coalesces into one change
	for i := 0; i < 5; i++ {
		os.WriteFile(filepath.Join(d, fmt.Sprint(i)), []byte("x"), 0o644)
	}
	if ev := next(); ev != `change {"path":`+string(pathJSON)+`}` {
		t.Fatal(ev)
	}
	select {
	case ev := <-events:
		t.Fatalf("burst not coalesced: %s", ev)
	case <-time.After(250 * time.Millisecond):
	}
	os.RemoveAll(d)
	for {
		ev := next()
		if strings.HasPrefix(ev, "gone ") {
			if ev != `gone {"path":`+string(pathJSON)+`,"error":"ENOENT"}` {
				t.Fatal(ev)
			}
			break
		}
	}
	if _, ok := <-events; ok {
		t.Fatal("stream did not end after gone")
	}

	// watching a missing dir: immediate gone
	res2, b := e.do("GET", "/api/fs/watch?path="+q(d), nil)
	if res2.StatusCode != 200 || !strings.Contains(string(b), "event: gone") || !strings.Contains(string(b), `"error":"ENOENT"`) {
		t.Fatal(string(b))
	}
}

func TestHelpers(t *testing.T) {
	cases := map[string]string{".bashrc": "", "..foo": ".foo", "a..": ".", "foo.": ".", "..": "", "...": ".", "a.b.c": ".c", ".a.b": ".b", "x/.y": ""}
	for in, want := range cases {
		if got := jsExtname(in); got != want {
			t.Errorf("extname(%q) = %q, want %q", in, got, want)
		}
	}
	if got := decodeUTF8([]byte("a\xe2\x82b\xffc\xe2\x82")); got != "a�b�c�" {
		t.Errorf("decodeUTF8: %q", got)
	}
	if got := string(decodeBase64("aGV sbG8=junk")); got != "hello" {
		t.Errorf("base64: %q", got)
	}
	if got := decodeBase64("_-8"); !bytes.Equal(got, []byte{0xff, 0xef}) {
		t.Errorf("base64 url: %x", got)
	}
	// node: [..."Z~1äbéeEfßssst"].sort(localeCompare base) order checks
	order := []string{"~", "1", "ä", "b", "é", "f", "ss", "st", "Z", "中"}
	for i := 0; i+1 < len(order); i++ {
		if localeCompareBase(order[i], order[i+1]) >= 0 {
			t.Errorf("collation: %q !< %q", order[i], order[i+1])
		}
	}
	if localeCompareBase("ß", "ss") != 0 || localeCompareBase("E", "e") != 0 || localeCompareBase("a-b", "ab") >= 0 {
		t.Error("collation equalities")
	}
	s := &Server{home: "/h"}
	for in, want := range map[string]string{"": "/h", "~": "/h", "~/": "/h", "~/a/../b/": "/h/b/", "/x//y/": "/x/y"} {
		if got := s.resolveFsPath(in); got != want {
			t.Errorf("resolveFsPath(%q) = %q, want %q", in, got, want)
		}
	}
	cwd, _ := os.Getwd()
	if got := s.resolveFsPath("rel/x"); got != filepath.Join(cwd, "rel/x") {
		t.Error(got)
	}
	if jsDirname("/a/b/") != "/a" || jsDirname("/a") != "/" || jsDirname("/") != "/" {
		t.Error("dirname")
	}
}
