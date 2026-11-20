{
  description = "webmux: the native GTK client, the host binary and the payload the client pushes";

  # What this flake is for, and how to put it in a NixOS configuration:
  # docs/nix.md.
  inputs = {
    # The Ghostty fork's own nixpkgs pin (gtk/ghostty/flake.lock), so the
    # client builds here against what its dev shell builds it against.
    nixpkgs.url = "https://channels.nixos.org/nixpkgs-unstable/nixexprs.tar.zst";

    # The client's source is the submodule at gtk/ghostty; the commit this
    # repo pins is the one that gets built.
    self.submodules = true;

    # The Ghostty commit libghostty-vt is built from for webmux-host. It
    # must be the commit host/build.sh names (GHOSTTY_COMMIT); the outputs
    # below refuse to evaluate when the two differ.
    ghostty-vt-src = {
      url = "github:ghostty-org/ghostty/f54340ad77814fe319d136e5e915d6a48de8dd23";
      flake = false;
    };
  };

  outputs = {
    self,
    nixpkgs,
    ghostty-vt-src,
  }: let
    inherit (nixpkgs) lib;

    systems = ["x86_64-linux" "aarch64-linux"];
    forAll = f: lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

    revision = self.shortRev or self.dirtyShortRev or "dirty";

    hostPin = let
      m = builtins.match ".*\nGHOSTTY_COMMIT=([0-9a-f]{40})\n.*" (builtins.readFile ./host/build.sh);
    in
      if m == null
      then throw "flake.nix: no GHOSTTY_COMMIT=<40 hex> line in host/build.sh"
      else builtins.head m;

    packagesFor = pkgs:
      assert lib.assertMsg (hostPin == ghostty-vt-src.rev) ''
        host/build.sh pins Ghostty ${hostPin}, the flake input ghostty-vt-src is at ${ghostty-vt-src.rev}.
        Set the commit in flake.nix (inputs.ghostty-vt-src.url) and run: nix flake update ghostty-vt-src
      ''; let
        host = pkgs.callPackage ./nix/host.nix {inherit ghostty-vt-src;};
        webmux-gtk = pkgs.callPackage ./nix/gtk.nix {
          inherit revision;
          payload = host.payload;
        };
      in {
        inherit webmux-gtk;
        webmux-host = host.native;
        webmux-payload = host.payload;
        default = webmux-gtk;
      };
  in {
    packages = forAll packagesFor;

    # Built with this flake's nixpkgs pin, not the importing system's: the
    # packages are the ones `nix build` here gives, whatever channel the
    # system follows.
    overlays.default = final: prev: {
      inherit (self.packages.${final.stdenv.hostPlatform.system}) webmux-gtk webmux-host webmux-payload;
    };

    nixosModules.default = {
      config,
      lib,
      pkgs,
      ...
    }: let
      cfg = config.programs.webmux;
    in {
      options.programs.webmux = {
        enable = lib.mkEnableOption "webmux-gtk, the native webmux client";
        package = lib.mkOption {
          type = lib.types.package;
          default = self.packages.${pkgs.stdenv.hostPlatform.system}.webmux-gtk;
          defaultText = lib.literalExpression "webmux.packages.\${system}.webmux-gtk";
          description = "The webmux-gtk package to install.";
        };
      };
      config = lib.mkIf cfg.enable {
        environment.systemPackages = [cfg.package];
      };
    };

    formatter = forAll (pkgs: pkgs.alejandra);
  };
}
