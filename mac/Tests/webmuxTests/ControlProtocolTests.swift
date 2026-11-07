import XCTest
@testable import webmux

/// The control socket's reply encoding and command table are plain data; the
/// socket itself is exercised by running the app (mac/README.md).
final class ControlProtocolTests: XCTestCase {
    func testHelpListsEveryCommand() {
        let names = ControlCommands.help.map { $0.split(separator: " ").first.map(String.init) ?? "" }
        for cmd in ["dump:", "menu", "setting", "window", "connections", "key", "text", "resize", "wait", "screenshot", "quit"] {
            XCTAssertTrue(names.contains(where: { $0.hasPrefix(cmd) }), cmd)
        }
    }
}
