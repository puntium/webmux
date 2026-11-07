#!/usr/bin/env bash
# Build GhosttyKit.xcframework from the Ghostty fork (gtk/ghostty, branch
# webmux-shell) and copy it to mac/GhosttyKit.xcframework, where
# mac/Package.swift expects its binary target. See docs/macos-client.md ›
# The seam in the fork.
#
# Needs: zig 0.17.x on PATH (Homebrew), Xcode with the Metal toolchain
# (xcodebuild -downloadComponent MetalToolchain). No nix. The first build
# takes several minutes; zig caches, so rebuilds are quick.
#
# Env: GHOSTTYKIT_OPTIMIZE (default ReleaseFast; Debug for a debug library).
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
fork="$root/gtk/ghostty"
out="$root/mac/GhosttyKit.xcframework"
optimize="${GHOSTTYKIT_OPTIMIZE:-ReleaseFast}"

[ -f "$fork/build.zig" ] || {
  echo "$fork is missing: fetch it with: git submodule update --init gtk/ghostty" >&2
  exit 1
}
command -v zig >/dev/null || { echo "zig not on PATH (brew install zig)" >&2; exit 1; }

cmd=(zig build
  -Demit-xcframework=true
  -Demit-macos-app=false
  -Dxcframework-target=native
  "-Doptimize=$optimize"
  -Dsentry=false
  -Di18n=false)

echo "+ (cd gtk/ghostty && ${cmd[*]})"
start=$(date +%s)
(cd "$fork" && "${cmd[@]}")
echo "built in $(( $(date +%s) - start ))s"

built="$fork/macos/GhosttyKit.xcframework"
[ -d "$built" ] || { echo "expected $built after the build" >&2; exit 1; }
rm -rf "$out"
cp -R "$built" "$out"
echo "copied to $out ($(du -sh "$out" | cut -f1))"
