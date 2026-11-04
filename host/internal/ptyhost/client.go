package ptyhost

import (
	"net"
	"sync"

	"webmux/host/internal/protocol"
)

// clientQueueFrames bounds how far a peer may fall behind before it is
// dropped. Frames are enqueued without blocking by the session owner, so a
// stalled socket can never stall a session (node buffered without bound in
// the socket; we cut the peer loose instead).
const clientQueueFrames = 4096

// client is one accepted unix connection. Every frame to it goes through a
// single writer goroutine, so frames from several goroutines (session owner,
// watch fan-out, the connection's own handler) are never interleaved.
type client struct {
	conn net.Conn
	q    chan []byte // nil frame = "end": half-close after flushing
	dead chan struct{}
	fin  chan struct{} // closed when the writer goroutine is done
	once sync.Once
}

func newClient(conn net.Conn) *client {
	c := &client{conn: conn, q: make(chan []byte, clientQueueFrames), dead: make(chan struct{}), fin: make(chan struct{})}
	go c.writer()
	return c
}

func (c *client) writer() {
	defer close(c.fin)
	for {
		select {
		case b := <-c.q:
			if b == nil {
				if uc, ok := c.conn.(*net.UnixConn); ok {
					_ = uc.CloseWrite() // like sock.end(): FIN, the reader sees the peer's close
				} else {
					c.kill()
				}
				return
			}
			if _, err := c.conn.Write(b); err != nil {
				c.kill() // peer vanished mid-write; the handler cleans up
				return
			}
		case <-c.dead:
			return
		}
	}
}

// send enqueues one frame; it never blocks. A full queue drops the peer.
func (c *client) send(v any) {
	b, err := protocol.Marshal(v)
	if err != nil {
		return
	}
	c.enqueue(b)
}

func (c *client) enqueue(b []byte) {
	select {
	case <-c.dead:
	case c.q <- b:
	default:
		c.kill()
	}
}

// end flushes queued frames, then half-closes (sock.end()).
func (c *client) end() { c.enqueue(nil) }

// kill closes the connection immediately (sock.destroy()).
func (c *client) kill() {
	c.once.Do(func() {
		close(c.dead)
		_ = c.conn.Close()
	})
}

// flushed is closed once everything queued before end() was written (or the
// peer was dropped).
func (c *client) flushed() <-chan struct{} { return c.fin }
