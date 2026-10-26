import Foundation

/// S98 wire format: pure packet builders and parsers. Mirrors src/sparekey/protocol.py;
/// spec/PROTOCOL.md describes it and spec/vectors/ checks both against the same bytes.
public enum S98 {
    public static let reportID: UInt8 = 9
    public static let reportLength = 519
    public static let headerLength = 7

    public static let screenWidth = 320
    public static let screenHeight = 172
    public static let frameBytes = screenWidth * screenHeight * 2
    public static let tftChunk = 512
    public static let maxFrames = 60

    public static let keys = 126
    public static let profileLength = 128
    public static let ledEffectLength = 420
    public static let ledColorsLength = 378
    public static let keymatrixLength = 504
    public static let macroLength = 4096
    public static let macroChunk = 512

    public enum Cmd: UInt8 {
        case setKeymatrix = 3, setProfile = 4, setMacros = 5, setLedColors = 6
        case setLedEffect = 10, setSysInfo = 11, tftData = 12, tftCtrl = 13, factoryReset = 17
        case getInfo = 130, getKeymatrix = 131, getProfile = 132, getMacros = 133
        case getLedColors = 134, getLedEffect = 138
    }

    public enum TFTMode: UInt8 { case finish = 0, start = 1, abort = 2 }

    public static func packet(_ cmd: Cmd, arg1: UInt8 = 0, arg2: UInt8 = 0, count: UInt8 = 1, index: UInt8 = 0,
                              payload: [UInt8] = [], length: Int? = nil) -> [UInt8] {
        let n = length ?? payload.count
        return [cmd.rawValue, arg1, arg2, count, index, UInt8(n & 0xFF), UInt8(n >> 8)] + payload
    }

    /// Shortest payload a real answer carries. Firmware 0001 cuts answers off after 164–248 data bytes,
    /// but blocks up to this size (profile, info) always arrive whole.
    public static let minAnswerPayload = 128

    /// A real answer echoes the whole 7-byte header and carries data. A bare header (no data ready)
    /// or a status packet must never be read as an all-zero block: writing that back blanks the settings.
    public static func isAnswer(_ data: [UInt8], to pkt: [UInt8], length: Int) -> Bool {
        guard data.count >= headerLength + min(length, minAnswerPayload),
              data.count > headerLength, pkt.count >= headerLength else { return false }
        return Array(data[0..<headerLength]) == Array(pkt[0..<headerLength])
    }

    public static func parseGet(_ data: [UInt8], length: Int) -> [UInt8] {
        let end = min(data.count, headerLength + length)
        guard end > headerLength else { return [UInt8](repeating: 0, count: length) }
        var out = Array(data[headerLength..<end])
        if out.count < length { out += [UInt8](repeating: 0, count: length - out.count) }
        return out
    }

    /// report = input report including the report ID. true = ok (status 1), false = other status, nil = not an ack.
    public static func parseAck(_ report: [UInt8]) -> Bool? {
        guard report.count >= 4, report[0] == reportID, report[2] == 0x06 else { return nil }
        return report[3] == 1
    }

    public static func getInfo() -> [UInt8] { packet(.getInfo, arg1: 1, length: 10) }

    public static func firmware(fromInfo data: [UInt8]) -> String {
        guard data.count > 16 else { return "?" }
        return String(format: "%02x%02x", data[15], data[16])
    }

    public static func getProfile(_ p: Int = 0) -> [UInt8] { packet(.getProfile, arg2: UInt8(p & 3), length: profileLength) }
    public static func setProfile(_ buf: [UInt8], _ p: Int = 0) -> [UInt8] { packet(.setProfile, arg2: UInt8(p & 3), payload: buf) }
    public static func getLedEffect(_ p: Int = 0) -> [UInt8] { packet(.getLedEffect, arg2: UInt8(p & 3), length: ledEffectLength) }
    public static func setLedEffect(_ buf: [UInt8], _ p: Int = 0) -> [UInt8] { packet(.setLedEffect, arg2: UInt8(p & 3), payload: buf) }
    public static func getLedColors(_ p: Int = 0) -> [UInt8] { packet(.getLedColors, arg2: UInt8(p & 3), length: ledColorsLength) }
    public static func setLedColors(_ buf: [UInt8], _ p: Int = 0) -> [UInt8] { packet(.setLedColors, arg2: UInt8(p & 3), payload: buf) }

    public static func getKeymatrix(table: Int, layer: Int) -> [UInt8] {
        packet(.getKeymatrix, arg1: UInt8((table << 2) | layer), length: keymatrixLength)
    }

    public static func setKeymatrix(table: Int, layer: Int, codes: [UInt32]) -> [UInt8] {
        precondition(codes.count == keys)
        var payload = [UInt8]()
        payload.reserveCapacity(keymatrixLength)
        for c in codes { payload += [UInt8(c >> 24), UInt8((c >> 16) & 0xFF), UInt8((c >> 8) & 0xFF), UInt8(c & 0xFF)] }
        return packet(.setKeymatrix, arg1: UInt8((table << 2) | layer), payload: payload)
    }

    public static func parseKeymatrix(_ data: [UInt8]) -> [UInt32] {
        (0..<keys).map { i in
            let o = i * 4
            guard o + 3 < data.count else { return 0 }
            return UInt32(data[o]) << 24 | UInt32(data[o + 1]) << 16 | UInt32(data[o + 2]) << 8 | UInt32(data[o + 3])
        }
    }

    public static func getMacros(chunk: Int) -> [UInt8] { packet(.getMacros, count: 1, index: UInt8(chunk), length: macroChunk) }

    public static func setMacros(_ blob: [UInt8]) -> [[UInt8]] {
        let count = max(1, (blob.count + macroChunk - 1) / macroChunk)
        return (0..<count).map { i in
            let part = Array(blob[min(blob.count, i * macroChunk)..<min(blob.count, (i + 1) * macroChunk)])
            return packet(.setMacros, count: UInt8(count), index: UInt8(i), payload: part)
        }
    }

    public static func factoryReset() -> [UInt8] { packet(.factoryReset, payload: [0]) }

    /// weekday: 0 = Sunday.
    public static func sysInfo(year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int, weekday: Int,
                               volume: UInt8 = 0, cpu: UInt8 = 0, mem: UInt8 = 0) -> [UInt8] {
        let payload: [UInt8] = [volume, cpu, mem, UInt8(year & 0xFF), UInt8(year >> 8), UInt8(month), UInt8(day),
                                UInt8(hour), UInt8(minute), UInt8(second), UInt8(weekday), 0, 0, 0]
        return packet(.setSysInfo, payload: payload)
    }

    public static func sysInfo(date: Date = Date(), calendar: Calendar = .current) -> [UInt8] {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .weekday], from: date)
        return sysInfo(year: c.year!, month: c.month!, day: c.day!, hour: c.hour!, minute: c.minute!,
                       second: c.second!, weekday: (c.weekday! - 1) % 7)
    }

    public static func tftCtrl(_ mode: TFTMode, frames: Int = 0, delayMs: Int = 0) -> [UInt8] {
        packet(.tftCtrl, payload: [mode.rawValue << 6, UInt8(frames), 0, UInt8(delayMs & 0xFF), UInt8(delayMs >> 8)])
    }

    public static func tftChunk(frame: Int, index: Int, data: ArraySlice<UInt8>) -> [UInt8] {
        var p = [UInt8](repeating: 0, count: headerLength)
        p[0] = Cmd.tftData.rawValue
        p[2] = UInt8(frame)
        p[3] = UInt8(index & 0xFF)
        p[4] = UInt8(data.reduce(0) { ($0 + Int($1)) & 0xFF })
        p[5] = UInt8(data.count & 0xFF)
        p[6] = UInt8(data.count >> 8)
        p += data
        return p
    }

    /// The S98 needs this long to draw one frame (DrawFrameTime in the vendor's model file).
    public static let drawMs = 180

    /// Extra wait to send for a frame shown `ms` long: the keyboard adds its own draw time on top.
    public static func frameDelay(_ ms: Int) -> Int { max(0, ms - drawMs) }

    /// Which frames to send, and how long each is shown, so the animation keeps its real speed.
    /// Like the Windows app: a GIF faster than the draw time is thinned out evenly in time
    /// (GIFs of 6 frames or fewer are sent whole). Mirrors protocol.pick_frames.
    public static func pickFrames(_ durations: [Int], maxFrames: Int = S98.maxFrames, drawMs: Int = S98.drawMs) -> (indices: [Int], ms: Int) {
        let n = durations.count
        guard n > 0 else { return ([], drawMs) }
        let total = durations.reduce(0, +)
        var k = min(n, maxFrames)
        if n > 6 { k = max(1, min(k, Int((Double(total) / Double(drawMs)).rounded(.toNearestOrEven)))) }
        var starts = [Int](), t = 0
        for d in durations { starts.append(t); t += d }
        var idx = [Int](), j = 0
        for i in 0..<k {
            let at = Double(i) * Double(total) / Double(k)
            while j + 1 < n && Double(starts[j + 1]) <= at { j += 1 }
            idx.append(j)
        }
        return (idx, max(drawMs, Int((Double(total) / Double(k)).rounded(.toNearestOrEven))))
    }

    /// Packed RGB888 -> RGB565 big-endian.
    public static func rgb565be(_ rgb: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: rgb.count / 3 * 2)
        var j = 0
        var i = 0
        while i + 2 < rgb.count {
            let v = UInt16(rgb[i] >> 3) << 11 | UInt16(rgb[i + 1] >> 2) << 5 | UInt16(rgb[i + 2] >> 3)
            out[j] = UInt8(v >> 8)
            out[j + 1] = UInt8(v & 0xFF)
            j += 2
            i += 3
        }
        return out
    }
}
