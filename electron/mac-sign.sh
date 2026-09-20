#!/bin/sh
# Re-sign webmux.app on the Mac it was installed on.
#
# The .app is cross-built on Linux, where electron-builder cannot sign it.
# The bundle still carries Electron's own ad-hoc signature, but that no
# longer validates once the executable is renamed and Info.plist rewritten
# — and macOS's Local Network privacy check identifies the responsible
# process by its code signature, so an app it cannot validate is denied
# every LAN connection no matter what the toggle says (macOS 26.5+/27).
# Signing the installed copy gives it an identity the grant can attach to.
#
#   sh mac-sign.sh                       # ad-hoc identity ("-")
#   sh mac-sign.sh "Apple Development"   # or any code-signing identity in your keychain
#   sh mac-sign.sh - /path/to/webmux.app
#
# Signs inside-out (frameworks, helpers, then the app) rather than --deep,
# which chokes on any framework whose layout it finds ambiguous.
set -eu
IDENTITY="${1:--}"
APP="${2:-/Applications/webmux.app}"
[ -d "$APP" ] || { echo "no app at $APP" >&2; exit 1; }

FW="$APP/Contents/Frameworks"
for f in "$FW"/*.framework; do
  codesign --force --sign "$IDENTITY" "$f"
done
for h in "$FW"/*.app; do
  codesign --force --sign "$IDENTITY" "$h"
done
codesign --force --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
echo "signed $APP with identity '$IDENTITY'"
echo "macOS treats a re-signed app as new: expect one more Local Network prompt on the first connect."
