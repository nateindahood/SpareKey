import AppKit
import SpareKeyKit
import SwiftUI
import UniformTypeIdentifiers

/// Animated preview of exactly what will be sent (320x172 frames at the keyboard's frame delay).
struct FramePreview: View {
    let url: URL?
    let fit: Fit
    @State private var frames: [NSImage] = []
    @State private var delay = 0.1
    @State private var index = 0
    @State private var caption = "Select a file to preview it."

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                Color.black
                if !frames.isEmpty {
                    Image(nsImage: frames[min(index, frames.count - 1)]).resizable().interpolation(.high)
                }
            }
            .frame(width: 448, height: 241)
            .border(Color.secondary.opacity(0.4))
            Text(caption).foregroundColor(.secondary).font(.callout)
        }
        .task(id: "\(url?.path ?? "")|\(fit.rawValue)") { await load() }
        .onReceive(Timer.publish(every: 0.02, on: .main, in: .common).autoconnect()) { _ in tick() }
    }

    @State private var lastTick = Date()

    private func tick() {
        guard frames.count > 1, Date().timeIntervalSince(lastTick) >= delay else { return }
        lastTick = Date()
        index = (index + 1) % frames.count
    }

    private func load() async {
        guard let url = url else { frames = []; return }
        caption = "\(url.lastPathComponent)\nPreparing preview…"
        let fit = self.fit
        let result: (frames: [NSImage], delay: Int, count: Int)? = await Task.detached {
            guard let f = try? Media.load(url, fit: fit) else { return nil }
            let imgs = f.images.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
            return (imgs, f.delayMs, imgs.count)
        }.value
        guard let r = result else { caption = "\(url.lastPathComponent)\nNo preview: unreadable file"; frames = []; return }
        frames = r.frames
        delay = Double(r.delay) / 1000
        index = 0
        caption = "\(url.lastPathComponent) — \(r.count) frame\(r.count == 1 ? "" : "s"), about \(minutes(Media.estimateSeconds(r.count))) to send"
    }
}

struct Thumb: View {
    let url: URL
    var body: some View {
        Group {
            if let img = NSImage(contentsOf: url) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "photo")
            }
        }
        .frame(width: 64, height: 36)
    }
}

struct ScreenView: View {
    @EnvironmentObject var model: AppModel
    @State private var selection: URL?
    @State private var fit: Fit = Store.loadConfig().fit ?? .cover
    @State private var showImporter = false

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Your library").bold()
                    Text(Store.libraryDir().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(.caption).foregroundColor(.secondary)
                    Spacer()
                    Button("Add files…") { showImporter = true }
                    Button("Open folder") { NSWorkspace.shared.open(Store.libraryDir()) }
                    Button("Change folder…") { chooseFolder() }
                }
                List(selection: $selection) {
                    ForEach(model.library, id: \.self) { url in
                        HStack {
                            Thumb(url: url)
                            Text(url.lastPathComponent).lineLimit(1)
                            Spacer()
                            let n = Media.frameCount(url)
                            Text("\(n) frame\(n == 1 ? "" : "s") · ~\(minutes(Media.estimateSeconds(n)))")
                                .foregroundColor(.secondary)
                            Button { model.upload(url, fit: fit) } label: { Image(systemName: "paperplane") }
                                .help("Send to the keyboard")
                            Button { try? FileManager.default.trashItem(at: url, resultingItemURL: nil); model.refreshLibrary() }
                                label: { Image(systemName: "trash") }
                                .help("Move to the Trash (removes it from your library only)")
                        }
                        .tag(url)
                    }
                }
                .overlay(model.library.isEmpty ? Text("Drop GIFs or images here to keep them in your library.")
                    .foregroundColor(.secondary) : nil)
                .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                    for p in providers {
                        _ = p.loadObject(ofClass: URL.self) { url, _ in
                            if let u = url { DispatchQueue.main.async { model.addFiles([u]) } }
                        }
                    }
                    return true
                }
            }
            .frame(minWidth: 520)
            .padding(.trailing, 8)

            VStack(alignment: .leading, spacing: 10) {
                Text("How it will look on the keyboard").bold()
                FramePreview(url: selection, fit: fit)
                HStack {
                    Picker("Send as:", selection: $fit) { ForEach(Fit.allCases) { Text($0.label).tag($0) } }
                        .frame(width: 240)
                        .onChange(of: fit) { f in Store.update { $0.fit = f } }
                    Button("Send to keyboard") { if let u = selection { model.upload(u, fit: fit) } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(selection == nil || model.busy != nil)
                }
                if let p = model.uploadProgress {
                    HStack {
                        ProgressView(value: p).frame(width: 300)
                        Text(model.uploadText).foregroundColor(.secondary)
                        Button("Cancel") { model.cancelUpload = true }
                    }
                } else if !model.uploadText.isEmpty {
                    Text(model.uploadText).foregroundColor(.secondary)
                }
                Text("The keyboard holds one animation and shows a frame at most every 0.18 s, so fast GIFs are sent "
                     + "with fewer frames to keep their speed (at most 60). Sending takes about 13 seconds per frame, "
                     + "and the screen is busy while it receives.")
                    .foregroundColor(.secondary).font(.callout).fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
            .padding(.leading, 8)
            .frame(minWidth: 460)
        }
        .padding()
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.image, .gif], allowsMultipleSelection: true) { r in
            if case .success(let urls) = r {
                let ok = urls.filter { $0.startAccessingSecurityScopedResource() || true }
                model.addFiles(ok)
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = Store.libraryDir()
        if panel.runModal() == .OK, let u = panel.url {
            Store.update { $0.libraryDir = u.path }
            model.refreshLibrary()
        }
    }
}
