# Signing the macOS client

The client `.app` is cross-built on Linux and signed there, with
[rcodesign](https://github.com/indygreg/apple-platform-rs) (the
`apple-codesign` project — a single static binary, no Apple tooling). This
note is the one place that says how, and why the signature matters more
than it used to.

## Why an unsigned app stopped working (macOS 26.5+ / 27)

Since macOS 15 a connection to a host on the local network — RFC 1918 or
link-local addresses, `.local` names — is gated behind a per-app grant in
System Settings › Privacy & Security › Local Network. A denied connect
fails instantly with `EHOSTUNREACH`, which ssh prints as
`ssh: connect to host … port 22: No route to host` — indistinguishable from
a real routing failure except by timing (a real one waits out ARP for
seconds; the denial takes milliseconds).

The grant is attached to the *responsible process*, and macOS identifies
that process by its **code signature**. macOS 26.5+/27 stopped tolerating
an app whose signature it cannot validate: the toggle shows on, the prompt
was answered, and every LAN socket is still denied — including the `ssh`
children the client spawns, which inherit the parent's verdict. Launching
the app from Terminal "fixes" it because Terminal becomes the responsible
process; that is a diagnostic, not a solution.

Our build produced exactly such an app. electron-builder cannot sign on
Linux, and its `--mac zip` target flattens every symlink into a copy, so
each framework unpacked on the Mac with two copies of its binary (a layout
`codesign` calls "bundle format is ambiguous"). That invalidated the
frameworks' leftover Electron signatures and made the app impossible to
re-sign even by hand. Two fixes, both in `make client`:

1. `electron/pack-mac.js` zips the `--mac dir` output with symlinks stored
   as symlinks (116 MB instead of 326 MB, byte-identical on extraction).
2. rcodesign signs the app before it is zipped.

## What `make client` does

```
electron-builder --mac dir --arm64        # unsigned .app in electron/dist/mac-arm64/
rcodesign sign [--pem-file $SIGN_PEM] …   # nested bundles, frameworks, dylibs, helpers, then the app
node pack-mac.js …                        # dist/webmux-<version>-arm64-mac.zip, the .app its only entry
```

Variables:

| variable   | default                          | effect |
|------------|----------------------------------|--------|
| `SIGN_PEM` | `~/.config/webmux/codesign.pem`  | unified PEM (private key + certificate). Present → certificate signature with a stable identity. Absent → ad-hoc signature, a new identity per build. |
| `APP_ID`   | `me.puntium.webmux`              | bundle identifier override. macOS treats a different identifier as a brand-new app: fresh Local Network prompt, separate settings entry. Helpers are renamed to match. |

Without rcodesign on PATH the build stops with an install pointer. It
must not fall back to unsigned: an unsigned zip installs fine and then
fails every connection, which is a much worse failure than a build error.

### Setting up a build host

```sh
# rcodesign: download the linux-musl tarball from the releases page, check
# the .sha256 next to it, put the binary on PATH (e.g. ~/.local/bin)
rcodesign --version

# release certificate, once (self-signed; see "Identity" for why that is enough)
mkdir -p ~/.config/webmux
rcodesign generate-self-signed-certificate --algorithm ecdsa \
  --person-name webmux --validity-days 3650 \
  --pem-unified-file ~/.config/webmux/codesign.pem
chmod 600 ~/.config/webmux/codesign.pem
```

### Checking a build

On the build host, rcodesign's `verify` is self-described as unreliable;
inspect instead:

```sh
rcodesign print-signature-info electron/dist/mac-arm64/webmux.app/Contents/MacOS/webmux
#   identifier: me.puntium.webmux
#   designated(3): (identifier "me.puntium.webmux") and (certificate root = H"…")
unzip -Z1 electron/dist/webmux-*-arm64-mac.zip | cut -d/ -f1 | sort -u   # → webmux.app only
```

On the Mac, after installing:

```sh
codesign --verify --deep --strict --verbose=2 /Applications/webmux.app
```

## Identity: what the certificate is for

Nobody trusts the certificate — it is self-signed and macOS never sees its
root anywhere else. It proves nothing about authorship, and Gatekeeper
still treats the download as unidentified (hence the quarantine step in
the install instructions). Its only job is to make the app's *designated
requirement* stable:

```
identifier "me.puntium.webmux" and certificate root = H"<hash of our root>"
```

Every grant macOS records for the app is keyed to that requirement:

- the Local Network toggle (`System Settings › Privacy & Security › Local
  Network`), and
- the Keychain ACL on `webmux Safe Storage`, the item Electron's
  `safeStorage` uses to encrypt the saved ssh passwords in `config.json`.

An ad-hoc signature has no certificate, so its requirement is the hash of
the binary itself: every rebuild is a new app, and every update re-prompts
for both. With the certificate the same requirement holds across versions,
so both prompts happen once per Mac.

## The private key

`~/.config/webmux/codesign.pem` holds the private key. It is **not in the
repository, and must not be**: the repository is public, and the key is
what makes the identity ours. Whoever has it can sign an arbitrary binary
that macOS treats as webmux — the same Local Network grant, and the same
Keychain ACL, i.e. the ability to decrypt saved ssh passwords without a
prompt on any Mac that has ever allowed webmux. Committing it once is
permanent (git history), and the only remedy is rotation, which is a new
identity: every user gets both prompts again.

Back it up outside git (a password manager, or an `age`/GPG-encrypted copy
— the ciphertext may live in the repo). Losing it is not a disaster, just
a rotation.

### Dev / test builds

A shared, committed *dev* key would be a legitimate pattern (cf. Android's
debug keystore) — contributors and CI would get stable dev identities
without generating their own — **only if dev builds are isolated** from the
release app's records: their own `APP_ID` *and* their own `productName`
(the Keychain item is named after the product, and so is the config
directory). Otherwise a public key accumulates grants on the real app's
Keychain item and becomes the backdoor described above. Not done as of
2026-09-19: with one builder, the no-`SIGN_PEM` ad-hoc path is good enough
for dev builds, at the cost of the two prompts when a dev build is
installed over the daily one. If it becomes worth doing, it should be a
single `DEV=1` flag that flips key, identifier and product name together.

## Runtime side (electron/lan.js)

Even a correctly signed app races the prompt: macOS fails the pending
connect while the dialog is up, and mDNS resolution of `.local` names is
gated by the same permission. So before the first ssh to a LAN target per
run, `main.js` opens one TCP connection to it from its own process (which
puts the prompt on the process whose children the ssh spawns are), holds
the attempt for up to 20 s while the probe is denied or unresolvable, and
if ssh still reports `No route to host` shows a hint naming the setting
instead of a bare exit code — then keeps probing for three minutes and
reconnects by itself once a connection goes through.

## Troubleshooting on the Mac

- **`No route to host` in under ~100 ms** → privacy/identity, not routing.
  `ssh` from Terminal to the same host works? Then it is the app's grant.
- **Toggle on, still denied** → the stored decision does not match the
  running process: check `codesign --verify --deep --strict` (must pass),
  then toggle the entry off and on.
- **App ran from `~/Downloads`** → App Translocation gives it a random path
  per launch; drag it to `/Applications` in Finder (the drag is what clears
  translocation), then `xattr -dr com.apple.quarantine /Applications/webmux.app`.
- **Stale or duplicate entries** in the Local Network list cannot be
  removed from System Settings. `tccutil` does not cover this permission.
  The decisions live in `/Library/Preferences/com.apple.networkextension.plist`,
  which is SIP-protected on Tahoe+: to reset, boot to Recovery, unlock the
  Data volume (`diskutil apfs unlockVolume`), move the file aside, reboot.
  Every app re-prompts once. Or sidestep with `make client APP_ID=<new id>`.
- **Keychain prompt after an update** → the identity changed (ad-hoc
  build, or a rotated key). Expected once; choose Always Allow.
