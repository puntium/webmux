# webmux — server, Electron client (macOS, Linux), native GTK client and native macOS client build entry points

.PHONY: deps start stop host-libs host payload payload-pack client-deps client-test client client-run client-linux linux-client linux-client-run linux-client-quick linux-client-try mac-ghosttykit mac-client mac-client-run mac-test clean

# ---- server (this machine) ------------------------------------------------

deps:            ## install server dependencies (needs make + g++ for node-pty)
	npm install

start:           ## run the web server (spawns the pty host on demand)
	npm start

stop:            ## shut down the pty host daemon (kills all sessions)
	npm run stop

# ---- native host (host/): webmux-host binaries for the push-deploy payload --

# Both run host/build.sh inside the host/ nix dev shell (zig, go, cmake);
# docs/native-host.md has the pins and targets.
host-libs:       ## build libghostty-vt for every target into host/third_party/
	cd host && nix develop . -c ./build.sh --libs

host:            ## build host/dist/webmux-host-<platform> (libghostty-vt too, if missing)
	cd host && nix develop . -c ./build.sh

# PAYLOAD_ONLY=linux-x64 builds a single platform's payload (e.g. when only
# that binary is built; run deploy/build-payload.js directly to skip `host`).
PAYLOAD_ONLY ?=
payload: host    ## build the per-platform server payloads the client pushes over ssh
	node deploy/build-payload.js $(if $(PAYLOAD_ONLY),--only $(PAYLOAD_ONLY),)

# Pack only (no nix, no host build): the Linux binaries must already be in
# host/dist (from `make host`, or a checkout that has them). The Mac client
# target uses this so a Mac without nix can bundle the payload it ships.
payload-pack:    ## pack electron/payload from the host/dist binaries already built (no nix)
	@ls host/dist/webmux-host-linux-* >/dev/null 2>&1 || { echo "payload-pack: no host/dist/webmux-host-linux-* (run 'make host' where nix is available)"; exit 1; }
	node deploy/build-payload.js $(if $(PAYLOAD_ONLY),--only $(PAYLOAD_ONLY),)

# ---- Electron client (electron/): shared targets + macOS build --------------

client-deps:     ## install client dependencies
	cd electron && npm install

# File-level view of the same steps, so client-run / client-test can
# demand them and stay incremental: the client's node_modules (electron,
# @xterm, marked — needed even with an electron on PATH) and the server
# payload main.js looks for at startup (missing → "no server payload
# bundled" on connect). The payload rule rebuilds when its inputs change
# (the native binaries in host/dist, the shims, the build script) and
# builds the binaries first if none exist; `make payload` forces it.
HOST_BINS := $(wildcard host/dist/webmux-host-*)
PAYLOAD_INPUTS := deploy/build-payload.js $(shell find shims -type f) $(HOST_BINS)
electron/node_modules: electron/package.json electron/package-lock.json
	cd electron && npm install
	@touch $@
electron/payload/payload.json: $(PAYLOAD_INPUTS)
	@[ -n "$(HOST_BINS)" ] || $(MAKE) host
	node deploy/build-payload.js

client-test: electron/node_modules  ## headless harness: profile store, IPC, tunnel state machine; lan.js unit tests; local deploy flow
	cd electron && node test/lan.js && node test/harness.js && node test/deploy-fake.js

# electron-builder's own zip target flattens symlinks when run on Linux,
# which breaks the frameworks' layout (and their signatures) on the Mac —
# see electron/pack-mac.js. So: build the .app as a directory, sign it,
# zip it here.
#
# Signing happens on this Linux host with rcodesign (apple-codesign; put
# the static binary on PATH). macOS 26.5+/27 identifies an app by its code
# signature for Local Network privacy and Keychain access, so an unsigned
# or unsignable app is denied every LAN connection. SIGN_PEM (unified PEM:
# private key + certificate) gives a stable identity across builds; absent
# → ad-hoc, a new identity per build; no rcodesign → the build stops rather
# than ship a zip that installs fine and then fails every connection. The
# PEM stays out of git. Setup, key handling, rationale: docs/signing.md.
#
# APP_ID overrides the bundle identifier (a fresh one makes macOS treat the
# app as new, e.g. to get a clean Local Network prompt).
APP_ID ?=
SIGN_PEM ?= $(HOME)/.config/webmux/codesign.pem
RCODESIGN := $(shell command -v rcodesign 2>/dev/null)
client: client-test payload  ## build the signed arm64 .app zip (cross-builds from Linux; needs rcodesign on PATH)
ifndef RCODESIGN
	$(error rcodesign not on PATH — install it from https://github.com/indygreg/apple-platform-rs/releases (apple-codesign, linux-musl tarball) so the .app can be signed here)
endif
	cd electron && npx electron-builder --mac dir --arm64 $(if $(APP_ID),-c.appId=$(APP_ID),)
	$(RCODESIGN) sign $(if $(wildcard $(SIGN_PEM)),--pem-file $(SIGN_PEM),) electron/dist/mac-arm64/webmux.app 2>&1 | grep -vE "^(entering|leaving|signing|creating cryptographic)" || true
	@echo "signed: $(if $(wildcard $(SIGN_PEM)),certificate $(SIGN_PEM) (stable identity),ad-hoc (identity changes per build; set SIGN_PEM for a stable one))"
	cd electron && node pack-mac.js dist/mac-arm64/webmux.app \
	  "dist/webmux-$$(node -p 'require("./package.json").version')$(if $(APP_ID),-$(subst .,_,$(APP_ID)),)-arm64-mac.zip"
	@ls -lh electron/dist/*.zip

# ---- Linux Electron client --------------------------------------------------

# Run from source. An `electron` on PATH wins (NixOS: put pkgs.electron in
# environment.systemPackages or a dev shell); otherwise the binary npm
# downloaded, which needs the usual FHS libraries (NSS, GTK 3, …) on the
# loader path — on NixOS it fails on libnspr4.so. ELECTRON=… overrides
# either (an absolute path or a name on PATH). Installs the client deps and
# builds the server payload first if they are missing or stale.
ELECTRON ?= $(shell command -v electron 2>/dev/null || echo ./node_modules/.bin/electron)
client-run: electron/node_modules electron/payload/payload.json ## run the client from source (ELECTRON=… picks the electron binary)
	cd electron && $(ELECTRON) .

# Unsigned Linux build: an AppImage (any distro with FUSE; NixOS: appimage-run)
# and a tar.gz of the unpacked app (run its ./webmux). LINUX_ARCH: x64 | arm64.
LINUX_ARCH ?= x64
client-linux: client-test payload  ## build the Linux AppImage + tar.gz
	cd electron && npx electron-builder --linux AppImage tar.gz --$(LINUX_ARCH)
	@ls -lh electron/dist/*linux* 2>/dev/null || ls -lh electron/dist

# ---- native Linux client (gtk/ghostty): webmux-gtk --------------------------

# A Ghostty fork with a GTK4 shell that speaks the webmux protocol; see
# gtk/README.md. The fork is a git submodule (github.com/puntium/ghostty), built
# by zig inside its nix dev shell. zig decides what is stale, so the build
# runs every time: a few seconds when nothing changed, about five minutes
# from cold. GTK_OPTIMIZE=Debug builds faster but parses terminal output
# about a hundred times slower. Each mode has its own output directory.
GTK_DIR := gtk/ghostty
GTK_OPTIMIZE ?= ReleaseFast
GTK_OUT := $(GTK_DIR)/zig-out$(if $(filter Debug,$(GTK_OPTIMIZE)),,-release)
linux-client:    ## build the native GTK client (GTK_OPTIMIZE=Debug for a debug build)
	@[ -f $(GTK_DIR)/build.zig ] || { echo "$(GTK_DIR) is missing: fetch it with: git submodule update --init $(GTK_DIR)" >&2; exit 1; }
	cd $(GTK_DIR) && nix develop . -c zig build -Dapp-runtime=gtk -Dwebmux=true \
	  -Doptimize=$(GTK_OPTIMIZE) --prefix "$(CURDIR)/$(GTK_OUT)"

# The client pushes the same server payload as the Electron one and finds
# it by walking up from its binary to electron/payload, so build that first
# if it is missing or stale. ARGS=… passes arguments to webmux-gtk.
ARGS ?=
linux-client-run: linux-client electron/payload/payload.json ## build and run the native GTK client
	$(GTK_OUT)/bin/webmux-gtk $(ARGS)

# The edit-and-try loop: about a minute of smokes on the binary just built,
# then the app. The full suite (webmux-dev/smoke --all) is for the final commit.
linux-client-quick: linux-client electron/payload/payload.json ## build, then the quick smokes
	cd $(GTK_DIR) && WEBMUX_GTK_BIN="$(CURDIR)/$(GTK_OUT)/bin/webmux-gtk" nix develop . -c webmux-dev/smoke --quick

linux-client-try: linux-client-quick ## build, quick smokes, then run the native GTK client
	$(GTK_OUT)/bin/webmux-gtk $(ARGS)

# ---- native macOS client (mac/): webmux.app on GhosttyKit ------------------

# The Swift/AppKit shell links GhosttyKit.xcframework, built from the same
# fork (gtk/ghostty) with Homebrew zig and Xcode's Metal toolchain, no nix;
# see docs/macos-client.md. The first build takes several minutes, rebuilds
# are quick (zig caches). GHOSTTYKIT_OPTIMIZE=Debug for a debug library.
mac-ghosttykit:  ## build gtk/ghostty → mac/GhosttyKit.xcframework (macOS only)
	mac/scripts/build-ghosttykit.sh

# The app itself: `swift build -c release` plus the bundle and an ad-hoc
# signature (mac/scripts/bundle.sh). The xcframework is built first if it is
# missing (a rebuild after a fork change is `make mac-ghosttykit`). Like the
# Electron client it ships the server payload (Contents/Resources/payload),
# packed by `payload-pack` from the host/dist binaries without nix (the
# Electron `payload` target needs nix for `host`).
# Ad hoc means a new identity per build; the stable-identity rcodesign path
# (docs/signing.md) is not wired up for this target yet.
mac/GhosttyKit.xcframework:
	mac/scripts/build-ghosttykit.sh
mac-client: mac/GhosttyKit.xcframework payload-pack ## build mac/dist/webmux.app with the payload (release, ad-hoc signed)
	mac/scripts/bundle.sh

mac-client-run: mac-client ## build the bundle and open it
	open mac/dist/webmux.app

# The SwiftPM tests of every mac/ target (the pure libraries and the app).
# Each area builds in its own scratch path; this one is the app's.
mac-test:        ## swift test for the native macOS client
	cd mac && swift test --scratch-path .build-app

clean:           ## remove client build output
	rm -rf electron/dist electron/payload
