import AppKit
import SpareKeyKit
import SwiftUI
import UniformTypeIdentifiers

struct LightingView: View {
    @EnvironmentObject var model: AppModel
    @State private var level = 5.0
    @State private var speed = 2.0
    @State private var mix = false
    @State private var color = Color.white
    @State private var loading = false
    @State private var paintColor = Color.white
    @State private var selectedKeys = Set<Int>()

    var effect: Effect? { Effects.byID(model.profile.effect) }

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading) {
                Text("Effect").bold()
                List(Effects.all) { e in
                    HStack {
                        Text(e.name)
                        Spacer()
                        if e.id == model.profile.effect { Image(systemName: "checkmark") }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { model.setEffect(e.id); load() }
                }
                .frame(width: 230)
            }
            VStack(alignment: .leading, spacing: 14) {
                Text("Settings for this effect").bold()
                Text(Effects.descriptions[model.profile.effect] ?? "").foregroundColor(.secondary)
                LabeledContent("Brightness") {
                    Slider(value: $level, in: 0...5, step: 1).frame(width: 260)
                    Text("\(Int(level))").frame(width: 20)
                }
                .disabled(!(effect?.hasBrightness ?? false))
                LabeledContent("Speed") {
                    Slider(value: $speed, in: 0...4, step: 1).frame(width: 260)
                    Text("\(Int(speed))").frame(width: 20)
                }
                .disabled(!(effect?.hasSpeed ?? false))
                LabeledContent("Color") {
                    ColorPicker("", selection: $color, supportsOpacity: false).labelsHidden()
                    Toggle("Mixed colors", isOn: $mix)
                }
                .disabled(!(effect?.hasColor ?? false))
                TryItBox(text: $model.lightingTryText)
                if model.profile.effect == Effects.custom {
                    Text("Per-key colors").bold().padding(.top, 8)
                    Text("Click keys to select them (click again to deselect), pick a color, then paint.")
                        .foregroundColor(.secondary)
                    KeyboardCanvas(colors: Dictionary(uniqueKeysWithValues: (0..<S98.keys).map { ($0, model.keyColors.get($0)) }),
                                   selected: selectedKeys) { i in
                        if selectedKeys.contains(i) { selectedKeys.remove(i) } else { selectedKeys.insert(i) }
                    }
                    HStack {
                        ColorPicker("", selection: $paintColor, supportsOpacity: false).labelsHidden()
                        Button("Paint selected") { paint(selectedKeys) }
                        Button("Select all") { selectedKeys = Set(Keymap.layout.map(\.index)) }
                        Button("Select none") { selectedKeys = [] }
                        Button("Paint all") { paint(Set(Keymap.layout.map(\.index))) }
                        Spacer()
                        Button("Send to keyboard") { model.sendKeyColors() }
                    }
                }
                Spacer()
            }
        }
        .padding()
        .onAppear(perform: load)
        .onChange(of: model.profile.buf) { _ in if !loading { load() } }
        .onChange(of: level) { _ in changed(color: false) }
        .onChange(of: speed) { _ in changed(color: false) }
        .onChange(of: mix) { _ in changed(color: false) }
        .onChange(of: color) { _ in changed(color: true) }
    }

    private func load() {
        loading = true
        let p = model.profile.ledParam()
        level = Double(Profile.level(for: p.brightness))
        speed = Double(p.speed)
        mix = p.mix
        let c = model.effects.color(model.profile.effect)
        color = c.isBlack ? .white : c.color
        if effect?.hasColor == true { model.carry = (c.isBlack ? RGB(255, 255, 255) : c, p.mix) }
        DispatchQueue.main.async { loading = false }
    }

    private func changed(color changedColor: Bool) {
        guard !loading, model.connected else { return }
        loading = true
        if changedColor { mix = false }
        model.lightingChanged(level: Int(level), speed: Int(speed), mix: mix, color: changedColor ? RGB(color) : nil)
        DispatchQueue.main.async { loading = false }
    }

    private func paint(_ keys: Set<Int>) {
        let c = RGB(paintColor)
        for i in keys { model.keyColors.set(i, c) }
    }
}

/// A scratch area to type in and see lighting or key changes on the keyboard. Nothing is saved.
struct TryItBox: View {
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Try it out").bold().padding(.top, 8)
            Text("Type here to try your changes on the keyboard. This isn't saved.").foregroundColor(.secondary)
            TextEditor(text: $text)
                .font(.body)
                .frame(height: 90)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.4)))
        }
    }
}

struct KeysView: View {
    @EnvironmentObject var model: AppModel
    @State private var table = 0
    @State private var layer = 0
    @State private var editing: Int?
    @State private var search = ""
    @State private var pendingFN: PendingAssign?

    struct PendingAssign: Identifiable { let id = UUID(); let index: Int; let action: UInt32? }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("", selection: $table) { Text("Windows mode").tag(0); Text("Mac mode").tag(1) }.frame(width: 180)
                Picker("", selection: $layer) {
                    ForEach(0..<4) { Text(Keymap.layers[$0] + " layer").tag($0) }
                }.frame(width: 160)
                Spacer()
                Button("Reset this layer") { model.resetLayer(table: table, layer: layer) }
            }
            Text("Click a key to choose what it does. Changes are sent straight to the keyboard; keys you changed are "
                 + "outlined in orange. The FN layer is what keys do while FN is held.")
                .foregroundColor(.secondary)
            KeyboardCanvas(labels: labels(), selected: editing.map { [$0] } ?? [],
                           marked: Set(model.config.overrides(table: table, layer: layer).keys)) { editing = $0 }
            TryItBox(text: $model.keysTryText)
            Spacer()
        }
        .padding()
        .sheet(item: Binding(get: { editing.map { KeyTarget(id: $0) } }, set: { editing = $0?.id })) { t in
            picker(for: t.id)
        }
        .alert(item: $pendingFN) { p in
            Alert(title: Text("Remap the FN key?"),
                  message: Text("Without FN you can't reach the FN layer (media keys, lighting, connection modes) "
                                + "from the keyboard. You can undo this here any time."),
                  primaryButton: .destructive(Text("Remap")) {
                      model.assign(table: table, layer: layer, index: p.index, action: p.action)
                  },
                  secondaryButton: .cancel())
        }
    }

    /// Taking FN off the base layer locks you out of the FN layer: ask first.
    private func choose(_ index: Int, _ action: UInt32?) {
        let fn = Keymap.codes["KEY_Fn1"]
        if layer == 0, Keymap.defaults(table: table, layer: 0)[index] == fn, let a = action, a != fn {
            pendingFN = PendingAssign(index: index, action: a)
        } else {
            model.assign(table: table, layer: layer, index: index, action: action)
        }
    }

    struct KeyTarget: Identifiable { let id: Int }

    private func labels() -> [Int: String] {
        let codes = model.codes(table: table, layer: layer)
        let defaults = Keymap.defaults(table: table, layer: 0)
        var out = [Int: String]()
        for k in Keymap.layout {
            let a = codes[k.index]
            if layer == 0 && a == defaults[k.index] { continue }      // show the keycap's own label
            out[k.index] = a == 0 ? "" : Keymap.describe(a)
        }
        return out
    }

    private func filteredChoices() -> [(offset: Int, element: (String, UInt32?))] {
        var choices: [(String, UInt32?)] = [("Default", nil)]
        for (i, m) in model.macros.enumerated() { choices.append(("Macro \(i + 1): \(m.name)", Keymap.macroAction(i))) }
        choices.append(("Disabled", 0))
        for a in Keymap.assignable { choices.append((a.label, a.action)) }
        let q = search.lowercased()
        return Array(choices.enumerated()).filter { q.isEmpty || $0.element.0.lowercased().contains(q) }
    }

    @ViewBuilder private func picker(for index: Int) -> some View {
        let key = Keymap.layout.first { $0.index == index }?.label ?? "key \(index)"
        let shown = filteredChoices()
        VStack(alignment: .leading) {
            Text("\(key) → \(Keymap.layers[layer]) layer").bold()
            TextField("Search keys, media, lighting…", text: $search)
            List(shown, id: \.offset) { item in
                Button(item.element.0) {
                    editing = nil
                    choose(index, item.element.1)
                    search = ""
                }
                .buttonStyle(.plain)
            }
            .frame(width: 340, height: 380)
            HStack { Spacer(); Button("Cancel") { editing = nil; search = "" }.keyboardShortcut(.cancelAction) }
        }
        .padding(16)
    }
}

struct MacrosView: View {
    @EnvironmentObject var model: AppModel
    @State private var selected: Int?
    @State private var recording = false
    @State private var stepDelay = 50
    @State private var realTiming = false
    @State private var monitor: Any?
    @State private var lastKeyTime: Date?

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading) {
                HStack {
                    Text("Macros").bold()
                    Spacer()
                    Button { add() } label: { Image(systemName: "plus") }
                    Button { delete() } label: { Image(systemName: "minus") }.disabled(selected == nil)
                }
                List(selection: $selected) {
                    ForEach(Array(model.macros.enumerated()), id: \.offset) { i, m in
                        Text("\(i + 1). \(m.name)").tag(i)
                    }
                }
                Button("Send macros to keyboard") { model.sendMacros() }
            }
            .frame(width: 260)
            if let i = selected, i < model.macros.count {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Macro name", text: Binding(get: { model.macros[i].name }, set: {
                        model.macros[i].name = String($0.prefix(60)); model.saveMacrosLocally()
                    }))
                    HStack {
                        Button(recording ? "■ Stop recording" : "● Record") { toggleRecording() }
                        Text("Delay between steps")
                        TextField("", value: $stepDelay, format: .number).frame(width: 70)
                        Text("ms")
                        Toggle("Keep my real timing", isOn: $realTiming)
                        Spacer()
                        Button("Clear") { model.macros[i].steps = []; model.saveMacrosLocally() }
                    }
                    List {
                        ForEach(Array(model.macros[i].steps.enumerated()), id: \.offset) { n, s in
                            HStack {
                                Text("\(n + 1)").frame(width: 28)
                                Text(Keymap.describe(s))
                                Spacer()
                                TextField("", value: Binding(get: { model.macros[i].steps[n].delay }, set: {
                                    model.macros[i].steps[n].delay = $0; model.saveMacrosLocally()
                                }), format: .number).frame(width: 70)
                                Button { model.macros[i].steps.remove(at: n); model.saveMacrosLocally() }
                                    label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                            }
                        }
                    }
                    .overlay(model.macros[i].steps.isEmpty ? Text("No steps. Press Record and type.").foregroundColor(.secondary) : nil)
                    Text("Assign a macro to a key on the Keys tab. Macros are kept on this Mac too, so you can edit them later.")
                        .foregroundColor(.secondary)
                }
            } else {
                Text("Create a macro with +").foregroundColor(.secondary)
                Spacer()
            }
        }
        .padding()
        .onDisappear { stopRecording() }
    }

    private func add() {
        guard model.macros.count < 16 else { model.error = "That's the most macros this app keeps (16)."; return }
        model.macros.append(Macro(name: "Macro \(model.macros.count + 1)"))
        model.saveMacrosLocally()
        selected = model.macros.count - 1
    }

    private func delete() {
        guard let i = selected, i < model.macros.count else { return }
        model.deleteMacro(i)
        selected = model.macros.isEmpty ? nil : max(0, i - 1)
    }

    private func toggleRecording() { recording ? stopRecording() : startRecording() }

    private func startRecording() {
        recording = true
        lastKeyTime = nil
        model.status = "Recording: type your keys."
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { ev in
            record(ev)
            return nil   // swallow while recording
        }
    }

    private func stopRecording() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        if recording { model.status = "Recording stopped." }
        recording = false
    }

    private func record(_ ev: NSEvent) {
        guard let i = selected, i < model.macros.count, let usage = MacKeys.hid[Int(ev.keyCode)] else { return }
        if ev.type == .keyDown && ev.isARepeat { return }
        let up: Bool
        switch ev.type {
        case .keyUp: up = true
        case .keyDown: up = false
        default: up = !MacKeys.isDown(ev)   // modifier changed
        }
        let now = Date()
        if realTiming, let last = lastKeyTime, !model.macros[i].steps.isEmpty {
            model.macros[i].steps[model.macros[i].steps.count - 1].delay = Int(now.timeIntervalSince(last) * 1000)
        }
        lastKeyTime = now
        let type = (0xE0...0xE7).contains(usage) ? 1 : 0
        model.macros[i].steps.append(MacroStep(up: up, type: type, key: usage, delay: stepDelay))
        model.saveMacrosLocally()
    }
}

/// macOS virtual key codes -> USB HID usages (for recording macros).
enum MacKeys {
    static let hid: [Int: Int] = [
        0: 0x04, 11: 0x05, 8: 0x06, 2: 0x07, 14: 0x08, 3: 0x09, 5: 0x0A, 4: 0x0B, 34: 0x0C, 38: 0x0D, 40: 0x0E, 37: 0x0F,
        46: 0x10, 45: 0x11, 31: 0x12, 35: 0x13, 12: 0x14, 15: 0x15, 1: 0x16, 17: 0x17, 32: 0x18, 9: 0x19, 13: 0x1A,
        7: 0x1B, 16: 0x1C, 6: 0x1D, 18: 0x1E, 19: 0x1F, 20: 0x20, 21: 0x21, 23: 0x22, 22: 0x23, 26: 0x24, 28: 0x25,
        25: 0x26, 29: 0x27, 36: 0x28, 53: 0x29, 51: 0x2A, 48: 0x2B, 49: 0x2C, 27: 0x2D, 24: 0x2E, 33: 0x2F, 30: 0x30,
        42: 0x31, 41: 0x33, 39: 0x34, 50: 0x35, 43: 0x36, 47: 0x37, 44: 0x38, 57: 0x39, 122: 0x3A, 120: 0x3B, 99: 0x3C,
        118: 0x3D, 96: 0x3E, 97: 0x3F, 98: 0x40, 100: 0x41, 101: 0x42, 109: 0x43, 103: 0x44, 111: 0x45, 114: 0x49,
        115: 0x4A, 116: 0x4B, 117: 0x4C, 119: 0x4D, 121: 0x4E, 124: 0x4F, 123: 0x50, 125: 0x51, 126: 0x52, 71: 0x53,
        75: 0x54, 67: 0x55, 78: 0x56, 69: 0x57, 76: 0x58, 83: 0x59, 84: 0x5A, 85: 0x5B, 86: 0x5C, 87: 0x5D, 88: 0x5E,
        89: 0x5F, 91: 0x60, 92: 0x61, 82: 0x62, 65: 0x63, 59: 0xE0, 56: 0xE1, 58: 0xE2, 55: 0xE3, 62: 0xE4, 60: 0xE5,
        61: 0xE6, 54: 0xE7,
    ]

    static func isDown(_ ev: NSEvent) -> Bool {
        let f = ev.modifierFlags
        switch Int(ev.keyCode) {
        case 59, 62: return f.contains(.control)
        case 56, 60: return f.contains(.shift)
        case 58, 61: return f.contains(.option)
        case 55, 54: return f.contains(.command)
        default: return false
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var sleep = 5.0
    @State private var winLock = false
    @State private var wasd = false
    @State private var loading = true
    @State private var confirmReset = false
    @State private var pending: DispatchWorkItem?

    var body: some View {
        Form {
            Section("Keyboard") {
                Stepper(value: $sleep, in: 0...120, step: 0.5) {
                    Text("Lights off after \(sleep, specifier: "%.1f") min idle (0 = never)")
                }
                Toggle("Lock the Windows key", isOn: $winLock)
                Toggle("Swap WASD and arrows", isOn: $wasd)
            }
            Section("Clock") {
                Button("Set the keyboard clock to this Mac's time") { model.syncClock() }
                Toggle("Keep it in sync (small background service, starts at login)", isOn: Binding(
                    get: { Service.isInstalled }, set: { on in on ? model.installService() : model.uninstallService() }))
            }
            Section("Backup") {
                HStack {
                    Button("Save backup…") { saveBackup() }
                    Button("Restore backup…") { restoreBackup() }
                }
                Text("Your settings from before SpareKey's first change are kept in "
                     + Store.backupDir.appendingPathComponent("s98-original.json").path
                        .replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .foregroundColor(.secondary)
            }
            Section("Factory reset") {
                Button("Factory reset…") { confirmReset = true }
            }
            Section("Firmware") {
                Text("\(model.model), firmware \(model.firmware)")
                Text("SpareKey doesn't flash firmware (a failed flash can leave the keyboard unusable). RK's web driver "
                     + "at drive.rkgaming.com works in Chrome on macOS if you need an update.")
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: load)
        .onChange(of: model.profile.buf) { _ in load() }
        .onChange(of: sleep) { _ in changed() }
        .onChange(of: winLock) { _ in changed() }
        .onChange(of: wasd) { _ in changed() }
        .confirmationDialog("Reset the keyboard to factory settings? Lighting, key maps and macros go back to how they "
                            + "shipped. SpareKey saves a backup first.", isPresented: $confirmReset) {
            Button("Factory reset", role: .destructive) { model.factoryReset() }
        }
    }

    private func load() {
        loading = true
        sleep = model.profile.sleepMinutes
        winLock = model.profile.winLock
        wasd = model.profile.wasdSwap
        DispatchQueue.main.async { loading = false }
    }

    private func changed() {
        guard !loading, model.connected else { return }
        pending?.cancel()
        let s = sleep, w = winLock, a = wasd
        let work = DispatchWorkItem { model.saveSettings(sleep: s, winLock: w, wasd: a) }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func saveBackup() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "s98-backup.json"
        if panel.runModal() == .OK, let url = panel.url {
            model.run("Saving backup…", { try Keyboard.backup($0, to: url) }) { u in model.status = "Saved \(u.lastPathComponent)" }
        }
    }

    private func restoreBackup() {
        let panel = NSOpenPanel()
        panel.directoryURL = Store.backupDir
        panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let url = panel.url {
            model.run("Restoring backup…", { try Keyboard.restore($0, from: url) }) { _ in
                model.config = Store.loadConfig()
                model.refresh()
            }
        }
    }
}
