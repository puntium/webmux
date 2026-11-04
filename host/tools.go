//go:build tools

// Package tools keeps every dependency the port needs referenced, so the
// requires in go.mod survive even before the packages that use them exist.
package tools

import (
	_ "github.com/coder/websocket"
	_ "github.com/creack/pty"
	_ "github.com/fsnotify/fsnotify"
	_ "github.com/google/uuid"
	_ "go.mitchellh.com/libghostty"
)
