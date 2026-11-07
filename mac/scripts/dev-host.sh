#!/usr/bin/env bash
# Native Darwin webmux-host for Mac-client dev mode. See docs/macos-client.md "Dev mode".
# Dev only: Darwin is never a payload platform; host/build.sh owns the real targets.
#
#   dev-host.sh build [--force]   libghostty-vt for aarch64-macos (cached under
#                                 host/third_party/ghostty-vt/<triple>, same Ghostty pin as
#                                 host/build.sh) + go build -> host/dist/webmux-host-darwin-arm64
#   dev-host.sh run [name]        start `webmux-host serve` (and its pty host) on
#                                 /tmp/wm-mac/<name>/http.sock; prints the socket path on stdout
#   dev-host.sh stop [name]       SIGTERM the server, shut the pty host down
#   dev-host.sh status [name]     is it up? (pid, socket, health JSON)
#
# Env: DEV_HOST_HOME       HOME for the host and its shells (default: your HOME; set to
#                          "isolated" for an empty /tmp/wm-mac/<name>/home)
#      WEBMUX_GHOSTTY_CACHE Ghostty checkout cache (default: ~/.cache/webmux-ghostty)
# Everything else is isolated per name: XDG_RUNTIME_DIR (pty host socket), TMPDIR (pastes),
# WEBMUX_SOCKET (HTTP socket; also suppresses the ~/.webmux advert), WEBMUX_PTYHOST (name).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOST_DIR="$ROOT/host"
BUILD_SH="$HOST_DIR/build.sh"
# Same pin as build.sh (it is not sourceable: it builds at top level).
GHOSTTY_COMMIT="$(sed -n 's/^GHOSTTY_COMMIT=\([0-9a-f]*\).*/\1/p' "$BUILD_SH")"
GHOSTTY_REPO="$(sed -n 's/^GHOSTTY_REPO=\(.*\)$/\1/p' "$BUILD_SH")"
ZIG_OPTIMIZE=fast
[ -n "$GHOSTTY_COMMIT" ] || { echo "dev-host.sh: no GHOSTTY_COMMIT in $BUILD_SH" >&2; exit 1; }

case "$(uname -s)-$(uname -m)" in
  Darwin-arm64) TRIPLE=aarch64-macos KEY=darwin-arm64 ;;
  Darwin-x86_64) TRIPLE=x86_64-macos KEY=darwin-amd64 ;;
  *) echo "dev-host.sh: Darwin only (got $(uname -sm)); use host/build.sh" >&2; exit 1 ;;
esac
CACHE_DIR="${WEBMUX_GHOSTTY_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/webmux-ghostty}"
SRC_DIR="$CACHE_DIR/ghostty"
PREFIX="$HOST_DIR/third_party/ghostty-vt/$TRIPLE"
BIN="$HOST_DIR/dist/webmux-host-$KEY"

fetch_ghostty() {
  mkdir -p "$CACHE_DIR"
  if [ ! -d "$SRC_DIR/.git" ]; then
    git init -q "$SRC_DIR"
    git -C "$SRC_DIR" remote add origin "$GHOSTTY_REPO"
  fi
  if [ "$(git -C "$SRC_DIR" rev-parse -q --verify HEAD 2>/dev/null || true)" != "$GHOSTTY_COMMIT" ]; then
    echo ">> fetching ghostty $GHOSTTY_COMMIT"
    git -C "$SRC_DIR" fetch -q --depth 1 origin "$GHOSTTY_COMMIT"
    git -C "$SRC_DIR" checkout -q --detach FETCH_HEAD
  fi
}

build_lib() { # [force]
  if [ -f "$PREFIX/.commit" ] && [ "$(cat "$PREFIX/.commit")" = "$GHOSTTY_COMMIT" ] && [ "${1:-0}" = 0 ]; then
    echo ">> libghostty-vt $TRIPLE: up to date ($PREFIX)"
    return
  fi
  command -v zig >/dev/null || { echo "dev-host.sh: zig not on PATH (brew install zig)" >&2; exit 1; }
  fetch_ghostty
  echo ">> building libghostty-vt for $TRIPLE"
  rm -rf "$PREFIX"
  (cd "$SRC_DIR" && zig build -Demit-lib-vt -Doptimize="$ZIG_OPTIMIZE" -Dtarget="$TRIPLE" --prefix "$PREFIX")
  echo "$GHOSTTY_COMMIT" > "$PREFIX/.commit"
}

build_go() {
  command -v go >/dev/null || { echo "dev-host.sh: go not on PATH (brew install go)" >&2; exit 1; }
  mkdir -p "$HOST_DIR/dist"
  echo ">> go build $KEY ($TRIPLE)"
  # Native cgo with the system clang; the bindings link via
  # `pkg-config --static libghostty-vt-static` (needs PKG_CONFIG_PATH). No -static on Darwin.
  (cd "$HOST_DIR" && \
    CGO_ENABLED=1 GOOS=darwin \
    PKG_CONFIG_PATH="$PREFIX/share/pkgconfig" \
    CGO_CFLAGS="-O2 -I$PREFIX/include -DGHOSTTY_STATIC" \
    go build -trimpath -ldflags="-s -w" -o "$BIN" ./cmd/webmux-host)
  ls -l "$BIN"
}

# --- run / stop / status -----------------------------------------------------
inst_env() { # name -> sets DIR SOCK PIDFILE LOG and exports the host's env
  local name=$1
  case "$name" in *[!A-Za-z0-9._-]*|"") echo "bad name '$name' (letters, digits, . _ -)" >&2; exit 2 ;; esac
  DIR="/tmp/wm-mac/$name"
  SOCK="$DIR/http.sock"
  PIDFILE="$DIR/serve.pid"
  LOG="$DIR/serve.log"
  mkdir -p "$DIR/run" "$DIR/tmp"
  export XDG_RUNTIME_DIR="$DIR/run" TMPDIR="$DIR/tmp" WEBMUX_SOCKET="$SOCK" WEBMUX_PTYHOST="$name"
  if [ "${DEV_HOST_HOME:-}" = isolated ]; then
    mkdir -p "$DIR/home"; export HOME="$DIR/home"
  elif [ -n "${DEV_HOST_HOME:-}" ]; then
    export HOME="$DEV_HOST_HOME"
  fi
  unset TMUX TMUX_PANE
}

serve_pid() { # running pid or nothing
  local pid
  [ -f "$PIDFILE" ] || return 0
  pid=$(cat "$PIDFILE")
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then echo "$pid"; fi
}

cmd_run() {
  inst_env "${1:-dev}"
  [ -x "$BIN" ] || { echo "dev-host.sh: $BIN missing; run '$0 build' first" >&2; exit 1; }
  if pid=$(serve_pid) && [ -n "$pid" ]; then
    echo "$SOCK"; echo "already running (pid $pid)" >&2; return 0
  fi
  rm -f "$SOCK"
  nohup "$BIN" serve >>"$LOG" 2>&1 </dev/null &
  echo $! > "$PIDFILE"
  for _ in $(seq 1 100); do
    [ -S "$SOCK" ] && break
    kill -0 "$(cat "$PIDFILE")" 2>/dev/null || { echo "dev-host.sh: serve exited; see $LOG" >&2; tail -20 "$LOG" >&2; exit 1; }
    sleep 0.1
  done
  [ -S "$SOCK" ] || { echo "dev-host.sh: no socket after 10s; see $LOG" >&2; exit 1; }
  echo "$SOCK"
  echo "webmux-host serve pid $(cat "$PIDFILE"), pty host '$WEBMUX_PTYHOST', log $LOG" >&2
}

cmd_stop() {
  inst_env "${1:-dev}"
  if pid=$(serve_pid) && [ -n "$pid" ]; then
    kill -TERM "$pid" 2>/dev/null || true
    for _ in $(seq 1 50); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
    kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null
    echo "server $pid stopped" >&2
  else
    echo "server not running" >&2
  fi
  rm -f "$PIDFILE"
  # The pty host is a separate daemon (setsid); shut it down the documented way.
  if [ -x "$BIN" ]; then
    "$BIN" ptyhost --name "$WEBMUX_PTYHOST" shutdown >&2 || echo "pty host '$WEBMUX_PTYHOST' not running" >&2
  fi
}

cmd_status() {
  inst_env "${1:-dev}"
  local rc=0
  if pid=$(serve_pid) && [ -n "$pid" ]; then echo "server: running (pid $pid)"; else echo "server: not running"; rc=1; fi
  if [ -S "$SOCK" ]; then
    echo "socket: $SOCK"
    curl -sS --max-time 2 --unix-socket "$SOCK" http://localhost/ && echo || { echo "health: no answer"; rc=1; }
  else
    echo "socket: missing ($SOCK)"; rc=1
  fi
  if [ -x "$BIN" ]; then
    if "$BIN" ptyhost --name "$WEBMUX_PTYHOST" ping >/dev/null 2>&1; then echo "pty host '$WEBMUX_PTYHOST': up"; else echo "pty host '$WEBMUX_PTYHOST': down"; fi
  fi
  return $rc
}

case "${1:-}" in
  build) shift; FORCE=0; for a in "$@"; do [ "$a" = --force ] && FORCE=1; done; build_lib "$FORCE"; build_go ;;
  run) shift; cmd_run "$@" ;;
  stop) shift; cmd_stop "$@" ;;
  status) shift; cmd_status "$@" ;;
  -h|--help|"") sed -n '2,19p' "$0"; [ -n "${1:-}" ] || exit 2 ;;
  *) echo "unknown subcommand: $1" >&2; exit 2 ;;
esac
