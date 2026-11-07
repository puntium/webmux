// webmux.app entry point. A manual NSApplication setup (no storyboard, no
// NSApplicationMain) so the same binary runs from `swift build` and from the
// bundle; see docs/macos-client.md.
import AppKit
import GhosttyKit

// Initialize Ghostty global state first: the config and app APIs need it. It
// does not need a resources directory (terminfo and shell integration live on
// the remote host); without GHOSTTY_RESOURCES_DIR the lookup just comes back
// empty.
if ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) != GHOSTTY_SUCCESS {
    FileHandle.standardError.write(Data("webmux: ghostty_init failed\n".utf8))
    exit(1)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
