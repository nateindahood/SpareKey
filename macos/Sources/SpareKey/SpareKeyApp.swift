import AppKit
import SpareKeyKit
import SwiftUI

struct SpareKeyApp: App {
    @StateObject private var model = AppModel()

    init() {
        // started from `swift run` (no .app bundle): still show a normal window with a Dock icon
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup("SpareKey") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 1080, minHeight: 700)
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if let e = model.error {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                    Text(e).textSelection(.enabled)
                    Spacer()
                    Button("Dismiss") { model.error = nil }
                }
                .padding(10)
                .background(Color.orange.opacity(0.15))
            }
            TabView {
                ScreenView().tabItem { Text("Screen") }
                LightingView().tabItem { Text("Lighting") }
                KeysView().tabItem { Text("Keys") }
                MacrosView().tabItem { Text("Macros") }
                SettingsView().tabItem { Text("Settings") }
            }
            .padding(8)
            HStack {
                if model.busy != nil { ProgressView().controlSize(.small) }
                Text(model.status).foregroundColor(.secondary)
                Spacer()
                Text(model.connected ? "\(model.model) · firmware \(model.firmware)" : "Not connected")
                    .foregroundColor(.secondary)
                Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Read everything from the keyboard again")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }
}

/// The S98 drawn from its key rectangles; click a key to select it.
struct KeyboardCanvas: View {
    var labels: [Int: String] = [:]
    var colors: [Int: RGB] = [:]
    var selected: Set<Int> = []
    var marked: Set<Int> = []
    var onTap: (Int) -> Void

    static let keys = Keymap.layout
    static let x0 = keys.map(\.x).min()!, y0 = keys.map(\.y).min()!
    static let x1 = keys.map { $0.x + $0.w }.max()!, y1 = keys.map { $0.y + $0.h }.max()!

    static let short: [String: String] = [
        "NumLock": "Num", "Backspace": "Bksp", "CapsLock": "Caps", "Delete": "Del", "Space": "", "Down": "↓", "Up": "↑",
        "Left": "←", "Right": "→", "LShift": "Shift", "RShift": "Shift", "LCtrl": "Ctrl", "RCtrl": "Ctrl",
        "LAlt": "Option", "RAlt": "Option", "LWin": "Cmd",
    ]

    static func shortLabel(_ l: String) -> String {
        if let s = short[l] { return s }
        if l.hasPrefix("Num") && l.count > 3 { return String(l.dropFirst(3)).trimmingCharacters(in: .whitespaces) }
        return l
    }

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width / (Self.x1 - Self.x0 + 20), geo.size.height / (Self.y1 - Self.y0 + 20))
            let ox = (geo.size.width - (Self.x1 - Self.x0) * s) / 2
            let oy = (geo.size.height - (Self.y1 - Self.y0) * s) / 2
            ZStack(alignment: .topLeading) {
                ForEach(Self.keys) { k in
                    KeyCap(label: labels[k.index] ?? Self.shortLabel(k.label), color: colors[k.index],
                           selected: selected.contains(k.index), marked: marked.contains(k.index),
                           width: k.w * s, height: k.h * s)
                        .onTapGesture { onTap(k.index) }
                        .offset(x: ox + (k.x - Self.x0) * s, y: oy + (k.y - Self.y0) * s)
                }
            }
        }
        .aspectRatio((Self.x1 - Self.x0 + 20) / (Self.y1 - Self.y0 + 20), contentMode: .fit)
    }
}

struct KeyCap: View {
    let label: String
    let color: RGB?
    let selected: Bool
    let marked: Bool
    let width: Double
    let height: Double

    var stroke: Color {
        if selected { return .accentColor }
        if marked { return .orange }
        return Color.primary.opacity(0.35)
    }

    var textColor: Color {
        guard let c = color else { return .primary }
        let lum = 0.3 * Double(c.r) + 0.59 * Double(c.g) + 0.11 * Double(c.b)
        return lum > 140 ? .black : .white
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 5)
        return shape
            .fill(color?.color ?? Color.primary.opacity(0.08))
            .overlay(shape.stroke(stroke, lineWidth: selected ? 3 : (marked ? 2 : 1)))
            .overlay(
                Text(label)
                    .font(.system(size: max(7, min(12, height / 3))))
                    .foregroundColor(textColor)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                    .padding(2)
            )
            .frame(width: width, height: height)
            .contentShape(Rectangle())
    }
}
