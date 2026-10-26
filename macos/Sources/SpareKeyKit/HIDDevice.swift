import Foundation
import IOKit
import IOKit.hid

public enum DeviceError: Error, LocalizedError {
    case notFound, notPermitted, openFailed(Int32), io(String), noAnswer(UInt8), busy, cancelled, stalled(Int)
    case outOfTurn(UInt8), emptyLayer(Int)

    public var errorDescription: String? {
        switch self {
        case .notFound: return "Keyboard not found. Plug in the USB cable, then choose USB in the keyboard screen's settings menu."
        case .notPermitted:
            return "macOS blocked access to the keyboard. Allow SpareKey under System Settings → Privacy & Security → "
                + "Input Monitoring, then reopen SpareKey."
        case .openFailed(let r): return String(format: "Couldn't open the keyboard (IOKit error 0x%08x).", r)
        case .io(let s): return "Talking to the keyboard failed: \(s). Was it unplugged?"
        case .noAnswer(let c): return "The keyboard didn't answer (cmd \(c)). Is USB selected in the keyboard screen's settings?"
        case .busy: return "The keyboard is busy (an upload is running)."
        case .cancelled: return "Upload cancelled."
        case .stalled(let f): return "The keyboard stopped responding during the upload (frame \(f))."
        case .outOfTurn(let c): return "The keyboard kept answering out of turn (cmd \(c)). Try again, or replug it."
        case .emptyLayer(let n): return "Refusing to write a base layer with only \(n) keys set."
        }
    }
}

/// One S98 vendor interface opened through IOKit. Not thread-safe: use from one queue
/// (SpareKeyKit.DeviceQueue does that for the app and the background service).
public final class S98Device {
    public static let vendorID = 0x258A
    public static let models: [Int: String] = [0x01AF: "RK S98"]
    public static var packetGap: TimeInterval = 0.02   // the keyboard paces itself through its acks

    let device: IOHIDDevice
    public let model: String
    private let inputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
    private var acks = [[UInt8]]()
    private let ackLock = NSCondition()
    private var runLoopThread: Thread?
    private var runLoop: CFRunLoop?
    public var verbose = false

    /// Vendor interfaces present (the HID interface that carries feature report 9).
    public static func find() -> [IOHIDDevice] {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatchingMultiple(manager, models.keys.map {
            [kIOHIDVendorIDKey: vendorID, kIOHIDProductIDKey: $0] as CFDictionary
        } as CFArray)
        guard let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return [] }
        return set.filter { dev in
            let size = IOHIDDeviceGetProperty(dev, kIOHIDMaxFeatureReportSizeKey as CFString) as? Int ?? 0
            return size >= S98.reportLength
        }
    }

    public static func requestAccess() -> Bool {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    public init() throws {
        guard let dev = S98Device.find().first else { throw DeviceError.notFound }
        device = dev
        let pid = IOHIDDeviceGetProperty(dev, kIOHIDProductIDKey as CFString) as? Int ?? 0x01AF
        model = S98Device.models[pid] ?? "RK keyboard"
        let r = IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone))
        if r == kIOReturnNotPermitted {
            _ = S98Device.requestAccess()
            throw DeviceError.notPermitted
        }
        guard r == kIOReturnSuccess else { throw DeviceError.openFailed(r) }
        startInputThread()
    }

    deinit {
        if let rl = runLoop {
            IOHIDDeviceUnscheduleFromRunLoop(device, rl, CFRunLoopMode.defaultMode.rawValue)
            CFRunLoopStop(rl)
        }
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        inputBuffer.deallocate()
    }

    private func startInputThread() {
        let ready = DispatchSemaphore(value: 0)
        let t = Thread { [weak self] in
            guard let self = self else { return }
            self.runLoop = CFRunLoopGetCurrent()
            let ctx = Unmanaged.passUnretained(self).toOpaque()
            IOHIDDeviceRegisterInputReportCallback(self.device, self.inputBuffer, 64, { ctx, _, _, _, reportID, report, length in
                guard let ctx = ctx else { return }
                let me = Unmanaged<S98Device>.fromOpaque(ctx).takeUnretainedValue()
                var bytes = Array(UnsafeBufferPointer(start: report, count: length))
                // IOKit includes the ID for numbered reports; normalise to "ID first" like hidraw
                if bytes.first != UInt8(truncatingIfNeeded: reportID) { bytes.insert(UInt8(truncatingIfNeeded: reportID), at: 0) }
                me.received(bytes)
            }, ctx)
            IOHIDDeviceScheduleWithRunLoop(self.device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
            ready.signal()
            CFRunLoopRun()
        }
        t.name = "sparekey-hid-input"
        t.start()
        runLoopThread = t
        ready.wait()
    }

    private func received(_ report: [UInt8]) {
        if verbose { print("IN ", report.map { String(format: "%02x", $0) }.joined(separator: " ")) }
        ackLock.lock()
        acks.append(report)
        ackLock.signal()
        ackLock.unlock()
    }

    // MARK: transport

    func setFeature(_ pkt: [UInt8]) throws {
        var buf = [UInt8](repeating: 0, count: S98.reportLength + 1)
        buf[0] = S98.reportID
        for (i, b) in pkt.enumerated() where i < S98.reportLength { buf[i + 1] = b }
        let r = buf.withUnsafeBufferPointer {
            IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, CFIndex(S98.reportID), $0.baseAddress!, $0.count)
        }
        if verbose { print("SET", buf[0..<16].map { String(format: "%02x", $0) }.joined(separator: " ")) }
        guard r == kIOReturnSuccess else { throw DeviceError.io(String(format: "set report 0x%08x", r)) }
    }

    func getFeature() throws -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: S98.reportLength + 1)
        buf[0] = S98.reportID
        var len = CFIndex(buf.count)
        let r = buf.withUnsafeMutableBufferPointer {
            IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, CFIndex(S98.reportID), $0.baseAddress!, &len)
        }
        guard r == kIOReturnSuccess else { throw DeviceError.io(String(format: "get report 0x%08x", r)) }
        // IOKit puts the report ID first and returns only what the keyboard sent: often far less than 520
        // bytes, a bare header when it has no data ready, or nothing. Strip the ID but don't pad, so
        // query() can tell a real answer from an empty one.
        var data = Array(buf[0..<max(0, min(len, buf.count))])
        if data.first == S98.reportID { data.removeFirst() } else { return [] }
        return data
    }

    func drain() {
        ackLock.lock()
        acks.removeAll()
        ackLock.unlock()
    }

    func waitAck(timeout: TimeInterval = 2.0) -> Bool? {
        let deadline = Date().addingTimeInterval(timeout)
        ackLock.lock()
        defer { ackLock.unlock() }
        while true {
            while !acks.isEmpty {
                let rep = acks.removeFirst()
                if let ok = S98.parseAck(rep) { return ok }
            }
            if !ackLock.wait(until: deadline) { return nil }
        }
    }

    /// Get command. The keyboard sometimes answers with a status packet (`0a 06 …`) or a bare header
    /// instead of the data, so only accept real answers (S98.isAnswer), and ask again otherwise.
    public func query(_ pkt: [UInt8], length: Int, attempts: Int = 6) throws -> [UInt8] {
        for _ in 0..<attempts {
            drain()
            try setFeature(pkt)
            let data = try getFeature()
            if S98.isAnswer(data, to: pkt, length: length) { return S98.parseGet(data, length: length) }
            Thread.sleep(forTimeInterval: 0.01)
        }
        throw DeviceError.outOfTurn(pkt[0])
    }

    /// Settings commands are acked with status 0; wait for it so commands never overlap.
    public func send(_ pkt: [UInt8]) throws {
        drain()
        try setFeature(pkt)
        if waitAck() == nil { throw DeviceError.noAnswer(pkt[0]) }
    }

    // MARK: commands

    public func firmware() throws -> String {
        let payload = try query(S98.getInfo(), length: 10)
        return S98.firmware(fromInfo: [UInt8](repeating: 0, count: 7) + payload)
    }

    public func profile() throws -> Profile { Profile(try query(S98.getProfile(), length: S98.profileLength)) }
    public func setProfile(_ p: Profile) throws { try send(S98.setProfile(p.buf)) }
    public func ledEffects() throws -> LedEffects { LedEffects(try query(S98.getLedEffect(), length: S98.ledEffectLength)) }
    public func setLedEffects(_ e: LedEffects) throws { try send(S98.setLedEffect(e.buf)) }
    public func keyColors() throws -> KeyColors { KeyColors(try query(S98.getLedColors(), length: S98.ledColorsLength)) }
    public func setKeyColors(_ c: KeyColors) throws { try send(S98.setLedColors(c.buf)) }

    public func keymatrix(table: Int, layer: Int) throws -> [UInt32] {
        S98.parseKeymatrix(try query(S98.getKeymatrix(table: table, layer: layer), length: S98.keymatrixLength))
    }

    public func setKeymatrix(table: Int, layer: Int, codes: [UInt32]) throws {
        let nonEmpty = codes.filter { $0 != 0 }.count
        // a base layer is ~100 real keys; anything emptier would disable typing
        if layer == 0 && nonEmpty < 80 { throw DeviceError.emptyLayer(nonEmpty) }
        try send(S98.setKeymatrix(table: table, layer: layer, codes: codes))
    }

    public func macrosBlob() throws -> [UInt8] {
        var out = [UInt8]()
        for i in 0..<(S98.macroLength / S98.macroChunk) { out += try query(S98.getMacros(chunk: i), length: S98.macroChunk) }
        return out
    }

    public func setMacrosBlob(_ blob: [UInt8]) throws { for p in S98.setMacros(blob) { try send(p) } }
    public func factoryReset() throws { try send(S98.factoryReset()) }
    public func syncClock(_ date: Date = Date()) throws { try send(S98.sysInfo(date: date)) }

    /// frames: RGB565BE (S98.frameBytes each). progress(done, total) is called on the calling queue.
    public func upload(frames: [[UInt8]], delayMs: Int, progress: ((Int, Int) -> Void)? = nil,
                       cancelled: (() -> Bool)? = nil) throws {
        let devDelay = S98.frameDelay(delayMs)
        drain()
        try setFeature(S98.tftCtrl(.start, frames: frames.count, delayMs: devDelay))
        _ = waitAck()
        var last = Date()
        let total = frames.reduce(0) { $0 + ($1.count + S98.tftChunk - 1) / S98.tftChunk }
        var done = 0
        for (fi, frame) in frames.enumerated() {
            let chunks = (frame.count + S98.tftChunk - 1) / S98.tftChunk
            for ci in 0..<chunks {
                if cancelled?() == true {
                    try? setFeature(S98.tftCtrl(.abort))
                    throw DeviceError.cancelled
                }
                let part = frame[(ci * S98.tftChunk)..<min(frame.count, (ci + 1) * S98.tftChunk)]
                let pkt = S98.tftChunk(frame: fi, index: ci, data: part)
                var ok = false
                for _ in 0..<6 {
                    let pause = S98Device.packetGap - Date().timeIntervalSince(last)
                    if pause > 0 { Thread.sleep(forTimeInterval: pause) }
                    try setFeature(pkt)
                    last = Date()
                    if waitAck() == true { ok = true; break }
                }
                if !ok {
                    try? setFeature(S98.tftCtrl(.abort))
                    throw DeviceError.stalled(fi + 1)
                }
                done += 1
                progress?(done, total)
            }
        }
        try setFeature(S98.tftCtrl(.finish, frames: frames.count, delayMs: devDelay))
    }

    // MARK: diagnostics

    /// `SpareKey --probe`: list the matching interfaces, then try both SET_REPORT framings
    /// (with and without the leading report ID) and dump what GET_REPORT returns.
    public static func probe() {
        func hex(_ b: ArraySlice<UInt8>) -> String { b.map { String(format: "%02x", $0) }.joined(separator: " ") }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: vendorID] as CFDictionary)
        let all = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []
        for dev in all {
            func prop(_ k: String) -> Int { IOHIDDeviceGetProperty(dev, k as CFString) as? Int ?? -1 }
            print(String(format: "device pid %04x usagePage %04x usage %04x maxIn %d maxOut %d maxFeature %d",
                         prop(kIOHIDProductIDKey), prop(kIOHIDPrimaryUsagePageKey), prop(kIOHIDPrimaryUsageKey),
                         prop(kIOHIDMaxInputReportSizeKey), prop(kIOHIDMaxOutputReportSizeKey),
                         prop(kIOHIDMaxFeatureReportSizeKey)))
        }
        let d: S98Device
        do { d = try S98Device() } catch { print("open failed: \(error.localizedDescription)"); return }
        d.verbose = true
        // read-only: every get command a few times; show the answer length, echoed header and how much is non-zero
        var gets: [(String, [UInt8])] = [("info", S98.getInfo()), ("profile", S98.getProfile()),
                                         ("ledEffect", S98.getLedEffect()), ("ledColors", S98.getLedColors()),
                                         ("macros0", S98.getMacros(chunk: 0))]
        for t in 0..<2 { for l in 0..<4 { gets.append(("keymatrix \(t)/\(l)", S98.getKeymatrix(table: t, layer: l))) } }
        for (name, pkt) in gets {
            for attempt in 0..<4 {
                d.drain()
                var out = [UInt8](repeating: 0, count: S98.reportLength + 1)
                out[0] = S98.reportID
                for (i, b) in pkt.enumerated() { out[i + 1] = b }
                let rs = out.withUnsafeBufferPointer {
                    IOHIDDeviceSetReport(d.device, kIOHIDReportTypeFeature, CFIndex(S98.reportID), $0.baseAddress!, $0.count)
                }
                var buf = [UInt8](repeating: 0, count: S98.reportLength + 1)
                buf[0] = S98.reportID
                var len = CFIndex(buf.count)
                let rg = buf.withUnsafeMutableBufferPointer {
                    IOHIDDeviceGetReport(d.device, kIOHIDReportTypeFeature, CFIndex(S98.reportID), $0.baseAddress!, &len)
                }
                let nz = buf[min(8, len)..<max(8, len)].filter { $0 != 0 }.count
                print(String(format: "%-14@ #%d set 0x%08x get 0x%08x len %3d nonzeroData %3d: ", name as NSString,
                             attempt, rs, rg, len, nz) + hex(buf[0..<12]))
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
    }
}

/// Serialises keyboard access within the process and, through a lock file, with the background service.
public final class DeviceQueue {
    public static let shared = DeviceQueue()
    private let queue = DispatchQueue(label: "sparekey.device")
    private let lockPath = NSTemporaryDirectory() + "sparekey-device.lock"

    public func run<T>(wait: Bool = true, _ body: @escaping (S98Device) throws -> T,
                       completion: @escaping (Result<T, Error>) -> Void) {
        queue.async {
            let result = Result { try self.runSync(wait: wait, body) }
            DispatchQueue.main.async { completion(result) }
        }
    }

    public func runSync<T>(wait: Bool = true, _ body: (S98Device) throws -> T) throws -> T {
        let fd = open(lockPath, O_CREAT | O_RDWR, 0o644)
        defer { if fd >= 0 { close(fd) } }
        if fd >= 0 && flock(fd, LOCK_EX | (wait ? 0 : LOCK_NB)) != 0 { throw DeviceError.busy }
        let dev = try S98Device()
        return try body(dev)
    }
}
