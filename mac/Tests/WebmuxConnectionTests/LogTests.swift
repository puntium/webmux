import XCTest
@testable import WebmuxConnection

final class LogTests: XCTestCase {
    func testFileLineFormatMatchesLogJs() {
        let log = ConnectionLog()
        log.fixedTime = "2026-11-04T10:00:00.000Z"
        log.push(level: .info, conn: "box", msg: "tunnel spawned", data: [
            LogField("pid", 123),
            LogField("socket", "/Users/me/Library/Application Support/x/run/box-1.sock"),
            LogField("cmd", "ssh -N host"),
            LogField("empty", ""),
            LogField("code", .null),
            LogField("ok", .bool(true)),
            LogField("obj", .json("{\"a\":1}")),
            LogField("q", "say \"hi\"\n"),
            LogField("bad-key", 1),
        ])
        log.push(level: .warn, msg: "app-wide")
        log.push(level: .error, src: .page, conn: "box", msg: "socket dropped")
        log.push(level: .debug, conn: "b", msg: "d", data: [LogField("f", .double(1.5))])
        // expected lines produced by node with electron/log.js formatLine
        XCTAssertEqual(log.text(), """
        2026-11-04T10:00:00.000Z INFO  [box] tunnel spawned pid=123 socket="/Users/me/Library/Application Support/x/run/box-1.sock" cmd="ssh -N host" empty="" code=null ok=true obj="{\\"a\\":1}" q="say \\"hi\\"\\n"
        2026-11-04T10:00:00.000Z WARN  app-wide
        2026-11-04T10:00:00.000Z ERROR [box] page: socket dropped
        2026-11-04T10:00:00.000Z DEBUG [b] d f=1.5
        """)
    }

    func testSanitizingRingBoundSinceClearSubscribe() {
        let log = ConnectionLog()
        log.fixedTime = "2026-11-04T10:00:00.000Z"
        var fields = (0..<14).map { LogField("k\($0)", $0) }
        fields[0] = LogField("k0", String(repeating: "d", count: 400))
        log.push(conn: String(repeating: "n", count: 100), msg: String(repeating: "m", count: 700), data: fields)
        let e = log.since(0)[0]
        XCTAssertEqual(e.msg.count, 500)
        XCTAssertEqual(e.conn?.count, 80)
        XCTAssertEqual(e.data.count, 12) // first 12 considered
        if case .string(let s) = e.data[0].value { XCTAssertEqual(s.count, 301) } else { XCTFail() }

        // page-style JSON input: level whitelist, plain keys
        log.pushJSON(conn: "box", src: .page, JSONValue.parse("{\"level\":\"fatal\",\"msg\":\"hi\",\"data\":{\"ok\":1,\"bad key\":2,\"o\":{\"x\":[1]}}}")!)
        let s2 = log.since(e.seq)
        XCTAssertEqual(s2.count, 1)
        XCTAssertEqual(s2[0].line, "2026-11-04T10:00:00.000Z INFO  [box] page: hi o=\"{\\\"x\\\":[1]}\" ok=1")
        // whole-number floats of any size never crash (G-04)
        log.pushJSON(conn: "h", src: .page, ["level": "info", "msg": "x", "data": ["a": 1e20, "b": -9.3e18, "c": 1e300]] as [String: Any])
        XCTAssertTrue(log.text().contains("a=100000000000000000000"))

        // subscription
        final class Seen: @unchecked Sendable {
            let lock = NSLock()
            var seqs: [UInt64] = []
        }
        let seen = Seen()
        let id = log.subscribe { entry in seen.lock.withLock { seen.seqs.append(entry.seq) } }
        let seq = log.push(msg: "x")
        XCTAssertEqual(seen.lock.withLock { seen.seqs }, [seq])
        log.unsubscribe(id)
        log.push(msg: "y")
        XCTAssertEqual(seen.lock.withLock { seen.seqs.count }, 1)

        // ring bound
        for _ in 0..<(ConnectionLog.maxEntries + 10) { log.push(msg: "fill") }
        let s3 = log.since(0)
        XCTAssertEqual(s3.count, ConnectionLog.maxEntries)
        XCTAssertGreaterThan(s3[0].seq, 10)
        XCTAssertEqual(s3.last!.seq - s3[0].seq + 1, UInt64(ConnectionLog.maxEntries)) // oldest first, in order
        // clear leaves one line saying so
        log.clear()
        let s4 = log.since(0)
        XCTAssertEqual(s4.count, 1)
        XCTAssertEqual(s4[0].msg, "log cleared (file untouched)")
    }

    func testFileSinkAndRotation() throws {
        let dir = "/tmp/wm-lg-\(Util.randomHex(bytes: 4))/logs"
        defer { try? FileManager.default.removeItem(atPath: Util.dirname(dir)) }
        let log = ConnectionLog()
        log.fixedTime = "2026-11-04T10:00:00.000Z"
        log.openFile(inDirectory: dir)
        log.fileMax = 200
        let file = log.filePath!
        XCTAssertTrue(file.hasSuffix("/logs/webmux.log"))
        log.push(conn: "box", msg: "first")
        XCTAssertEqual(Util.readString(file), "2026-11-04T10:00:00.000Z INFO  [box] first\n")
        // grow past fileMax: the next push rolls webmux.log → webmux.log.1
        for _ in 0..<6 { log.push(msg: "padding padding padding padding") }
        let rolled = Util.readString(file + ".1")!
        XCTAssertTrue(rolled.hasPrefix("2026-11-04T10:00:00.000Z INFO  [box] first\n"))
        XCTAssertGreaterThan(rolled.utf8.count, 200)
        let cur = Util.readString(file)!
        XCTAssertLessThan(cur.count, rolled.count)
        XCTAssertTrue(cur.hasSuffix("padding padding padding padding\n"))
        // a reopened sink picks up the existing size
        let log2 = ConnectionLog()
        log2.openFile(inDirectory: dir)
        XCTAssertEqual(log2.currentFileSize, UInt64(cur.utf8.count))
    }
}
