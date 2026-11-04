package server

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"sync"

	"github.com/coder/websocket"

	"webmux/host/internal/protocol"
)

// ---------------------------------------------------------------------------
// WebSocket attach: /ws?session=<id>
// ---------------------------------------------------------------------------

// wsMaxPayload is the ws library's default maxPayload (100 MiB): pasted
// images arrive as base64 inside one message.
const wsMaxPayload = 100 * 1024 * 1024

// wsClient is one browser socket. Sends from any goroutine are queued
// (unbounded, like ws.send's buffering) and written in order by a single
// writer goroutine, so one slow browser never stalls the fan-out to others.
type wsClient struct {
	conn    *websocket.Conn
	ctx     context.Context
	cancel  context.CancelFunc
	mu      sync.Mutex
	queue   [][]byte
	closing bool // close once the queue has drained (ws.close() after sends)
	wake    chan struct{}

	pidMu sync.Mutex
	pid   string // shell pid from the snapshot frame; "" = unknown (0)
}

func newWSClient(conn *websocket.Conn) *wsClient {
	ctx, cancel := context.WithCancel(context.Background())
	return &wsClient{conn: conn, ctx: ctx, cancel: cancel, wake: make(chan struct{}, 1)}
}

func (c *wsClient) signal() {
	select {
	case c.wake <- struct{}{}:
	default:
	}
}

// send queues a text frame (dropped once the socket is closing/closed, as
// the readyState === OPEN checks do).
func (c *wsClient) send(frame []byte) {
	c.mu.Lock()
	if c.closing || c.ctx.Err() != nil {
		c.mu.Unlock()
		return
	}
	c.queue = append(c.queue, frame)
	c.mu.Unlock()
	c.signal()
}

func (c *wsClient) closeAfterDrain() {
	c.mu.Lock()
	c.closing = true
	c.mu.Unlock()
	c.signal()
}

func (c *wsClient) teardown() {
	c.cancel()
	_ = c.conn.CloseNow()
}

func (c *wsClient) writer() {
	for {
		c.mu.Lock()
		q := c.queue
		c.queue = nil
		closing := c.closing
		c.mu.Unlock()
		if len(q) == 0 {
			if closing {
				_ = c.conn.Close(websocket.StatusNormalClosure, "")
				c.cancel()
				return
			}
			select {
			case <-c.wake:
			case <-c.ctx.Done():
				return
			}
			continue
		}
		for _, m := range q {
			if err := c.conn.Write(c.ctx, websocket.MessageText, m); err != nil {
				c.teardown()
				return
			}
		}
	}
}

func (c *wsClient) setPid(v any) {
	var p string
	switch x := v.(type) {
	case float64:
		if x != 0 {
			p = jsNumber(x)
		}
	default:
		if truthy(x) {
			p = jsString(x)
		}
	}
	c.pidMu.Lock()
	c.pid = p
	c.pidMu.Unlock()
}

func (c *wsClient) getPid() string {
	c.pidMu.Lock()
	defer c.pidMu.Unlock()
	return c.pid
}

func (s *Server) register(c *wsClient, id string) {
	s.clientsMu.Lock()
	defer s.clientsMu.Unlock()
	s.clients[c] = struct{}{}
	if id != "" {
		set := s.bySession[id]
		if set == nil {
			set = map[*wsClient]struct{}{}
			s.bySession[id] = set
		}
		set[c] = struct{}{}
	}
}

func (s *Server) unregister(c *wsClient, id string) {
	s.clientsMu.Lock()
	defer s.clientsMu.Unlock()
	delete(s.clients, c)
	if set := s.bySession[id]; set != nil {
		delete(set, c)
		if len(set) == 0 {
			delete(s.bySession, id)
		}
	}
}

func (s *Server) handleWS(w http.ResponseWriter, r *http.Request, u reqURL) {
	conn, err := websocket.Accept(w, r, &websocket.AcceptOptions{
		// server.js's ws server checks no origin: the socket perms and sshd
		// are the access control.
		InsecureSkipVerify: true,
		// ws's perMessageDeflate defaults to off on the server; keep it off.
		CompressionMode: websocket.CompressionDisabled,
	})
	if err != nil {
		return
	}
	conn.SetReadLimit(wsMaxPayload)
	id, hasID := u.param("session")
	c := newWSClient(conn)

	// Register for open-url delivery (see the browser-open spool).
	s.register(c, id)
	go c.writer()

	// One pty-host connection per attached browser client. The host's frames
	// mirror the WS protocol, so host→browser lines are forwarded verbatim
	// (snapshot/output/title/exit/error).
	host, err := protocol.Connect(s.hostName)
	if err == nil {
		var session any // null when ?session is absent, as in JS
		if hasID {
			session = id
		}
		_ = protocol.WriteFrame(host, map[string]any{"cmd": "attach", "session": session})
		go func() {
			lr := protocol.NewLineReader(host)
			for {
				line, err := lr.Next()
				if err != nil {
					break
				}
				if c.getPid() == "" {
					// First frame is the snapshot; remember the shell pid for
					// foreground-process detection (paste routing).
					var f struct {
						Pid any `json:"pid"`
					}
					if json.Unmarshal(line, &f) == nil {
						c.setPid(f.Pid)
					}
				}
				c.send(line)
			}
			// host gone → close the browser socket (after what was queued)
			c.closeAfterDrain()
		}()
	} else {
		c.closeAfterDrain()
	}
	sendHost := func(frame []byte) {
		if host != nil {
			_, _ = host.Write(frame)
		}
	}

	for {
		_, raw, err := conn.Read(c.ctx)
		if err != nil {
			break
		}
		s.handleWSMessage(c, raw, sendHost)
	}

	if host != nil {
		host.Close()
	}
	s.unregister(c, id)
	c.teardown()
}

// handleWSMessage handles one browser→server message.
func (s *Server) handleWSMessage(c *wsClient, raw []byte, sendHost func([]byte)) {
	var msg map[string]json.RawMessage
	if json.Unmarshal([]byte(decodeUTF8(raw)), &msg) != nil || msg == nil {
		return
	}
	var typ string
	if t, ok := msg["type"]; ok {
		_ = json.Unmarshal(t, &typ)
	}
	// field re-encodes a value compactly (a newline inside it would split
	// the host's line framing); absent fields stay absent, like undefined
	// under JSON.stringify.
	frame := func(typ string, keys ...string) []byte {
		var b bytes.Buffer
		b.WriteString(`{"type":`)
		b.Write(jsonBytes(typ))
		for _, k := range keys {
			v, ok := msg[k]
			if !ok {
				continue
			}
			var cb bytes.Buffer
			if json.Compact(&cb, v) != nil {
				continue
			}
			b.WriteString(`,"` + k + `":`)
			b.Write(cb.Bytes())
		}
		b.WriteString("}\n")
		return b.Bytes()
	}
	decode := func(k string) any {
		var v any
		if r, ok := msg[k]; ok {
			_ = json.Unmarshal(r, &v)
		}
		return v
	}
	input := func(data string) {
		b, _ := protocol.Marshal(map[string]any{"type": "input", "data": data})
		sendHost(b)
	}
	switch typ {
	case "input":
		sendHost(frame("input", "data"))
	case "resize":
		sendHost(frame("resize", "cols", "rows"))
	case "paste-image":
		s.handlePasteImage(c, decode("mime"), decode("data"), input)
	case "clipboard-sync":
		s.writeClipboardSlot(decode("mime"), decode("data")) // slot only, no injection
	}
}

// handlePasteImage: an image pasted in the browser. Always update the
// clipboard slot; then either nudge a foreground Claude Code with Ctrl+V (it
// will spawn our xclip shim and find the image "in the clipboard"), or type
// the file path for a plain shell.
func (s *Server) handlePasteImage(c *wsClient, mime, data any, input func(string)) {
	buf, ext, ok := s.writeClipboardSlot(mime, data)
	if !ok {
		return
	}
	if isClaudeForeground(c.getPid()) {
		input("\x16") // Ctrl+V
		c.send(jsonBytes(map[string]any{"type": "paste-result", "mode": "claude"}))
		return
	}
	file := s.newPasteFile(ext)
	if err := writeFile(file, buf); err != nil {
		logErr("paste file write failed (%s): %s", file, nodeErrString(err))
		return
	}
	input("'" + file + "' ")
	c.send(jsonBytes(map[string]any{"type": "paste-result", "mode": "path", "path": file}))
}
