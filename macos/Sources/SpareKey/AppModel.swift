import AppKit
import ImageIO
import Foundation
import SpareKeyKit
import SwiftUI

final class AppModel: ObservableObject {
    @Published var connected = false
    @Published var model = ""
    @Published var firmware = ""
    @Published var busy: String?
    @Published var status = ""
    @Published var error: String?

    @Published var profile = Profile([UInt8](repeating: 0, count: S98.profileLength))
    @Published var effects = LedEffects([UInt8](repeating: 0, count: S98.ledEffectLength))
    @Published var keyColors = KeyColors([UInt8](repeating: 0, count: S98.ledColorsLength))
    @Published var macros: [Macro] = []
    // "Try it out" boxes on the Lighting and Keys pages: kept while the app runs, never saved
    @Published var lightingTryText = ""
    @Published var keysTryText = ""

    @Published var library: [URL] = []
    /// Frame count and a small thumbnail per library file, worked out once (not on every redraw).
    @Published var libraryInfo: [URL: LibraryItem] = [:]
    struct LibraryItem { let frames: Int; let thumb: NSImage? }
    @Published var config = Store.loadConfig()
    @Published var uploadProgress: Double?
    @Published var uploadText = ""
    var cancelUpload = false

    private var lightWork: DispatchWorkItem?

    init() {
        Service.replaceOldAgent(executable: Bundle.main.executablePath ?? CommandLine.arguments[0])
        refreshLibrary()
        refresh()
    }

    // MARK: device plumbing

    func run<T>(_ text: String?, _ body: @escaping (S98Device) throws -> T, failed: (() -> Void)? = nil,
                done: ((T) -> Void)? = nil) {
        busy = text
        if let t = text { status = t }
        DeviceQueue.shared.run(body) { [weak self] result in
            guard let self = self else { return }
            self.busy = nil
            switch result {
            case .success(let v):
                self.error = nil
                done?(v)
            case .failure(let e):
                self.error = e.localizedDescription
                self.status = ""
                failed?()
            }
        }
    }

    /// A settings change, keeping a copy of the original settings first.
    func change(_ text: String, _ body: @escaping (S98Device) throws -> Void) {
        run(text, { d in try Keyboard.ensureFirstBackup(d); try body(d) }) { [weak self] _ in
            self?.status = text.replacingOccurrences(of: "…", with: "") + " — done."
        }
    }

    func refresh() {
        run("Reading the keyboard…", { d -> (String, String, Profile, LedEffects, KeyColors, [Macro]) in
            // per-key colors and macros often can't be read; show them empty rather than fail
            var colors = (try? d.keyColors()) ?? KeyColors([UInt8](repeating: 0, count: S98.ledColorsLength))
            if !colors.buf.contains(where: { $0 != 0 }), let saved = Store.loadConfig().keyColors {
                let b = Keyboard.unhex(saved)   // the keyboard can't report them: use the ones last sent from here
                if b.count == S98.ledColorsLength { colors = KeyColors(b) }
            }
            return (d.model, try d.firmware(), try d.profile(), try d.ledEffects(), colors,
                    Keymap.decodeMacros((try? d.macrosBlob()) ?? []))
        }) { [weak self] r in
            guard let self = self else { return }
            (self.model, self.firmware, self.profile, self.effects, self.keyColors, _) = r
            self.macros = Store.loadConfig().macros ?? r.5
            self.connected = true
            self.status = "Connected."
        }
    }

    // MARK: library & upload

    func refreshLibrary() {
        let urls = Store.library()
        library = urls
        config = Store.loadConfig()
        let known = libraryInfo
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var info = [URL: LibraryItem]()
            for u in urls { info[u] = known[u] ?? LibraryItem(frames: Media.frameCount(u), thumb: thumbnail(u)) }
            DispatchQueue.main.async { self?.libraryInfo = info }
        }
    }

    func addFiles(_ urls: [URL]) {
        var added = 0
        for u in urls where Store.isMedia(u) {
            if (try? Store.addToLibrary(u)) != nil { added += 1 }
        }
        refreshLibrary()
        status = "Added \(added) file(s) to your library."
    }

    func upload(_ url: URL, fit: Fit) {
        guard uploadProgress == nil else {
            error = "An upload is already running. Wait for it to finish, or press Cancel."
            return
        }
        cancelUpload = false
        uploadProgress = 0
        uploadText = "Converting…"
        let start = Date()
        let name = url.lastPathComponent
        run("Sending \(name)…", { [weak self] d in
            try Keyboard.upload(d, url, fit: fit, progress: { done, total in
                let el = Date().timeIntervalSince(start)
                let left = el / Double(done) * Double(total - done)
                DispatchQueue.main.async {
                    self?.uploadProgress = Double(done) / Double(total)
                    self?.uploadText = "Sending \(done * 100 / total)% — about \(minutes(left)) left"
                }
            }, canceled: { [weak self] in self?.cancelUpload ?? false })
        }, failed: { [weak self] in self?.uploadProgress = nil; self?.uploadText = "" }) { [weak self] _ in
            self?.uploadText = "Sent \(name)"
            self?.uploadProgress = nil
        }
    }

    // MARK: lighting

    /// The color and "Mixed colors" choice the user last had, carried to the next effect they try.
    var carry: (color: RGB, mix: Bool)?

    func setEffect(_ id: Int) {
        profile.effect = id
        var sendColor = false
        if let c = carry, Effects.byID(id)?.hasColor == true {
            profile.setLedParam(id, mix: c.mix)
            if effects.color(id) != c.color {
                effects.setColor(id, c.color)
                sendColor = true
            }
        }
        let p = profile, fx = effects
        change("Lighting: \(Effects.byID(id)?.name ?? "")…") { d in
            try d.setProfile(p)
            if sendColor { try d.setLedEffects(fx) }
        }
    }

    /// Debounced like the Linux GUI: sliders send 350 ms after they stop moving.
    func lightingChanged(level: Int, speed: Int, mix: Bool, color: RGB?) {
        let e = profile.effect
        profile.setLedParam(e, brightness: Int(Profile.brightnessLevels[level]), speed: speed, mix: color != nil ? false : mix)
        if let c = color { effects.setColor(e, c) }
        if Effects.byID(e)?.hasColor == true { carry = (effects.color(e), color != nil ? false : mix) }
        let p = profile, fx = effects, sendColor = color != nil
        lightWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.change("Updating lighting…") { d in
                try d.setProfile(p)
                if sendColor { try d.setLedEffects(fx) }
            }
        }
        lightWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    func sendKeyColors() {
        let c = keyColors
        Store.update { $0.keyColors = Keyboard.hex(c.buf) }   // the keyboard can't report them back
        change("Sending per-key colors…") { try $0.setKeyColors(c) }
    }

    // MARK: keys

    func codes(table: Int, layer: Int) -> [UInt32] {
        Keyboard.layerCodes(table: table, layer: layer, config: config)
    }

    func assign(table: Int, layer: Int, index: Int, action: UInt32?) {
        Store.update { c in
            var t = c.keymap[String(table)] ?? [:]
            var l = t[String(layer)] ?? [:]
            if let a = action { l[String(index)] = a } else { l.removeValue(forKey: String(index)) }
            t[String(layer)] = l
            c.keymap[String(table)] = t
        }
        config = Store.loadConfig()
        change("Updating key map…") { try Keyboard.writeLayer($0, table: table, layer: layer) }
    }

    func resetLayer(table: Int, layer: Int) {
        Store.update { c in c.keymap[String(table)]?.removeValue(forKey: String(layer)) }
        config = Store.loadConfig()
        change("Resetting \(Keymap.layers[layer]) layer…") { try Keyboard.writeLayer($0, table: table, layer: layer) }
    }

    // MARK: macros

    func saveMacrosLocally() { let m = macros; Store.update { $0.macros = m } }

    /// Delete a macro; keys that pointed at it go back to default and later macros move up.
    func deleteMacro(_ i: Int) {
        saveMacrosLocally()
        var cfg = Store.loadConfig()
        let changed = Keyboard.deleteMacro(&cfg, i)
        Store.saveConfig(cfg)
        config = cfg
        macros = cfg.macros ?? []
        if !changed.isEmpty {
            status = "Keys using macro \(i + 1) went back to default; later macros moved up. Send macros to update the keyboard."
        }
    }

    func sendMacros() {
        do {
            let blob = try Keymap.encodeMacros(macros)
            let layers = Keyboard.changedLayers(Store.loadConfig())
            change("Sending \(macros.count) macro(s)…") { d in
                try d.setMacrosBlob(blob)
                // macro numbers may have moved: rewrite the keys that use them
                for (t, l) in layers { try Keyboard.writeLayer(d, table: t, layer: l) }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: settings

    func saveSettings(sleep: Double, winLock: Bool, wasd: Bool) {
        profile.sleepMinutes = sleep
        profile.winLock = winLock
        profile.wasdSwap = wasd
        let p = profile
        change("Saving keyboard settings…") { try $0.setProfile(p) }
    }

    func syncClock() { run("Setting the clock…", { try $0.syncClock() }) { [weak self] _ in self?.status = "Clock set." } }

    func factoryReset() {
        run("Factory reset…", { d in try Keyboard.factoryReset(d) }) { [weak self] _ in
            self?.config = Store.loadConfig()
            self?.macros = []
            self?.refresh()
        }
    }

    // MARK: clock service

    func installService() {
        do {
            try Service.install(executable: Bundle.main.executablePath ?? CommandLine.arguments[0])
        } catch {
            self.error = "Couldn't set up the background service: \(error.localizedDescription)"
        }
        objectWillChange.send()
    }

    func uninstallService() { Service.uninstall(); objectWillChange.send() }
}

/// A small first-frame thumbnail (decoding a whole GIF for a 64x36 picture is wasteful).
func thumbnail(_ url: URL) -> NSImage? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                 kCGImageSourceThumbnailMaxPixelSize: 128, kCGImageSourceCreateThumbnailWithTransform: true]
    guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
    return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
}

func minutes(_ seconds: Double) -> String {
    let m = max(0, Int((seconds / 60).rounded()))
    return m < 60 ? "\(m) min" : "\(m / 60) h \(String(format: "%02d", m % 60)) min"
}

extension RGB {
    var color: Color { Color(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255) }
    init(_ c: Color) {
        let ns = NSColor(c).usingColorSpace(.sRGB) ?? .white
        self.init(UInt8((ns.redComponent * 255).rounded()), UInt8((ns.greenComponent * 255).rounded()),
                  UInt8((ns.blueComponent * 255).rounded()))
    }
}
