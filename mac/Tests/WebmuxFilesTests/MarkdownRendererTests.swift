import AppKit
import XCTest
@testable import WebmuxFiles

final class MarkdownRendererTests: XCTestCase {
    private func render(_ md: String) -> NSAttributedString {
        MarkdownRenderer.render(md, fileDir: "/home/u/docs").attributed
    }

    private func font(_ s: NSAttributedString, at text: String) -> NSFont? {
        let r = (s.string as NSString).range(of: text)
        guard r.location != NSNotFound else { return nil }
        return s.attribute(.font, at: r.location, effectiveRange: nil) as? NSFont
    }

    func testHeadingsAndParagraphs() {
        let s = render("# Title\n\nBody text here.\n\n## Second")
        XCTAssertEqual(s.string, "Title\nBody text here.\nSecond")
        let h1 = font(s, at: "Title")
        let body = font(s, at: "Body")
        let h2 = font(s, at: "Second")
        XCTAssertEqual(h1?.pointSize, 13 * 1.5)
        XCTAssertEqual(body?.pointSize, 13)
        XCTAssertEqual(h2?.pointSize, 13 * 1.3)
        XCTAssertTrue(h1?.fontDescriptor.symbolicTraits.contains(.bold) ?? false)
    }

    func testInlineStyles() {
        let s = render("a *em* **strong** `code` ~~gone~~")
        XCTAssertTrue(font(s, at: "em")?.fontDescriptor.symbolicTraits.contains(.italic) ?? false)
        XCTAssertTrue(font(s, at: "strong")?.fontDescriptor.symbolicTraits.contains(.bold) ?? false)
        XCTAssertTrue(font(s, at: "code")?.fontDescriptor.symbolicTraits.contains(.monoSpace) ?? false)
        let r = (s.string as NSString).range(of: "gone")
        XCTAssertNotNil(s.attribute(.strikethroughStyle, at: r.location, effectiveRange: nil))
    }

    func testRawHTMLIsLiteralText() {
        let s = render("x <b>bold</b> y\n\n<div onclick=\"evil()\">block</div>\n\n<script>alert(1)</script>")
        XCTAssertTrue(s.string.contains("<b>bold</b>"))
        XCTAssertTrue(s.string.contains("<div onclick=\"evil()\">block</div>"))
        XCTAssertTrue(s.string.contains("<script>alert(1)</script>"))
    }

    func testListsAndTasks() {
        let s = render("- [ ] open\n- [x] done\n- plain\n\n1. one\n2. two")
        XCTAssertEqual(s.string, "•  ☐ open\n•  ☑ done\n•  plain\n1. one\n2. two")
    }

    func testCodeBlockAndQuote() {
        let s = render("```swift\nlet x = 1\n```\n\n> quoted")
        XCTAssertEqual(s.string, "let x = 1\nquoted")
        XCTAssertTrue(font(s, at: "let x")?.fontDescriptor.symbolicTraits.contains(.monoSpace) ?? false)
        let r = (s.string as NSString).range(of: "let x")
        XCTAssertNotNil(s.attribute(.backgroundColor, at: r.location, effectiveRange: nil))
        let q = (s.string as NSString).range(of: "quoted")
        let para = s.attribute(.paragraphStyle, at: q.location, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(para?.headIndent, 18)
    }

    func testTable() {
        let s = render("| a | b |\n|---|---|\n| 1 | 2 |")
        XCTAssertEqual(s.string, "a  │  b\n1  │  2")
        XCTAssertTrue(font(s, at: "a")?.fontDescriptor.symbolicTraits.contains(.bold) ?? false)
    }

    func testLinksKeepRawTargets() {
        let s = render("[rel](docs/x.md) [abs](https://example.com) [mail](mailto:a@b.c) [anchor](#top)")
        func link(_ t: String) -> String? {
            let r = (s.string as NSString).range(of: t)
            return s.attribute(.link, at: r.location, effectiveRange: nil) as? String
        }
        XCTAssertEqual(link("rel"), "docs/x.md")
        XCTAssertEqual(link("abs"), "https://example.com")
        XCTAssertEqual(link("mail"), "mailto:a@b.c")
        XCTAssertEqual(link("anchor"), "#top")
    }

    func testImages() {
        let r = MarkdownRenderer.render("![remote](https://example.com/x.png) ![local](img/a%20b.png) ![](../c.png)", fileDir: "/home/u/docs")
        XCTAssertEqual(r.localImagePaths, ["/home/u/docs/img/a b.png", "/home/u/c.png"])
        XCTAssertEqual(r.attributed.string, "remote local c.png")
        let s = r.attributed
        let remote = (s.string as NSString).range(of: "remote")
        XCTAssertNil(s.attribute(.webmuxImagePath, at: remote.location, effectiveRange: nil))
        let local = (s.string as NSString).range(of: "local")
        XCTAssertEqual(s.attribute(.webmuxImagePath, at: local.location, effectiveRange: nil) as? String, "/home/u/docs/img/a b.png")
    }

    func testEmptyAndPlain() {
        XCTAssertEqual(render("").string, "")
        XCTAssertEqual(render("just text").string, "just text")
        XCTAssertEqual(render("line one\nline two").string, "line one line two") // soft break
        XCTAssertEqual(render("hard  \nbreak").string, "hard\nbreak")
    }
}
