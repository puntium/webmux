// The Settings window (⌘,; PARITY E-10…E-15; deviations 27, 32, 67; reference:
// panels/settings_panel.zig): a standard toolbar-style settings window with
// one pane, General — Appearance (System / Dark / Light), the unfocused-pane
// fade slider (live preview, saved 400 ms after it stops or on close), the
// minimum and maximum terminal widths, and the connection log button.
import AppKit
import os
import WebmuxConnection

@MainActor
public final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSTextFieldDelegate {
    private static let logger = Logger(subsystem: panelsLogSubsystem, category: "panels")
    public static let fadeSettleMs = 400
    public static let windowTitle = "Settings"

    private let engine: ConnectionEngine
    /// Opens the Connection Log window (E-14).
    public var onOpenLog: (() -> Void)?

    private let appearancePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let fadeSlider = NSSlider(value: 40, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let fadeReadout = NSTextField(labelWithString: "40%")
    private let minField = NSTextField(string: "90")
    private let maxField = NSTextField(string: "200")
    private let minStepper = NSStepper()
    private let maxStepper = NSStepper()
    private var syncing = false
    private var fadeSave: DispatchWorkItem?
    private var pendingFade: Int?

    public init(engine: ConnectionEngine) {
        self.engine = engine
        let window = PanelWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 360),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false)
        window.title = Self.windowTitle
        window.tabbingMode = .disallowed
        window.toolbarStyle = .preference
        window.setFrameAutosaveName("webmux.settings")
        window.center()
        super.init(window: window)
        window.delegate = self
        let toolbar = NSToolbar(identifier: "webmux.settings.toolbar")
        toolbar.delegate = self
        toolbar.allowsUserCustomization = false
        toolbar.displayMode = .iconAndLabel
        toolbar.selectedItemIdentifier = Self.generalItem
        window.toolbar = toolbar
        window.contentView = buildContent()
        apply(settings: engine.settings)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Public

    /// E-10: open (or bring to the front). Opens with no host in front too
    /// (deviation 32). The appearance popup takes initial focus.
    public func show() {
        guard let window else { return }
        apply(settings: engine.settings)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(appearancePopup)
    }

    /// E-15: follow changes made elsewhere while open (a width field being
    /// edited is left alone).
    public func apply(settings s: Settings) {
        syncing = true
        defer { syncing = false }
        let appearance = Appearance(theme: s.theme)
        appearancePopup.selectItem(at: Appearance.allCases.firstIndex(of: appearance) ?? 1)
        if pendingFade == nil {
            fadeSlider.integerValue = s.unfocusedFade
            fadeReadout.stringValue = "\(s.unfocusedFade)%"
        }
        if window?.firstResponder !== minField.currentEditor() { minField.integerValue = s.minCols }
        if window?.firstResponder !== maxField.currentEditor() { maxField.integerValue = s.maxCols }
        minStepper.integerValue = s.minCols
        maxStepper.integerValue = s.maxCols
    }

    /// Choose an appearance as the popup would (the control socket's path).
    public func select(appearance: Appearance) {
        appearancePopup.selectItem(at: Appearance.allCases.firstIndex(of: appearance) ?? 1)
        appearanceChanged(appearancePopup)
    }

    /// Move the fade slider as a drag would (the control socket's path).
    public func setFade(_ value: Int) {
        fadeSlider.integerValue = value
        fadeChanged(fadeSlider)
    }

    public var selectedAppearance: Appearance {
        Appearance.allCases[max(0, min(Appearance.allCases.count - 1, appearancePopup.indexOfSelectedItem))]
    }

    /// Save a fade preview that is still pending (deviation 27: on close).
    public func flushPendingSave() {
        fadeSave?.cancel()
        fadeSave = nil
        if let f = pendingFade {
            pendingFade = nil
            engine.updateSettings(Settings.Patch(unfocusedFade: Double(f)))
        }
    }

    // MARK: Content

    private func buildContent() -> NSView {
        for a in Appearance.allCases { appearancePopup.addItem(withTitle: a.label) }
        appearancePopup.target = self
        appearancePopup.action = #selector(appearanceChanged(_:))

        fadeSlider.isContinuous = true
        fadeSlider.numberOfTickMarks = 21
        fadeSlider.allowsTickMarkValuesOnly = true
        fadeSlider.target = self
        fadeSlider.action = #selector(fadeChanged(_:))
        fadeSlider.widthAnchor.constraint(equalToConstant: 200).isActive = true
        fadeReadout.alignment = .right
        fadeReadout.widthAnchor.constraint(equalToConstant: 40).isActive = true
        let fadeRow = NSStackView(views: [fadeSlider, fadeReadout])
        fadeRow.orientation = .horizontal
        fadeRow.spacing = 8

        let logButton = NSButton(title: "Open Connection Log…", target: self, action: #selector(openLog(_:)))

        let grid = NSGridView(views: [
            [label("Appearance:"), appearancePopup],
            [NSGridCell.emptyContentView, description("System follows the desktop; Dark and Light also pick the terminal palette.")],
            [label("Unfocused pane fade:"), fadeRow],
            [NSGridCell.emptyContentView, description("How much panes other than the focused one dim. 0% leaves them untouched.")],
            [label("Minimum terminal width:"), widthRow(minField, minStepper, #selector(minChanged(_:)))],
            [NSGridCell.emptyContentView, description("No column is narrower than this. As many columns as fit at this width share the window exactly; open more and the layout scrolls sideways.")],
            [label("Maximum terminal width:"), widthRow(maxField, maxStepper, #selector(maxChanged(_:)))],
            [NSGridCell.emptyContentView, description("No column is wider than this. Fewer columns than fit the window grow to share it up to this width and sit centred.")],
            [label("Connection log:"), logButton],
            [NSGridCell.emptyContentView, description("Tunnel setup, teardown, and reconnect events for every host on this client, live and copyable. Also written to a file on disk.")],
        ])
        grid.rowSpacing = 6
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 170
        grid.column(at: 1).width = 300
        for i in stride(from: 1, to: grid.numberOfRows, by: 2) { grid.row(at: i).bottomPadding = 8 }
        grid.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            grid.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            grid.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -20),
        ])
        return root
    }

    private func label(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.alignment = .right
        return l
    }

    private func description(_ s: String) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: s)
        l.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        l.textColor = .secondaryLabelColor
        l.preferredMaxLayoutWidth = 300
        return l
    }

    private func widthRow(_ field: NSTextField, _ stepper: NSStepper, _ action: Selector) -> NSView {
        field.alignment = .right
        field.widthAnchor.constraint(equalToConstant: 60).isActive = true
        field.delegate = self
        field.target = self
        field.action = action
        let formatter = NumberFormatter()
        formatter.minimum = 40
        formatter.maximum = 400
        formatter.allowsFloats = false
        field.formatter = formatter
        stepper.minValue = 40
        stepper.maxValue = 400
        stepper.increment = 1
        stepper.valueWraps = false
        stepper.target = self
        stepper.action = action
        let unit = NSTextField(labelWithString: "columns")
        unit.textColor = .secondaryLabelColor
        let row = NSStackView(views: [field, stepper, unit])
        row.orientation = .horizontal
        row.spacing = 4
        return row
    }

    // MARK: Actions

    @objc private func appearanceChanged(_ sender: Any?) {
        guard !syncing else { return }
        let a = selectedAppearance
        ThemeController.apply(a)
        engine.updateSettings(Settings.Patch(theme: a.rawValue))
    }

    /// E-12 / deviation 27: preview at once, save 400 ms after the last move.
    @objc private func fadeChanged(_ sender: Any?) {
        guard !syncing else { return }
        let v = fadeSlider.integerValue
        fadeReadout.stringValue = "\(v)%"
        ThemeController.applyFade(v)
        pendingFade = v
        fadeSave?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.flushPendingSave() }
        fadeSave = item
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Self.fadeSettleMs), execute: item)
    }

    @objc private func minChanged(_ sender: Any?) {
        guard !syncing else { return }
        let v = (sender as? NSStepper)?.integerValue ?? minField.integerValue
        let s = engine.updateSettings(Settings.Patch(minCols: Double(v)))
        apply(settings: s)
        minField.integerValue = s.minCols
    }

    @objc private func maxChanged(_ sender: Any?) {
        guard !syncing else { return }
        let v = (sender as? NSStepper)?.integerValue ?? maxField.integerValue
        let s = engine.updateSettings(Settings.Patch(maxCols: Double(v)))
        apply(settings: s)
        maxField.integerValue = s.maxCols
    }

    /// E-13: commit on blur as well as on Enter.
    public func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        if field === minField { minChanged(nil) } else if field === maxField { maxChanged(nil) }
    }

    @objc private func openLog(_ sender: Any?) {
        onOpenLog?()
    }

    // MARK: NSToolbarDelegate

    static let generalItem = NSToolbarItem.Identifier("webmux.settings.general")

    public func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [Self.generalItem] }
    public func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [Self.generalItem] }
    public func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [Self.generalItem] }

    public func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard itemIdentifier == Self.generalItem else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = "General"
        item.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "General")
        item.target = self
        item.action = #selector(selectGeneral(_:))
        return item
    }

    @objc private func selectGeneral(_ sender: Any?) {}

    // MARK: NSWindowDelegate

    public func windowWillClose(_ notification: Notification) {
        flushPendingSave()
    }

}
