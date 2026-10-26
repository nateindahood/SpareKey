import Foundation

public struct Config: Codable {
    public var libraryDir: String?
    public var fit: Fit?
    public var keymap: [String: [String: [String: UInt32]]] = [:]   // table -> layer -> key index -> action
    public var macros: [Macro]?
    public init() {}
    enum CodingKeys: String, CodingKey { case libraryDir = "library_dir", fit, keymap, macros }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        libraryDir = try c.decodeIfPresent(String.self, forKey: .libraryDir)
        fit = try c.decodeIfPresent(Fit.self, forKey: .fit)
        keymap = try c.decodeIfPresent([String: [String: [String: UInt32]]].self, forKey: .keymap) ?? [:]
        macros = try c.decodeIfPresent([Macro].self, forKey: .macros)
    }

    public func overrides(table: Int, layer: Int) -> [Int: UInt32] {
        var out = [Int: UInt32]()
        for (k, v) in keymap[String(table)]?[String(layer)] ?? [:] { if let i = Int(k) { out[i] = v } }
        return out
    }
}

/// Settings and the library, stored as JSON in ~/Library/Application Support/SpareKey.
/// Same structure as the Linux config, so files can be copied between machines.
public enum Store {
    public static let dir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let d = base.appendingPathComponent("SpareKey", isDirectory: true)
        // settings from the pre-release name "keyframe" move over once
        let old = base.appendingPathComponent("keyframe", isDirectory: true)
        if FileManager.default.fileExists(atPath: old.path) && !FileManager.default.fileExists(atPath: d.path) {
            try? FileManager.default.moveItem(at: old, to: d)
        }
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    public static var configURL: URL { dir.appendingPathComponent("config.json") }
    public static var backupDir: URL { dir.appendingPathComponent("backups", isDirectory: true) }

    static func read<T: Decodable>(_ url: URL, _ fallback: T) -> T {
        guard let data = try? Data(contentsOf: url) else { return fallback }
        return (try? JSONDecoder().decode(T.self, from: data)) ?? fallback
    }

    static func write<T: Encodable>(_ url: URL, _ value: T) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(value) { try? data.write(to: url, options: .atomic) }
    }

    public static func loadConfig() -> Config { read(configURL, Config()) }
    public static func saveConfig(_ c: Config) { write(configURL, c) }
    public static func update(_ change: (inout Config) -> Void) { var c = loadConfig(); change(&c); saveConfig(c) }

    public static func libraryDir() -> URL {
        let path = loadConfig().libraryDir.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0].appendingPathComponent("sparekey")
        try? FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        return path
    }

    public static func isMedia(_ url: URL) -> Bool {
        Media.extensions.contains(url.pathExtension.lowercased()) && !url.lastPathComponent.hasPrefix(".")
    }

    public static func library() -> [URL] {
        let dir = libraryDir()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.sorted { $0.lowercased() < $1.lowercased() }
            .map { dir.appendingPathComponent($0) }
            .filter { isMedia($0) }
    }

    @discardableResult
    public static func addToLibrary(_ src: URL) throws -> URL {
        let dir = libraryDir()
        let stem = src.deletingPathExtension().lastPathComponent, ext = src.pathExtension
        var dest = dir.appendingPathComponent(src.lastPathComponent)
        if dest.standardizedFileURL == src.standardizedFileURL { return dest }
        var n = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = dir.appendingPathComponent("\(stem) (\(n)).\(ext)")
            n += 1
        }
        try FileManager.default.copyItem(at: src, to: dest)
        return dest
    }
}
