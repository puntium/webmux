# host/ — `webmux-host`

The server side of webmux as one statically linked Go binary per
architecture (`linux-x64`, `linux-arm64`), with libghostty-vt as the
terminal mirror. It replaces the node `server.js` / `ptyhost.js` /
`deploy/remote-start.js` (still in the repo root as the reference) and
speaks the same HTTP/WebSocket API and pty-host socket protocol, so it
interoperates with them in both directions.

```
webmux-host serve                         HTTP API + WebSocket bridge (env: WEBMUX_PTYHOST, WEBMUX_SOCKET)
webmux-host ptyhost [--name X] [ping|list|shutdown]   pty host daemon / its control commands
webmux-host start [--name X]              what the client runs after pushing a payload
webmux-host version                       payload hash + libghostty build info
```

The three commands you need (run them from `host/`; Nix with flakes is
the only prerequisite — `build.sh` enters the dev shell by itself):

```sh
./build.sh                                   # libghostty-vt (first time: minutes) + host/dist/webmux-host-linux-{x64,arm64}
nix develop . -c go test ./...               # unit tests (go only works from host/, not the repo root)
node test/e2e.js && node test/migrate.js     # end-to-end harness + node→native migration test
```

`./build.sh --host-only` rebuilds just the x64 binary. Then
`node ../deploy/build-payload.js` packs the client payloads.

Everything else — layout, pins, the alt-screen snapshot, every deliberate
deviation from the JS, the test matrix, gotchas (108-byte socket paths,
the flake needing `git add -N`) and open items — is in
[`docs/native-host.md`](../docs/native-host.md).
