// The in-pane delete confirmation (F-52): a modal centred over the file
// browser only, with `Delete folder “<name>” and everything in it?` or
// `Delete “<name>”?`, Cancel and a red default Delete that has initial
// focus. Escape or a click on the backdrop cancels.
import AppKit

@MainActor
final class FilesConfirmView: NSView {
    let onDone: (Bool) -> Void
    private let box = NSVisualEffectView()
    private let label = NSTextField(wrappingLabelWithString: "")
    let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    let deleteButton = NSButton(title: "Delete", target: nil, action: nil)
    private var finished = false

    init(text: String, onDone: @escaping (Bool) -> Void) {
        self.onDone = onDone
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.35).cgColor

        box.material = .popover
        box.blendingMode = .withinWindow
        box.state = .active
        box.wantsLayer = true
        box.layer?.cornerRadius = 10
        box.layer?.borderWidth = 1
        box.layer?.borderColor = NSColor.separatorColor.cgColor
        box.translatesAutoresizingMaskIntoConstraints = false
        addSubview(box)

        label.stringValue = text
        label.font = .systemFont(ofSize: 13)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        box.addSubview(label)

        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.target = self
        cancelButton.action = #selector(cancel(_:))
        deleteButton.bezelStyle = .rounded
        deleteButton.keyEquivalent = "\r"
        deleteButton.hasDestructiveAction = true
        deleteButton.bezelColor = NSColor(srgbRed: 0xc3 / 255, green: 0x4f / 255, blue: 0x5e / 255, alpha: 1)
        deleteButton.target = self
        deleteButton.action = #selector(confirm(_:))
        let buttons = NSStackView(views: [cancelButton, deleteButton])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        buttons.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(buttons)

        NSLayoutConstraint.activate([
            box.centerXAnchor.constraint(equalTo: centerXAnchor),
            box.centerYAnchor.constraint(equalTo: centerYAnchor),
            box.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -24),
            box.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
            label.topAnchor.constraint(equalTo: box.topAnchor, constant: 18),
            label.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 18),
            label.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -18),
            label.widthAnchor.constraint(greaterThanOrEqualToConstant: 200),
            buttons.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 16),
            buttons.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -14),
            buttons.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -14),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    var text: String { label.stringValue }

    override var acceptsFirstResponder: Bool { true }

    func takeFocus() {
        window?.makeFirstResponder(deleteButton)
    }

    override func mouseDown(with event: NSEvent) {
        // A click on the backdrop (not the box) cancels.
        let p = convert(event.locationInWindow, from: nil)
        if !box.frame.contains(p) { finish(false) }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: finish(false) // Escape
        case 36, 76: finish(true) // Return, keypad Enter
        default: super.keyDown(with: event)
        }
    }

    @objc private func cancel(_ sender: Any?) { finish(false) }
    @objc private func confirm(_ sender: Any?) { finish(true) }

    func finish(_ ok: Bool) {
        if finished { return }
        finished = true
        onDone(ok)
    }
}
