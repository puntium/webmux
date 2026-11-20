# webmux-host, as host/build.sh builds it: a static musl binary per payload
# platform, linked against libghostty-vt from the pinned Ghostty commit, with
# `zig cc` as the C compiler so either Linux builds both. Then the payload
# the clients push (deploy/build-payload.js).
#
# Returns { native, payload, bins }.
{
  lib,
  stdenv,
  callPackage,
  buildGoModule,
  runCommand,
  go,
  nodejs,
  pkg-config-unwrapped,
  zig_0_17,
  ghostty-vt-src,
}: let
  # zig triple, GOARCH and payload key, as ZIG_TARGETS in host/build.sh.
  targets = {
    x86_64-linux = {
      triple = "x86_64-linux-musl";
      goarch = "amd64";
      key = "linux-x64";
    };
    aarch64-linux = {
      triple = "aarch64-linux-musl";
      goarch = "arm64";
      key = "linux-arm64";
    };
  };

  version = "0-unstable-${builtins.substring 0 8 ghostty-vt-src.rev}";

  src = lib.fileset.toSource {
    root = ../host;
    fileset = lib.fileset.unions [
      ../host/go.mod
      ../host/go.sum
      ../host/tools.go
      ../host/cmd
      ../host/internal
    ];
  };

  # zig keeps its caches under these; the sandbox has no home directory.
  zigEnv = ''
    export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-global" ZIG_LOCAL_CACHE_DIR="$TMPDIR/zig-local"
  '';

  zigDeps = callPackage "${ghostty-vt-src}/build.zig.zon.nix" {
    name = "libghostty-vt-zig-packages";
  };

  libFor = t:
    stdenv.mkDerivation {
      pname = "libghostty-vt-${t.triple}";
      inherit version;
      src = ghostty-vt-src;
      dontConfigure = true;
      dontFixup = true;
      buildPhase = ''
        runHook preBuild
        ${zigEnv}
        ${zig_0_17}/bin/zig build --system ${zigDeps} \
          -Demit-lib-vt -Doptimize=fast -Dtarget=${t.triple} \
          -Dlib-version-string=1.0.0-dev+${builtins.substring 0 8 ghostty-vt-src.rev}-nix \
          --prefix "$out"
        runHook postBuild
      '';
      dontInstall = true;
    };

  # The Go modules as a local module proxy (not `go mod vendor`, which
  # leaves out what the cgo package needs beside its .go files).
  goModules =
    (buildGoModule {
      pname = "webmux-host";
      inherit version src;
      proxyVendor = true;
      vendorHash = "sha256-nXwiOLowLjCg+5T+S+9UENXesT6dRZP/d+nYrP+6M+U=";
    }).goModules;

  binFor = t: let
    vt = libFor t;
  in
    stdenv.mkDerivation {
      pname = "webmux-host-${t.key}";
      inherit version src;
      nativeBuildInputs = [go];
      # nixpkgs' hardening flags must not reach zig cc.
      hardeningDisable = ["all"];
      dontConfigure = true;
      dontFixup = true;
      buildPhase = ''
        runHook preBuild
        ${zigEnv}
        export HOME="$TMPDIR" GOCACHE="$TMPDIR/go-cache" GOPATH="$TMPDIR/go"
        export GOPROXY="file://${goModules}" GOSUMDB=off GOTOOLCHAIN=local
        export PATH="${zig_0_17}/bin:$PATH"
        export PKG_CONFIG="${pkg-config-unwrapped}/bin/pkg-config"
        export PKG_CONFIG_PATH="${vt}/share/pkgconfig"
        CGO_ENABLED=1 GOOS=linux GOARCH=${t.goarch} \
        CC="zig cc -target ${t.triple}" CXX="zig c++ -target ${t.triple}" \
        CGO_CFLAGS="-O2 -I${vt}/include -DGHOSTTY_STATIC" \
        go build -trimpath -tags osusergo,netgo \
          -ldflags="-s -w -linkmode=external '-extldflags=-static -s'" \
          -o webmux-host ./cmd/webmux-host
        runHook postBuild
      '';
      installPhase = ''
        runHook preInstall
        install -Dm755 webmux-host "$out/bin/webmux-host"
        runHook postInstall
      '';
      meta = {
        description = "The webmux server: sessions on a host, for the webmux clients";
        mainProgram = "webmux-host";
        platforms = lib.attrNames targets;
      };
    };

  bins = lib.mapAttrs' (_: t: lib.nameValuePair t.key (binFor t)) targets;

  # electron/payload as deploy/build-payload.js writes it, without the
  # staging trees: <key>/payload.tar.gz and payload.json.
  payload =
    runCommand "webmux-payload-${version}" {
      nativeBuildInputs = [nodejs];
      src = lib.fileset.toSource {
        root = ../.;
        fileset = lib.fileset.unions [../deploy/build-payload.js ../shims];
      };
    } ''
      mkdir bin
      ${lib.concatStrings (lib.mapAttrsToList (key: bin: ''
          cp ${bin}/bin/webmux-host bin/webmux-host-${key}
        '')
        bins)}
      WEBMUX_HOST_BIN_DIR="$PWD/bin" WEBMUX_PAYLOAD_OUT_DIR="$out" node "$src/deploy/build-payload.js"
      rm -r "$out"/*/staging
    '';
in {
  inherit bins payload;
  native = binFor targets.${stdenv.hostPlatform.system};
}
