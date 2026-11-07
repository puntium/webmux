// The workspace area: one connection's strip of columns of stacked panes
// (reference: gtk/ghostty/src/apprt/webmux/workspace; spec: gtk/PARITY.md
// §§ 3–5). Depends on WebmuxLayout (the model), WebmuxTerminal (the
// terminal pane) and WebmuxHost (the sessions API).
//
//   WorkspaceController   one per connection: Layout + WorkspaceView + panes,
//                         sessions (list/create/delete), layout file, S-12 flag
//   WorkspaceView         the strip (NSView): geometry, animation, scrolling,
//                         divider drags, the pane chords (performKeyEquivalent)
//   PaneFrame             a pane's chrome: title bar, border, focus ring
//   WorkspacePane         what a pane is to the strip; TerminalPane implements
//                         it over WebmuxSurfaceView; the Files area registers
//                         its own through WorkspacePaneFactories
//   WorkspaceCommand      the chord table (PARITY § 5, macOS column) for menus
//   StripAnimation, Box, Flight, WorkspaceGeometry   pure arithmetic (anim.zig,
//                         geometry.zig), tested without a window
//
// Embedding (the app): create a `WorkspaceController(connection:ghostty:
// layoutURL:)` per connection, put `controller.view` in the window, call
// `attach()`; forward menu actions to `controller.run(_:)`; register the
// files factory once: `WorkspacePaneFactories.shared.register(.files, f)`.
@_exported import WebmuxLayout
