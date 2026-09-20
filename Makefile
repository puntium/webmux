# webmux — server + macOS Electron client build entry points

.PHONY: deps start stop payload client-deps client-test client clean

# ---- server (this machine) ------------------------------------------------

deps:            ## install server dependencies (needs make + g++ for node-pty)
	npm install

start:           ## run the web server (spawns the pty host on demand)
	npm start

stop:            ## shut down the pty host daemon (kills all sessions)
	npm run stop

payload:         ## build the auto-deploy server payload the client pushes over ssh
	node deploy/build-payload.js

# ---- macOS Electron client (electron/) -------------------------------------

client-deps:     ## install client dependencies
	cd electron && npm install

client-test:     ## headless harness: profile store, IPC, tunnel state machine; lan.js unit tests
	cd electron && node test/lan.js && node test/harness.js

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

clean:           ## remove client build output
	rm -rf electron/dist electron/payload
