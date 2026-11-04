#!/usr/bin/env bash
# Build libghostty-vt and webmux-host for every target. See docs/native-host.md "Build".
#
#   ./build.sh               libs (if missing) + Go binaries for all targets
#   ./build.sh --libs        only the C libraries
#   ./build.sh --host-only   only the native linux-x64 binary (fast iteration)
#   ./build.sh --force       rebuild libs even if their prefix exists
#
# Re-execs itself inside `nix develop` (this directory's flake) when zig/go are
# not on PATH.
set -euo pipefail

# --- pins: bump together with go.mod's go.mitchellh.com/libghostty version ---
# Ghostty commit pinned by go-libghostty v0.0.0-20261021212106-df1957cbff56's CMakeLists.txt.
GHOSTTY_COMMIT=f54340ad77814fe319d136e5e915d6a48de8dd23
GHOSTTY_REPO=https://github.com/ghostty-org/ghostty.git
# zig triple : go arch : dist key
ZIG_TARGETS=(
  "x86_64-linux-musl:amd64:linux-x64"
  "aarch64-linux-musl:arm64:linux-arm64"
)
ZIG_OPTIMIZE=fast   # Zig 0.17 names: debug|safe|fast|small

HOST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHE_DIR="${WEBMUX_GHOSTTY_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/webmux-ghostty}"
SRC_DIR="$CACHE_DIR/ghostty"
TP_DIR="$HOST_DIR/third_party/ghostty-vt"
DIST_DIR="$HOST_DIR/dist"

MODE=all FORCE=0
for a in "$@"; do
  case "$a" in
    --libs) MODE=libs ;;
    --host-only) MODE=host ;;
    --force) FORCE=1 ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) echo "unknown argument: $a" >&2; exit 2 ;;
  esac
done

if ! command -v zig >/dev/null || ! command -v go >/dev/null; then
  if [ -z "${WEBMUX_IN_NIX:-}" ] && command -v nix >/dev/null; then
    export WEBMUX_IN_NIX=1
    exec nix develop "$HOST_DIR" -c "$0" "$@"
  fi
  echo "build.sh: zig and go must be on PATH (run inside 'nix develop ./host')" >&2
  exit 1
fi

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

build_lib() { # triple
  local triple=$1 prefix="$TP_DIR/$1"
  if [ -f "$prefix/.commit" ] && [ "$(cat "$prefix/.commit")" = "$GHOSTTY_COMMIT" ] && [ "$FORCE" = 0 ]; then
    echo ">> libghostty-vt $triple: up to date ($prefix)"
    return
  fi
  fetch_ghostty
  echo ">> building libghostty-vt for $triple"
  rm -rf "$prefix"
  (cd "$SRC_DIR" && zig build -Demit-lib-vt -Doptimize="$ZIG_OPTIMIZE" -Dtarget="$triple" --prefix "$prefix")
  echo "$GHOSTTY_COMMIT" > "$prefix/.commit"
}

build_go() { # triple goarch key
  local triple=$1 goarch=$2 key=$3 prefix="$TP_DIR/$1"
  mkdir -p "$DIST_DIR"
  echo ">> go build $key ($triple)"
  # The bindings' cgo directive is `pkg-config --static libghostty-vt-static`,
  # whose .pc links $prefix/lib/libghostty-vt.a by path. osusergo/netgo keep
  # os/user and net off libc NSS so the static binary is self-contained.
  (cd "$HOST_DIR" && \
    CGO_ENABLED=1 GOOS=linux GOARCH="$goarch" \
    CC="zig cc -target $triple" CXX="zig c++ -target $triple" \
    PKG_CONFIG_PATH="$prefix/share/pkgconfig" \
    CGO_CFLAGS="-O2 -I$prefix/include -DGHOSTTY_STATIC" \
    go build -trimpath -tags osusergo,netgo \
      -ldflags="-s -w -linkmode=external '-extldflags=-static -s'" \
      -o "$DIST_DIR/webmux-host-$key" ./cmd/webmux-host)
}

for t in "${ZIG_TARGETS[@]}"; do
  IFS=: read -r triple goarch key <<<"$t"
  if [ "$MODE" = host ] && [ "$key" != linux-x64 ]; then continue; fi
  build_lib "$triple"
done
[ "$MODE" = libs ] && exit 0

for t in "${ZIG_TARGETS[@]}"; do
  IFS=: read -r triple goarch key <<<"$t"
  if [ "$MODE" = host ] && [ "$key" != linux-x64 ]; then continue; fi
  build_go "$triple" "$goarch" "$key"
done
ls -l "$DIST_DIR"
