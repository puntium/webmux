{
  description = "webmux-host dev shell (Go + libghostty-vt toolchain)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    zig-overlay.url = "github:mitchellh/zig-overlay";
    zig-overlay.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { nixpkgs, zig-overlay, ... }:
    let
      # nix system -> zig triple of the native libghostty-vt build
      triples = {
        x86_64-linux = "x86_64-linux-musl";
        aarch64-linux = "aarch64-linux-musl";
      };
      forAll = f: nixpkgs.lib.mapAttrs (system: triple: f system triple nixpkgs.legacyPackages.${system}) triples;
    in {
      devShells = forAll (system: triple: pkgs: {
        default = pkgs.mkShell {
          packages = [
            zig-overlay.packages.${system}."0.17.1"
            pkgs.go
            pkgs.cmake
            pkgs.pkg-config
            pkgs.gnumake
            pkgs.file
            pkgs.git
          ];
          # nixpkgs' hardening wrappers must not leak into zig cc / cgo.
          hardeningDisable = [ "all" ];
          # Native cgo env so plain `go build/test/vet ./...` work in the shell
          # once `./build.sh --libs` has built third_party/ghostty-vt.
          shellHook = ''
            _root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
            if [ -d "$_root/host" ]; then _host="$_root/host"; else _host="$_root"; fi
            export CGO_ENABLED=1
            export CC="zig cc -target ${triple}" CXX="zig c++ -target ${triple}"
            export PKG_CONFIG_PATH="$_host/third_party/ghostty-vt/${triple}/share/pkgconfig"
            export GOFLAGS="-tags=osusergo,netgo"
            unset _root _host
          '';
        };
      });
    };
}
