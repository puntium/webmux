import XCTest
@testable import WebmuxConnection

final class ProfileTests: XCTestCase {
    func testValidationFollowsMainJsRules() {
        let store = ConfigStore(file: "/nonexistent/config.json")
        // instance check comes first, as in main.js
        XCTAssertEqual(store.save(ProfileInput(name: "", host: "", instance: "a b"), originalName: nil), Profile.instanceError)
        for bad in ["x;rm -rf ~", "$(id)", "a'b", "a\"b", "a/b", "ä"] {
            XCTAssertEqual(store.save(ProfileInput(name: "n", host: "h", instance: bad), originalName: nil), Profile.instanceError)
        }
        XCTAssertEqual(store.save(ProfileInput(name: "  ", host: "h"), originalName: nil), "name and host are required")
        XCTAssertEqual(store.save(ProfileInput(name: "n", host: ""), originalName: nil), "name and host are required")
        XCTAssertNil(store.save(ProfileInput(name: " box ", host: " me@box ", instance: " dev.1_x-y "), originalName: nil))
        let p = store.find("box")!
        XCTAssertEqual(p.host, "me@box")
        XCTAssertEqual(p.instance, "dev.1_x-y")
        XCTAssertEqual(p.id.count, 16)
        let id = p.id
        // duplicate name
        XCTAssertEqual(store.save(ProfileInput(name: "box", host: "x"), originalName: nil), "a profile named \"box\" already exists")
        // rename keeps id, downloadDir carries over, lastProfile follows
        XCTAssertTrue(store.setDownloadDir("box", "/dl"))
        store.setLastProfile("box")
        XCTAssertNil(store.save(ProfileInput(name: "box2", host: "me@box"), originalName: "box"))
        XCTAssertNil(store.find("box"))
        let r = store.find("box2")!
        XCTAssertEqual(r.id, id)
        XCTAssertEqual(r.downloadDir, "/dl")
        XCTAssertEqual(store.lastProfile, "box2")
        XCTAssertEqual(store.profiles.count, 1)
        // rename onto an existing name is refused
        XCTAssertNil(store.save(ProfileInput(name: "other", host: "o"), originalName: nil))
        XCTAssertEqual(store.save(ProfileInput(name: "other", host: "x"), originalName: "box2"), "a profile named \"other\" already exists")
        store.delete("box2")
        XCTAssertNil(store.lastProfile)
        XCTAssertTrue(Profile.validInstance(""))
    }

    func testJSONRoundTripAndSettingsSanitizing() throws {
        let store = ConfigStore(file: "/nonexistent/config.json")
        XCTAssertNil(store.save(ProfileInput(name: "a", host: "h1", sshPort: 2222, identityFile: "~/.ssh/k", instance: "i", extraOptions: "-o ProxyJump=b", downloadDir: "/tmp"), originalName: nil))
        XCTAssertNil(store.save(ProfileInput(name: "b \"q\"", host: "h2"), originalName: nil))
        store.setLastProfile("a")
        store.settings = store.settings.sanitized(with: Settings.Patch(theme: "light", unfocusedFade: 12.5, minCols: 100, maxCols: 80))
        XCTAssertEqual(store.settings.unfocusedFade, 13) // Math.round
        XCTAssertEqual(store.settings.maxCols, 100) // range stays a range
        let json = store.toJSON()
        XCTAssertTrue(json.hasPrefix("{\n  \"profiles\": [\n    {\n      \"name\": \"a\",\n      \"host\": \"h1\",\n      \"sshPort\": 2222,"), json)
        XCTAssertTrue(json.hasSuffix("}\n"))
        XCTAssertFalse(json.contains("passwordEnc"))
        XCTAssertFalse(json.contains("localPort"))

        let back = ConfigStore(file: "/nonexistent/config.json")
        try back.load(text: json)
        XCTAssertEqual(back.profiles.count, 2)
        let p = back.profiles[0]
        XCTAssertEqual(p.name, "a")
        XCTAssertEqual(p.sshPort, 2222)
        XCTAssertEqual(p.identityFile, "~/.ssh/k")
        XCTAssertEqual(p.extraOptions, "-o ProxyJump=b")
        XCTAssertEqual(p.downloadDir, "/tmp")
        XCTAssertEqual(p.id, store.profiles[0].id)
        XCTAssertEqual(back.profiles[1].name, "b \"q\"")
        XCTAssertEqual(back.lastProfile, "a")
        XCTAssertEqual(back.settings.theme, "light")
        XCTAssertEqual(back.toJSON(), json)

        // hand-edited / odd values: JS Number() semantics, clamps, unknown fields
        let odd = ConfigStore(file: "/nonexistent/config.json")
        try odd.load(text: """
        {"profiles":[{"name":"x","host":"y","sshPort":"22","passwordEnc":"zz","localPort":5,"bogus":1}, 7],
         "lastProfile":"x","settings":{"theme":"Bad Theme!","unfocusedFade":"250","minCols":null,"maxCols":true}}
        """)
        XCTAssertEqual(odd.profiles[0].sshPort, 22)
        XCTAssertEqual(odd.profiles.count, 1)
        XCTAssertEqual(odd.settings.theme, "dark")
        XCTAssertEqual(odd.settings.unfocusedFade, 100)
        XCTAssertEqual(odd.settings.minCols, 40) // Number(null) = 0 → clamp 40
        XCTAssertEqual(odd.settings.maxCols, 40) // Number(true) = 1 → 40
        // garbage → an error (the engine keeps the file aside), defaults
        let bad = ConfigStore(file: "/nonexistent/config.json")
        XCTAssertThrowsError(try bad.load(text: "not json"))
        XCTAssertThrowsError(try bad.load(text: "[1,2]"))
        XCTAssertEqual(bad.settings.minCols, 90)
        XCTAssertEqual(bad.settings.maxCols, 200)
        XCTAssertEqual(bad.settings.unfocusedFade, 40)
        // ports: deviation 39, only whole decimal numbers 0–65535; the rest
        // is repaired to the default and reported
        let ports = ConfigStore(file: "/nonexistent/config.json")
        try ports.load(text: """
        {"profiles":[{"name":"big","host":"h","sshPort":99999},{"name":"frac","host":"h","sshPort":22.5},
         {"name":"neg","host":"h","sshPort":-1},{"name":"hex","host":"h","sshPort":"0x16"},{"name":"f","host":"h","sshPort":"22.0"},
         {"name":"ok","host":"h","sshPort":"2222"},{"name":"ok2","host":"h","sshPort":22}]}
        """)
        for pp in ports.profiles[0..<5] { XCTAssertEqual(pp.sshPort, 0, pp.name) }
        XCTAssertEqual(ports.profiles[5].sshPort, 2222)
        XCTAssertEqual(ports.profiles[6].sshPort, 22)
        XCTAssertEqual(ports.repairs.filter { $0.contains("\"sshPort\"") }.count, 5)
        XCTAssertTrue(ports.repairs[0].contains("\"big\": \"sshPort\" 99999 is not a port"), ports.repairs[0])
        XCTAssertNil(Profile.parsePort("0"))
        XCTAssertNil(Profile.parsePort("0x16"))
        XCTAssertNil(Profile.parsePort("22.0"))
        XCTAssertEqual(Profile.parsePort(" "), 0)
        XCTAssertEqual(Profile.parsePort("65535"), 65535)
        XCTAssertEqual(ports.save(ProfileInput(name: "x", host: "h", sshPort: 70000), originalName: nil), Profile.portError)
        XCTAssertNil(ports.save(ProfileInput(name: "x", host: "h", sshPort: 65535, id: "00ff00ff00ff00ff"), originalName: nil))
        XCTAssertEqual(ports.find("x")!.id, "00ff00ff00ff00ff")
    }

    func testSharedAndMissingIDsAreRepaired() throws {
        let st = ConfigStore(file: "/nonexistent/config.json")
        try st.load(text: """
        {"profiles":[{"name":"one","host":"o","id":"0123456789abcdef"},{"name":"two","host":"t","id":"0123456789ABCDEF"},
         {"name":"three","host":42,"id":"zz"}, {"name":"one","host":"x"}, 7],
         "lastProfile":5,"settings":{"theme":3,"unfocusedFade":"x"}}
        """)
        XCTAssertEqual(st.profiles.count, 4)
        XCTAssertNotEqual(st.profiles[0].id, st.profiles[1].id)
        XCTAssertEqual(st.droppedIDs.count, 2) // both spellings: the Keychain matches ids exactly
        for p in st.profiles {
            XCTAssertTrue(Profile.validID(p.id))
            XCTAssertNotEqual(p.id.lowercased(), "0123456789abcdef")
        }
        XCTAssertEqual(st.profiles[3].name, "one (2)")
        XCTAssertTrue(st.repairs.contains { $0.contains("\"one\", \"two\" had the same id") }, "\(st.repairs)")
        XCTAssertTrue(st.repairs.contains("\"three\": \"host\" is not text: cleared"), "\(st.repairs)")
        XCTAssertTrue(st.repairs.contains("\"one (2)\" has no id: given one"), "\(st.repairs)")
        XCTAssertTrue(st.repairs.contains("\"lastProfile\" is not text: cleared"))
        XCTAssertTrue(st.repairs.contains("settings: \"theme\" is not a theme name: dark used"))
        // an explicit id that is taken is replaced
        XCTAssertNil(st.save(ProfileInput(name: "n", host: "h", id: st.profiles[0].id), originalName: nil))
        XCTAssertNotEqual(st.find("n")!.id, st.profiles[0].id)
    }

    func testHostSlugMatchesMainJsAppOrigin() {
        // reference values computed with node from main.js's appOrigin
        XCTAssertEqual(Profile.hostSlug(host: "me@Box.example.com", instance: ""), "me-box-example-com-05547d73")
        XCTAssertEqual(Profile.hostSlug(host: "--x--", instance: "dev"), "x-1ea96727")
        XCTAssertEqual(Profile.hostSlug(host: "@@@", instance: "a.b"), "95b88b65")
        XCTAssertEqual(Profile.hostSlug(host: "host", instance: ""), "host-a22a7f04")
        XCTAssertEqual(Profile.hostSlug(host: "host", instance: "default"), "host-a22a7f04")
    }

    func testUtilFormatting() {
        XCTAssertEqual(Util.iso(ms: 0), "1970-01-01T00:00:00.000Z")
        XCTAssertEqual(Util.iso(ms: 1793832732604), "2026-11-04T22:52:12.604Z")
        XCTAssertEqual(Util.clipChars("abc", 2), "ab")
        XCTAssertEqual(Util.clipChars("a—b", 2), "a—")
        XCTAssertEqual(Util.clipChars("abc", 10), "abc")
        XCTAssertEqual(Util.jsNumber(1e20), "100000000000000000000")
        XCTAssertEqual(Util.jsNumber(9.223372036854775808e18), "9223372036854775808")
        XCTAssertEqual(Util.jsNumber(-1e20), "-100000000000000000000")
        XCTAssertEqual(Util.jsNumber(1.5), "1.5")
        XCTAssertEqual(Util.jsNumber(42), "42")
        XCTAssertEqual(Util.jsonString("say \"hi\"\n\u{01}"), "\"say \\\"hi\\\"\\n\\u0001\"")
        XCTAssertEqual(Util.sha256Hex(["abc"]), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testSocketPathKeepsTheHashAndFits() throws {
        let p = Paths(root: "/Users/me/Library/Application Support/me.puntium.webmux.mac")
        XCTAssertEqual(try p.socketPath(slug: "host-a22a7f04"), "/Users/me/Library/Application Support/me.puntium.webmux.mac/run/host-a22a7f04.sock")
        let long = String(repeating: "a", count: 120) + "-0123abcd"
        let p2 = try p.socketPath(slug: long)
        XCTAssertLessThanOrEqual(p2.utf8.count, Paths.maxSocketPath)
        XCTAssertTrue(p2.hasSuffix("-0123abcd.sock"))
        let tooLong = Paths(root: "/" + String(repeating: "d", count: 120))
        XCTAssertThrowsError(try tooLong.socketPath(slug: "host-a22a7f04"))
    }
}
