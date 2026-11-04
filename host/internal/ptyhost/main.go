package ptyhost

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"strings"
	"time"

	"webmux/host/internal/protocol"
)

const usageLine = "usage: webmux-host ptyhost [--name X] [shutdown|list|ping]"

// Main implements `webmux-host ptyhost [--name X] [ping|list|shutdown]`.
func Main(args []string) int {
	name := protocol.DefaultName
	var positional []string
	for i := 0; i < len(args); i++ {
		a := args[i]
		switch {
		case a == "--name":
			if i+1 >= len(args) {
				fmt.Fprintln(os.Stderr, usageLine)
				return 2
			}
			i++
			name = args[i]
		case strings.HasPrefix(a, "--name="):
			name = strings.TrimPrefix(a, "--name=")
		default:
			positional = append(positional, a)
		}
	}
	if len(positional) == 0 {
		err := Run(name)
		if errors.Is(err, ErrAlreadyRunning) {
			return 1
		}
		if err != nil {
			fmt.Fprintf(os.Stderr, "pty host '%s': %v\n", name, err)
			return 1
		}
		return 0 // shutdown() exits 0
	}
	switch positional[0] {
	case "shutdown", "list", "ping":
		return cli(name, positional[0], os.Stdout, os.Stderr)
	}
	fmt.Fprintln(os.Stderr, usageLine)
	return 2
}

// rawControl is protocol.Control returning the reply line verbatim, so
// `ping` can print it exactly as JSON.stringify(res) did (same key order).
func rawControl(name string, msg any) ([]byte, error) {
	conn, err := protocol.Connect(name)
	if err != nil {
		return nil, err
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(protocol.DefaultTimeout))
	if err := protocol.WriteFrame(conn, msg); err != nil {
		return nil, err
	}
	line, err := protocol.NewLineReader(conn).Next()
	if err != nil {
		return nil, err
	}
	if !json.Valid(line) {
		return nil, errors.New("invalid reply")
	}
	return line, nil
}

// cli: `ptyhost [--name X] shutdown|list|ping`, output and exit codes as
// ptyhost.js cli().
func cli(name, cmd string, stdout, stderr io.Writer) int {
	fail := func() int {
		sock, err := protocol.SocketPath(name)
		if err != nil {
			fmt.Fprintln(stderr, err)
			return 1
		}
		fmt.Fprintf(stderr, "no pty host '%s' running (socket: %s)\n", name, sock)
		return 1
	}
	line, err := rawControl(name, map[string]any{"cmd": cmd})
	if err != nil {
		return fail()
	}
	switch cmd {
	case "list":
		var res struct {
			Sessions *[]struct {
				ID      any `json:"id"`
				Cols    any `json:"cols"`
				Rows    any `json:"rows"`
				Clients any `json:"clients"`
				Pid     any `json:"pid"`
				Title   any `json:"title"`
			} `json:"sessions"`
		}
		if json.Unmarshal(line, &res) != nil || res.Sessions == nil {
			return fail() // res.sessions undefined threw inside the try in JS
		}
		for _, s := range *res.Sessions {
			fmt.Fprintf(stdout, "%s  %sx%s  clients=%s  pid=%s  %s\n",
				jsStr(s.ID), jsStr(s.Cols), jsStr(s.Rows), jsStr(s.Clients), jsStr(s.Pid), jsStr(s.Title))
		}
		if len(*res.Sessions) == 0 {
			fmt.Fprintf(stdout, "(no sessions on pty host '%s')\n", name)
		}
	case "shutdown":
		fmt.Fprintf(stdout, "pty host '%s' shut down\n", name)
	default:
		// JSON.stringify(JSON.parse(line)) is the line itself for the
		// daemon's compact output; print it verbatim to keep key order.
		fmt.Fprintln(stdout, string(line))
	}
	return 0
}

// jsStr formats a decoded JSON value the way a JS template literal does.
func jsStr(v any) string {
	switch x := v.(type) {
	case nil:
		return "undefined" // a missing field; null would print "null" but never occurs
	case string:
		return x
	case float64:
		if x == float64(int64(x)) {
			return fmt.Sprint(int64(x))
		}
		return fmt.Sprint(x)
	case bool:
		return fmt.Sprint(x)
	default:
		b, _ := json.Marshal(x)
		return string(b)
	}
}
