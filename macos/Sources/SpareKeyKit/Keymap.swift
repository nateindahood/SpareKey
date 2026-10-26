import Foundation

public struct LayoutKey: Codable, Hashable, Identifiable {
    public let label: String
    public let x: Double, y: Double, w: Double, h: Double
    public let index: Int
    public var id: Int { index }
}

public struct MacroStep: Codable, Hashable {
    public var up: Bool
    public var type: Int     // 0 key, 1 modifier, 2 mouse
    public var key: Int
    public var delay: Int
    public init(up: Bool, type: Int, key: Int, delay: Int) { self.up = up; self.type = type; self.key = key; self.delay = delay }
}

public struct Macro: Codable, Hashable {
    public var name: String
    public var steps: [MacroStep]
    public init(name: String, steps: [MacroStep] = []) { self.name = name; self.steps = steps }
}

/// Key codes, layout, defaults and macro encoding. Mirrors src/sparekey/keymap.py.
public enum Keymap {
    public static let layers = ["Base", "FN", "FN2", "Tap"]
    public static let macroType: UInt32 = 3

    struct KeymapFile: Decodable { let keycodes: [String: Int]; let defaults: [String: [[UInt32]]] }
    struct LayoutFile: Decodable { let keys: [LayoutKey] }

    static let file: KeymapFile = load("keymap")
    public static let layout: [LayoutKey] = (load("layout_s98") as LayoutFile).keys.filter { $0.w > 0 }
    public static let codes: [String: UInt32] = file.keycodes.filter { !$0.key.hasPrefix("SP_TEST") }.mapValues { UInt32($0) }
    public static let names: [UInt32: String] = {
        var out = [UInt32: String]()
        for (name, value) in codes.sorted(by: { $0.key < $1.key }) where out[value] == nil { out[value] = name }
        return out
    }()

    static func load<T: Decodable>(_ name: String) -> T {
        let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Data")!
        return try! JSONDecoder().decode(T.self, from: Data(contentsOf: url))
    }

    public static func defaults(table: Int, layer: Int) -> [UInt32] { file.defaults[table == 1 ? "mac" : "win"]![layer] }

    public static func pretty(_ name: String) -> String {
        var n = name
        for p in ["KEY_", "SP_", "MAC_"] where n.hasPrefix(p) { n = String(n.dropFirst(p.count)); break }
        for (k, v) in [("L_", "Left "), ("R_", "Right "), ("NUM_", "Num "), ("LED_", "Light "), ("Fn1", "FN")] {
            n = n.replacingOccurrences(of: k, with: v)
        }
        return n.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces)
    }

    public static func describe(_ action: UInt32) -> String {
        if action == 0 { return "(default)" }
        if action >> 24 == macroType { return "Macro \((action & 0xFFFF) + 1)" }
        if let n = names[action] { return pretty(n) }
        return String(format: "0x%08x", action)
    }

    static let types: Set<UInt32> = Set(codes.values.map { $0 >> 24 }).union([0, macroType])

    public static func macroAction(_ n: Int) -> UInt32 { macroType << 24 | UInt32(n) }

    public static let assignable: [(label: String, action: UInt32)] = codes
        .filter { $0.value != 0 && !$0.key.hasPrefix("KEY_CODE") && !$0.key.hasPrefix("SP_BT") }
        .map { (pretty($0.key), $0.value) }
        .sorted { ($0.action >> 24, $0.label.lowercased()) < ($1.action >> 24, $1.label.lowercased()) }

    /// Vendor default, then the readable part from the keyboard (first 62 keys), then the user's edits.
    public static func mergedMatrix(table: Int, layer: Int, fromDevice: [UInt32]?, overrides: [Int: UInt32]) -> [UInt32] {
        var out = defaults(table: table, layer: layer)
        if let dev = fromDevice, dev.count >= 62 {
            let head = Array(dev[0..<62])
            // the Mac table reads back as all zeros although it works: empty where the default isn't = no read
            let unread = !head.contains { $0 != 0 } && out[0..<62].contains { $0 != 0 }
            // Some layers read back as random memory. Real actions always have a known type byte, even
            // ones missing from the vendor's key list (the S98's FN+1 is 0x08091300), so check types.
            if !unread && head.allSatisfy({ types.contains($0 >> 24) }) {
                out.replaceSubrange(0..<62, with: head)
            }
        }
        for (i, a) in overrides where i >= 0 && i < out.count { out[i] = a }
        return out
    }

    // MARK: macros

    public static func encodeStep(_ s: MacroStep) -> [UInt8] {
        let d = max(0, min(0xFFFFF, s.delay))
        return [UInt8((s.up ? 1 : 0) << 7 | (s.type & 7) << 4 | d >> 16), UInt8((d >> 8) & 0xFF), UInt8(d & 0xFF),
                UInt8(s.key & 0xFF)]
    }

    public static func decodeStep(_ b: ArraySlice<UInt8>) -> MacroStep {
        let a = Array(b)
        return MacroStep(up: a[0] >> 7 == 1, type: Int((a[0] >> 4) & 7),
                         key: Int(a[3]), delay: Int(a[0] & 15) << 16 | Int(a[1]) << 8 | Int(a[2]))
    }

    public enum MacroError: Error, LocalizedError {
        case tooLong(Int)
        public var errorDescription: String? {
            if case .tooLong(let n) = self { return "Macros too long (\(n) bytes, the keyboard holds 4096)" }
            return nil
        }
    }

    public static func encodeMacros(_ macros: [Macro]) throws -> [UInt8] {
        var bodies = [[UInt8]]()
        for m in macros {
            var name = [UInt8]()
            for u in m.name.utf16 { name += [UInt8(u & 0xFF), UInt8(u >> 8)] }
            if name.count > 254 { name = Array(name[0..<254]) }
            var body: [UInt8] = [UInt8(name.count)] + name
            for s in m.steps { body += encodeStep(s) }
            bodies.append(body)
        }
        var head = [UInt8](), off = 4 * bodies.count
        for b in bodies {
            head += [UInt8(off & 0xFF), UInt8(off >> 8), UInt8(b.count & 0xFF), UInt8(b.count >> 8)]
            off += b.count
        }
        let blob = head + bodies.flatMap { $0 }
        if blob.count > S98.macroLength { throw MacroError.tooLong(blob.count) }
        return blob
    }

    public static func decodeMacros(_ blob: [UInt8]) -> [Macro] {
        guard blob.count >= 4 else { return [] }
        let first = Int(blob[0]) | Int(blob[1]) << 8
        guard first != 0, first % 4 == 0, first <= blob.count else { return [] }
        var out = [Macro]()
        for i in 0..<(first / 4) {
            let off = Int(blob[i * 4]) | Int(blob[i * 4 + 1]) << 8
            let len = Int(blob[i * 4 + 2]) | Int(blob[i * 4 + 3]) << 8
            guard off + len <= blob.count, len >= 1 else { continue }
            let body = Array(blob[off..<(off + len)])
            let nlen = Int(body[0])
            guard 1 + nlen <= body.count else { continue }
            var units = [UInt16]()
            for j in stride(from: 1, to: nlen, by: 2) { units.append(UInt16(body[j]) | UInt16(body[j + 1]) << 8) }
            let name = String(decoding: units, as: UTF16.self)
            var steps = [MacroStep]()
            for k in stride(from: 1 + nlen, to: body.count - 3, by: 4) {
                steps.append(decodeStep(body[k..<(k + 4)]))
            }
            out.append(Macro(name: name, steps: steps))
        }
        return out
    }

    public static let modifiers: [Int: String] = [224: "Left Ctrl", 225: "Left Shift", 226: "Left Alt", 227: "Left Cmd",
                                                  228: "Right Ctrl", 229: "Right Shift", 230: "Right Alt", 231: "Right Cmd"]
    public static let mouse: [Int: String] = [1: "Mouse left", 2: "Mouse right", 4: "Mouse middle", 8: "Mouse back",
                                              16: "Mouse forward"]

    public static func describe(_ s: MacroStep) -> String {
        let what: String
        switch s.type {
        case 1: what = modifiers[s.key] ?? "Mod \(s.key)"
        case 2: what = mouse[s.key] ?? "Mouse \(s.key)"
        default: what = names[UInt32(s.key)].map(pretty) ?? String(format: "0x%02x", s.key)
        }
        return "\(s.up ? "Release" : "Press") \(what), then wait \(s.delay) ms"
    }
}
