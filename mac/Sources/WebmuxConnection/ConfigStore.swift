// The config store: `config.json` under Application Support, the port of
// main.js's loadStore/saveStore and profiles:save/delete (minus
// `passwordEnc` and `localPort`, minus the legacy migrations: this client
// has no history). Not thread-safe by itself; the engine locks it.
//
// A file that exists but cannot be read or parsed is never overwritten: it
// is renamed to `config.json.broken-<time>` (or, if even that fails, the
// store refuses to save until restarted) and the store starts empty. A file
// that parsed but held values of the wrong type or shape is repaired in
// memory, the original kept as `config.json.before-repair-<time>`, and the
// repairs reported (main.js only printed `config.json unreadable` and then
// overwrote the file on the next save).
import Foundation

public final class ConfigStore {
    public let file: String
    public private(set) var profiles: [Profile] = []
    public private(set) var lastProfile: String?
    public var settings = Settings()
    /// What `load` had to repair (user-facing lines). Empty when the file was clean.
    public private(set) var repairs: [String] = []
    /// Ids that more than one profile carried: every such profile got a new
    /// id, and the secret stored under the old one must never be offered
    /// again (the app forgets it).
    public private(set) var droppedIDs: [String] = []
    /// A user-facing sentence when the file could not be used as is, and
    /// where the original was kept. Nil when it loaded fine.
    public private(set) var problem: String?
    /// The kept-aside copy ("" when the original could not be kept but
    /// saving is still allowed); nil with `problem` set means never save.
    private var aside: String?

    public init(file: String) {
        self.file = file
    }

    // -- load / save ------------------------------------------------------

    /// Load the file. Missing → empty store with default settings.
    public func load() {
        let data: Data?
        do {
            data = try Util.readFile(file)
        } catch {
            broken((error as? Util.FileError)?.name ?? "unreadable")
            return
        }
        guard let bytes = data else { return }
        guard let root = JSONValue.parse(bytes), case .object = root else {
            broken("not valid JSON")
            return
        }
        loadJSON(root)
        if !repairs.isEmpty { repaired(original: bytes) }
    }

    public struct InvalidConfig: Error {}

    /// Parse config text (tests). `InvalidConfig` when it is not a JSON object.
    public func load(text: String) throws {
        guard let root = JSONValue.parse(text), case .object = root else { throw InvalidConfig() }
        loadJSON(root)
    }

    private func loadJSON(_ root: JSONValue) {
        if let profs = root["profiles"] {
            if case .array(let items) = profs {
                for (i, pv) in items.enumerated() {
                    let n = i + 1
                    guard case .object(let o) = pv else {
                        repair("profile #\(n) is not an object: dropped")
                        continue
                    }
                    profiles.append(profileFromJSON(o, n))
                }
            } else {
                repair("\"profiles\" is not a list: no profile could be read")
            }
        }
        repairIDs()
        if let l = root["lastProfile"] {
            switch l {
            case .string(let s): if !s.isEmpty { lastProfile = s }
            case .null: break
            default: repair("\"lastProfile\" is not text: cleared")
            }
        }
        checkSettings(root["settings"])
        settings = Settings().sanitized(withJSON: root["settings"])
    }

    private func repair(_ line: String) { repairs.append(line) }

    /// One profile, every field checked for its type (wrong types become
    /// empty, with a repair line).
    private func profileFromJSON(_ o: [String: JSONValue], _ n: Int) -> Profile {
        let label = o["name"]?.stringValue.map { Util.clipChars($0, 80) } ?? ""
        let who = label.isEmpty ? "profile #\(n)" : "\"\(label)\""
        var p = Profile()
        func text(_ key: String) -> String {
            guard let v = o[key] else { return "" }
            switch v {
            case .string(let s): return s
            case .null: return ""
            default:
                repair("\(who): \"\(key)\" is not text: cleared")
                return ""
            }
        }
        p.id = text("id")
        p.name = text("name")
        p.host = text("host")
        p.identityFile = text("identityFile")
        p.instance = text("instance")
        p.extraOptions = text("extraOptions")
        p.downloadDir = text("downloadDir")
        if let v = o["sshPort"] {
            if let port = v.portValue {
                p.sshPort = port
            } else {
                var short = v.serialized
                if short.count > 60 { short = "(a long value)" }
                repair("\(who): \"sshPort\" \(short) is not a port (a whole number 1–65535): set to ssh's default")
            }
        }
        if p.name.isEmpty {
            p.name = "profile \(n)"
            repair("profile #\(n) has no name: named \"\(p.name)\"")
        }
        if find(p.name) != nil {
            var k = 2
            while true {
                let cand = "\(p.name) (\(k))"
                if find(cand) == nil {
                    repair("two profiles are named \"\(Util.clipChars(p.name, 80))\": the second is now \"\(cand)\"")
                    p.name = cand
                    break
                }
                k += 1
            }
        }
        if p.host.isEmpty { repair("\"\(Util.clipChars(p.name, 80))\" has no host: it cannot connect until one is set") }
        return p
    }

    /// Every profile gets an id of its own: missing or malformed ids are
    /// generated, and an id more than one profile carries (a copied block)
    /// is replaced in all of them; the secret stored under it is dropped,
    /// since it cannot be known which host it was saved for.
    private func repairIDs() {
        for i in profiles.indices {
            let p = profiles[i]
            if !Profile.validID(p.id) {
                if !p.id.isEmpty {
                    repair("\"\(Util.clipChars(p.name, 80))\": its id is malformed: given a new one")
                } else {
                    repair("\"\(Util.clipChars(p.name, 80))\" has no id: given one")
                }
                profiles[i].id = ""
                continue
            }
            let shared = profiles.indices.contains { j in j != i && profiles[j].id.caseInsensitiveCompare(p.id) == .orderedSame }
            if shared {
                let known = droppedIDs.contains { $0.caseInsensitiveCompare(p.id) == .orderedSame }
                let exact = droppedIDs.contains(p.id)
                // Every spelling is dropped: the Keychain matches ids exactly.
                if known && !exact { droppedIDs.append(p.id) }
                if !known {
                    let names = profiles.filter { $0.id.caseInsensitiveCompare(p.id) == .orderedSame }
                        .map { "\"\(Util.clipChars($0.name, 80))\"" }.joined(separator: ", ")
                    repair("\(names) had the same id: each was given a new one, and a password saved under it was cleared (re-enter it)")
                    droppedIDs.append(p.id)
                }
            }
        }
        for i in profiles.indices {
            let id = profiles[i].id
            let reissue = id.isEmpty || droppedIDs.contains { $0.caseInsensitiveCompare(id) == .orderedSame }
            if reissue { profiles[i].id = uniqueID() }
        }
    }

    /// A new id no profile has.
    public func uniqueID() -> String {
        while true {
            let id = Profile.newID()
            if !idInUse(id) { return id }
        }
    }

    public func idInUse(_ id: String) -> Bool {
        profiles.contains { $0.id.caseInsensitiveCompare(id) == .orderedSame }
            || droppedIDs.contains { $0.caseInsensitiveCompare(id) == .orderedSame }
    }

    private func checkSettings(_ raw: JSONValue?) {
        guard let v = raw else { return }
        if case .null = v { return }
        guard case .object(let o) = v else {
            repair("\"settings\" is not an object: defaults used")
            return
        }
        if let t = o["theme"] {
            if case .string(let s) = t, Settings.validTheme(s) {} else { repair("settings: \"theme\" is not a theme name: dark used") }
        }
        for (key, lo, hi) in [("unfocusedFade", 0.0, 100.0), ("minCols", 40.0, 400.0), ("maxCols", 40.0, 400.0)] {
            guard let x = o[key] else { continue }
            let ok: Bool
            switch x {
            case .integer(let i): ok = Double(i) >= lo && Double(i) <= hi
            case .float(let f): ok = f.isFinite && f >= lo && f <= hi
            default: ok = false
            }
            if !ok {
                var short = x.serialized
                if short.count > 60 { short = "(a long value)" }
                repair("settings: \"\(key)\" \(short) is not a number from \(Int(lo)) to \(Int(hi)): adjusted")
            }
        }
    }

    /// Serialize as `JSON.stringify(store, null, 2) + '\n'`.
    public func toJSON() -> String {
        var s = "{\n  \"profiles\": ["
        if profiles.isEmpty {
            s += "]"
        } else {
            s += "\n"
            for (i, p) in profiles.enumerated() {
                s += "    {\n"
                s += "      \"name\": \(Util.jsonString(p.name)),\n"
                s += "      \"host\": \(Util.jsonString(p.host)),\n"
                s += "      \"sshPort\": \(p.sshPort),\n"
                s += "      \"identityFile\": \(Util.jsonString(p.identityFile)),\n"
                s += "      \"instance\": \(Util.jsonString(p.instance)),\n"
                s += "      \"extraOptions\": \(Util.jsonString(p.extraOptions)),\n"
                s += "      \"downloadDir\": \(Util.jsonString(p.downloadDir)),\n"
                s += "      \"id\": \(Util.jsonString(p.id))\n"
                s += "    }" + (i + 1 < profiles.count ? ",\n" : "\n")
            }
            s += "  ]"
        }
        s += ",\n  \"lastProfile\": " + (lastProfile.map(Util.jsonString) ?? "null")
        s += ",\n  \"settings\": {\n"
        s += "    \"theme\": \(Util.jsonString(settings.theme)),\n"
        s += "    \"unfocusedFade\": \(settings.unfocusedFade),\n"
        s += "    \"minCols\": \(settings.minCols),\n"
        s += "    \"maxCols\": \(settings.maxCols)\n"
        s += "  }\n}\n"
        return s
    }

    /// Write the file atomically (0600). Returns a user-facing error, or nil.
    @discardableResult
    public func save() -> String? {
        // A broken config.json that could not be moved aside is never overwritten.
        if problem != nil && aside == nil { return "config.json is unreadable and was not overwritten — fix or remove it, then restart" }
        try? Util.makePath(Util.dirname(file), mode: 0o700)
        do {
            try Util.atomicWrite(file, toJSON(), mode: 0o600)
        } catch {
            return "could not save \(file): \((error as? Util.FileError)?.name ?? "\(error)")"
        }
        return nil
    }

    private static func stamp() -> String {
        // 2026-11-04T12:34:56.789Z → 20261104T123456Z (no ':' in file names)
        var out = ""
        for ch in Util.isoNow() {
            if ch == "." { break }
            if ch.isNumber || ch == "T" || ch == "Z" { out.append(ch) }
        }
        return out
    }

    private func broken(_ why: String) {
        let asidePath = "\(file).broken-\(ConfigStore.stamp())Z"
        var kept: String?
        if rename(file, asidePath) == 0 { kept = asidePath }
        aside = kept
        if let k = kept {
            problem = "config.json could not be read (\(why)); it was kept as \(k) and the profile list starts empty"
        } else {
            problem = "config.json could not be read (\(why)) and could not be moved aside; nothing will be saved until it is fixed or removed"
        }
        logger.error("config.json unreadable: \(why, privacy: .public)")
        loadReport = LoadReport(unreadable: why, keptAs: kept)
    }

    private func repaired(original: Data) {
        let copy = "\(file).before-repair-\(ConfigStore.stamp())Z"
        let kept = (try? Util.atomicWrite(copy, Array(original), mode: 0o600)) != nil
        var list = ""
        for (i, r) in repairs.enumerated() {
            if i == 5 {
                list += "; and \(repairs.count - 5) more (see the connection log)"
                break
            }
            if i > 0 { list += "; " }
            list += r
        }
        if kept {
            problem = "config.json had values that could not be used and were repaired: \(list). The original was kept as \(copy); the repaired version is written on the next save"
            aside = copy
        } else {
            problem = "config.json had values that could not be used and were repaired: \(list). The repaired version is written on the next save"
            aside = ""
        }
        loadReport = LoadReport(repairs: repairs, keptAs: kept ? copy : nil)
    }

    /// What `load` found, for the engine's log lines.
    public struct LoadReport: Equatable {
        public var unreadable: String?
        public var repairs: [String] = []
        public var keptAs: String?
        init(unreadable: String? = nil, repairs: [String] = [], keptAs: String? = nil) {
            self.unreadable = unreadable
            self.repairs = repairs
            self.keptAs = keptAs
        }
    }

    public private(set) var loadReport: LoadReport?

    /// Every profile id something may still refer to: the profiles', and any
    /// 16-hex-digit token in a config file kept aside next to config.json
    /// (`.broken-*`, `.before-repair-*`), so restoring one of them still
    /// finds its passwords.
    public func referencedIDs() -> [String] {
        var out = profiles.map { $0.id }
        let dir = Util.dirname(file)
        let base = Util.basename(file)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return out }
        for name in names where name.hasPrefix(base) && name.count > base.count {
            let rest = name.dropFirst(base.count)
            guard rest.hasPrefix(".broken-") || rest.hasPrefix(".before-repair-") else { continue }
            guard let text = Util.readString(Util.join(dir, name)) else { continue }
            var run = ""
            for u in text.unicodeScalars {
                let hex = ("0"..."9").contains(u) || ("a"..."f").contains(u) || ("A"..."F").contains(u)
                if hex {
                    run.unicodeScalars.append(u)
                } else {
                    if run.count == 16 { out.append(run) }
                    run = ""
                }
            }
            if run.count == 16 { out.append(run) }
        }
        return out
    }

    // -- profiles -----------------------------------------------------------

    public func find(_ name: String) -> Profile? {
        profiles.first { $0.name == name }
    }

    public func findIndex(_ name: String) -> Int? {
        profiles.firstIndex { $0.name == name }
    }

    public func setLastProfile(_ name: String?) {
        lastProfile = name
    }

    /// The checks of `save(_:originalName:)`, in main.js's order, without saving.
    public func validate(_ input: ProfileInput, originalName: String?) -> String? {
        let name = Util.trim(input.name)
        let host = Util.trim(input.host)
        let instance = Util.trim(input.instance)
        if !instance.isEmpty && !Profile.validInstance(instance) { return Profile.instanceError }
        if !Profile.validPort(input.sshPort) { return Profile.portError }
        if name.isEmpty || host.isEmpty { return "name and host are required" }
        if (originalName == nil || name != originalName!) && find(name) != nil {
            return "a profile named \"\(Util.clipChars(name, 200))\" already exists"
        }
        return nil
    }

    /// main.js profiles:save (the store half): trim, validate, insert or
    /// replace (`originalName` = the profile being edited, nil for new),
    /// carry over id and downloadDir, follow a rename into lastProfile.
    /// Returns a user-facing error, or nil.
    public func save(_ input: ProfileInput, originalName: String?) -> String? {
        if let msg = validate(input, originalName: originalName) { return msg }
        let name = Util.trim(input.name)
        let host = Util.trim(input.host)
        let instance = Util.trim(input.instance)
        let existing = find(originalName ?? name)
        var p = Profile()
        if let e = existing {
            p.id = e.id
        } else if let id = input.id, Profile.validID(id), !idInUse(id) {
            p.id = id
        } else {
            p.id = uniqueID()
        }
        p.name = name
        p.host = host
        p.sshPort = input.sshPort
        // connect.html trims these two before saving
        p.identityFile = Util.trim(input.identityFile)
        p.instance = instance
        p.extraOptions = Util.trim(input.extraOptions)
        p.downloadDir = input.downloadDir ?? existing?.downloadDir ?? ""
        if let idx = findIndex(originalName ?? name) {
            profiles[idx] = p
        } else {
            profiles.append(p)
        }
        if let orig = originalName, orig != name, lastProfile == orig { lastProfile = name }
        return nil
    }

    /// main.js profiles:delete (the store half).
    public func delete(_ name: String) {
        if let idx = findIndex(name) { profiles.remove(at: idx) }
        if lastProfile == name { lastProfile = nil }
    }

    public func setDownloadDir(_ name: String, _ dir: String) -> Bool {
        guard let idx = findIndex(name) else { return false }
        profiles[idx].downloadDir = dir
        return true
    }

    // -- first-run import (deviation 5) --------------------------------------

    /// Profiles (not passwords, not `localPort`) from an Electron client's
    /// config.json. Each is saved through `save`; returns the imported
    /// count and the names that were refused with their errors. `nil` when
    /// the file does not exist or is not a JSON object.
    public func importElectronProfiles(from path: String) -> (imported: Int, refused: [(name: String, error: String)])? {
        guard let data = try? Util.readFile(path) else { return nil }
        // Untyped: one odd field must not lose every profile (C-8).
        guard let root = JSONValue.parse(data), case .object(let o) = root else { return nil }
        guard case .array(let items)? = o["profiles"] else { return (0, []) }
        var n = 0
        var refused: [(String, String)] = []
        for pv in items {
            guard case .object(let po) = pv, let name = po["name"]?.stringValue, let host = po["host"]?.stringValue else { continue }
            // main.js: Number(sshPort) || 0; a whole number is kept (an
            // out-of-range one is refused by the save, and reported).
            var port = 0
            if let v = po["sshPort"] {
                let f = v.jsNumber
                if f.isFinite && f >= 0 && f <= Double(Int32.max) && f.rounded(.down) == f { port = Int(f) }
            }
            let input = ProfileInput(name: name, host: host, sshPort: port,
                                     identityFile: po["identityFile"]?.stringValue ?? "",
                                     instance: po["instance"]?.stringValue ?? "",
                                     extraOptions: po["extraOptions"]?.stringValue ?? "",
                                     downloadDir: po["downloadDir"]?.stringValue ?? "")
            if let err = save(input, originalName: nil) {
                refused.append((name, err))
            } else {
                n += 1
            }
        }
        return (n, refused)
    }
}
