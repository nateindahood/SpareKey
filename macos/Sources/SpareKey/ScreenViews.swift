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
    @State private var newPlaylistFor: URL?
    @State private var newPlaylistName = ""

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
                            Menu {
                                ForEach(model.config.playlists.keys.sorted(), id: \.self) { name in
                                    Button("Add to “\(name)”") { model.addToPlaylist(name, [url]) }
                                }
                                Button("New playlist…") { newPlaylistFor = url; newPlaylistName = "Playlist \(model.config.playlists.count + 1)" }
                            } label: { Image(systemName: "plus") }
                            .menuStyle(.borderlessButton).frame(width: 30).help("Add to a playlist")
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
                Text("The keyboard holds one animation. Sending takes about 13 seconds per frame (GIFs are limited to 60 "
                     + "frames), and the screen is busy while it receives.")
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
        .sheet(item: $newPlaylistFor) { url in
            NameSheet(title: "New playlist", name: $newPlaylistName) {
                model.savePlaylist(newPlaylistName, Playlist(items: [url.path]))
                newPlaylistFor = nil
            } cancel: { newPlaylistFor = nil }
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

extension URL: Identifiable { public var id: String { absoluteString } }

struct NameSheet: View {
    let title: String
    @Binding var name: String
    let ok: () -> Void
    let cancel: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).bold()
            TextField("Name", text: $name).frame(width: 300).onSubmit(ok)
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("OK", action: ok).keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
    }
}

struct PlaylistsView: View {
    @EnvironmentObject var model: AppModel
    @State private var selected: String?
    @State private var naming: String?      // "new" or the playlist being renamed
    @State private var name = ""
    @State private var picking = false
    @State private var confirmDelete = false

    var playlist: Playlist? { selected.flatMap { model.config.playlists[$0] } }

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Playlists").bold()
                    Spacer()
                    Button("New…") { naming = "new"; name = "Playlist \(model.config.playlists.count + 1)" }
                }
                List(selection: $selected) {
                    ForEach(model.config.playlists.keys.sorted(), id: \.self) { n in
                        let p = model.config.playlists[n]!
                        HStack {
                            Text(model.state.active == n ? "▶" : " ").frame(width: 14)
                            Text(n)
                            Spacer()
                            Text("\(p.items.count) · \(p.order == "shuffle" ? "shuffle" : "in order")").foregroundColor(.secondary)
                        }
                        .tag(n)
                    }
                }
                statusView
                Toggle("Background service", isOn: Binding(get: { Service.isInstalled }, set: { on in
                    on ? model.installService() : model.uninstallService()
                }))
                Text("The service switches GIFs on schedule and keeps the keyboard clock right, even when this window "
                     + "is closed. It starts when you log in.")
                    .font(.callout).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .frame(minWidth: 300, maxWidth: 380)
            .padding(.trailing, 8)

            VStack(alignment: .leading, spacing: 10) {
                if let name = selected, let p = playlist {
                    Text(name).bold()
                    HStack {
                        Picker("", selection: bind(p, \.order)) {
                            Text("Play in order").tag("loop")
                            Text("Shuffle").tag("shuffle")
                        }.frame(width: 160)
                        Text("Switch every")
                        Stepper(value: bind(p, \.interval), in: Store.minInterval...(24 * 60), step: 5) {
                            Text("\(p.interval) minutes")
                        }
                        Picker("", selection: bind(p, \.fit)) { ForEach(Fit.allCases) { Text($0.label).tag($0) } }
                            .frame(width: 170)
                    }
                    List {
                        ForEach(Array(p.items.enumerated()), id: \.offset) { i, path in
                            let url = URL(fileURLWithPath: path)
                            HStack {
                                Text(path == model.state.current ? "▶" : "\(i + 1)").frame(width: 24)
                                Thumb(url: url)
                                Text(url.lastPathComponent + (FileManager.default.fileExists(atPath: path) ? "" : "  (missing)"))
                                Spacer()
                                Button { edit(name) { $0.items.remove(at: i) } } label: { Image(systemName: "minus.circle") }
                                    .buttonStyle(.borderless).help("Remove from this playlist")
                            }
                        }
                        .onMove { from, to in edit(name) { $0.items.move(fromOffsets: from, toOffset: to) } }
                    }
                    .overlay(p.items.isEmpty ? Text("Empty. Use “Add from library…” or the + next to a file on the Screen tab.")
                        .foregroundColor(.secondary) : nil)
                    HStack {
                        Button("Add from library…") { picking = true }
                        Button("Start") { model.startPlaylist(name) }.keyboardShortcut(.defaultAction).disabled(p.items.isEmpty)
                        Button("Next now") { model.nextNow() }
                        Button("Stop") { model.stopPlaylist() }
                        Spacer()
                        Button("Rename…") { naming = name; self.name = name }
                        Button { confirmDelete = true } label: { Image(systemName: "trash") }
                    }
                    Text("Every switch re-sends the GIF (minutes per GIF), so intervals start at \(Store.minInterval) minutes and "
                         + "30–60 are a good choice: it keeps flash writes to the keyboard modest. Drag rows to reorder.")
                        .font(.callout).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Select or create a playlist").bold()
                    Spacer()
                }
            }
            .padding(.leading, 8)
        }
        .padding()
        .sheet(item: Binding(get: { naming.map { NamingTarget(id: $0) } }, set: { naming = $0?.id })) { target in
            NameSheet(title: target.id == "new" ? "New playlist" : "Rename playlist", name: $name) {
                if target.id == "new" { model.savePlaylist(name, Playlist()) } else { model.renamePlaylist(target.id, name) }
                selected = name
                naming = nil
            } cancel: { naming = nil }
        }
        .sheet(isPresented: $picking) {
            LibraryPicker { urls in if let n = selected { model.addToPlaylist(n, urls) }; picking = false }
        }
        .confirmationDialog("Delete the playlist “\(selected ?? "")”? Your GIFs stay in the library.", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { if let n = selected { model.deletePlaylist(n); selected = nil } }
        }
    }

    struct NamingTarget: Identifiable { let id: String }

    @ViewBuilder var statusView: some View {
        let st = model.state
        if let active = st.active {
            if let up = st.uploading {
                Text("▶ \(active): sending \((up as NSString).lastPathComponent)…")
                ProgressView(value: st.progress ?? 0)
            } else {
                let when: String = {
                    guard let n = st.nextAt, n > Date().timeIntervalSince1970 else { return "any moment" }
                    return "in " + minutes(n - Date().timeIntervalSince1970)
                }()
                Text("▶ \(active): showing \(((st.current ?? "—") as NSString).lastPathComponent), next \(when)"
                     + (st.error.map { "\nLast attempt failed: \($0)" } ?? "")
                     + (Service.isInstalled ? "" : "\nThe background service is off, so nothing will switch."))
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Text("No playlist running.").foregroundColor(.secondary)
        }
    }

    private func edit(_ name: String, _ change: (inout Playlist) -> Void) {
        guard var p = model.config.playlists[name] else { return }
        change(&p)
        model.savePlaylist(name, p)
    }

    private func bind<T>(_ p: Playlist, _ kp: WritableKeyPath<Playlist, T>) -> Binding<T> {
        Binding(get: { p[keyPath: kp] }, set: { v in if let n = selected { edit(n) { $0[keyPath: kp] = v } } })
    }
}

struct LibraryPicker: View {
    let done: ([URL]) -> Void
    @State private var chosen = Set<URL>()
    var body: some View {
        VStack(alignment: .leading) {
            Text("Add GIFs from your library").bold()
            List(Store.library(), id: \.self) { url in
                Toggle(isOn: Binding(get: { chosen.contains(url) }, set: { on in
                    if on { chosen.insert(url) } else { chosen.remove(url) }
                })) {
                    HStack { Thumb(url: url); Text(url.lastPathComponent) }
                }
            }
            .frame(width: 520, height: 420)
            HStack {
                Spacer()
                Button("Cancel") { done([]) }.keyboardShortcut(.cancelAction)
                Button("Add") { done(Array(chosen).sorted { $0.lastPathComponent < $1.lastPathComponent }) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }
}
