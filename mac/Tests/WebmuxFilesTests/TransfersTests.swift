import XCTest
@testable import WebmuxFiles

final class TransfersTests: XCTestCase {
    private func tempDir() throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("wm-files-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    func testCollectFilesFoldersRecursivelyEmptyFoldersSkipped() throws {
        let d = try tempDir()
        defer { try? FileManager.default.removeItem(at: d) }
        let fm = FileManager.default
        try fm.createDirectory(at: d.appendingPathComponent("drop/sub/empty"), withIntermediateDirectories: true)
        try fm.createDirectory(at: d.appendingPathComponent("drop/sub/deep"), withIntermediateDirectories: true)
        try "bb".write(to: d.appendingPathComponent("drop/b.txt"), atomically: true, encoding: .utf8)
        try "ccc".write(to: d.appendingPathComponent("drop/sub/deep/c.bin"), atomically: true, encoding: .utf8)
        try "a".write(to: d.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "no".write(to: d.appendingPathComponent("drop/sub/unreadable.txt"), atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: d.appendingPathComponent("drop/sub/unreadable.txt").path)
        let files = LocalUploads.collect([d.appendingPathComponent("a.txt"), d.appendingPathComponent("drop"), d.appendingPathComponent("missing")])
        XCTAssertEqual(files.map(\.name), ["a.txt", "drop/b.txt", "drop/sub/deep/c.bin"])
        XCTAssertEqual(files.map(\.size), [1, 2, 3])
        XCTAssertTrue(files[2].url.path.hasSuffix("/drop/sub/deep/c.bin"))
    }

    func testSaveFileNeverTouchesExistingFiles() throws {
        let d = try tempDir()
        defer { try? FileManager.default.removeItem(at: d) }
        try "precious".write(to: d.appendingPathComponent("out.txt.part"), atomically: true, encoding: .utf8)
        try "old".write(to: d.appendingPathComponent("keep.txt"), atomically: true, encoding: .utf8)
        let dest = d.appendingPathComponent("out.txt")
        let tf = try SaveFile(destination: dest)
        XCTAssertTrue(tf.temporaryURL.lastPathComponent.hasPrefix(".out.txt."))
        XCTAssertTrue(tf.temporaryURL.lastPathComponent.hasSuffix(".webmux-part"))
        try "new data".write(to: tf.temporaryURL, atomically: false, encoding: .utf8)
        try tf.commit()
        XCTAssertEqual(try String(contentsOf: dest, encoding: .utf8), "new data")
        XCTAssertEqual(try String(contentsOf: d.appendingPathComponent("out.txt.part"), encoding: .utf8), "precious")

        let tf2 = try SaveFile(destination: d.appendingPathComponent("keep.txt"))
        try "partial".write(to: tf2.temporaryURL, atomically: false, encoding: .utf8)
        tf2.discard()
        XCTAssertEqual(try String(contentsOf: d.appendingPathComponent("keep.txt"), encoding: .utf8), "old")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: d.path).count, 3)
    }

    func testSaveFileLongNamesAndReasons() throws {
        let d = try tempDir()
        defer { try? FileManager.default.removeItem(at: d) }
        let name = String(repeating: "é", count: 125) // 250 bytes
        let tf = try SaveFile(destination: d.appendingPathComponent(name))
        let tmpName = tf.temporaryURL.lastPathComponent
        XCTAssertLessThanOrEqual(tmpName.utf8.count, 255)
        try "x".write(to: tf.temporaryURL, atomically: false, encoding: .utf8)
        try tf.commit()
        XCTAssertEqual(try String(contentsOf: d.appendingPathComponent(name), encoding: .utf8), "x")
        XCTAssertEqual(SaveFile.reason(errno: ENAMETOOLONG), "name too long for the target folder")
        XCTAssertEqual(SaveFile.shorten("ééé", max: 3), "é")
        XCTAssertThrowsError(try SaveFile(destination: d.appendingPathComponent("nodir/x")))
    }

    func testFreeName() throws {
        let d = try tempDir()
        defer { try? FileManager.default.removeItem(at: d) }
        XCTAssertEqual(SaveFile.freeName(in: d, "a.txt").lastPathComponent, "a.txt")
        try "x".write(to: d.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        XCTAssertEqual(SaveFile.freeName(in: d, "a.txt").lastPathComponent, "a (1).txt")
        try "x".write(to: d.appendingPathComponent("a (1).txt"), atomically: true, encoding: .utf8)
        XCTAssertEqual(SaveFile.freeName(in: d, "a.txt").lastPathComponent, "a (2).txt")
        XCTAssertEqual(SaveFile.freeName(in: d, "noext").lastPathComponent, "noext")
    }
}
