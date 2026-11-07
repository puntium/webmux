// The pure parts of the panels area: status mapping, the profile form, the
// log filter, the menu table against PARITY, the HUD timer, URL kinds.
import AppKit
import XCTest
@testable import WebmuxConnection
@testable import WebmuxPanels

final class HostStatusTests: XCTestCase {
    private func status(_ state: ConnectionState, step: ConnectionStep = .idle, msg: String = "", hadConnection: Bool = false) -> ConnectionStatus {
        ConnectionStatus(name: "box", state: state, msg: msg, stderr: "", step: step,
                         host: "box.example", instance: "", sshPort: 0, hadConnection: hadConnection)
    }

    func testKindMapping() {
        XCTAssertEqual(HostStatusKind(status: nil), .none)
        XCTAssertEqual(HostStatusKind(status: status(.connecting)), .connecting)
        XCTAssertEqual(HostStatusKind(status: status(.connected)), .connected)
        XCTAssertEqual(HostStatusKind(status: status(.connected), offline: true), .degraded)
        XCTAssertEqual(HostStatusKind(status: status(.retry)), .retry)
        XCTAssertEqual(HostStatusKind(status: status(.failed)), .failed)
        // offline matters only while connected
        XCTAssertEqual(HostStatusKind(status: status(.retry), offline: true), .retry)
    }

    func testLabelsAndTexts() {
        // W-21 card labels
        XCTAssertEqual(HostStatusKind.connecting.cardLabel, "connecting…")
        XCTAssertEqual(HostStatusKind.degraded.cardLabel, "degraded")
        XCTAssertEqual(HostStatusKind.retry.cardLabel, "retrying…")
        XCTAssertEqual(HostStatusKind.failed.cardLabel, "failed")
        // W-14 state texts
        XCTAssertEqual(HostStatusKind.degraded.stateText(), "server unreachable — page retrying")
        XCTAssertEqual(HostStatusKind.retry.stateText(retrySeconds: 4), "interrupted — retrying in 4s")
        XCTAssertEqual(HostStatusKind.retry.stateText(), "interrupted — retrying")
        XCTAssertEqual(HostStatusKind.failed.stateText(), "connection failed")
        XCTAssertEqual(HostStatusKind.none.stateText(), "")
    }

    func testDotColours() {
        // W-12 semantics: yellow for connecting/degraded, green connected, red retry/failed
        XCTAssertEqual(HostStatusKind.connecting.color, HostStatusKind.degraded.color)
        XCTAssertEqual(HostStatusKind.retry.color, HostStatusKind.failed.color)
        XCTAssertNotEqual(HostStatusKind.connected.color, HostStatusKind.failed.color)
        XCTAssertTrue(HostStatusKind.connected.isUp)
        XCTAssertTrue(HostStatusKind.degraded.isUp)
        XCTAssertFalse(HostStatusKind.retry.isUp)
        let img = HostStatusKind.connected.dotImage(diameter: 8)
        XCTAssertEqual(img.size, NSSize(width: 8, height: 8))
    }

    func testStatusDetail() {
        XCTAssertNil(StatusDetail(status: status(.connected), offline: false, retrySeconds: nil))
        let retry = StatusDetail(status: status(.retry, msg: "ssh exited (255)"), offline: false, retrySeconds: 3)
        XCTAssertEqual(retry?.explanation, "Connection interrupted — retrying in 3s… (sessions keep running on the server)")
        XCTAssertEqual(retry?.message, "ssh exited (255)")
        let failed = StatusDetail(status: status(.failed, msg: "connection failed"), offline: false, retrySeconds: nil)
        XCTAssertEqual(failed?.explanation?.hasPrefix("Not retrying automatically"), true)
        let degraded = StatusDetail(status: status(.connected), offline: true, retrySeconds: nil)
        XCTAssertEqual(degraded?.kind, .degraded)
        XCTAssertEqual(degraded?.explanation?.contains("workspace's session sockets"), true)
        var pushing = status(.connecting, step: .pushing, msg: "pushing webmux… 40% of 3.2 MB")
        pushing.pushSent = 40
        pushing.pushTotal = 100
        let d = StatusDetail(status: pushing, offline: false, retrySeconds: nil)
        XCTAssertEqual(d?.pushFraction, 0.4)
        XCTAssertNil(d?.explanation)
        let lan = StatusDetail(status: status(.failed, msg: LocalNetwork.hint), offline: false, retrySeconds: nil)
        XCTAssertEqual(lan?.isLocalNetworkHint, true)
        XCTAssertEqual(failed?.isLocalNetworkHint, false)
    }

    func testRetryCountdownRoundsUp() {
        XCTAssertEqual(retryCountdownSeconds(remainingMs: 0), 0)
        XCTAssertEqual(retryCountdownSeconds(remainingMs: 1), 1)
        XCTAssertEqual(retryCountdownSeconds(remainingMs: 1000), 1)
        XCTAssertEqual(retryCountdownSeconds(remainingMs: 1001), 2)
        XCTAssertEqual(retryCountdownSeconds(remainingMs: 14999), 15)
    }
}

final class ProfileFormTests: XCTestCase {
    func testTrimAndRequired() {
        var v = ProfileFormValues()
        XCTAssertEqual(v.input().failureDescription, "name and host are required")
        v.name = "  box "
        XCTAssertEqual(v.input().failureDescription, "name and host are required")
        v.host = " me@box "
        v.identityFile = " ~/.ssh/id "
        v.extraOptions = " -o ProxyJump=b "
        v.instance = " dev "
        let input = try? v.input().get()
        XCTAssertEqual(input?.name, "box")
        XCTAssertEqual(input?.host, "me@box")
        XCTAssertEqual(input?.identityFile, "~/.ssh/id")
        XCTAssertEqual(input?.extraOptions, "-o ProxyJump=b")
        XCTAssertEqual(input?.instance, "dev")
        XCTAssertEqual(input?.sshPort, 0)
    }

    func testPortRule() {
        var v = ProfileFormValues()
        v.name = "a"
        v.host = "b"
        v.sshPort = "2222"
        XCTAssertEqual((try? v.input().get())?.sshPort, 2222)
        v.sshPort = ""
        XCTAssertEqual((try? v.input().get())?.sshPort, 0)
        for bad in ["0", "65536", "22a", "-1", "1e3"] {
            v.sshPort = bad
            XCTAssertEqual(v.input().failureDescription, Profile.portError, bad)
        }
    }

    func testInstanceRule() {
        var v = ProfileFormValues()
        v.name = "a"
        v.host = "b"
        v.instance = "bad name"
        XCTAssertEqual(v.input().failureDescription, Profile.instanceError)
        v.instance = "ok.name_1-x"
        XCTAssertNotNil(try? v.input().get())
    }

    func testPasswordRules() {
        var v = ProfileFormValues()
        XCTAssertEqual(v.passwordAction, .keep)
        v.password = "s3cret"
        XCTAssertEqual(v.passwordAction, .set("s3cret"))
        v.clearPassword = true
        XCTAssertEqual(v.passwordAction, .clear)
        XCTAssertEqual(ProfileFormValues.passwordPlaceholder(hasStored: true), "saved — leave blank to keep")
        XCTAssertEqual(ProfileFormValues.passwordPlaceholder(hasStored: false), "blank = key auth (recommended)")
    }

    func testFromProfileAndDetailLine() {
        let p = Profile(id: "ab", name: "box", host: "me@box", sshPort: 2222, identityFile: "~/.ssh/k", instance: "dev", extraOptions: "-v", downloadDir: "/tmp")
        let v = ProfileFormValues(profile: p)
        XCTAssertEqual(v.sshPort, "2222")
        XCTAssertEqual(v.password, "")
        XCTAssertEqual(profileDetailLine(p), "me@box -p 2222 → dev")
        XCTAssertEqual(profileDetailLine(Profile(name: "x", host: "h")), "h")
    }
}

final class LogFilterTests: XCTestCase {
    private let log = ConnectionLog()

    private func entry(_ seq: UInt64, _ level: LogLevel, conn: String?, msg: String, src: LogSource = .main) -> LogEntry {
        let n = log.push(level: level, src: src, conn: conn, msg: msg)
        return log.since(n - 1).first!
    }

    func testLevelAndHost() {
        var f = LogFilter()
        XCTAssertFalse(f.passes(entry(1, .debug, conn: nil, msg: "x")))
        XCTAssertTrue(f.passes(entry(2, .info, conn: nil, msg: "x")))
        f.level = .warn
        XCTAssertFalse(f.passes(entry(3, .info, conn: "a", msg: "x")))
        XCTAssertTrue(f.passes(entry(4, .error, conn: "a", msg: "x")))
        f.level = .debug
        f.host = "a"
        XCTAssertTrue(f.passes(entry(5, .debug, conn: "a", msg: "x")))
        XCTAssertFalse(f.passes(entry(6, .debug, conn: "b", msg: "x")))
        XCTAssertFalse(f.passes(entry(7, .debug, conn: nil, msg: "x")))
        f.host = LogFilter.clientKey
        XCTAssertTrue(f.passes(entry(8, .debug, conn: nil, msg: "x")))
        XCTAssertFalse(f.passes(entry(9, .debug, conn: "a", msg: "x")))
    }

    func testTextIsCaseInsensitiveOverTheFileLine() {
        var f = LogFilter(level: .debug, text: "TUNNEL")
        XCTAssertTrue(f.passes(entry(1, .info, conn: "a", msg: "tunnel spawned")))
        XCTAssertFalse(f.passes(entry(2, .info, conn: "a", msg: "probe")))
        f.text = "[a]"
        XCTAssertTrue(f.passes(entry(3, .info, conn: "a", msg: "probe")))
        f.text = "page:"
        XCTAssertTrue(f.passes(entry(4, .info, conn: "a", msg: "probe", src: .page)))
        XCTAssertFalse(f.passes(entry(5, .info, conn: "a", msg: "probe")))
    }

    func testTexts() {
        XCTAssertEqual(LogFilter.countText(shown: 3, total: 3), "3 entries")
        XCTAssertEqual(LogFilter.countText(shown: 1, total: 3), "1 of 3 entries")
        XCTAssertEqual(LogFilter.copiedText(1, visible: true), "copied 1 visible line")
        XCTAssertEqual(LogFilter.copiedText(2, visible: false), "copied 2 lines")
        XCTAssertEqual(LogFilter.emptyText(total: 0), "No log entries yet.")
        XCTAssertEqual(LogFilter.emptyText(total: 5), "Nothing matches the current filters.")
        XCTAssertEqual(LogFilter.copyText(["a", "b"]), "a\nb\n")
        XCTAssertEqual(LogFilter.copyText([]), "")
        XCTAssertEqual(LogFilter.localTime("not a date"), "not a date")
        XCTAssertEqual(LogFilter.localTime("2026-11-07T10:11:12.345Z").count, 12)
    }

    func testHostListOrder() {
        var hosts = LogHostList()
        XCTAssertTrue(hosts.note(entry(1, .info, conn: "b", msg: "")))
        XCTAssertFalse(hosts.note(entry(2, .info, conn: "b", msg: "")))
        XCTAssertTrue(hosts.note(entry(3, .info, conn: nil, msg: "")))
        XCTAssertTrue(hosts.note(entry(4, .info, conn: "a", msg: "")))
        XCTAssertEqual(hosts.hosts, ["b", "a"])
        XCTAssertTrue(hosts.hasClient)
    }
}

final class MenuSpecTests: XCTestCase {
    /// PARITY § 5 (macOS column) and W-41, W-45: command → shortcut.
    func testShortcutsMatchParity() {
        let expected: [MenuCommand: String] = [
            .connections: "⇧⌘O", .reconnect: "⇧⌘R", .connectionLog: "⌃⌘L", .settings: "⌘,", .quit: "⌘Q",
            .newTerminal: "⌘↩", .newTerminalBelow: "⌥⌘↩", .newFileBrowser: "⇧⌘↩", .closePane: "⌘W", .toggleFullWindow: "⌘F",
            .focusLeft: "⌘←", .focusRight: "⌘→", .focusUp: "⌘↑", .focusDown: "⌘↓",
            .consumeExpelLeft: "⌘[", .consumeExpelRight: "⌘]",
            .moveColumnLeft: "⌥⌘←", .moveColumnRight: "⌥⌘→", .movePaneUp: "⌥⌘↑", .movePaneDown: "⌥⌘↓",
            .previousHost: "⇧⌘[", .nextHost: "⇧⌘]", .host1: "⌘1", .host9: "⌘9",
            .actualSize: "⌘0", .zoomIn: "⌘=", .zoomOut: "⌘-", .toggleFullScreen: "⌃⌘F", .minimize: "⌘M",
            .pasteAndMatchStyle: "⌥⇧⌘V",
        ]
        for (cmd, shortcut) in expected {
            XCTAssertEqual(MenuSpec.item(for: cmd)?.shortcutText, shortcut, cmd.rawValue)
        }
    }

    /// W-41: Hide / Hide Others / Show All carry no accelerator (⌘H, ⌥⌘H are chords);
    /// About and Open Config File have none either; no window-close item.
    func testNoAcceleratorsWhereParityForbids() {
        for cmd in [MenuCommand.hide, .hideOthers, .showAll, .about, .openConfigFile, .zoom, .bringAllToFront, .help] {
            XCTAssertEqual(MenuSpec.item(for: cmd)?.key, "", cmd.rawValue)
        }
        XCTAssertFalse(MenuSpec.allItems.contains { $0.title.hasPrefix("Close Window") })
    }

    /// K-27: no app shortcut collides with a pane chord; every shortcut is unique.
    func testShortcutsAreUnique() {
        var seen: [String: MenuCommand] = [:]
        for item in MenuSpec.allItems where !item.key.isEmpty {
            let s = item.shortcutText
            XCTAssertNil(seen[s], "\(item.command!.rawValue) and \(seen[s]!.rawValue) share \(s)")
            seen[s] = item.command
        }
    }

    func testMenuTitlesAndOrder() {
        XCTAssertEqual(MenuSpec.menuBar.map { $0.title }, ["webmux", "Edit", "View", "Pane", "Window", "Help"])
        let app = MenuSpec.menuBar[0].items.compactMap { $0.command }
        XCTAssertEqual(app, [.about, .connections, .reconnect, .openConfigFile, .connectionLog, .settings, .hide, .hideOthers, .showAll, .quit])
        let edit = MenuSpec.menuBar[1].items.compactMap { $0.command }
        XCTAssertEqual(edit, [.undo, .redo, .cut, .copy, .paste, .pasteAndMatchStyle, .delete, .selectAll])
        let window = MenuSpec.menuBar[4].items.compactMap { $0.command }
        XCTAssertEqual(Array(window.prefix(4)), [.minimize, .zoom, .previousHost, .nextHost])
        XCTAssertEqual(window.compactMap { $0.hostIndex }, Array(1...9))
        // every command appears exactly once
        let all = MenuSpec.allItems.compactMap { $0.command }
        XCTAssertEqual(Set(all).count, all.count)
        XCTAssertEqual(Set(all), Set(MenuCommand.allCases))
    }

    func testPaneCommandsAreTheResponderChainOnes() {
        let pane = MenuSpec.menuBar[3].items.compactMap { $0.command }
        XCTAssertTrue(pane.allSatisfy { $0.isPaneCommand })
        XCTAssertEqual(pane.count, 15)
        XCTAssertFalse(MenuCommand.connections.isPaneCommand)
        XCTAssertTrue(MenuCommand.reload.isPaneCommand)
    }
}

final class StatusHUDModelTests: XCTestCase {
    func testTimerRestartsOnNewMessage() {
        var m = StatusHUDModel()
        XCTAssertTrue(m.show("a", now: 1000))
        XCTAssertEqual(m.remainingMs(now: 1000), 3000)
        XCTAssertEqual(m.remainingMs(now: 2500), 1500)
        XCTAssertTrue(m.show("b", now: 2500))
        XCTAssertEqual(m.text, "b")
        XCTAssertEqual(m.remainingMs(now: 2500), 3000)
        m.expire(now: 4000)
        XCTAssertTrue(m.isShowing)
        m.expire(now: 5500)
        XCTAssertFalse(m.isShowing)
        XCTAssertEqual(m.count, 2)
    }

    func testPerConnectionMessagesWaitForTheirHost() {
        var m = StatusHUDModel()
        m.setFront("a", now: 0)
        XCTAssertTrue(m.show("from a", from: "a", now: 0))
        XCTAssertFalse(m.show("from b", from: "b", now: 1000))
        XCTAssertEqual(m.text, "from a")
        // switching to b hides a's and shows what is left of b's 3 s
        let p = m.setFront("b", now: 2000)
        XCTAssertEqual(p?.text, "from b")
        XCTAssertEqual(m.remainingMs(now: 2000), 2000)
        // back to a: a's message has expired
        XCTAssertNil(m.setFront("a", now: 3500))
        XCTAssertFalse(m.isShowing)
        // app-wide messages always show
        XCTAssertTrue(m.show("global", now: 4000))
        // landing (nil front): host messages are kept, not shown
        m.setFront(nil, now: 4000)
        XCTAssertFalse(m.show("x", from: "a", now: 4000))
    }

    func testBeforeFrontIsKnownEverythingShows() {
        var m = StatusHUDModel()
        XCTAssertTrue(m.show("x", from: "a", now: 0))
    }
}

final class URLKindTests: XCTestCase {
    func testKinds() {
        XCTAssertEqual(URLKind(url: "https://example.com/x"), .web)
        XCTAssertEqual(URLKind(url: "HTTP://example.com"), .web)
        XCTAssertEqual(URLKind(url: "mailto:a@b.c"), .mailto)
        XCTAssertEqual(URLKind(url: "file:///etc/passwd"), .other)
        XCTAssertEqual(URLKind(url: "javascript:alert(1)"), .other)
        XCTAssertEqual(URLKind(url: "ssh://host"), .other)
    }

    func testChooserButtons() {
        XCTAssertEqual(URLKind.web.openLabel, "Open in Browser")
        XCTAssertEqual(URLKind.mailto.openLabel, "Open")
        XCTAssertNil(URLKind.other.openLabel)
        XCTAssertTrue(URLKind.web.isClickable)
        XCTAssertFalse(URLKind.mailto.isClickable)
    }
}

final class AppearanceTests: XCTestCase {
    func testThemeMapping() {
        XCTAssertEqual(Appearance(theme: "dark"), .dark)
        XCTAssertEqual(Appearance(theme: "light"), .light)
        XCTAssertEqual(Appearance(theme: "system"), .system)
        XCTAssertEqual(Appearance(theme: "solarized"), .dark) // unknown ids render as dark (E-01)
        XCTAssertEqual(Appearance.system.scheme(systemIsDark: true), "dark")
        XCTAssertEqual(Appearance.system.scheme(systemIsDark: false), "light")
        XCTAssertEqual(Appearance.light.scheme(systemIsDark: true), "light")
        XCTAssertNil(Appearance.system.nsAppearance)
        XCTAssertEqual(Appearance.dark.nsAppearance?.name, .darkAqua)
        XCTAssertEqual(Appearance.light.nsAppearance?.name, .aqua)
    }
}

private extension Result where Failure == FormError {
    var failureDescription: String? {
        if case .failure(let e) = self { return e.description }
        return nil
    }
}
