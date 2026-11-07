import XCTest
import WebmuxHost
@testable import WebmuxFiles

final class ZipTreeTests: XCTestCase {
    /// ZipEntry has only its Decodable init: build one from the host's JSON shape.
    private func e(_ name: String, _ size: Double = 0, dir: Bool = false) -> ZipEntry {
        let obj: [String: Any] = ["name": name, "size": size, "dir": dir]
        let data = try! JSONSerialization.data(withJSONObject: obj)
        return try! JSONDecoder().decode(ZipEntry.self, from: data)
    }

    func testTreeConnectorsFoldersFirstImpliedFoldersSizes() {
        let rows = ZipTree.rows([
            e("README.md", 10), e("src/", dir: true), e("src/b.zig", 2), e("src/A.zig", 1),
            e("docs/img/x.png", 3), e("z.txt", 4), e("src/sub/", dir: true),
        ])
        let text = rows.map { "\($0.prefix)\($0.name)|\(Int($0.size))" }.joined(separator: "\n")
        XCTAssertEqual(text, """
        ├── docs/|0
        │   └── img/|0
        │       └── x.png|3
        ├── src/|0
        │   ├── sub/|0
        │   ├── A.zig|1
        │   └── b.zig|2
        ├── README.md|10
        └── z.txt|4
        """)
    }

    func testMemberWithChildrenIsAFolderAndEmptyArchive() {
        let rows = ZipTree.rows([e("a", 5), e("a/b", 1)])
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows[0].dir)
        XCTAssertEqual(rows[0].name, "a/")
        XCTAssertEqual(rows[1].prefix, "    └── ")
        XCTAssertEqual(ZipTree.rows([]), [])
    }

    func testOutlineTree() {
        let root = ZipTree.build([e("b/x", 1), e("a", 2), e("B/y", 3)])
        XCTAssertEqual(root.children.map(\.name), ["b", "B", "a"]) // folders first, case-insensitive (stable)
        XCTAssertTrue(root.children[0].isDir)
        XCTAssertFalse(root.children[2].isDir)
        XCTAssertEqual(root.children[2].size, 2)
    }

    func testDecodesHostShape() throws {
        let json = "{\"size\":22,\"mtime\":1.7e12,\"kind\":\"zip\",\"entries\":[{\"name\":\"a/\",\"size\":0,\"dir\":true},{\"name\":\"a/b.txt\",\"size\":7,\"dir\":false}],\"count\":2}"
        let p = try JSONDecoder().decode(FilePreview.self, from: Data(json.utf8))
        XCTAssertEqual(p.kind, .zip)
        let rows = ZipTree.rows(p.entries ?? [])
        XCTAssertEqual(rows.map(\.name), ["a/", "b.txt"])
        XCTAssertEqual(rows[1].size, 7)
    }
}
