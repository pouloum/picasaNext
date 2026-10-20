import AppKit
import AVKit
import PicasaCore
import SwiftUI

/// Brings the app to the front with its window when it starts (launched from a terminal it would
/// otherwise stay behind until clicked in the Dock) and sets the Dock icon when there is no app bundle.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if Bundle.main.bundleIdentifier == nil, let icon = AppIcon.nsImage { NSApp.applicationIconImage = icon }
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct PicasaNextApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    init() {
        // Build helper: `PicasaNext --write-icns FILE` writes the app icon and exits.
        if let i = CommandLine.arguments.firstIndex(of: "--write-icns"), i + 1 < CommandLine.arguments.count {
            do { try AppIcon.writeIcns(to: URL(fileURLWithPath: CommandLine.arguments[i + 1])); exit(0) }
            catch { FileHandle.standardError.write("icns: \(error)\n".data(using: .utf8)!); exit(1) }
        }
        // Running as a bare executable (swift run): become a regular app with a Dock icon.
        NSApplication.shared.setActivationPolicy(.regular)
        // Print the reason of an Objective-C exception before AppKit aborts (crash reports omit it).
        NSSetUncaughtExceptionHandler { e in
            FileHandle.standardError.write("PicasaNext exception: \(e.name.rawValue): \(e.reason ?? "")\n\(e.callStackSymbols.prefix(25).joined(separator: "\n"))\n".data(using: .utf8)!)
        }
    }

    var body: some Scene {
        WindowGroup("PicasaNext") {
            RootView().environmentObject(model)
                .frame(minWidth: 900, minHeight: 600)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Add Folder to Library…") { model.addFolder() }.keyboardShortcut("o")
                Button("Import Picasa Data…") { model.importPicasa() }
                Button("Rescan Library") { model.rescan() }.keyboardShortcut("r")
            }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationSplitView {
            Sidebar()
        } detail: {
            VStack(spacing: 0) {
                SearchBar().padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 6)
                Divider()
                Group {
                    if model.isSearching { GridView() }
                    else if case .people? = model.selection { PeopleView() }
                    else if case .labels? = model.selection { LabelsView() }
                    else { GridView() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .toolbar {
                ToolbarItem(placement: .status) { JobStatus() }
                ToolbarItem { Button { model.addFolder() } label: { Label("Add Folder", systemImage: "folder.badge.plus") } }
            }
        }
        .onChange(of: model.selection) {
            model.clearSearch()
            Task { await model.reloadGrid() }
        }
        .sheet(isPresented: Binding(get: { model.viewing != nil }, set: { if !$0 { model.viewing = nil } })) {
            ViewerView().environmentObject(model).frame(minWidth: 1000, minHeight: 700)
        }
        .alert("Error", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
}

struct JobStatus: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        if let job = model.job {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(job + (model.jobDetail.map { " — \($0)" } ?? "")).font(.caption).monospacedDigit()
            }
        } else if let s = model.stats {
            Text("\(s.images + s.raws) photos · \(s.videos) videos").font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct Sidebar: View {
    @EnvironmentObject private var model: AppModel
    /// Local selection, forwarded to the model on the next run-loop turn: updating published state
    /// from inside the List's NSTableView delegate callback re-entered it ("reentrant operation" warning).
    @State private var selection: SidebarItem? = .filter(.all, "All photos")

    var body: some View {
        List(selection: $selection) {
            Section("Library") {
                Label("All photos", systemImage: "photo.on.rectangle").tag(SidebarItem.filter(.all, "All photos"))
                Label("Starred", systemImage: "star").tag(SidebarItem.filter(.starred, "Starred"))
                Label("Videos", systemImage: "film").tag(SidebarItem.filter(.videos, "Videos"))
                Label("People", systemImage: "person.2").tag(SidebarItem.people)
                Label("Labels", systemImage: "tag").tag(SidebarItem.labels)
            }
            Section("Discover") {
                Label("Best photos", systemImage: "sparkles").tag(SidebarItem.filter(.best, "Best photos"))
                Label("Similar & duplicates", systemImage: "square.on.square")
                    .badge(model.stats?.similarGroups ?? 0).tag(SidebarItem.filter(.similar, "Similar & duplicates"))
                Label("Bursts", systemImage: "square.stack.3d.forward.dottedline")
                    .badge(model.stats?.bursts ?? 0)
                    .help("Sequences of at least 3 shots taken ≤ 2 s apart with the same camera")
                    .tag(SidebarItem.filter(.bursts, "Bursts"))
                Label("Animals", systemImage: "pawprint").badge(model.stats?.animals ?? 0).tag(SidebarItem.filter(.animals, "Animals"))
                Label("Screenshots & documents", systemImage: "doc.text.viewfinder")
                    .badge(model.stats?.utility ?? 0).tag(SidebarItem.filter(.utility, "Screenshots & documents"))
                if (model.stats?.ignored ?? 0) > 0 {
                    Label("Small images (ignored)", systemImage: "eye.slash")
                        .badge(model.stats?.ignored ?? 0).foregroundStyle(.secondary)
                        .help("Probable thumbnails written by other apps: small and without camera metadata. Not analysed, hidden elsewhere.")
                        .tag(SidebarItem.filter(.ignored, "Small images (ignored)"))
                }
            }
            if !model.albums.isEmpty {
                Section("Albums") {
                    ForEach(model.albums) { a in
                        Label(a.name, systemImage: "rectangle.stack").badge(a.count).tag(SidebarItem.filter(.album(a.id), a.name))
                    }
                }
            }
            if !model.years.isEmpty {
                Section("Years") {
                    ForEach(model.years, id: \.year) { y in
                        Label(String(y.year), systemImage: "calendar").badge(y.count).tag(SidebarItem.filter(.year(y.year), String(y.year)))
                    }
                }
            }
            Section("Folders") {
                ForEach(model.folders) { f in
                    Label(f.title, systemImage: "folder").badge(f.count).help(f.path).tag(SidebarItem.filter(.folder(f.id), f.title))
                }
            }
        }
        .onChange(of: selection) { _, new in
            DispatchQueue.main.async { if model.selection != new { model.selection = new } }
        }
        .onChange(of: model.selection) { _, new in if selection != new { selection = new } }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 200, ideal: 240)
    }
}

struct GridView: View {
    @EnvironmentObject private var model: AppModel
    @State private var size: CGFloat = 150

    var body: some View {
        if model.ids.isEmpty {
            let e = emptyState
            ContentUnavailableView(e.title, systemImage: e.icon, description: Text(e.message))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                CollectionGrid(ids: model.ids, cellSize: size, thumbs: model.thumbs) { model.open(model.ids, at: $0) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                HStack {
                    Text("\(model.ids.count) item\(model.ids.count > 1 ? "s" : "")").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Slider(value: $size, in: 80...320).frame(width: 160)
                }
                .padding(.horizontal, 10).padding(.vertical, 4)
            }
        }
    }

    /// Message for an empty section, depending on what is being shown.
    var emptyState: (title: String, icon: String, message: String) {
        if model.stats?.folders == 0 {
            return ("Library is empty", "photo.on.rectangle", "Add a folder with File ▸ Add Folder to Library… (⌘O).")
        }
        if model.isSearching {
            let what = (model.tokens.map(\.title) + [model.search.trimmingCharacters(in: .whitespaces)].filter { !$0.isEmpty })
                .map { "“\($0)”" }.joined(separator: " + ")
            return ("No results", "magnifyingglass", "No photo matches \(what) together.")
        }
        switch model.selection {
        case .filter(.videos, _)?: return ("No videos", "film", "No video files were found in the scanned folders.")
        case .filter(.best, _)?: return ("No scores yet", "sparkles", "Run the analysis (picasa-cli analyze) to score photos. Needs macOS 15 or later.")
        case .filter(.bursts, _)?: return ("No bursts", "square.stack.3d.forward.dottedline", "No sequences of 3+ shots taken within 2 seconds were found (run picasa-cli similar).")
        case .filter(.similar, _)?: return ("No similar photos", "square.on.square", "No duplicates or near-duplicates found (run picasa-cli analyze first).")
        case .filter(.animals, _)?: return ("No animals", "pawprint", "No cats or dogs found (run picasa-cli analyze first).")
        case .filter(.ignored, _)?: return ("No ignored images", "eye.slash", "No small images without camera metadata were found.")
        case .filter(.utility, _)?: return ("No screenshots or documents", "doc.text.viewfinder", "None found (run picasa-cli analyze first; needs macOS 15 or later).")
        case .filter(.starred, _)?: return ("No starred photos", "star", "Star a photo in the viewer (S), or import stars from Picasa.")
        case let .filter(.album, name)?: return ("Album is empty", "rectangle.stack", "“\(name)” has no photos in the scanned folders.")
        case let .filter(.year, name)?: return ("No photos in \(name)", "calendar", "No photo in the library is dated \(name).")
        case let .filter(.folder, name)?: return ("Empty folder", "folder", "“\(name)” has no photos left (or they are hidden in Picasa).")
        default: return ("No photos", "photo", "Nothing to show here.")
        }
    }
}

struct ViewerView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var item: MediaItem?
    @State private var full: NSImage?
    @State private var faces: [FaceRecord] = []
    @State private var tags: [String] = []
    @State private var scene: Library.SceneInfo?
    @State private var showFaces = true
    @State private var naming: FaceRecord?
    @State private var newName = ""
    @State private var player: AVPlayer?

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            HStack(spacing: 0) {
                ZStack {
                    Color.black
                    if let item, item.kind == .video, let player {
                        PlayerView(player: player)
                    } else if let full {
                        GeometryReader { geo in
                            let fitted = fit(full.size, in: geo.size)
                            ZStack(alignment: .topLeading) {
                                Image(nsImage: full).resizable().frame(width: fitted.width, height: fitted.height)
                                if showFaces {
                                    ForEach(faces) { f in
                                        faceBox(f, in: fitted)
                                    }
                                }
                            }
                            .frame(width: fitted.width, height: fitted.height)
                            .position(x: geo.size.width / 2, y: geo.size.height / 2)
                        }
                    } else {
                        ProgressView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Fixed-width panel so the sheet's size never depends on the loaded photo.
                InfoPanel(item: item, faces: faces, tags: tags, scene: scene)
            }
        }
        .task(id: model.viewing) { await load() }
        .onDisappear { player?.pause() }
        .alert("Who is this?", isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
            TextField("Name", text: $newName)
            Button("Save") {
                if let f = naming, !newName.isEmpty { Task { _ = try? await model.library.nameFace(f.id, name: newName); await load(); await model.refreshAll() } }
                naming = nil
            }
            Button("Cancel", role: .cancel) { naming = nil }
        }
    }

    /// Buttons in the sheet itself: a toolbar inside a sheet ties the sheet's size to its content and
    /// SwiftUI reported an AttributeGraph cycle when a photo was opened.
    var controls: some View {
        HStack(spacing: 12) {
            Button { step(-1) } label: { Image(systemName: "chevron.left") }
                .keyboardShortcut(.leftArrow, modifiers: []).help("Previous (←)")
            Button { step(1) } label: { Image(systemName: "chevron.right") }
                .keyboardShortcut(.rightArrow, modifiers: []).help("Next (→)")
            Text(item?.name ?? " ").font(.headline).lineLimit(1).truncationMode(.middle)
            Spacer()
            Toggle(isOn: $showFaces) { Image(systemName: "person.crop.square") }
                .toggleStyle(.button).help("Show faces")
            Button { if let item { Task { await model.toggleStar(item); await load() } } } label: {
                Image(systemName: item?.star == true ? "star.fill" : "star")
            }
            .keyboardShortcut("s", modifiers: []).help("Star (S)").disabled(item == nil)
            Button { if let item { NSWorkspace.shared.activateFileViewerSelecting([item.url]) } } label: { Image(systemName: "folder") }
                .help("Show in Finder").disabled(item == nil)
            Button("Close") { dismiss() }.keyboardShortcut(.escape, modifiers: [])
            // Space closes a photo like Quick Look (for videos it stays play/pause): always present, disabled for videos.
            Button("") { dismiss() }.keyboardShortcut(.space, modifiers: [])
                .disabled(item?.kind == .video).opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(height: 44)
    }

    func faceBox(_ f: FaceRecord, in size: CGSize) -> some View {
        let named = f.personId != nil
        let color: Color = named ? .green : (f.suggestedPersonId != nil ? .yellow : .white)
        return VStack(alignment: .leading, spacing: 2) {
            Rectangle().stroke(color, lineWidth: 2)
                .frame(width: f.w * size.width, height: f.h * size.height)
            if let n = f.personName {
                Text(named ? n : "\(n)?").font(.caption).padding(.horizontal, 3).background(.black.opacity(0.6)).foregroundStyle(color)
            }
        }
        .offset(x: f.x * size.width, y: f.y * size.height)
        .onTapGesture { newName = f.personName ?? ""; naming = f }
        .help(named ? "Rename" : "Name this face")
    }

    func fit(_ s: NSSize, in box: CGSize) -> CGSize {
        guard s.width > 0, s.height > 0 else { return box }
        let k = min(box.width / s.width, box.height / s.height)
        return CGSize(width: s.width * k, height: s.height * k)
    }

    func step(_ d: Int) {
        guard let v = model.viewing, !model.viewerIds.isEmpty else { return }
        model.viewing = min(max(0, v + d), model.viewerIds.count - 1)
    }

    func load() async {
        guard let v = model.viewing, model.viewerIds.indices.contains(v) else { return }
        let id = model.viewerIds[v]
        player?.pause()
        player = nil
        item = try? await model.library.items(ids: [id]).first
        faces = (try? await model.library.faces(mediaId: id)) ?? []
        tags = (try? await model.library.tags(mediaId: id)) ?? []
        scene = try? await model.library.scene(mediaId: id)
        full = model.thumbs.cached(id)
        if let item, item.kind == .video { player = AVPlayer(url: item.url); return }
        guard let item else { return }
        let px = Int((NSScreen.main?.frame.width ?? 2560) * (NSScreen.main?.backingScaleFactor ?? 2))
        let url = item.url
        if let cg = await Task.detached(priority: .userInitiated, operation: { ThumbnailStore.imageThumbnail(url, maxPixel: px) }).value,
           model.viewing == v {
            full = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }
    }
}

struct InfoPanel: View {
    let item: MediaItem?
    let faces: [FaceRecord]
    let tags: [String]
    let scene: Library.SceneInfo?

    var body: some View {
        Form {
            if let item {
                Section("File") {
                    LabeledContent("Name", value: item.name)
                    LabeledContent("Folder", value: (item.path as NSString).deletingLastPathComponent)
                    LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
                    if let w = item.width, let h = item.height { LabeledContent("Pixels", value: "\(w) × \(h)") }
                    if let d = item.duration { LabeledContent("Duration", value: Duration.seconds(d).formatted(.time(pattern: .minuteSecond))) }
                }
                Section("Picture") {
                    if let t = item.takenAt { LabeledContent("Taken", value: t.formatted(date: .long, time: .shortened)) }
                    if let c = item.camera { LabeledContent("Camera", value: c) }
                    if let lat = item.lat, let lon = item.lon {
                        LabeledContent("Place") {
                            Link(String(format: "%.5f, %.5f", lat, lon), destination: URL(string: "https://maps.apple.com/?ll=\(lat),\(lon)")!)
                        }
                    }
                    if let c = item.caption { LabeledContent("Caption", value: c) }
                    if !tags.isEmpty { LabeledContent("Tags", value: tags.joined(separator: ", ")) }
                    let people = faces.compactMap { $0.personId != nil ? $0.personName : nil }
                    if !people.isEmpty { LabeledContent("People", value: Array(Set(people)).sorted().joined(separator: ", ")) }
                }
                if let scene, !(scene.labels.isEmpty && scene.animals.isEmpty && scene.aesthetic == nil) {
                    Section("Detected") {
                        if !scene.animals.isEmpty { LabeledContent("Animals", value: Array(Set(scene.animals)).sorted().joined(separator: ", ")) }
                        if !scene.labels.isEmpty { LabeledContent("Labels", value: scene.labels.prefix(10).joined(separator: ", ")) }
                        if let a = scene.aesthetic { LabeledContent("Aesthetics", value: String(format: "%.2f", a) + (scene.utility ? " · document/screenshot" : "")) }
                        if scene.similarCount > 0 { LabeledContent("Similar", value: "\(scene.similarCount) other photo\(scene.similarCount > 1 ? "s" : "")") }
                        if scene.burstCount > 0 { LabeledContent("Burst", value: "\(scene.burstCount) shots") }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 300)
    }
}

struct PeopleView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selected: PersonSummary?
    @State private var naming: FaceCluster?

    var body: some View {
        if let p = selected {
            VStack(spacing: 0) {
                HStack {
                    Button { selected = nil } label: { Label("People", systemImage: "chevron.left") }
                    Text(p.name).font(.title2.bold())
                    Spacer()
                    if p.suggestions > 0 {
                        Button("Confirm \(p.suggestions) suggestions") { Task { await model.confirmAll(p); selected = nil } }
                    }
                }.padding(10)
                PersonGrid(person: p)
            }
        } else {
            ScrollView {
                if !model.persons.isEmpty {
                    header("People")
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 12)], spacing: 16) {
                        ForEach(model.persons) { p in
                            card(faceId: p.coverFaceId, title: p.name,
                                 subtitle: "\(p.faces) photos" + (p.suggestions > 0 ? " · \(p.suggestions) to confirm" : ""))
                                .onTapGesture { selected = p }
                        }
                    }.padding(.horizontal)
                }
                if !model.clusters.isEmpty {
                    header("Unnamed — click a group to name it")
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 12)], spacing: 16) {
                        ForEach(model.clusters) { c in
                            card(faceId: c.coverFaceId, title: "Unnamed", subtitle: "\(c.faceIds.count) face\(c.faceIds.count > 1 ? "s" : "")")
                                .onTapGesture { naming = c }
                        }
                    }.padding(.horizontal)
                }
            }
            .overlay {
                if model.persons.isEmpty && model.clusters.isEmpty {
                    ContentUnavailableView("No faces yet", systemImage: "person.2",
                                           description: Text("Run face detection (picasa-cli faces), import Picasa data, or name faces in the viewer."))
                }
            }
            .sheet(item: $naming) { c in ClusterSheet(cluster: c).environmentObject(model) }
        }
    }

    func header(_ t: String) -> some View {
        Text(t).font(.headline).frame(maxWidth: .infinity, alignment: .leading).padding([.horizontal, .top])
    }

    func card(faceId: Int64?, title: String, subtitle: String) -> some View {
        VStack {
            FaceThumb(faceId: faceId).frame(width: 120, height: 120).clipShape(Circle())
            Text(title).font(.headline).lineLimit(1)
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Name a group of similar unnamed faces; click a face to leave it out.
struct ClusterSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let cluster: FaceCluster
    @State private var excluded: Set<Int64> = []
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Who is this?").font(.title2.bold())
            Text("Click a face that is not this person to leave it out.").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: 8)], spacing: 8) {
                    ForEach(cluster.faceIds, id: \.self) { f in
                        FaceThumb(faceId: f).frame(width: 84, height: 84).clipShape(Circle())
                            .opacity(excluded.contains(f) ? 0.25 : 1)
                            .overlay(alignment: .bottomTrailing) {
                                if excluded.contains(f) { Image(systemName: "xmark.circle.fill").foregroundStyle(.red) }
                            }
                            .onTapGesture { if excluded.contains(f) { excluded.remove(f) } else { excluded.insert(f) } }
                    }
                }
            }
            .frame(minHeight: 200, maxHeight: 420)
            HStack {
                TextField("Name", text: $name).textFieldStyle(.roundedBorder).onSubmit(save)
                    .frame(minWidth: 240)
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Name \(cluster.faceIds.count - excluded.count) faces", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || excluded.count == cluster.faceIds.count)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    func save() {
        let faces = cluster.faceIds.filter { !excluded.contains($0) }
        let n = name
        guard !n.trimmingCharacters(in: .whitespaces).isEmpty, !faces.isEmpty else { return }
        dismiss()
        Task { await model.name(faces: faces, as: n) }
    }
}

struct PersonGrid: View {
    @EnvironmentObject private var model: AppModel
    let person: PersonSummary
    @State private var confirmed: [Int64] = []
    @State private var suggested: [Int64] = []
    @State private var showSuggested = false

    var body: some View {
        let ids = showSuggested ? suggested : confirmed
        VStack(spacing: 0) {
            Picker("", selection: $showSuggested) {
                Text("Confirmed (\(confirmed.count))").tag(false)
                Text("Suggested (\(suggested.count))").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize().padding(.bottom, 6)
            if ids.isEmpty {
                ContentUnavailableView(showSuggested ? "No suggestions" : "No confirmed photos", systemImage: "person.crop.square",
                                       description: Text(showSuggested ? "Run face detection to get suggestions for \(person.name)." : "Name faces of \(person.name) to see them here."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Same grid as the main view: arrows select, space/return opens, double-click opens.
                CollectionGrid(ids: ids, cellSize: 150, thumbs: model.thumbs) { model.open(ids, at: $0) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: person.id) {
            confirmed = (try? await model.library.mediaIds(.person(person.id))) ?? []
            suggested = (try? await model.library.mediaIds(.personSuggestions(person.id))) ?? []
        }
    }
}

/// Face crop taken from the cached thumbnail.
struct FaceThumb: View {
    @EnvironmentObject private var model: AppModel
    let faceId: Int64?
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Circle().fill(.quaternary)
            if let image { Image(nsImage: image).resizable().scaledToFill() } else { Image(systemName: "person.fill").font(.largeTitle).foregroundStyle(.secondary) }
        }
        .task(id: faceId) {
            guard let faceId, let f = try? await model.library.face(id: faceId) else { return }
            if let thumb = await model.thumbs.load(f.mediaId), let cg = thumb.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                image = Self.crop(cg, f)
                // Small faces are blurry in a 320 px thumbnail: re-crop from the original.
                if max(f.w * Double(cg.width), f.h * Double(cg.height)) >= 64 { return }
            }
            guard let item = try? await model.library.items(ids: [f.mediaId]).first else { return }
            let url = item.url
            if let big = await Task.detached(priority: .utility, operation: { ThumbnailStore.imageThumbnail(url, maxPixel: 2048) }).value,
               let c = Self.crop(big, f) {
                image = c
            }
        }
    }

    /// Square crop around the face, 1.4× its size.
    static func crop(_ cg: CGImage, _ f: FaceRecord) -> NSImage? {
        let W = Double(cg.width), H = Double(cg.height)
        let side = max(f.w * W, f.h * H) * 1.4
        let r = CGRect(x: (f.x + f.w / 2) * W - side / 2, y: (f.y + f.h / 2) * H - side / 2, width: side, height: side)
            .intersection(CGRect(x: 0, y: 0, width: W, height: H))
        guard let c = cg.cropping(to: r) else { return nil }
        return NSImage(cgImage: c, size: NSSize(width: c.width, height: c.height))
    }
}

/// AppKit's AVPlayerView. SwiftUI's VideoPlayer is avoided: on macOS it crashes when the player
/// is swapped and when the app runs outside an .app bundle (as with `swift run`).
struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.controlsStyle = .floating
        v.showsFullScreenToggleButton = true
        v.player = player
        return v
    }

    func updateNSView(_ v: AVPlayerView, context: Context) {
        if v.player !== player { v.player = player }
    }

    static func dismantleNSView(_ v: AVPlayerView, coordinator: ()) {
        v.player?.pause()
        v.player = nil
    }
}


/// Every label/keyword as a card (best photo as cover); click to open its photos.
struct LabelsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var labels: [LabelSummary] = []
    @State private var selected: LabelSummary?
    @State private var ids: [Int64] = []
    @State private var loading = true

    var body: some View {
        Group {
            if let l = selected {
                VStack(spacing: 0) {
                    HStack {
                        Button { selected = nil } label: { Label("Labels", systemImage: "chevron.left") }
                        Text(l.title).font(.title2.bold())
                        Text("\(ids.count) photos").foregroundStyle(.secondary)
                        Spacer()
                    }.padding(10)
                    CollectionGrid(ids: ids, cellSize: 150, thumbs: model.thumbs) { model.open(ids, at: $0) }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .task(id: l.label) { ids = (try? await model.library.mediaIds(.label(l.label))) ?? [] }
            } else if labels.isEmpty && !loading {
                ContentUnavailableView("No labels yet", systemImage: "tag",
                                       description: Text("Run the analysis (picasa-cli analyze) or import Picasa keywords."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14)], spacing: 16) {
                        ForEach(labels) { l in
                            VStack(spacing: 4) {
                                CoverThumb(mediaId: l.coverMediaId).frame(width: 140, height: 140)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                Text(l.title).font(.headline).lineLimit(1)
                                Text("\(l.count) photo\(l.count > 1 ? "s" : "")").font(.caption).foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { selected = l }
                        }
                    }.padding()
                }
            }
        }
        .task { labels = (try? await model.library.labelSummaries()) ?? []; loading = false }
    }
}

/// Square thumbnail of one media item.
struct CoverThumb: View {
    @EnvironmentObject private var model: AppModel
    let mediaId: Int64
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let image { Image(nsImage: image).resizable().scaledToFill() }
        }
        .clipped()
        .task(id: mediaId) { image = await model.thumbs.load(mediaId) }
    }
}
