package server

import (
	"fmt"
	"net/http"
	"sync"
	"time"

	"github.com/fsnotify/fsnotify"
)

// Directory watch for the file browser: a Server-Sent Events stream that
// emits `change` whenever anything in ?path (direct children only — a
// non-recursive inotify watch, as node's fs.watch) is created, removed,
// renamed or written. Bursts are coalesced (~100 ms); a comment line every
// 25 s keeps the ssh tunnel from idling the connection out. The client
// re-lists on every event — there is no payload — and EventSource
// reconnects on its own if the tunnel blinks. Watching a directory that
// vanishes ends the stream with a `gone` event, which the client treats as
// one more change.
const (
	watchHeartbeat = 25 * time.Second
	watchCoalesce  = 100 * time.Millisecond
)

func (s *Server) handleFsWatch(w http.ResponseWriter, r *http.Request, u reqURL, _ []string) error {
	dir := s.paramPath(u, "path")
	h := w.Header()
	h.Set("Content-Type", "text/event-stream")
	h.Set("Cache-Control", "no-cache")
	h.Set("Connection", "keep-alive")
	setCORS(h)
	w.WriteHeader(200)
	flusher, _ := w.(http.Flusher)
	var mu sync.Mutex // serializes writes from the timer and this goroutine
	write := func(s string) {
		mu.Lock()
		defer mu.Unlock()
		_, _ = w.Write([]byte(s))
		if flusher != nil {
			flusher.Flush()
		}
	}
	// {path, error?} in server.js's key order
	type payload struct {
		Path  string `json:"path"`
		Error string `json:"error,omitempty"`
	}
	emit := func(event string, errCode string) {
		write(fmt.Sprintf("event: %s\ndata: %s\n\n", event, jsonBytes(payload{dir, errCode})))
	}
	if flusher != nil {
		flusher.Flush()
	}

	watcher, err := fsnotify.NewWatcher()
	if err == nil {
		if err = watcher.Add(dir); err != nil {
			watcher.Close()
		}
	}
	if err != nil {
		emit("gone", codeOrString(err))
		return nil
	}
	defer watcher.Close()
	emit("ready", "")

	heartbeat := time.NewTicker(watchHeartbeat)
	defer heartbeat.Stop()
	var pending <-chan time.Time
	for {
		select {
		case <-r.Context().Done():
			return nil
		case <-heartbeat.C:
			write(": ping\n\n")
		case _, ok := <-watcher.Events:
			if !ok {
				return nil
			}
			if pending == nil {
				pending = time.After(watchCoalesce)
			}
		case err, ok := <-watcher.Errors:
			if !ok {
				return nil
			}
			emit("gone", codeOrString(err))
			return nil
		case <-pending:
			pending = nil
			// inotify stops reporting once the watched directory itself is
			// removed — check on every burst so the stream ends.
			if !exists(dir) {
				emit("gone", "ENOENT")
				return nil
			}
			emit("change", "")
		}
	}
}
