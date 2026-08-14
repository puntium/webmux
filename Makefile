# webmux — server + macOS Electron client build entry points

.PHONY: deps start stop client-deps client-test client clean

# ---- server (this machine) ------------------------------------------------

deps:            ## install server dependencies (needs make + g++ for node-pty)
	npm install

start:           ## run the web server (spawns the pty host on demand)
	npm start

stop:            ## shut down the pty host daemon (kills all sessions)
	npm run stop

# ---- macOS Electron client (electron/) -------------------------------------

client-deps:     ## install client dependencies
	cd electron && npm install

client-test:     ## headless harness: profile store, IPC, tunnel state machine
	cd electron && node test/harness.js

client: client-test  ## build the unsigned arm64 .app zip (cross-builds from Linux)
	cd electron && npx electron-builder --mac zip --arm64
	@ls -lh electron/dist/*.zip

clean:           ## remove client build output
	rm -rf electron/dist
