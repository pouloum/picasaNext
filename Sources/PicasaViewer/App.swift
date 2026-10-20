import AppKit
import AVKit
import PicasaCore
import SwiftUI

@main
struct PicasaNextApp: App {
    @StateObject private var model = AppModel()

    init() {
        // Running as a bare executable (swift run): become a regular app with a Dock icon.
        NSApplication.shared.setActivationPolicy(.regular)
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
            Group {
                if case .people? = model.selection { PeopleView() } else { GridView() }
            }
            .toolbar {
                ToolbarItem(placement: .status) { JobStatus() }
                ToolbarItem { Button { model.addFolder() } label: { Label("Add Folder", systemImage: "folder.badge.plus") } }
            }
        }
        .searchable(text: $model.search, prompt: "Name, caption, tag, person, album, camera")
        .onChange(of: model.search) { Task { await model.reloadGrid() } }
        .onChange(of: model.selection) { Task { await model.reloadGrid() } }
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

    var body: some View {
        List(selection: $model.selection) {
            Section("Library") {
                Label("All photos", systemImage: "photo.on.rectangle").tag(SidebarItem.filter(.all, "All photos"))
                Label("Starred", systemImage: "star").tag(SidebarItem.filter(.starred, "Starred"))
                Label("Videos", systemImage: "film").tag(SidebarItem.filter(.videos, "Videos"))
                Label("People", systemImage: "person.2").tag(SidebarItem.people)
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
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 200, ideal: 240)
    }
}

struct GridView: View {
    @EnvironmentObject private var model: AppModel
    @State private var size: CGFloat = 150

    var body: some View {
        VStack(spacing: 0) {
            if model.ids.isEmpty {
                ContentUnavailableView("No photos", systemImage: "photo",
                                       description: Text(model.stats?.folders == 0 ? "Add a folder (⌘O) to start." : "Nothing matches."))
            } else {
                CollectionGrid(ids: model.ids, cellSize: size, thumbs: model.thumbs) { model.open(model.ids, at: $0) }
            }
            HStack {
                Text("\(model.ids.count) items").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Slider(value: $size, in: 80...320).frame(width: 160)
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
        }
    }
}

struct ThumbCell: View {
    @EnvironmentObject private var model: AppModel
    let id: Int64
    let size: CGFloat
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            }
        }
        .frame(minWidth: size, minHeight: size).aspectRatio(1, contentMode: .fit)
        .clipped()
        .task(id: id) { image = model.thumbs.cached(id); if image == nil { image = await model.thumbs.load(id) } }
    }
}

struct ViewerView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var item: MediaItem?
    @State private var full: NSImage?
    @State private var faces: [FaceRecord] = []
    @State private var tags: [String] = []
    @State private var showFaces = true
    @State private var naming: FaceRecord?
    @State private var newName = ""
    @State private var player: AVPlayer?

    var body: some View {
        HStack(spacing: 0) {
            ZStack {
                Color.black
                if let item, item.kind == .video, let player {
                    VideoPlayer(player: player)
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
            if let item { InfoPanel(item: item, faces: faces, tags: tags) }
        }
        .toolbar {
            ToolbarItemGroup {
                Button { step(-1) } label: { Image(systemName: "chevron.left") }.keyboardShortcut(.leftArrow, modifiers: [])
                Button { step(1) } label: { Image(systemName: "chevron.right") }.keyboardShortcut(.rightArrow, modifiers: [])
                Toggle(isOn: $showFaces) { Image(systemName: "person.crop.square") }
                if let item {
                    Button { Task { await model.toggleStar(item); await load() } } label: {
                        Image(systemName: item.star ? "star.fill" : "star")
                    }.keyboardShortcut("s", modifiers: [])
                    Button { NSWorkspace.shared.activateFileViewerSelecting([item.url]) } label: { Image(systemName: "folder") }
                }
                Button("Close") { dismiss() }.keyboardShortcut(.escape, modifiers: [])
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
    let item: MediaItem
    let faces: [FaceRecord]
    let tags: [String]

    var body: some View {
        Form {
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
        }
        .formStyle(.grouped)
        .frame(width: 300)
    }
}

struct PeopleView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selected: PersonSummary?

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
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 12)], spacing: 16) {
                    ForEach(model.persons) { p in
                        VStack {
                            FaceThumb(faceId: p.coverFaceId).frame(width: 120, height: 120).clipShape(Circle())
                            Text(p.name).font(.headline).lineLimit(1)
                            Text("\(p.faces) photos" + (p.suggestions > 0 ? " · \(p.suggestions) to confirm" : ""))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .onTapGesture { selected = p }
                    }
                }.padding()
            }
            .overlay { if model.persons.isEmpty { ContentUnavailableView("No people yet", systemImage: "person.2", description: Text("Import Picasa data or name faces in the viewer.")) } }
        }
    }
}

struct PersonGrid: View {
    @EnvironmentObject private var model: AppModel
    let person: PersonSummary
    @State private var confirmed: [Int64] = []
    @State private var suggested: [Int64] = []

    var body: some View {
        ScrollView {
            if !suggested.isEmpty {
                Text("Suggested").font(.headline).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal)
                grid(suggested)
            }
            Text("Confirmed").font(.headline).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal)
            grid(confirmed)
        }
        .task(id: person.id) {
            confirmed = (try? await model.library.mediaIds(.person(person.id))) ?? []
            suggested = (try? await model.library.mediaIds(.personSuggestions(person.id))) ?? []
        }
    }

    func grid(_ ids: [Int64]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 4)], spacing: 4) {
            ForEach(ids, id: \.self) { id in
                ThumbCell(id: id, size: 140).onTapGesture(count: 2) {
                    if let i = ids.firstIndex(of: id) { model.open(ids, at: i) }
                }
            }
        }.padding(6)
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
            guard let faceId, let f = try? await model.library.face(id: faceId),
                  let thumb = await model.thumbs.load(f.mediaId),
                  let cg = thumb.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
            let W = Double(cg.width), H = Double(cg.height)
            let side = max(f.w * W, f.h * H) * 1.4
            let r = CGRect(x: (f.x + f.w / 2) * W - side / 2, y: (f.y + f.h / 2) * H - side / 2, width: side, height: side)
                .intersection(CGRect(x: 0, y: 0, width: W, height: H))
            if let c = cg.cropping(to: r) { image = NSImage(cgImage: c, size: NSSize(width: c.width, height: c.height)) }
        }
    }
}
