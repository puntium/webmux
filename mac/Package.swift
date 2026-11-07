// swift-tools-version: 5.10
// The native macOS webmux client. See docs/macos-client.md and mac/README.md.
//
// Target graph (arrows = depends on). Every area is a library that builds
// and tests on its own (`swift build --target <T>`, `--scratch-path .build-<area>`):
//
//   GhosttyKit (binary)  <- WebmuxTerminal  (Ghostty wrapper + WebmuxSurfaceView; AppKit)
//   WebmuxLayout         (layout model; Foundation only)
//   WebmuxHost           (one host over its unix socket; Foundation + Network)
//   WebmuxConnection     (profiles, Keychain, ssh tunnel, deploy; Foundation + Security)
//   WebmuxWorkspace      <- WebmuxLayout, WebmuxTerminal, WebmuxHost
//   WebmuxFiles          <- WebmuxHost, WebmuxWorkspace
//   WebmuxPanels         <- WebmuxConnection, WebmuxHost
//   webmux (app)         <- all of the above: App/, Control/, Support/
//
// Each library has a Tests/<T>Tests target; the app's own tests cover Control/.
import PackageDescription

let package = Package(
    name: "webmux",
    platforms: [.macOS(.v14)],
    targets: [
        // Built from the Ghostty fork by `make mac-ghosttykit` (mac/scripts/build-ghosttykit.sh).
        .binaryTarget(name: "GhosttyKit", path: "GhosttyKit.xcframework"),

        // The column/stack layout model, its commands, width rule and persistence
        // (reference: gtk/ghostty/src/webmux/layout). Pure Swift, Foundation only.
        .target(name: "WebmuxLayout", path: "Sources/WebmuxLayout", exclude: ["README.md"]),
        .testTarget(name: "WebmuxLayoutTests", dependencies: ["WebmuxLayout"], path: "Tests/WebmuxLayoutTests"),

        // Talking to one webmux host over its unix socket: HTTP/1.1, WebSocket,
        // SSE, the protocol frames, sessions and fs APIs
        // (reference: gtk/ghostty/src/webmux/net). Foundation + Network.
        // Its live tests start a Darwin dev host themselves (dev-host.sh run host-tests).
        .target(name: "WebmuxHost", path: "Sources/WebmuxHost"),
        .testTarget(name: "WebmuxHostTests", dependencies: ["WebmuxHost"], path: "Tests/WebmuxHostTests"),

        // Profiles and settings store, Keychain, ssh tunnel supervision, probe,
        // deploy, liveness, retry, connection log
        // (reference: gtk/ghostty/src/webmux/conn). Foundation + Security.
        // Tests find Fixtures/ (fake ssh, fake host) through #filePath, so it is
        // excluded rather than bundled as a resource.
        .target(name: "WebmuxConnection", path: "Sources/WebmuxConnection"),
        .testTarget(
            name: "WebmuxConnectionTests",
            dependencies: ["WebmuxConnection"],
            path: "Tests/WebmuxConnectionTests",
            exclude: ["Fixtures"]
        ),

        // The terminal pane: the trimmed Ghostty wrapper (Ghostty/, copied from
        // ghostty macos/Sources/Ghostty) and WebmuxSurfaceView (Terminal/), a
        // Ghostty surface attached to a webmux session. AppKit + GhosttyKit; the
        // frameworks the static library needs are linked here.
        .target(
            name: "WebmuxTerminal",
            dependencies: ["GhosttyKit"],
            path: "Sources/WebmuxTerminal",
            linkerSettings: [
                .linkedFramework("Metal"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("CoreText"),
                .linkedFramework("Carbon"),
                .linkedFramework("IOSurface"),
                .linkedFramework("UniformTypeIdentifiers"),
                .linkedLibrary("c++"),
            ]
        ),
        .testTarget(name: "WebmuxTerminalTests", dependencies: ["WebmuxTerminal"], path: "Tests/WebmuxTerminalTests"),

        // The workspace: the strip of panes, pane frames, animations, sessions
        // (reference: src/apprt/webmux/workspace).
        .target(
            name: "WebmuxWorkspace",
            dependencies: ["WebmuxLayout", "WebmuxTerminal", "WebmuxHost"],
            path: "Sources/WebmuxWorkspace"
        ),
        .testTarget(name: "WebmuxWorkspaceTests", dependencies: ["WebmuxWorkspace"], path: "Tests/WebmuxWorkspaceTests"),

        // The file browser pane (reference: src/apprt/webmux/files).
        .target(
            name: "WebmuxFiles",
            dependencies: ["WebmuxHost", "WebmuxWorkspace"],
            path: "Sources/WebmuxFiles"
        ),
        .testTarget(name: "WebmuxFilesTests", dependencies: ["WebmuxFiles"], path: "Tests/WebmuxFilesTests"),

        // Settings, Connections and Connection Log windows, HUD, link chooser, About
        // (reference: src/apprt/webmux/panels).
        .target(
            name: "WebmuxPanels",
            dependencies: ["WebmuxConnection", "WebmuxHost"],
            path: "Sources/WebmuxPanels"
        ),
        .testTarget(name: "WebmuxPanelsTests", dependencies: ["WebmuxPanels"], path: "Tests/WebmuxPanelsTests"),

        // The app: AppKit shell (App/, Control/, Support/) on the libraries.
        .executableTarget(
            name: "webmux",
            dependencies: [
                "GhosttyKit", "WebmuxLayout", "WebmuxHost", "WebmuxConnection",
                "WebmuxTerminal", "WebmuxWorkspace", "WebmuxFiles", "WebmuxPanels",
            ],
            path: "Sources/webmux"
        ),
        .testTarget(name: "webmuxTests", dependencies: ["webmux"], path: "Tests/webmuxTests"),
    ]
)
