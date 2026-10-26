import Foundation

public struct Playlist: Codable, Hashable {
    public var items: [String]
    public var order: String = "loop"       // "loop" | "shuffle"
    public var interval: Int = Store.defaultInterval
    public var fit: Fit = .cover
    public init(items: [String] = [], order: String = "loop", interval: Int = Store.defaultInterval, fit: Fit = .cover) {
        self.items = items; self.order = order; self.interval = interval; self.fit = fit
    }
}

public struct Config: Codable {
    public var libraryDir: String?
    public var fit: Fit?
    public var playlists: [String: Playlist] = [:]
    public var keymap: [String: [String: [String: UInt32]]] = [:]   // table -> layer -> key index -> action
    public var macros: [Macro]?
    public init() {}
    enum CodingKeys: String, CodingKey { case libraryDir = "library_dir", fit, playlists, keymap, macros }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        libraryDir = try c.decodeIfPresent(String.self, forKey: .libraryDir)
        fit = try c.decodeIfPresent(Fit.self, forKey: .fit)
        playlists = try c.decodeIfPresent([String: Playlist].self, forKey: .playlists) ?? [:]
        keymap = try c.decodeIfPresent([String: [String: [String: UInt32]]].self, forKey: .keymap) ?? [:]
        macros = try c.decodeIfPresent([Macro].self, forKey: .macros)
    }

    public func overrides(table: Int, layer: Int) -> [Int: UInt32] {
        var out = [Int: UInt32]()
        for (k, v) in keymap[String(table)]?[String(layer)] ?? [:] { if let i = Int(k) { out[i] = v } }
        return out
    }
}

public struct PlaylistState: Codable {
    public var active: String?
    public var position: Int = -1
    public var bag: [String] = []
    public var current: String?
    public var nextAt: Double?
    public var uploading: String?
    public var progress: Double?
    public var error: String?
    public init() {}
    enum CodingKeys: String, CodingKey {
        case active, position, bag, current, nextAt = "next_at", uploading, progress, error
    }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        active = try c.decodeIfPresent(String.self, forKey: .active)
        position = try c.decodeIfPresent(Int.self, forKey: .position) ?? -1
        bag = try c.decodeIfPresent([String].self, forKey: .bag) ?? []
        current = try c.decodeIfPresent(String.self, forKey: .current)
        nextAt = try c.decodeIfPresent(Double.self, forKey: .nextAt)
        uploading = try c.decodeIfPresent(String.self, forKey: .uploading)
        progress = try c.decodeIfPresent(Double.self, forKey: .progress)
        error = try c.decodeIfPresent(String.self, forKey: .error)
    }
}

/// Settings, library and playlists, stored as JSON in ~/Library/Application Support/SpareKey.
/// Same structure as the Linux config, so files can be copied between machines.
public enum Store {
    public static let minInterval = 15
    public static let defaultInterval = 60
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
    public static var stateURL: URL { dir.appendingPathComponent("playlist-state.json") }
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
    public static func loadState() -> PlaylistState { read(stateURL, PlaylistState()) }
    public static func saveState(_ s: PlaylistState) { write(stateURL, s) }

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

    public static func savePlaylist(_ name: String, _ p: Playlist) {
        var pl = p
        pl.interval = max(minInterval, pl.interval)
        update { $0.playlists[name] = pl }
    }

    public static func deletePlaylist(_ name: String) {
        update { $0.playlists.removeValue(forKey: name) }
        if loadState().active == name { stopPlaylist() }
    }

    public static func renamePlaylist(_ old: String, _ new: String) {
        update { c in
            if let p = c.playlists[old], !new.isEmpty, c.playlists[new] == nil {
                c.playlists.removeValue(forKey: old)
                c.playlists[new] = p
            }
        }
        var st = loadState()
        if st.active == old { st.active = new; saveState(st) }
    }

    public static func startPlaylist(_ name: String) {
        var st = loadState()
        st.active = name; st.position = -1; st.bag = []; st.nextAt = 0
        saveState(st)
    }

    public static func stopPlaylist() {
        var st = loadState()
        st.active = nil; st.nextAt = nil
        saveState(st)
    }

    /// Same rules as store.next_item on Linux: loop in order, or shuffle without repeating the last GIF.
    public static func nextItem(_ p: Playlist, _ st: inout PlaylistState) -> String? {
        let items = p.items.filter { FileManager.default.fileExists(atPath: $0) }
        guard !items.isEmpty else { return nil }
        let item: String
        if p.order == "shuffle" {
            var bag = st.bag.filter { items.contains($0) }
            if bag.isEmpty {
                bag = items.shuffled()
                if bag.count > 1 && bag[0] == st.current { bag.append(bag.removeFirst()) }
            }
            item = bag.removeFirst()
            st.bag = bag
        } else {
            var pos = (st.position + 1) % items.count
            if items[pos] == st.current && items.count > 1 && st.position == -1 { pos = (pos + 1) % items.count }
            st.position = pos
            item = items[pos]
        }
        st.current = item
        return item
    }
}
