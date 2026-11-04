# webmux — server + Electron client (macOS, Linux) build entry points

.PHONY: deps start stop host-libs host payload client-deps client-test client client-run client-linux clean

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

clean:           ## remove client build output
	rm -rf electron/dist electron/payload
