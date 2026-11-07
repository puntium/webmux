# WebmuxLayout

The column/stack layout model of the native macOS client: the workspace
strip (columns of stacked panes), its commands, the change sets the
workspace view animates from, the width rule and geometry, and the saved
layout file. Pure Swift, Foundation only, value types, `Sendable`. The
reference implementation is the Zig package `gtk/ghostty/src/webmux/layout`
(itself a port of the layout half of `electron/ui/app.js`, the behavioural
spec, PARITY §§ 3–5); this is a 1:1 port of its semantics.

## Zig → Swift

| Zig | Swift | Notes |
| --- | --- | --- |
| `layout.zig` | (module) | |
| `layout/Layout.zig` | `Layout.swift`, `LayoutCommand.swift` | `Layout`, `Column`, `Pane`, `PaneKind`, `Position`, `Direction`, `HorizontalDirection`, `VerticalDirection`, `LayoutError`, `LayoutInvariantError`; `Command` → `LayoutCommand` (raw values are the app.js names) |
| `layout/change.zig` | `Change.swift` | `Snapshot` → `LayoutSnapshot`, `Change` → `LayoutChange`, `Slot`, `Neighbour`, `Origin`, `PaneChange`, `DividerChange`, `ColumnChange`, `Leaving`; plus `Layout.snapshot()` and `Layout.recording { … }` |
| `layout/width.zig` | `Width.swift` | `Metrics` → `StripMetrics`, `Settings` → `WidthSettings`, `ColumnWidths`, `ColumnBox`, `StripGeometry` (+ `clampScroll`, `revealTarget`, `endChaseTarget`), `ChaseStep`, `scrollTauMs`, `Span`, `StackGeometry` |
| `layout/persist.zig` | `Persistence.swift` | `LayoutPersistence` (`serialize`/`encode`, `parse`, `parseSaved`, `reconcile`, `load`, `relativePath(hostSlug:)`, `saveDebounce`) |
| (std.json) | `JSON.swift` | internal: ordered, strict, non-recursive JSON parser/writer (see below) |
| `layout/testing.zig` | `Tests/…/LayoutSpec.swift` | the `a,b^*|!c` spec strings, `expectLayout`, `expectSizes`, `expectSame` |
| `layout/test_layout.zig` | `Tests/…/LayoutTests.swift` | |
| `layout/test_change.zig` | `Tests/…/ChangeTests.swift` | |
| `layout/test_width.zig` | `Tests/…/WidthTests.swift` | |
| `layout/test_persist.zig` | `Tests/…/PersistenceTests.swift` | |
| `layout/test_trace.zig` | `Tests/…/TraceTests.swift` | replays `testdata/app_js_trace.jsonl` |
| `layout/testdata/*` | (read from the fork) | the tests read `gtk/ghostty/src/webmux/layout/testdata/` via `#filePath`; this target declares no resources (Package.swift is the lead's), and the data has one source of truth |
| — | `Tests/…/JSONTests.swift` | the parser/writer, which has no Zig counterpart |

## Differences from the Zig (all deliberate)

- **Value types, ids instead of pointers.** `Layout`, `Column`, `Pane` are
  structs; `Column.active` and `Layout.focused` are pane ids; `*Pane`
  parameters became `String` ids (`drop(_ id:)`). A `Layout` is its own
  snapshot; `LayoutSnapshot` still exists (structure only, no browser
  state) because `LayoutChange.diff` is defined on it.
- **Mutation is `internal(set)`.** Callers go through the commands;
  `@testable import` lets the tests poke weights and focus as the Zig
  tests do. `check()` is public for debug assertions.
- **No allocator, no OOM tests.** The three `checkAllAllocationFailures`
  tests have no Swift equivalent and were not ported.
- **`appendColumn` throws `invalidId`** for inconsistent arguments (no
  ids, length mismatch, `active` out of range) where the Zig asserts.
- **`StackGeometry.dividerSpan/dividerOffset` return optionals** for an
  out-of-range divider (the Zig indexes unchecked).
- **`statePath` → `relativePath(hostSlug:)`**: validates the slug (one
  plain path component) and returns `layout/<slug>.json`; the app roots it
  at `~/Library/Application Support/<bundle id>/` (macOS deviation 4). The
  XDG logic has no Mac meaning.
- **Saving is `encode(_:) -> Data`** (or `serialize(_:) -> String`); the
  250 ms debounce (deviation 35) is the caller's timer, exposed only as the
  constant `saveDebounce`.
- **Own JSON parser/writer** instead of `std.json`: Foundation's
  `JSONSerialization` loses member order and makes recursion/depth
  behaviour opaque. Ours keeps member order, folds a repeated key into
  its first slot with the last value (JSON.parse), is strict (trailing
  content, control characters, bad escapes, invalid UTF-8 → the whole
  document is unusable → empty layout), never recurses, and stops
  *building* containers past `Layout.maxStateDepth + 2` levels (deeper
  content is still syntax-checked and reads as `.tooDeep`, i.e. rejected
  as a browser state). Lone `\uD800`-style surrogates become U+FFFD.
  Number output: integral values print as integers (`1`, not `1.0`),
  others as Swift's shortest round-trip text (`1e+20` is valid JSON), so
  the written text can differ from the Zig's for non-integral weights
  while parsing to the same doubles.
- **`columnWidths`** guards non-finite viewports (`fit` falls back to 1)
  exactly as the Zig does; the Swift `Int` conversion is guarded the same
  way.
- **The random-walk test** uses a SplitMix64 generator of its own, so the
  sequence differs from the Zig's `DefaultPrng`; it is an invariant test,
  not a golden one.

Everything else, including every edge case of app.js that the Zig
documents (focus fall-through, average weights, `active` re-pick, the
`-1 + 1` focus-right rule, `full` flag travel, matchColumns ties, the
entryRect order, the 45 % divider clamp, the hostile-input hardening of
deviation 5), is identical and covered by the same tests.

## Not in the reference (and so not here)

The brief listed "column width grow/shrink", "zoom" and "focus by index"
as commands. None exists in app.js, PARITY § 4/§ 5 or the Zig: there are
fifteen pane commands (`LayoutCommand.allCases`), the only width control
is the min/max settings (`WidthSettings`), and zoom (K-31, deviation 24)
is a change of the cell width fed into `StripGeometry`, not a layout
command. Nothing was invented.
