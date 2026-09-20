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
# see electron/pack-mac.js. So: build the .app as a directory, zip it here.
# APP_ID overrides the bundle identifier (a fresh one makes macOS treat the
# app as new, e.g. to get a clean Local Network prompt).
APP_ID ?=
client: client-test payload  ## build the unsigned arm64 .app zip (cross-builds from Linux)
	cd electron && npx electron-builder --mac dir --arm64 $(if $(APP_ID),-c.appId=$(APP_ID),)
	cd electron && node pack-mac.js dist/mac-arm64/webmux.app \
	  "dist/webmux-$$(node -p 'require("./package.json").version')$(if $(APP_ID),-$(subst .,_,$(APP_ID)),)-arm64-mac.zip" mac-sign.sh
	@ls -lh electron/dist/*.zip

clean:           ## remove client build output
	rm -rf electron/dist electron/payload
