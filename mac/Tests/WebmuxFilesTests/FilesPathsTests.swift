import XCTest
@testable import WebmuxFiles

final class FilesPathsTests: XCTestCase {
    func testJoinParentBase() {
        XCTAssertEqual(FilesPaths.join("/", "etc"), "/etc")
        XCTAssertEqual(FilesPaths.join("/home/u", "x y"), "/home/u/x y")
        XCTAssertEqual(FilesPaths.parent("/"), "/")
        XCTAssertEqual(FilesPaths.parent("/etc"), "/")
        XCTAssertEqual(FilesPaths.parent("/home/u"), "/home")
        XCTAssertEqual(FilesPaths.base("/"), "/")
        XCTAssertEqual(FilesPaths.base("/home/u"), "u")
        XCTAssertEqual(FilesPaths.base("plain"), "plain")
    }

    func testChain() {
        XCTAssertEqual(FilesPaths.chain("/a/b"), ["/", "/a", "/a/b"])
        XCTAssertEqual(FilesPaths.chain("/"), ["/"])
        XCTAssertEqual(FilesPaths.chain("/a//b/"), ["/", "/a", "/a/b"])
    }

    func testIsMarkdownName() {
        XCTAssertTrue(FilesPaths.isMarkdownName("README.md"))
        XCTAssertTrue(FilesPaths.isMarkdownName("x.MarkDown"))
        XCTAssertTrue(FilesPaths.isMarkdownName("a.mkd"))
        XCTAssertTrue(FilesPaths.isMarkdownName("a.mdown"))
        XCTAssertFalse(FilesPaths.isMarkdownName("md"))
        XCTAssertFalse(FilesPaths.isMarkdownName("a.mdx"))
    }

    func testTilde() {
        XCTAssertEqual(FilesPaths.tilde(home: "/home/u", "/home/u"), "~")
        XCTAssertEqual(FilesPaths.tilde(home: "/home/u", "/home/u/src/x"), "~/src/x")
        XCTAssertEqual(FilesPaths.tilde(home: "/home/u", "/home/user"), "/home/user")
        XCTAssertEqual(FilesPaths.tilde(home: "/home/u", "/etc"), "/etc")
        XCTAssertEqual(FilesPaths.tilde(home: nil, "/home/u"), "/home/u")
        XCTAssertEqual(FilesPaths.tilde(home: "/", "/x"), "/x")
    }

    func testFitPathDocumentedSequence() {
        let measure: (String) -> CGFloat = { CGFloat($0.count) } // '…' is one unit
        let full = "~/src/webmux/electron/ui/app.js"
        let expect: [(CGFloat, String)] = [
            (100, full), (31, full),
            (30, "~/…/webmux/electron/ui/app.js"),
            (22, "~/…/electron/ui/app.js"),
            (21, "~/…/ui/app.js"),
            (12, "~/…/app.js"),
            (9, "…/app.js"),
            (7, "app.js"),
            (2, "app.js"),
        ]
        for (w, s) in expect {
            XCTAssertEqual(FilesPaths.fitPath(full, maxWidth: w, measure: measure), s, "width \(w)")
        }
        XCTAssertEqual(FilesPaths.fitPath("/", maxWidth: 0, measure: measure), "/")
        XCTAssertEqual(FilesPaths.fitPath("/usr/share/doc/x", maxWidth: 13, measure: measure), "/…/doc/x")
    }

    func testFormatSize() {
        XCTAssertEqual(FilesPaths.formatSize(0), "0 B")
        XCTAssertEqual(FilesPaths.formatSize(1023), "1023 B")
        XCTAssertEqual(FilesPaths.formatSize(1024), "1.0 KB")
        XCTAssertEqual(FilesPaths.formatSize(1536), "1.5 KB")
        XCTAssertEqual(FilesPaths.formatSize(12 * 1024 * 1024), "12 MB")
        XCTAssertEqual(FilesPaths.formatSize(10 * 1024 - 1), "10.0 KB")
        XCTAssertEqual(FilesPaths.formatSize(2.25 * 1024), "2.3 KB")
        XCTAssertEqual(FilesPaths.formatSize(2048.0 * 1024 * 1024 * 1024 * 1024), "2048 TB")
        XCTAssertEqual(FilesPaths.formatSize(-5), "0 B")
    }

    func testResolveRelative() {
        let cases: [(String, String, String)] = [
            ("/home/u/docs", "img/a.png", "/home/u/docs/img/a.png"),
            ("/home/u/docs", "../b.md", "/home/u/b.md"),
            ("/home/u/docs", "./c", "/home/u/docs/c"),
            ("/home/u/docs", "/etc/x", "/etc/x"),
            ("/", "../../x", "/x"),
            ("/a", "..", "/"),
        ]
        for (base, href, want) in cases {
            XCTAssertEqual(FilesPaths.resolveRelative(baseDir: base, href: href), want, href)
        }
        XCTAssertNil(FilesPaths.resolveRelative(baseDir: "/", href: "https://x"))
        XCTAssertNil(FilesPaths.resolveRelative(baseDir: "/", href: "mailto:a@b"))
        XCTAssertTrue(FilesPaths.hasScheme("a+b.c-d:x"))
        XCTAssertFalse(FilesPaths.hasScheme("1http:x"))
        XCTAssertFalse(FilesPaths.hasScheme("dir/x:y"))
        XCTAssertFalse(FilesPaths.hasScheme(""))
    }

    func testPercentDecode() {
        XCTAssertEqual(FilesPaths.percentDecode("my%20file%2Emd%zz%4"), "my file.md%zz%4")
        XCTAssertEqual(FilesPaths.percentDecode("caf%C3%A9"), "café")
    }

    func testRenameStem() {
        func stem(_ s: String) -> String { String(s[FilesPaths.renameStem(s)]) }
        XCTAssertEqual(stem("report.pdf"), "report")
        XCTAssertEqual(stem("a.tar.gz"), "a.tar")
        XCTAssertEqual(stem(".bashrc"), ".bashrc")
        XCTAssertEqual(stem("Makefile"), "Makefile")
        XCTAssertEqual(stem("archive."), "archive")
    }

    func testFileExtension() {
        XCTAssertEqual(FilesPaths.fileExtension("a.PDF"), "pdf")
        XCTAssertEqual(FilesPaths.fileExtension(".bashrc"), "")
        XCTAssertEqual(FilesPaths.fileExtension("noext"), "")
    }
}
