# Nix flake

`flake.nix` at the repo root packages what a NixOS machine needs to use
webmux as a client: `webmux-gtk` with the server payload beside it. It does
not replace the build described in [development.md](development.md); the
`Makefile`, `host/flake.nix` and the fork's own flake stay the way to work
on the code.

## Outputs

| Output | What |
| --- | --- |
| `packages.<system>.webmux-gtk` (also `default`) | The native GTK client (`bin/webmux-gtk`), a desktop entry, and the payload at `share/webmux-gtk/payload`, where the client looks first |
| `packages.<system>.webmux-payload` | What the client pushes to a host on connect: `payload.json` and `<platform>/payload.tar.gz` for `linux-x64` and `linux-arm64` |
| `packages.<system>.webmux-host` | `bin/webmux-host` for this machine, the static binary that is also in the payload |
| `nixosModules.default` | `programs.webmux.enable` (and `programs.webmux.package`): installs `webmux-gtk` system-wide |
| `overlays.default` | Adds `webmux-gtk`, `webmux-host` and `webmux-payload` to `pkgs` |

`<system>` is `x86_64-linux` or `aarch64-linux`. The Electron client and the
macOS clients are not packaged here.

The packages are built with the nixpkgs revision in this repo's
`flake.lock`, also when they come in through the module or the overlay, so
the system's own channel does not change what gets built. Nothing is in a
binary cache: the first build compiles libghostty-vt twice and the client
once, about ten minutes.

## Adding it to a NixOS configuration

The flake has to be fetched as a git repository (`git+https://…`), because
the client's source is a submodule, which a `github:puntium/webmux`
reference (a tarball) does not carry. The build stops with a message when
`gtk/ghostty` is empty.

A configuration without flakes (`/etc/nixos/configuration.nix`), with
`flakes` and `nix-command` in `nix.settings.experimental-features`:

```nix
{ config, pkgs, ... }:
let
  webmux = builtins.getFlake
    "git+https://github.com/puntium/webmux?ref=main&rev=<commit>";
in {
  imports = [
    ./hardware-configuration.nix
    webmux.nixosModules.default
  ];

  programs.webmux.enable = true;
}
```

`<commit>` is the full hash of the webmux commit to install; a new version
is a new hash here and `nixos-rebuild switch`. Without `&rev=…` the
rebuild takes whatever `main` is at the time.

A flake-based configuration:

```nix
{
  inputs.webmux.url = "git+https://github.com/puntium/webmux";
  # no `inputs.nixpkgs.follows`: see "Outputs" above

  outputs = { nixpkgs, webmux, ... }: {
    nixosConfigurations.<host> = nixpkgs.lib.nixosSystem {
      modules = [
        ./configuration.nix
        webmux.nixosModules.default
        { programs.webmux.enable = true; }
      ];
    };
  };
}
```

`nix flake update webmux` there moves to the current `main`.

To install for one user only, leave the module out and add
`webmux.packages.${pkgs.stdenv.hostPlatform.system}.webmux-gtk` to that
user's `users.users.<name>.packages`.

## Trying it without installing

```sh
nix run 'git+https://github.com/puntium/webmux'          # the client
nix build .#webmux-gtk                                   # in a checkout, submodule fetched
```

In a checkout the build takes the working tree as it is, uncommitted
changes in `gtk/ghostty` included.

## What has to stay in step

- **The client's commit** is the submodule pointer; there is nothing to
  update in the flake when the fork moves.
- **The host's Ghostty commit** is in two places: `GHOSTTY_COMMIT` in
  `host/build.sh` and `inputs.ghostty-vt-src` in `flake.nix`. The flake
  refuses to evaluate when they differ. After changing both, run
  `nix flake update ghostty-vt-src`.
- **The host's Go modules**: after a change to `host/go.mod` or
  `host/go.sum`, the build fails with the new hash for `vendorHash` in
  `nix/host.nix`.
- **nixpkgs** is locked to the revision the fork's `flake.lock` has, so the
  client is built against the libraries its dev shell uses. To move it,
  copy the `nixpkgs` node from `gtk/ghostty/flake.lock` into `flake.lock`.

A payload built here has a different hash from one built by `make payload`
(another zig, another build of the same source), so a host that was last
used from a checkout gets the payload pushed again on the first connect
from the installed client, and the other way round.
