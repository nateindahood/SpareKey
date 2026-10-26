import Foundation

public struct Effect: Identifiable, Hashable {
    public let id: Int
    public let name: String
    public let hasSpeed: Bool
    public let hasBrightness: Bool
    public let hasColor: Bool
}

public enum Effects {
    public static let all: [Effect] = [
        Effect(id: 1, name: "Static", hasSpeed: false, hasBrightness: true, hasColor: true),
        Effect(id: 2, name: "Breathing", hasSpeed: true, hasBrightness: true, hasColor: true),
        Effect(id: 3, name: "Rainbow", hasSpeed: true, hasBrightness: true, hasColor: false),
        Effect(id: 4, name: "Flash away", hasSpeed: true, hasBrightness: true, hasColor: true),
        Effect(id: 5, name: "Raindrops", hasSpeed: true, hasBrightness: true, hasColor: true),
        Effect(id: 6, name: "Rainbow wheel", hasSpeed: true, hasBrightness: true, hasColor: false),
        Effect(id: 7, name: "Ripple shining", hasSpeed: true, hasBrightness: true, hasColor: true),
        Effect(id: 8, name: "Stars twinkle", hasSpeed: true, hasBrightness: true, hasColor: true),
        Effect(id: 9, name: "Shadow disappear", hasSpeed: true, hasBrightness: true, hasColor: true),
        Effect(id: 10, name: "Retro snake", hasSpeed: true, hasBrightness: true, hasColor: true),
        Effect(id: 11, name: "Neon stream", hasSpeed: true, hasBrightness: true, hasColor: true),
        Effect(id: 12, name: "Reaction", hasSpeed: true, hasBrightness: true, hasColor: true),
        Effect(id: 13, name: "Sine wave", hasSpeed: true, hasBrightness: true, hasColor: true),
        Effect(id: 14, name: "Side scan", hasSpeed: true, hasBrightness: true, hasColor: true),
        Effect(id: 15, name: "Rotating windmill", hasSpeed: true, hasBrightness: true, hasColor: true),
        Effect(id: 16, name: "Colourful waterfall", hasSpeed: true, hasBrightness: true, hasColor: false),
        Effect(id: 17, name: "Blossoming", hasSpeed: true, hasBrightness: true, hasColor: true),
        Effect(id: 18, name: "Custom (per key)", hasSpeed: false, hasBrightness: false, hasColor: false),
        Effect(id: 0, name: "Off", hasSpeed: false, hasBrightness: false, hasColor: false),
    ]
    public static let custom = 18
    public static func byID(_ id: Int) -> Effect? { all.first { $0.id == id } }
}

public struct RGB: Hashable, Codable {
    public var r: UInt8, g: UInt8, b: UInt8
    public init(_ r: UInt8, _ g: UInt8, _ b: UInt8) { self.r = r; self.g = g; self.b = b }
    public var isBlack: Bool { r == 0 && g == 0 && b == 0 }
}

/// The 128-byte profile block (see PROTOCOL.md).
public struct Profile {
    public var buf: [UInt8]
    public static let brightnessLevels: [UInt8] = [0, 4, 8, 12, 16, 20]
    static let ledParamBase = 56, mix: UInt8 = 7

    public init(_ buf: [UInt8]) { precondition(buf.count == S98.profileLength); self.buf = buf }

    public var effect: Int {
        get { Int(buf[10]) }
        set { buf[10] = UInt8(newValue); buf[9] = newValue == Effects.custom ? 1 : 0 }
    }

    public struct LedParam: Equatable { public var brightness: Int; public var speed: Int; public var mix: Bool }

    public func ledParam(_ effect: Int? = nil) -> LedParam {
        let e = effect ?? self.effect
        if e > 17 { return LedParam(brightness: Int(buf[6]), speed: Int(buf[7]), mix: false) }
        let o = Profile.ledParamBase + e * 2
        return LedParam(brightness: Int(buf[o]), speed: Int(buf[o + 1] >> 4), mix: (buf[o + 1] & 15) == Profile.mix)
    }

    public mutating func setLedParam(_ effect: Int? = nil, brightness: Int? = nil, speed: Int? = nil, mix: Bool? = nil) {
        let e = effect ?? self.effect
        guard e <= 17 else { return }
        let o = Profile.ledParamBase + e * 2
        if let b = brightness { buf[o] = UInt8(max(0, min(20, b))) }
        var sp = buf[o + 1] >> 4, col = buf[o + 1] & 15
        if let s = speed { sp = UInt8(max(0, min(4, s))) }
        if let m = mix { col = m ? Profile.mix : 0 }
        buf[o + 1] = sp << 4 | col
    }

    public static func level(for brightness: Int) -> Int {
        var best = 0
        for (i, v) in brightnessLevels.enumerated() where abs(Int(v) - brightness) < abs(Int(brightnessLevels[best]) - brightness) {
            best = i
        }
        return best
    }

    public var sleepMinutes: Double {
        get { Double(buf[24]) * 30 / 60 }
        set { buf[24] = UInt8(max(0, min(255, (newValue * 60 / 30).rounded()))) }
    }
    public var winLock: Bool { get { buf[15] != 0 } set { buf[15] = newValue ? 1 : 0 } }
    public var wasdSwap: Bool { get { buf[17] != 0 } set { buf[17] = newValue ? 1 : 0 } }
}

/// 20 effects x 21 bytes; the first RGB triple is the effect's colour.
public struct LedEffects {
    public var buf: [UInt8]
    public init(_ buf: [UInt8]) { precondition(buf.count == S98.ledEffectLength); self.buf = buf }
    public func color(_ effect: Int) -> RGB {
        let o = effect * 21
        guard o + 2 < buf.count else { return RGB(255, 255, 255) }
        return RGB(buf[o], buf[o + 1], buf[o + 2])
    }
    public mutating func setColor(_ effect: Int, _ c: RGB) {
        let o = effect * 21
        guard o + 2 < buf.count else { return }
        buf[o] = c.r; buf[o + 1] = c.g; buf[o + 2] = c.b
    }
}

/// Per-key colours, planar R[126] G[126] B[126].
public struct KeyColors {
    public var buf: [UInt8]
    public init(_ buf: [UInt8]) { precondition(buf.count == S98.ledColorsLength); self.buf = buf }
    public func get(_ i: Int) -> RGB { RGB(buf[i], buf[i + S98.keys], buf[i + 2 * S98.keys]) }
    public mutating func set(_ i: Int, _ c: RGB) { buf[i] = c.r; buf[i + S98.keys] = c.g; buf[i + 2 * S98.keys] = c.b }
}
