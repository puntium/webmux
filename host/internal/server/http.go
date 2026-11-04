package server

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"regexp"
	"strings"
)

// ---------------------------------------------------------------------------
// HTTP API — a hand-rolled router over net/http, as server.js does over
// node:http. The route surface is small and JSON-shaped.
// ---------------------------------------------------------------------------

const (
	jsonLimit   = 30 * 1024 * 1024 // pasted images arrive as base64 JSON
	uploadLimit = 200 * 1024 * 1024
)

// The client pages live on their own webmux:// origin, so every API call is
// cross-origin. Wave everything through: the unix socket's permissions and
// sshd are the access control, and nothing else can reach this socket.
func setCORS(h http.Header) { h.Set("Access-Control-Allow-Origin", "*") }

// jsonBytes encodes v like JSON.stringify: no HTML escaping, no newline.
func jsonBytes(v any) []byte {
	var b bytes.Buffer
	enc := json.NewEncoder(&b)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(v); err != nil {
		return []byte("null")
	}
	return bytes.TrimSuffix(b.Bytes(), []byte("\n"))
}

func sendJSON(w http.ResponseWriter, code int, v any) {
	h := w.Header()
	h.Set("Content-Type", "application/json")
	setCORS(h)
	w.WriteHeader(code)
	_, _ = w.Write(jsonBytes(v))
}

// sendRawJSON sends an already-encoded JSON body (or nothing, mirroring
// res.end(JSON.stringify(undefined))).
func sendRawJSON(w http.ResponseWriter, code int, body []byte) {
	h := w.Header()
	h.Set("Content-Type", "application/json")
	setCORS(h)
	w.WriteHeader(code)
	_, _ = w.Write(body)
}

// httpError is a thrown error carrying an HTTP status (err.status in JS).
type httpError struct {
	status int
	msg    string
}

func (e *httpError) Error() string { return e.msg }

func errStatus(status int, msg string) error { return &httpError{status, msg} }

// readBody reads the request body, failing with 413 past limit. Node
// destroys the request socket at that point; here the 413 JSON is sent and
// the connection is closed (see the report: the node client usually saw a
// reset instead of the 413).
func readBody(w http.ResponseWriter, r *http.Request, limit int64) ([]byte, error) {
	b, err := io.ReadAll(io.LimitReader(r.Body, limit+1))
	if int64(len(b)) > limit {
		w.Header().Set("Connection", "close")
		return nil, errStatus(413, "payload too large")
	}
	if err != nil {
		return nil, err
	}
	return b, nil
}

// jsBody is a decoded JSON request body. JSON null is remembered so the
// handlers that destructure it can fail like JS does.
type jsBody struct {
	val any
}

func (b jsBody) get(key string) any {
	if m, ok := b.val.(map[string]any); ok {
		return m[key]
	}
	return nil
}

// destructure mirrors `const { a } = body`: TypeError (→ 500) on null.
func (b jsBody) destructure(first string) error {
	if b.val == nil {
		return fmt.Errorf("Cannot destructure property '%s' of '(intermediate value)' as it is null.", first)
	}
	return nil
}

func readJSONBody(w http.ResponseWriter, r *http.Request) (jsBody, error) {
	raw, err := readBody(w, r, jsonLimit)
	if err != nil {
		return jsBody{}, err
	}
	if len(raw) == 0 {
		return jsBody{val: map[string]any{}}, nil
	}
	var v any
	if err := json.Unmarshal([]byte(decodeUTF8(raw)), &v); err != nil {
		return jsBody{}, errStatus(400, "invalid JSON body")
	}
	return jsBody{val: v}, nil
}

// trackingWriter remembers whether headers were sent (res.headersSent).
type trackingWriter struct {
	http.ResponseWriter
	sent bool
}

func (t *trackingWriter) WriteHeader(code int) {
	t.sent = true
	t.ResponseWriter.WriteHeader(code)
}

func (t *trackingWriter) Write(b []byte) (int, error) {
	t.sent = true
	return t.ResponseWriter.Write(b)
}

func (t *trackingWriter) Flush() {
	if f, ok := t.ResponseWriter.(http.Flusher); ok {
		t.sent = true
		f.Flush()
	}
}

func (t *trackingWriter) Unwrap() http.ResponseWriter { return t.ResponseWriter }

// reqURL is the parsed request URL as the JS handlers see it: pathname in
// its percent-encoded form, query values decoded like URLSearchParams.
type reqURL struct {
	pathname string
	query    url.Values
}

// param mirrors url.searchParams.get: the first value, or ok=false (null).
func (u reqURL) param(name string) (string, bool) {
	vs, ok := u.query[name]
	if !ok || len(vs) == 0 {
		return "", false
	}
	// URLSearchParams decodes percent-escapes as UTF-8 with replacement.
	return decodeUTF8([]byte(vs[0])), true
}

type handler func(w http.ResponseWriter, r *http.Request, u reqURL, m []string) error

type route struct {
	method string
	exact  string
	re     *regexp.Regexp
	h      handler
}

func (s *Server) routes() []route {
	return []route{
		{method: "GET", exact: "/", h: s.handleHealth},
		{method: "GET", exact: "/api/sessions", h: s.handleSessionsList},
		{method: "POST", exact: "/api/sessions", h: s.handleSessionsCreate},
		{method: "POST", exact: "/api/paste", h: s.handlePaste},
		{method: "GET", exact: "/api/fs/list", h: s.handleFsList},
		{method: "GET", exact: "/api/fs/preview", h: s.handleFsPreview},
		{method: "GET", exact: "/api/fs/watch", h: s.handleFsWatch},
		{method: "POST", exact: "/api/fs/upload", h: s.handleFsUpload},
		{method: "POST", exact: "/api/fs/delete", h: s.handleFsDelete},
		{method: "POST", exact: "/api/fs/rename", h: s.handleFsRename},
		{method: "GET", exact: "/api/fs/raw", h: s.handleFsRaw},
		{method: "DELETE", re: regexp.MustCompile(`^/api/sessions/([^/]+)$`), h: s.handleSessionsDelete},
	}
}

// ServeHTTP is handleHttp plus the WebSocket upgrade on /ws.
func (s *Server) ServeHTTP(rw http.ResponseWriter, r *http.Request) {
	w := &trackingWriter{ResponseWriter: rw}
	defer func() {
		if p := recover(); p != nil {
			if p == http.ErrAbortHandler {
				panic(p)
			}
			fmt.Fprintf(os.Stderr, "http handler panic: %v\n", p)
			if !w.sent {
				sendJSON(w, 500, map[string]any{"error": fmt.Sprint(p)})
			}
		}
	}()
	u := reqURL{pathname: r.URL.EscapedPath(), query: r.URL.Query()}
	if u.pathname == "" {
		u.pathname = "/"
	}

	// The ws library owns every upgrade request: /ws is accepted, any other
	// path is refused with 400 (abortHandshake), as the node server did.
	if isUpgrade(r) {
		if u.pathname == "/ws" {
			s.handleWS(rw, r, u)
		} else {
			http.Error(rw, "Bad Request", 400)
		}
		return
	}

	if r.Method == "OPTIONS" { // preflight for the webmux:// pages' fetches
		h := w.Header()
		setCORS(h)
		h.Set("Access-Control-Allow-Methods", "GET, POST, DELETE, OPTIONS")
		h.Set("Access-Control-Allow-Headers", "Content-Type")
		h.Set("Access-Control-Max-Age", "600")
		w.WriteHeader(204)
		return
	}
	for _, rt := range s.routeTable {
		if rt.method != r.Method {
			continue
		}
		var m []string
		if rt.re == nil {
			if rt.exact == u.pathname {
				m = []string{u.pathname}
			}
		} else {
			m = rt.re.FindStringSubmatch(u.pathname)
		}
		if m == nil {
			continue
		}
		if err := rt.h(w, r, u, m); err != nil {
			if !w.sent {
				status := 500
				var he *httpError
				if errors.As(err, &he) {
					status = he.status
				}
				sendJSON(w, status, map[string]any{"error": err.Error()})
			}
		}
		return
	}
	sendJSON(w, 404, map[string]any{"error": "not found"})
}

func isUpgrade(r *http.Request) bool {
	for _, v := range r.Header.Values("Connection") {
		for _, t := range strings.Split(v, ",") {
			if strings.EqualFold(strings.TrimSpace(t), "upgrade") {
				return strings.EqualFold(r.Header.Get("Upgrade"), "websocket")
			}
		}
	}
	return false
}

// ---------------------------------------------------------------------------
// Health / sessions
// ---------------------------------------------------------------------------

// Health / identity — the Electron client polls this through the tunnel to
// decide when the server is up (main.js pollServer).
func (s *Server) handleHealth(w http.ResponseWriter, _ *http.Request, _ reqURL, _ []string) error {
	sendJSON(w, 200, map[string]any{"ok": true, "server": "webmux", "payloadHash": s.payloadHash, "ptyhost": s.hostName})
	return nil
}

func (s *Server) handleSessionsList(w http.ResponseWriter, _ *http.Request, _ reqURL, _ []string) error {
	r, err := s.hostControl(map[string]any{"cmd": "list"})
	if err != nil {
		sendJSON(w, 502, map[string]any{"error": err.Error()})
		return nil
	}
	sessions, ok := r["sessions"]
	if !ok { // JSON.stringify(undefined): res.end() with no body
		sendRawJSON(w, 200, nil)
		return nil
	}
	sendJSON(w, 200, sessions)
	return nil
}

func (s *Server) handleSessionsCreate(w http.ResponseWriter, r *http.Request, _ reqURL, _ []string) error {
	body, err := readJSONBody(w, r)
	if err != nil {
		return err
	}
	if err := body.destructure("cols"); err != nil {
		return err
	}
	cols, rows := body.get("cols"), body.get("rows")
	if !truthy(cols) {
		cols = 80
	}
	if !truthy(rows) {
		rows = 24
	}
	reply, err := s.hostControl(map[string]any{"cmd": "create", "cols": cols, "rows": rows})
	if err != nil {
		sendJSON(w, 502, map[string]any{"error": err.Error()})
		return nil
	}
	out := map[string]any{}
	if id, ok := reply["id"]; ok {
		out["id"] = id
	}
	sendJSON(w, 201, out)
	return nil
}

func (s *Server) handleSessionsDelete(w http.ResponseWriter, _ *http.Request, _ reqURL, m []string) error {
	id, err := decodeURIComponent(m[1])
	if err != nil {
		sendJSON(w, 502, map[string]any{"error": "URI malformed"})
		return nil
	}
	reply, err := s.hostControl(map[string]any{"cmd": "kill", "session": id})
	if err != nil {
		sendJSON(w, 502, map[string]any{"error": err.Error()})
		return nil
	}
	if !truthy(reply["ok"]) {
		var msg any = "not found"
		if e := reply["error"]; truthy(e) {
			msg = e
		}
		sendJSON(w, 404, map[string]any{"error": msg})
		return nil
	}
	sendJSON(w, 200, map[string]any{"ok": true})
	return nil
}

// decodeURIComponent: percent-decoding that must yield valid UTF-8 (else
// URIError, "URI malformed").
func decodeURIComponent(s string) (string, error) {
	out, err := url.PathUnescape(s)
	if err != nil {
		return "", err
	}
	if decodeUTF8([]byte(out)) != out {
		return "", errors.New("URI malformed")
	}
	return out, nil
}
