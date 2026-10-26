import Foundation
import XCTest
@testable import SpareKeyKit

/// Checks the Swift implementation against the byte-exact examples generated from the Linux
/// implementation (spec/vectors, made by tests/make_vectors.py). Run: swift test
final class VectorTests: XCTestCase {
    static let specDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("spec/vectors")

    func json(_ name: String) throws -> [String: Any] {
        let data = try Data(contentsOf: Self.specDir.appendingPathComponent(name))
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }
    func unhex(_ s: String) -> [UInt8] {
        var out = [UInt8](), chars = Array(s), i = 0
        while i + 1 < chars.count { out.append(UInt8(String(chars[i...i + 1]), radix: 16)!); i += 2 }
        return out
    }

    func testPackets() throws {
        let list = try json("packets.json")["packets"] as! [[String: Any]]
        var byName = [String: [String: Any]]()
        for p in list { byName[p["name"] as! String] = p }
        func expect(_ name: String, _ got: [UInt8], file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertEqual(hex(got), byName[name]!["hex"] as! String, name, file: file, line: line)
        }
        func args(_ name: String) -> [String: Any] { byName[name]!["args"] as? [String: Any] ?? [:] }

        expect("get_info", S98.getInfo())
        expect("get_profile", S98.getProfile(0))
        expect("set_profile", S98.setProfile(unhex(args("set_profile")["payload"] as! String), 1))
        expect("get_led_effect", S98.getLedEffect(0))
        expect("get_led_colors", S98.getLedColors(0))
        expect("get_keymatrix", S98.getKeymatrix(table: 1, layer: 2))
        let codes = (args("set_keymatrix")["codes"] as! [NSNumber]).map { $0.uint32Value }
        expect("set_keymatrix", S98.setKeymatrix(table: 0, layer: 1, codes: codes))
        expect("get_macros", S98.getMacros(chunk: 3))
        expect("factory_reset", S98.factoryReset())
        expect("sysinfo", S98.sysInfo(year: 2026, month: 10, day: 25, hour: 21, minute: 50, second: 43, weekday: 0))
        expect("tft_start", S98.tftCtrl(.start, frames: 39, delayMs: S98.frameDelay(100)))
        expect("tft_finish", S98.tftCtrl(.finish, frames: 39, delayMs: 75))
        expect("tft_abort", S98.tftCtrl(.abort))
        let chunk = unhex(args("tft_chunk")["data"] as! String)
        expect("tft_chunk", S98.tftChunk(frame: 2, index: 214, data: chunk[...]))
    }

    func testModels() throws {
        let m = try json("models.json")
        let px = m["rgb565be"] as! [String: String]
        XCTAssertEqual(hex(S98.rgb565be(unhex(px["rgb"]!))), px["out"]!)
        for pair in m["frame_delay"] as! [[Int]] { XCTAssertEqual(S98.frameDelay(pair[0]), pair[1]) }
        for c in m["pick_frames"] as! [[String: Any]] {
            let got = S98.pickFrames(c["durations"] as! [Int], maxFrames: c["max_frames"] as! Int)
            XCTAssertEqual(got.indices, c["indices"] as! [Int], "\(c["durations"]!)")
            XCTAssertEqual(got.ms, c["ms"] as! Int)
        }

        var prof = Profile([UInt8](repeating: 0, count: 128))
        prof.effect = 9
        prof.setLedParam(9, brightness: 12, speed: 3, mix: true)
        prof.sleepMinutes = 5
        prof.winLock = true
        XCTAssertEqual(hex(prof.buf), (m["profile_edit"] as! [String: Any])["out"] as! String)

        var fx = LedEffects([UInt8](repeating: 0, count: 420))
        fx.setColor(9, RGB(1, 2, 3))
        XCTAssertEqual(hex(fx.buf), (m["led_effect_color"] as! [String: Any])["out"] as! String)

        var kc = KeyColors([UInt8](repeating: 0, count: 378))
        kc.set(5, RGB(10, 20, 30))
        XCTAssertEqual(hex(kc.buf), (m["key_color"] as! [String: Any])["out"] as! String)

        for a in m["ack"] as! [[String: Any]] {
            let got = S98.parseAck(unhex(a["report"] as! String))
            if a["ok"] is NSNull { XCTAssertNil(got) } else { XCTAssertEqual(got, a["ok"] as? Bool) }
        }

        let km = m["keymatrix_parse"] as! [String: Any]
        XCTAssertEqual(S98.parseKeymatrix(unhex(km["data"] as! String)), (km["codes"] as! [NSNumber]).map { $0.uint32Value })
    }

    func testMacros() throws {
        let m = try json("models.json")["macros"] as! [String: Any]
        let data = try JSONSerialization.data(withJSONObject: m["macros"]!)
        let macros = try JSONDecoder().decode([Macro].self, from: data)
        let blob = try Keymap.encodeMacros(macros)
        XCTAssertEqual(hex(blob), m["blob"] as! String)
        XCTAssertEqual(Keymap.decodeMacros(blob + [UInt8](repeating: 0, count: 64)), macros)
        let packets = try json("packets.json")["packets"] as! [[String: Any]]
        let expected = packets.filter { ($0["name"] as! String).hasPrefix("set_macros") }.map { $0["hex"] as! String }
        XCTAssertEqual(S98.setMacros(blob).map(hex), expected)
    }

    func testKeymapMerge() {
        var dev = [UInt32](repeating: 0, count: 126)
        dev[0] = 0x29
        let merged = Keymap.mergedMatrix(table: 0, layer: 0, fromDevice: dev, overrides: [79: Keymap.macroAction(0)])
        XCTAssertEqual(merged[0], 0x29)
        XCTAssertEqual(merged[79], Keymap.macroAction(0))
        XCTAssertEqual(merged[81], Keymap.defaults(table: 0, layer: 0)[81])
        XCTAssertEqual(Keymap.mergedMatrix(table: 1, layer: 3, fromDevice: [UInt32](repeating: 0x900BA6E0, count: 126),
                                           overrides: [:]), Keymap.defaults(table: 1, layer: 3))
        XCTAssertEqual(Keymap.mergedMatrix(table: 1, layer: 0, fromDevice: [UInt32](repeating: 0, count: 126),
                                           overrides: [:]), Keymap.defaults(table: 1, layer: 0))
        XCTAssertEqual(Keymap.layout.count, 98)
    }
}
