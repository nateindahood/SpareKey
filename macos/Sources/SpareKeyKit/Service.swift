import Foundation

/// Backups, layer writes and the background playlist/clock service. Mirrors cli.py + service.py.
public enum Keyboard {
    public struct Backup: Codable {
        var version = 1
        var model: String
        var firmware: String
        var time: Double
        var profile: String
        var led_effects: String
        var key_colors: String
        var keymatrix: [String: [UInt32]]
        var macros: String
    }

    static func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }
    static func unhex(_ s: String) -> [UInt8] {
        var out = [UInt8](), chars = Array(s.utf8), i = 0
        while i + 1 < chars.count {
            out.append(UInt8(String(bytes: chars[i...i + 1], encoding: .ascii)!, radix: 16) ?? 0)
            i += 2
        }
        return out
    }

    @discardableResult
    public static func backup(_ d: S98Device, to url: URL? = nil) throws -> URL {
        // A layer is kept only if two reads agree: some (e.g. Mac FN) read back as random memory,
        // and a missing layer falls back to the vendor defaults. Per-key colours and macros often
        // can't be read at all (the keyboard answers with a bare header); they're saved as "" then.
        var km = [String: [UInt32]]()
        for t in 0..<2 { for l in 0..<4 {
            let a = try d.keymatrix(table: t, layer: l)
            if try d.keymatrix(table: t, layer: l) == a { km["\(t)/\(l)"] = a }
        } }
        let b = Backup(model: d.model, firmware: try d.firmware(), time: Date().timeIntervalSince1970,
                       profile: hex(try d.profile().buf), led_effects: hex(try d.ledEffects().buf),
                       key_colors: (try? d.keyColors()).map { hex($0.buf) } ?? "", keymatrix: km,
                       macros: (try? d.macrosBlob()).map(hex) ?? "")
        let dest: URL
        if let u = url { dest = u } else {
            let f = DateFormatter()
            f.dateFormat = "yyyyMMdd-HHmmss"
            dest = Store.backupDir.appendingPathComponent("s98-\(f.string(from: Date())).json")
        }
        // also needed for s98-original.json, which is written before the folder exists
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = .prettyPrinted
        try enc.encode(b).write(to: dest, options: .atomic)
        return dest
    }

    /// Before the first change, keep a copy of how the keyboard was set up.
    public static func ensureFirstBackup(_ d: S98Device) throws {
        let first = Store.backupDir.appendingPathComponent("s98-original.json")
        if !FileManager.default.fileExists(atPath: first.path) { try backup(d, to: first) }
    }

    /// Write back only the profile (lighting, sleep, debounce …) from a backup; returns whether it reads back the same.
    public static func restoreProfile(_ d: S98Device, from url: URL) throws -> Bool {
        let b = try JSONDecoder().decode(Backup.self, from: Data(contentsOf: url))
        let p = unhex(b.profile)
        guard p.count == S98.profileLength, p.suffix(2) == [0x5a, 0xa5] else { throw DeviceError.io("backup profile is invalid") }
        try d.setProfile(Profile(p))
        return try d.profile().buf == p
    }

    public static func restore(_ d: S98Device, from url: URL) throws {
        let b = try JSONDecoder().decode(Backup.self, from: Data(contentsOf: url))
        try d.setProfile(Profile(unhex(b.profile)))
        try d.setLedEffects(LedEffects(unhex(b.led_effects)))
        // older backups and unreadable blocks: skip rather than write something that isn't a real copy
        let colors = unhex(b.key_colors)
        if colors.count == S98.ledColorsLength && colors.contains(where: { $0 != 0 }) { try d.setKeyColors(KeyColors(colors)) }
        for (tl, codes) in b.keymatrix {
            let p = tl.split(separator: "/").compactMap { Int($0) }
            guard p.count == 2 else { continue }
            try d.setKeymatrix(table: p[0], layer: p[1],
                               codes: Keymap.mergedMatrix(table: p[0], layer: p[1], fromDevice: codes, overrides: [:]))
        }
        var blob = unhex(b.macros)
        while blob.last == 0 { blob.removeLast() }
        if !blob.isEmpty { try d.setMacrosBlob(blob) }
    }

    /// How the layer looked before SpareKey changed anything (the original backup's readable part).
    /// Live reads can't be used once keys are remapped, or "Default" would just write the remap back.
    public static func baseline(table: Int, layer: Int) -> [UInt32]? {
        let url = Store.backupDir.appendingPathComponent("s98-original.json")
        guard let data = try? Data(contentsOf: url), let b = try? JSONDecoder().decode(Backup.self, from: data) else { return nil }
        return b.keymatrix["\(table)/\(layer)"]
    }

    public static func layerCodes(table: Int, layer: Int, config: Config = Store.loadConfig()) -> [UInt32] {
        Keymap.mergedMatrix(table: table, layer: layer, fromDevice: baseline(table: table, layer: layer),
                            overrides: config.overrides(table: table, layer: layer))
    }

    public static func writeLayer(_ d: S98Device, table: Int, layer: Int) throws {
        try ensureFirstBackup(d)
        try d.setKeymatrix(table: table, layer: layer, codes: layerCodes(table: table, layer: layer))
    }

    /// Convert and send a file on an already-open device.
    public static func upload(_ d: S98Device, _ url: URL, fit: Fit, progress: ((Int, Int) -> Void)? = nil,
                              cancelled: (() -> Bool)? = nil) throws {
        let frames = try Media.load(url, fit: fit)
        let data = frames.images.map(Media.encode)
        try d.upload(frames: data, delayMs: frames.delayMs, progress: progress, cancelled: cancelled)
        try d.syncClock()
    }
}

public enum Service {
    public static let label = "io.github.nateindahood.sparekey.service"
    static let clockEvery: TimeInterval = 600

    static func log(_ s: String) {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        print("\(f.string(from: Date())) \(s)")
        fflush(stdout)
    }

    /// One scheduling step; true when it uploaded something.
    @discardableResult
    public static func runOnce(now: Double = Date().timeIntervalSince1970) -> Bool {
        var st = Store.loadState()
        guard let name = st.active, let pl = Store.loadConfig().playlists[name], let next = st.nextAt, now >= next else {
            return false
        }
        guard let item = Store.nextItem(pl, &st) else {
            log("playlist \(name) has no files left; stopping")
            st.active = nil; st.nextAt = nil
            Store.saveState(st)
            return false
        }
        st.uploading = item; st.progress = 0
        Store.saveState(st)
        log("uploading \((item as NSString).lastPathComponent)")
        var lastFrac = 0.0
        var stopped = false
        var err: String?
        do {
            try DeviceQueue.shared.runSync { d in try Keyboard.upload(d, URL(fileURLWithPath: item), fit: pl.fit, progress: { done, total in
                let frac = Double(done) / Double(total)
                guard frac - lastFrac >= 0.02 else { return }
                lastFrac = frac
                var cur = Store.loadState()
                if cur.active != name { stopped = true; return }
                cur.progress = frac
                Store.saveState(cur)
            }, cancelled: { stopped }) }
        } catch {
            err = error.localizedDescription
        }
        let cur = Store.loadState()
        if cur.active == name {
            st.uploading = nil; st.progress = nil; st.error = err
            st.nextAt = Date().timeIntervalSince1970 + (err == nil ? Double(max(Store.minInterval, pl.interval) * 60) : 120)
            Store.saveState(st)
        }
        log(err.map { "failed: \($0)" } ?? "done")
        return err == nil
    }

    public static func run() -> Never {
        log("sparekey service started")
        var lastClock = 0.0
        while true {
            let now = Date().timeIntervalSince1970
            if runOnce(now: now) {
                lastClock = Date().timeIntervalSince1970
            } else if now - lastClock >= clockEvery {
                if (try? DeviceQueue.shared.runSync(wait: false) { try $0.syncClock() }) != nil { lastClock = now }
            }
            Thread.sleep(forTimeInterval: 15)
        }
    }

    // MARK: LaunchAgent (runs `SpareKey --service` at login)

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    public static var isInstalled: Bool { FileManager.default.fileExists(atPath: plistURL.path) }

    public static func install(executable: String) throws {
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable, "--service"],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "StandardOutPath": Store.dir.appendingPathComponent("service.log").path,
            "StandardErrorPath": Store.dir.appendingPathComponent("service.log").path,
        ]
        try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: plistURL, options: .atomic)
        launchctl(["bootout", "gui/\(getuid())/\(label)"])
        launchctl(["bootstrap", "gui/\(getuid())", plistURL.path])
    }

    /// The pre-release build was called Keyframe; replace its LaunchAgent with SpareKey's.
    public static func replaceOldAgent(executable: String) {
        let oldLabel = "io.github.nateindahood.keyframe.service"
        let oldPlist = plistURL.deletingLastPathComponent().appendingPathComponent("\(oldLabel).plist")
        guard FileManager.default.fileExists(atPath: oldPlist.path) else { return }
        launchctl(["bootout", "gui/\(getuid())/\(oldLabel)"])
        try? FileManager.default.removeItem(at: oldPlist)
        try? install(executable: executable)
    }

    public static func uninstall() {
        launchctl(["bootout", "gui/\(getuid())/\(label)"])
        try? FileManager.default.removeItem(at: plistURL)
    }

    @discardableResult
    static func launchctl(_ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }
}
