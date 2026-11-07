// Markdown for the preview column (F-35…F-39, deviation 8 and 29):
// Foundation's own parser (`AttributedString(markdown:)`, GitHub-flavoured
// through `.full`) gives block and inline *intents*; this file turns them
// into a styled NSAttributedString for an NSTextView. Raw HTML is literal
// text (the parser already keeps it as such: F-36), remote images show
// their alt text, local images (relative or absolute paths without a
// scheme) are marked with `.webmuxImagePath` for the preview view to fetch
// through /api/fs/raw and swap in (F-37). Links keep their raw target in
// `.link` (relative ones stay relative; the preview view resolves them,
// F-38). Not covered: footnotes, math, definition lists, front matter.
import AppKit

public extension NSAttributedString.Key {
    /// A local image's host path, on the run holding its alt text.
    static let webmuxImagePath = NSAttributedString.Key("webmux.imagePath")
}

public struct MarkdownRendering {
    public var attributed: NSAttributedString
    /// Host paths of the local images, in document order.
    public var localImagePaths: [String]
}

public enum MarkdownRenderer {
    public struct Style {
        public var baseSize: CGFloat = 13
        public var monoSize: CGFloat = 11.5
        public var lineHeightMultiple: CGFloat = 1.25
        public init() {}
    }

    /// Render `source`. `fileDir` resolves relative image paths and is the
    /// directory of the file being previewed.
    public static func render(_ source: String, fileDir: String, style: Style = Style()) -> MarkdownRendering {
        var opts = AttributedString.MarkdownParsingOptions()
        opts.interpretedSyntax = .full
        opts.allowsExtendedAttributes = true
        opts.failurePolicy = .returnPartiallyParsedIfPossible
        let parsed: AttributedString
        do {
            parsed = try AttributedString(markdown: source, options: opts)
        } catch {
            // Unparseable: the source as a plain paragraph.
            let s = NSAttributedString(string: source, attributes: [.font: NSFont.systemFont(ofSize: style.baseSize), .foregroundColor: NSColor.labelColor])
            return MarkdownRendering(attributed: s, localImagePaths: [])
        }
        var b = Builder(style: style, fileDir: fileDir)
        for run in parsed.runs {
            b.add(text: String(parsed[run.range].characters), run: run)
        }
        return b.finish()
    }

    // MARK: - colours and fonts

    static let codeBackground = NSColor(name: nil) { ap in
        ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor.white.withAlphaComponent(0.10) : NSColor.black.withAlphaComponent(0.07)
    }
    static let codeBlockBackground = NSColor(name: nil) { ap in
        ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor.black.withAlphaComponent(0.40) : NSColor.black.withAlphaComponent(0.05)
    }

    static func font(size: CGFloat, bold: Bool, italic: Bool, mono: Bool) -> NSFont {
        var f: NSFont = mono ? .monospacedSystemFont(ofSize: size, weight: bold ? .semibold : .regular) : .systemFont(ofSize: size, weight: bold ? .semibold : .regular)
        if italic {
            let d = f.fontDescriptor.withSymbolicTraits(f.fontDescriptor.symbolicTraits.union(.italic))
            f = NSFont(descriptor: d, size: size) ?? f
        }
        return f
    }

    // MARK: - the builder

    private struct Builder {
        let style: Style
        let fileDir: String
        var out = NSMutableAttributedString()
        var images: [String] = []
        /// Identity of the innermost block of the previous run.
        var lastBlock: Int? = nil
        var lastRow: Int? = nil
        var lastListItem: Int? = nil

        init(style: Style, fileDir: String) {
            self.style = style
            self.fileDir = fileDir
        }

        mutating func add(text raw: String, run: AttributedString.Runs.Run) {
            let comps = run.presentationIntent?.components ?? []
            let inner = comps.first
            var text = raw
            let inline = run.inlinePresentationIntent ?? []

            // Block boundaries.
            var para = NSMutableParagraphStyle()
            var blockFont = MarkdownRenderer.font(size: style.baseSize, bold: false, italic: false, mono: false)
            var color = NSColor.labelColor
            var background: NSColor? = nil
            var prefix = ""
            var isCode = false
            var isTableCell = false
            var tableHeader = false
            var depth: CGFloat = 0

            for c in comps.reversed() { // outermost first
                switch c.kind {
                case .header(let level):
                    let factor: CGFloat = [1.5, 1.3, 1.15, 1.0, 1.0, 1.0][max(0, min(5, level - 1))]
                    blockFont = MarkdownRenderer.font(size: style.baseSize * factor, bold: true, italic: false, mono: false)
                    para.paragraphSpacingBefore = style.baseSize * 0.8
                    para.paragraphSpacing = style.baseSize * 0.3
                case .paragraph:
                    para.paragraphSpacing = style.baseSize * 0.6
                case .codeBlock:
                    isCode = true
                    blockFont = MarkdownRenderer.font(size: style.monoSize, bold: false, italic: false, mono: true)
                    background = MarkdownRenderer.codeBlockBackground
                    para.paragraphSpacing = style.baseSize * 0.6
                    para.lineBreakMode = .byClipping
                case .blockQuote:
                    depth += 1
                    color = .secondaryLabelColor
                case .orderedList, .unorderedList:
                    depth += 1
                case .listItem(let ordinal):
                    if case .orderedList? = parentKind(of: c, in: comps) {
                        prefix = "\(ordinal). "
                    } else {
                        prefix = "•  "
                    }
                case .thematicBreak:
                    text = String(repeating: "─", count: 40)
                    color = .separatorColor
                case .table:
                    isTableCell = true
                    blockFont = MarkdownRenderer.font(size: style.monoSize, bold: false, italic: false, mono: true)
                    para.lineBreakMode = .byClipping
                case .tableHeaderRow:
                    tableHeader = true
                case .tableRow, .tableCell:
                    break
                @unknown default:
                    break
                }
            }
            para.headIndent = depth * 18
            para.firstLineHeadIndent = depth * 18
            para.lineHeightMultiple = style.lineHeightMultiple
            if isCode {
                para.headIndent += 8
                para.firstLineHeadIndent += 8
                para.tailIndent = -8
            }
            if inline.contains(.blockHTML) {
                para = NSMutableParagraphStyle()
                para.paragraphSpacing = style.baseSize * 0.6
                para.lineHeightMultiple = style.lineHeightMultiple
            }

            // Separator from the previous block.
            let blockID = inner?.identity
            let rowID = comps.first { if case .tableRow = $0.kind { return true }; if case .tableHeaderRow = $0.kind { return true }; return false }?.identity
            let itemID = comps.first { if case .listItem = $0.kind { return true }; return false }?.identity
            if out.length > 0 {
                if isTableCell, rowID == lastRow {
                    out.append(NSAttributedString(string: "  │  ", attributes: [.font: blockFont, .foregroundColor: NSColor.separatorColor, .paragraphStyle: para]))
                } else if blockID != lastBlock || inline.contains(.blockHTML) {
                    out.append(NSAttributedString(string: "\n", attributes: [.font: blockFont, .paragraphStyle: para]))
                }
            }
            let newBlock = blockID != lastBlock
            lastBlock = blockID
            lastRow = rowID

            // A list item's marker goes before its first paragraph only.
            if newBlock, itemID != nil, itemID != lastListItem {
                var marker = prefix
                if text.hasPrefix("[ ] ") { marker += "☐ "; text.removeFirst(4) }
                else if text.hasPrefix("[x] ") || text.hasPrefix("[X] ") { marker += "☑ "; text.removeFirst(4) }
                out.append(NSAttributedString(string: marker, attributes: [.font: blockFont, .foregroundColor: color, .paragraphStyle: para]))
            }
            lastListItem = itemID

            if isCode, text.hasSuffix("\n") { text.removeLast() }

            // Inline attributes.
            var attrs: [NSAttributedString.Key: Any] = [.paragraphStyle: para, .foregroundColor: color]
            var size = blockFont.pointSize
            var bold = blockFont.fontDescriptor.symbolicTraits.contains(.bold) || tableHeader
            var italic = false
            var mono = isCode || isTableCell
            if inline.contains(.emphasized) { italic = true }
            if inline.contains(.stronglyEmphasized) { bold = true }
            if inline.contains(.code) {
                mono = true
                size = style.monoSize
                attrs[.backgroundColor] = MarkdownRenderer.codeBackground
            }
            if inline.contains(.strikethrough) { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if inline.contains(.softBreak) { text = " " }
            if inline.contains(.lineBreak) { text = "\n" }
            if let bg = background { attrs[.backgroundColor] = bg }
            attrs[.font] = MarkdownRenderer.font(size: size, bold: bold, italic: italic, mono: mono)

            if let link = run.link {
                attrs[.link] = link.relativeString.isEmpty ? link.absoluteString : link.relativeString
                attrs[.cursor] = NSCursor.pointingHand
            }
            if let img = run.imageURL {
                let target = img.relativeString.isEmpty ? img.absoluteString : img.relativeString
                // An image without alt text comes through as U+FFFC.
                let altText = text.replacingOccurrences(of: "\u{FFFC}", with: "")
                let alt = altText.isEmpty ? FilesPaths.base(target) : altText
                if let local = FilesPaths.resolveRelative(baseDir: fileDir, href: FilesPaths.percentDecode(target)) {
                    attrs[.webmuxImagePath] = local
                    images.append(local)
                    text = alt
                } else {
                    // Remote images are not fetched (deviation 29): the alt text.
                    text = alt
                    attrs[.font] = MarkdownRenderer.font(size: size, bold: bold, italic: true, mono: mono)
                    attrs[.foregroundColor] = NSColor.secondaryLabelColor
                }
            }
            out.append(NSAttributedString(string: text, attributes: attrs))
        }

        private func parentKind(of c: PresentationIntent.IntentType, in comps: [PresentationIntent.IntentType]) -> PresentationIntent.Kind? {
            guard let i = comps.firstIndex(where: { $0.identity == c.identity }), i + 1 < comps.count else { return nil }
            return comps[i + 1].kind
        }

        func finish() -> MarkdownRendering {
            MarkdownRendering(attributed: out, localImagePaths: images)
        }
    }
}
