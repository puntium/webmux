# webmux-gtk: the Ghostty fork at gtk/ghostty built with -Dwebmux=true, with
# the server payload beside it and a desktop entry. Follows the fork's own
# nix/package.nix (which builds stock Ghostty) and takes its build inputs
# and zig packages from the fork.
{
  lib,
  stdenv,
  callPackage,
  pkgs,
  makeDesktopItem,
  copyDesktopItems,
  gobject-introspection,
  blueprint-compiler,
  libxml2,
  gettext,
  wrapGAppsHook4,
  git,
  ncurses,
  pandoc,
  pkg-config,
  zig_0_17,
  wayland-protocols,
  wayland-scanner,
  payload,
  revision ? "dirty",
}: let
  fork = ../gtk/ghostty;
  forkArgs = {
    inherit pkgs lib stdenv;
  };
in
  assert lib.assertMsg (builtins.pathExists (fork + "/build.zig")) ''
    gtk/ghostty is empty: the flake was fetched without its submodule.
    Fetch it as a git flake (git+https://… or git+file://…), not github:….
  '';
    stdenv.mkDerivation (finalAttrs: {
      pname = "webmux-gtk";
      # Ghostty's version (gtk/ghostty/build.zig.zon) and this repo's commit.
      version = "1.4.1-dev+${revision}-nix";

      src = lib.fileset.toSource {
        root = fork;
        fileset = lib.fileset.unions [
          (fork + "/dist/linux")
          (fork + "/images")
          (fork + "/include")
          (fork + "/po")
          (fork + "/pkg")
          (fork + "/src")
          (fork + "/vendor")
          (fork + "/build.zig")
          (fork + "/build.zig.zon")
        ];
      };

      deps = callPackage (fork + "/deps/packages.nix") {};

      nativeBuildInputs = [
        git
        ncurses
        pandoc
        pkg-config
        zig_0_17
        gobject-introspection
        wrapGAppsHook4
        blueprint-compiler
        libxml2
        gettext
        wayland-scanner
        wayland-protocols
        copyDesktopItems
      ];

      buildInputs = import (fork + "/nix/build-support/build-inputs.nix") forkArgs;

      GI_TYPELIB_PATH = import (fork + "/nix/build-support/gi-typelib-path.nix") forkArgs;

      dontSetZigDefaultFlags = true;

      zigBuildFlags = [
        "--system"
        "${finalAttrs.deps}"
        "-Dversion-string=${finalAttrs.version}"
        "-Dapp-runtime=gtk"
        "-Dwebmux=true"
        "-Dgtk-x11=true"
        "-Dgtk-wayland=true"
        "-Dcpu=baseline"
        "-Doptimize=fast"
        "-Dstrip=true"
      ];

      # The application id is me.puntium.webmux.gtk; the desktop file has to
      # carry that name for the shell to tie windows and notifications to it.
      desktopItems = [
        (makeDesktopItem {
          name = "me.puntium.webmux.gtk";
          desktopName = "webmux";
          comment = "Terminal sessions on remote hosts";
          exec = "webmux-gtk";
          icon = "utilities-terminal";
          categories = ["System" "TerminalEmulator"];
          startupNotify = true;
          startupWMClass = "me.puntium.webmux.gtk";
          extraConfig.X-GNOME-UsesNotifications = "true";
        })
      ];

      postInstall = ''
        # The build installs stock Ghostty's launchers, which start a
        # `ghostty` this package does not have.
        rm -rf "$out"/share/applications "$out"/share/dbus-1 "$out"/lib/systemd "$out"/share/systemd \
          "$out"/share/metainfo "$out"/share/kio "$out"/share/nautilus-python

        # Where the client looks first: <exe dir>/../share/webmux-gtk/payload.
        mkdir -p "$out/share/webmux-gtk"
        ln -s ${payload} "$out/share/webmux-gtk/payload"
      '';

      doInstallCheck = true;
      installCheckPhase = ''
        runHook preInstallCheck
        test -f "$out/share/webmux-gtk/payload/payload.json"
        test -f "$out/share/applications/me.puntium.webmux.gtk.desktop"
        runHook postInstallCheck
      '';

      passthru = {inherit payload;};

      meta = {
        description = "Native GTK client for webmux, on a fork of Ghostty";
        homepage = "https://github.com/puntium/webmux";
        platforms = ["x86_64-linux" "aarch64-linux"];
        mainProgram = "webmux-gtk";
      };
    })
