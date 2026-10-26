import Foundation

/// Backups, layer writes and the background clock service. Mirrors cli.py + service.py.
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

    public static func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }
    public static func unhex(_ s: String) -> [UInt8] {
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
        try Store.writePrivate(try enc.encode(b), to: dest)   // macros can hold typed text
        return dest
    }

    /// Before the first change, keep a copy of how the keyboard was set up.
    public static func ensureFirstBackup(_ d: S98Device) throws {
        let first = Store.backupDir.appendingPathComponent("s98-original.json")
        if !FileManager.default.fileExists(atPath: first.path) { try backup(d, to: first) }
    }

    /// Write back only the profile (lighting, sleep, debounce …) from a backup; returns whether it reads back the same.
    public static func restoreProfile(_ d: S98Device, from url: URL) throws -> Bool {
        let p = try readBackup(url).profile
        try d.setProfile(Profile(p))
        return try d.profile().buf == p
    }

    static func isHex(_ s: String) -> Bool { s.count % 2 == 0 && s.allSatisfy { $0.isHexDigit } }

    /// Load and check a backup completely before anything is written: a damaged or edited file
    /// must never reach the keyboard. Mirrors cli.read_backup.
    static func readBackup(_ url: URL) throws -> (Backup, profile: [UInt8], effects: [UInt8], colors: [UInt8],
                                                  layers: [(Int, Int, [UInt32])], macros: [UInt8]) {
        let b: Backup
        do { b = try JSONDecoder().decode(Backup.self, from: Data(contentsOf: url)) } catch {
            throw DeviceError.badBackup("unreadable file")
        }
        guard [b.profile, b.led_effects, b.key_colors, b.macros].allSatisfy(isHex) else { throw DeviceError.badBackup("bad hex") }
        let profile = unhex(b.profile), effects = unhex(b.led_effects), colors = unhex(b.key_colors)
        var macros = unhex(b.macros)
        while macros.last == 0 { macros.removeLast() }
        guard profile.count == S98.profileLength, profile.suffix(2) == [0x5a, 0xa5] else { throw DeviceError.badBackup("damaged profile") }
        guard effects.count == S98.ledEffectLength, colors.isEmpty || colors.count == S98.ledColorsLength,
              macros.count <= S98.macroLength else { throw DeviceError.badBackup("a block has the wrong size") }
        var layers = [(Int, Int, [UInt32])]()
        for (tl, codes) in b.keymatrix {
            let p = tl.split(separator: "/").compactMap { Int($0) }
            guard p.count == 2, (0...1).contains(p[0]), (0...3).contains(p[1]), codes.count == S98.keys else {
                throw DeviceError.badBackup("key layer \(tl)")
            }
            layers.append((p[0], p[1], codes))
        }
        return (b, profile, effects, colors, layers, macros)
    }

    public static func restore(_ d: S98Device, from url: URL) throws {
        let b = try readBackup(url)
        var cfg = Store.loadConfig()
        try d.setProfile(Profile(b.profile))
        // unreadable blocks were saved empty (or all zero by older versions): skip rather than write
        // something that isn't a real copy
        if b.effects.contains(where: { $0 != 0 }) { try d.setLedEffects(LedEffects(b.effects)) }
        if b.colors.contains(where: { $0 != 0 }) { try d.setKeyColors(KeyColors(b.colors)) }
        for (t, l, codes) in b.layers {
            let restored = Keymap.mergedMatrix(table: t, layer: l, fromDevice: codes, overrides: [:])
            try d.setKeymatrix(table: t, layer: l, codes: restored)
            // what the keyboard now has becomes your saved key changes, so later edits build on it
            let base = Keymap.mergedMatrix(table: t, layer: l, fromDevice: baseline(table: t, layer: l), overrides: [:])
            var changes = [String: UInt32]()
            for i in 0..<restored.count where restored[i] != base[i] { changes[String(i)] = restored[i] }
            var tbl = cfg.keymap[String(t)] ?? [:]
            tbl[String(l)] = changes.isEmpty ? nil : changes
            cfg.keymap[String(t)] = tbl
        }
        if !b.macros.isEmpty {
            try d.setMacrosBlob(b.macros)
            cfg.macros = Keymap.decodeMacros(b.macros)
        }
        if b.colors.contains(where: { $0 != 0 }) { cfg.keyColors = hex(b.colors) }
        Store.saveConfig(cfg)
    }

    /// Back up, reset, and only then forget what SpareKey kept about the old setup.
    public static func factoryReset(_ d: S98Device) throws {
        try backup(d)
        try d.factoryReset()
        Store.update { $0.keymap = [:]; $0.macros = nil; $0.keyColors = nil }
    }

    /// Remove macro `number` (0-based) and fix keys that point at macros by position: keys on the
    /// deleted one go back to default, later ones move down by one. Mirrors cli.delete_macro.
    @discardableResult
    public static func deleteMacro(_ cfg: inout Config, _ number: Int) -> Set<[Int]> {
        if var m = cfg.macros, number >= 0, number < m.count { m.remove(at: number); cfg.macros = m }
        var changed = Set<[Int]>()
        for (t, layers) in cfg.keymap {
            for (l, keys) in layers {
                var keys = keys
                for (idx, action) in keys where action >> 24 == Keymap.macroType {
                    let n = Int(action & 0xFFFF)
                    if n == number { keys.removeValue(forKey: idx) }
                    else if n > number { keys[idx] = Keymap.macroAction(n - 1) }
                    else { continue }
                    changed.insert([Int(t) ?? 0, Int(l) ?? 0])
                }
                cfg.keymap[t]?[l] = keys
            }
        }
        return changed
    }

    /// Every layer with saved key changes (rewritten after sending macros, as macro numbers may move).
    public static func changedLayers(_ cfg: Config) -> [(Int, Int)] {
        cfg.keymap.flatMap { t, layers in layers.keys.compactMap { l in
            Int(t).flatMap { tt in Int(l).map { (tt, $0) } } } }.sorted { ($0.0, $0.1) < ($1.0, $1.1) }
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

    /// Keeps the keyboard clock right: sets it at login and every 10 minutes. Never waits behind an upload.
    public static func run() -> Never {
        log("SpareKey clock service started")
        var lastClock = 0.0
        while true {
            let now = Date().timeIntervalSince1970
            if now - lastClock >= clockEvery,
               (try? DeviceQueue.shared.runSync(wait: false) { try $0.syncClock() }) != nil {
                lastClock = now
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
