#!/usr/bin/env bash
# Build the native macOS client and assemble mac/dist/webmux.app, ad-hoc signed.
# See docs/macos-client.md and mac/README.md.
#
#   bundle.sh [--debug]     swift build (release unless --debug) with the app's
#                           scratch path, then Contents/{MacOS,Info.plist,Resources}
#                           (+ Resources/payload, the server payload the app pushes
#                           over ssh, from electron/payload when it exists — `make
#                           payload-pack` builds it) and `codesign --sign -`.
#
# Ad hoc only: every build gets a new identity, so macOS forgets per-app grants
# (Local Network, Keychain) between builds. The stable-identity path with
# rcodesign and a certificate PEM (docs/signing.md, as `make client` does for
# the Electron app) is a later step.
set -euo pipefail

MAC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="$(cd "$MAC/.." && pwd)"
PAYLOAD="${WEBMUX_PAYLOAD_SRC:-$REPO/electron/payload}"
SCRATCH="$MAC/.build-app"
CONFIG=release
for a in "$@"; do
  case "$a" in
    --debug) CONFIG=debug ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) echo "bundle.sh: unknown argument $a" >&2; exit 2 ;;
  esac
done

[ -d "$MAC/GhosttyKit.xcframework" ] || { echo "bundle.sh: mac/GhosttyKit.xcframework missing; run 'make mac-ghosttykit' first" >&2; exit 1; }

echo ">> swift build -c $CONFIG"
(cd "$MAC" && swift build -c "$CONFIG" --scratch-path "$SCRATCH" --product webmux)
BIN="$(cd "$MAC" && swift build -c "$CONFIG" --scratch-path "$SCRATCH" --show-bin-path)/webmux"
[ -x "$BIN" ] || { echo "bundle.sh: $BIN not built" >&2; exit 1; }

APP="$MAC/dist/webmux.app"
echo ">> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/webmux"
cp "$MAC/Resources/Info.plist" "$APP/Contents/Info.plist"
[ -f "$MAC/Resources/AppIcon.icns" ] && cp "$MAC/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# The server payload (payload.json + <platform>/payload.tar.gz), where
# Paths.findPayloadDir looks first inside a bundle: Contents/Resources/payload.
# The staging trees are build leftovers and stay out.
if [ -f "$PAYLOAD/payload.json" ]; then
  echo ">> payload from $PAYLOAD"
  mkdir -p "$APP/Contents/Resources/payload"
  cp "$PAYLOAD/payload.json" "$APP/Contents/Resources/payload/"
  for d in "$PAYLOAD"/*/; do
    [ -f "$d/payload.tar.gz" ] || continue
    k="$(basename "$d")"
    mkdir -p "$APP/Contents/Resources/payload/$k"
    cp "$d/payload.tar.gz" "$APP/Contents/Resources/payload/$k/"
  done
else
  echo "bundle.sh: no payload at $PAYLOAD (make payload-pack); the app will not be able to deploy a host" >&2
fi

echo ">> codesign (ad hoc)"
codesign --force --deep --sign - --entitlements "$MAC/Resources/webmux.entitlements" "$APP"
codesign --verify --verbose=1 "$APP"
echo "built: $APP ($CONFIG, ad-hoc signed)"
