// The link chooser (M-04; deviations 26, 68; reference: panels/url.zig and
// model.zig's URL rules): an `NSAlert` sheet with the URL, Open / Copy /
// Cancel. http(s) opens in the default browser; `mailto:` opens the default
// mail application; anything else offers Copy only.
import AppKit
import os

/// T-24…T-26, M-04: what a URL may do.
public enum URLKind: Equatable, Sendable {
    /// http: / https: — a click opens it, the chooser offers "Open in Browser".
    case web
    /// mailto: — the chooser offers "Open" (the mail application).
    case mailto
    /// anything else (file:, javascript:, ssh:, …) — inert; Copy only.
    case other

    public init(url: String) {
        let lower = url.lowercased()
        if lower.hasPrefix("http:") || lower.hasPrefix("https:") {
            self = .web
        } else if lower.hasPrefix("mailto:") {
            self = .mailto
        } else {
            self = .other
        }
    }

    /// Whether a plain click (open) or shift-click (copy) acts on it.
    public var isClickable: Bool { self == .web }

    /// The chooser's Open button label, or nil when there is none.
    public var openLabel: String? {
        switch self {
        case .web: return "Open in Browser"
        case .mailto: return "Open"
        case .other: return nil
        }
    }
}

@MainActor
public enum LinkChooser {
    private static let logger = Logger(subsystem: panelsLogSubsystem, category: "panels")

    public enum Choice: Equatable, Sendable { case open, copy, cancel }

    /// The chooser's heading and the button order (Open is the default
    /// button when present; Cancel answers Escape).
    public static let heading = "Link options"

    /// How many choosers are open (control socket / tests).
    public private(set) static var openCount = 0

    /// Present the chooser as a sheet on `window` (or app-modal without one).
    /// `completion` runs after the choice was carried out.
    public static func present(url: String, kind: URLKind? = nil, in window: NSWindow?, completion: ((Choice) -> Void)? = nil) {
        let kind = kind ?? URLKind(url: url)
        let alert = NSAlert()
        alert.messageText = heading
        alert.informativeText = ""
        alert.alertStyle = .informational
        let field = NSTextField(wrappingLabelWithString: url)
        field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        field.textColor = .controlAccentColor
        field.isSelectable = true
        field.lineBreakMode = .byCharWrapping
        field.preferredMaxLayoutWidth = 420
        field.frame = NSRect(x: 0, y: 0, width: 420, height: min(200, field.intrinsicContentSize.height))
        alert.accessoryView = field
        var buttons: [(Choice, String)] = []
        if let open = kind.openLabel { buttons.append((.open, open)) }
        buttons.append((.copy, "Copy"))
        buttons.append((.cancel, "Cancel"))
        for (_, title) in buttons {
            let b = alert.addButton(withTitle: title)
            if title == "Cancel" { b.keyEquivalent = "\u{1b}" }
        }
        openCount += 1
        let handle: (NSApplication.ModalResponse) -> Void = { response in
            openCount -= 1
            let index = Int(response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue)
            let choice = (index >= 0 && index < buttons.count) ? buttons[index].0 : .cancel
            act(choice, url: url, kind: kind, in: window)
            completion?(choice)
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: handle)
        } else {
            handle(alert.runModal())
        }
    }

    static func act(_ choice: Choice, url: String, kind: URLKind, in window: NSWindow?) {
        switch choice {
        case .cancel: break
        case .copy:
            copy(url, in: window)
        case .open:
            open(url, kind: kind, in: window)
        }
    }

    /// Put a URL on the clipboard and show "link copied" (M-02).
    public static func copy(_ url: String, in window: NSWindow?) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(url, forType: .string)
        StatusHUD.show("link copied", in: window)
    }

    /// Open an http(s) or mailto URL with the default application; anything
    /// else shows "can't open <href>" (M-02).
    public static func open(_ url: String, kind: URLKind? = nil, in window: NSWindow?) {
        let kind = kind ?? URLKind(url: url)
        guard kind != .other, let u = URL(string: url) else {
            StatusHUD.show("can't open \(url)", in: window)
            return
        }
        if !NSWorkspace.shared.open(u) {
            logger.warning("open failed: \(url, privacy: .public)")
            StatusHUD.show("can't open \(url)", in: window)
        }
    }
}
