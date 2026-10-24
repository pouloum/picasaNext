import AppKit
import AVKit
import PicasaCore
import SwiftUI

/// Brings the app to the front with its window when it starts (launched from a terminal it would
/// otherwise stay behind until clicked in the Dock) and sets the Dock icon when there is no app bundle.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Set at runtime too, so the Dock and ⌘-Tab show the phoenix even without the bundle's
        // .icns (swift run, .build/release) or while macOS still has a stale icon cached.
        if let icon = AppIcon.nsImage { NSApp.applicationIconImage = icon }
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
    /// Width of the detail column: the status bar is sized from it (toolbar items do not stretch).
    @State private var detailWidth: CGFloat = 900

    var body: some View {
        NavigationSplitView {
            Sidebar()
        } detail: {
            VStack(spacing: 0) {
                SearchBar().padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 6)
                Divider()
                Group {
                    if model.isSearching { GridView() }
                    else if case .people? = model.selection { IdentitiesView(kind: .face).id("faces") }
                    else if case .pets? = model.selection { IdentitiesView(kind: .pet).id("pets") }
                    else if case .relations? = model.selection { RelationsView() }
                    else if case .labels? = model.selection { LabelsView() }
                    else if case .places? = model.selection { PlacesView() }
                    else { GridView() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { detailWidth = $0 }
            .toolbar {
                // After the window title: four equal slots, content centred in each —
                // last scan · photos/videos · processing · add folder.
                ToolbarItem(placement: .primaryAction) {
                    let slot = max(60, (detailWidth - 200) / 4)
                    HStack(spacing: 0) {
                        LastScanStatus().frame(width: slot)
                        CountStatus().frame(width: slot)
                        JobStatus().frame(width: slot)
                        Button { model.addFolder() } label: { Label("Add Folder", systemImage: "folder.badge.plus") }
                            .labelStyle(.iconOnly).help("Add Folder to Library… (⌘O)").frame(width: slot)
                    }
                    .lineLimit(1)
                }
            }
        }
        .onChange(of: model.selection) {
            model.clearSearch()
            Task { await model.reloadGrid() }
        }
        .overlay {
            // Overlay rather than a sheet, so the viewer fills the window and can go full screen.
            if model.viewing != nil {
                ViewerView().environmentObject(model)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .transition(.opacity)
            }
        }
        .alert("Error", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
}

/// Toolbar, left: when the library was last scanned.
struct LastScanStatus: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        if let d = model.stats?.lastScan {
            Label("Last scan \(d.formatted(date: .abbreviated, time: .shortened))", systemImage: "clock.arrow.circlepath")
                .labelStyle(.titleAndIcon).font(.caption).foregroundStyle(.secondary)
                .help(d.formatted(.relative(presentation: .named)))
        }
    }
}

/// Toolbar, centre: what the grids show (indexed photos and videos).
struct CountStatus: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        if let s = model.stats {
            Text("\(s.shownPhotos.formatted()) photos · \(s.shownVideos.formatted()) videos").font(.callout).monospacedDigit()
        }
    }
}

/// Toolbar, right: work in progress (an app job, picasa-cli in a terminal, or what is left to do).
/// Click for the details (scanned / indexed / analysed, unreadable files, disks).
struct JobStatus: View {
    @EnvironmentObject private var model: AppModel
    @State private var showDetails = false

    var body: some View {
        Button { showDetails.toggle() } label: {
            HStack(spacing: 6) {
                if model.job != nil || model.externalActivity { ProgressView().controlSize(.small) }
                Text(summary).font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .help("Library status — click for details")
        .popover(isPresented: $showDetails, arrowEdge: .bottom) { LibraryStatus().environmentObject(model) }
    }

    var summary: String {
        if let job = model.job { return job + (model.jobDetail.map { " — \($0)" } ?? "") }
        guard let s = model.stats else { return "" }
        var todo: [String] = []
        if s.toIndex > 0 { todo.append("\(s.toIndex.formatted()) to index") }
        if s.pendingAnalysis > 0 { todo.append("\(s.pendingAnalysis.formatted()) to analyze") }
        if todo.isEmpty { return model.externalActivity ? "Processing…" : "" }
        return "Processing: " + todo.joined(separator: ", ")
    }
}

struct LibraryStatus: View {
    @EnvironmentObject private var model: AppModel
    @State private var roots: [(path: String, mounted: Bool)] = []

    var body: some View {
        let s = model.stats ?? Library.Stats()
        let files = s.images + s.raws + s.videos
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
            GridRow { Text("Scanned").bold(); Text("\(files.formatted()) files in \(s.folders.formatted()) folders · \(ByteCountFormatter.string(fromByteCount: s.bytes, countStyle: .file))") }
            GridRow { Text(""); Text("\(s.images.formatted()) photos · \(s.raws.formatted()) RAW · \(s.videos.formatted()) videos").foregroundStyle(.secondary) }
            Divider().gridCellColumns(2)
            stage("Metadata", done: files - s.pendingMeta - s.unreadableMeta, pending: s.pendingMeta, unreadable: s.unreadableMeta)
            stage("Thumbnails", done: s.thumbnails, pending: s.pendingThumbs, unreadable: s.unreadableThumbs)
            stage("Analysis", done: s.analysed, pending: s.pendingAnalysis, unreadable: 0)
            GridRow { Text("Faces"); Text("\(s.faces.formatted()) · \(s.namedFaces.formatted()) named · \(s.ignoredFaces.formatted()) ignored") }
            GridRow { Text("Animals"); Text("\(s.animals.formatted()) photos · \(s.pets.formatted()) pets named") }
            Divider().gridCellColumns(2)
            GridRow { Text("Last scan"); Text(s.lastScan.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "never") }
            ForEach(roots, id: \.path) { r in
                GridRow {
                    Text(r.path == roots.first?.path ? "Folders" : "")
                    Label(r.path, systemImage: r.mounted ? "externaldrive.fill" : "externaldrive.badge.xmark")
                        .foregroundStyle(r.mounted ? Color.primary : Color.red)
                        .help(r.mounted ? "Available" : "Not available (disk not mounted?)")
                }
            }
            if s.pendingMeta + s.pendingThumbs + s.pendingAnalysis + s.unreadableThumbs > 0 {
                Divider().gridCellColumns(2)
                Text("Missing thumbnails are made as you browse. To finish everything: picasa-cli index, then picasa-cli analyze (unreadable files are retried each time).")
                    .font(.caption).foregroundStyle(.secondary).gridCellColumns(2).frame(width: 420, alignment: .leading)
            }
        }
        .font(.callout)
        .padding(16)
        .task {
            roots = ((try? await model.library.roots()) ?? []).map { ($0.path, FileManager.default.fileExists(atPath: $0.path)) }
        }
    }

    @ViewBuilder func stage(_ name: String, done: Int, pending: Int, unreadable: Int) -> some View {
        GridRow {
            Text(name)
            HStack(spacing: 4) {
                Text("\(max(0, done).formatted()) done")
                if pending > 0 { Text("· \(pending.formatted()) to do").foregroundStyle(.orange) }
                if unreadable > 0 { Text("· \(unreadable.formatted()) unreadable").foregroundStyle(.red).help("The file could not be read when it was processed (disk away?). Retried on the next run.") }
            }
        }
    }
}

struct Sidebar: View {
    @EnvironmentObject private var model: AppModel
    /// Local selection, forwarded to the model on the next run-loop turn: updating published state
    /// from inside the List's NSTableView delegate callback re-entered it ("reentrant operation" warning).
    @State private var selection: SidebarItem? = .filter(.all, "All photos")

    /// A sidebar entry; the selected one is bold with a filled icon, so it stays visible when the
    /// sidebar loses focus (the system highlight then fades to light grey).
    /// The tag must stay the outermost modifier: a badge or help applied after it hid the tag from
    /// the List, and the row could no longer be selected.
    func row(_ title: String, _ icon: String, _ tag: SidebarItem, badge: Int = 0, help: String = "", dim: Bool = false) -> some View {
        let on = selection == tag
        return Label { Text(title).fontWeight(on ? .semibold : .regular) } icon: { Image(systemName: icon).symbolVariant(on ? .fill : .none) }
            .foregroundStyle(dim ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            .badge(badge)
            .help(help)
            .tag(tag)
    }

    var body: some View {
        List(selection: $selection) {
            Section("Library") {
                row("All photos", "photo.on.rectangle", SidebarItem.filter(.all, "All photos"))
                row("Last indexed", "clock.badge.checkmark", SidebarItem.filter(.recent, "Last indexed"),
                    help: "The 2 000 photos most recently added to the library, newest first (fills in live during a scan)")
                row("Starred", "star", SidebarItem.filter(.starred, "Starred"))
                row("Videos", "film", SidebarItem.filter(.videos, "Videos"))
                row("People", "person.2", SidebarItem.people)
                row("Relations", "point.3.connected.trianglepath.dotted", SidebarItem.relations,
                    help: "Who is photographed with whom: people and the photos they share")
                row("Animals", "pawprint", SidebarItem.pets, badge: model.stats?.animals ?? 0)
                row("Labels", "tag", SidebarItem.labels)
                row("Places", "map", SidebarItem.places)
            }
            Section("Discover") {
                row("Best photos", "sparkles", SidebarItem.filter(.best, "Best photos"))
                row("Duplicates", "doc.on.doc", SidebarItem.filter(.duplicates, "Duplicates"), badge: model.stats?.duplicateGroups ?? 0,
                    help: "Identical files: one copy is kept in the library, the others are hidden (files are never touched)")
                row("Similar", "square.on.square", SidebarItem.filter(.similar, "Similar"), badge: model.stats?.similarGroups ?? 0,
                    help: "Near-duplicates (same scene, re-saves, edits), outside bursts and identical files")
                row("Bursts", "square.stack.3d.forward.dottedline", SidebarItem.filter(.bursts, "Bursts"), badge: model.stats?.bursts ?? 0,
                    help: "Sequences of at least 3 shots taken ≤ 2 s apart with the same camera")
                row("Estimated dates", "calendar.badge.exclamationmark", SidebarItem.filter(.estimatedDates, "Estimated dates"),
                    badge: model.stats?.estimatedDates ?? 0,
                    help: "No date in the photo itself: dated from its file name, its folder, or the file date. Worth checking.")
                row("Screenshots & documents", "doc.text.viewfinder", SidebarItem.filter(.utility, "Screenshots & documents"), badge: model.stats?.utility ?? 0)
                if (model.stats?.ignored ?? 0) > 0 {
                    row("Small images (ignored)", "eye.slash", SidebarItem.filter(.ignored, "Small images (ignored)"), badge: model.stats?.ignored ?? 0,
                        help: "Probable thumbnails written by other apps: small and without camera metadata. Not analysed, hidden elsewhere.", dim: true)
                }
            }
            if !model.albums.isEmpty {
                Section("Albums") {
                    ForEach(model.albums) { a in
                        row(a.name, "rectangle.stack", SidebarItem.filter(.album(a.id), a.name), badge: a.count)
                    }
                }
            }
            if !model.years.isEmpty {
                Section("Years") {
                    ForEach(model.years, id: \.year) { y in
                        row(String(y.year), "calendar", SidebarItem.filter(.year(y.year), String(y.year)), badge: y.count)
                    }
                }
            }
            Section("Folders") {
                ForEach(model.folders) { f in
                    row(f.title, "folder", SidebarItem.filter(.folder(f.id), f.title), badge: f.count, help: f.path)
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
        if !model.loaded {
            ProgressView("Loading the library…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.ids.isEmpty {
            let e = emptyState
            ContentUnavailableView(e.title, systemImage: e.icon, description: Text(e.message))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                YearGrid(ids: model.ids, sections: model.sections, cellSize: size, resetKey: model.currentFilter,
                         badges: model.groups.isEmpty ? [:] : model.groupBadges, expanded: model.expanded,
                         members: model.groups.isEmpty ? [] : model.expandedMembers,
                         onBadge: model.groups.isEmpty ? nil : { model.toggleGroup($0) })
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
        case .filter(.estimatedDates, _)?: return ("No estimated dates", "calendar.badge.exclamationmark", "Every indexed photo has a date of its own.")
        case .filter(.recent, _)?: return ("Nothing indexed yet", "clock.badge.checkmark", "Photos show up here as the indexer makes their thumbnails (picasa-cli index).")
        case .filter(.videos, _)?: return ("No videos", "film", "No video files were found in the scanned folders.")
        case .filter(.best, _)?: return ("No scores yet", "sparkles", "Run the analysis (picasa-cli analyze) to score photos. Needs macOS 15 or later.")
        case .filter(.bursts, _)?: return ("No bursts", "square.stack.3d.forward.dottedline", "No series of look-alike shots taken within 2 seconds were found (picasa-cli similar).")
        case .filter(.similar, _)?: return ("No similar photos", "square.on.square", "No near-duplicates found (picasa-cli analyze, then picasa-cli similar).")
        case .filter(.duplicates, _)?: return ("No duplicates", "doc.on.doc", "No identical files found (picasa-cli similar).")
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

/// Full-window photo/video viewer, shown as an overlay on the main window (a sheet cannot go full screen).
/// Pinch or double-click to zoom (the full-resolution file is loaded when zoomed), drag to pan,
/// click outside the photo, Esc or Space to close, F for full screen.
struct ViewerView: View {
    @EnvironmentObject private var model: AppModel
    @State private var item: MediaItem?
    @State private var full: NSImage?
    @State private var fullResLoaded = false
    @State private var faces: [FaceRecord] = []
    @State private var pets: [FaceRecord] = []
    /// The face / animal whose naming popover is open (kind + region id).
    @State private var editing: String?
    /// The photo is being analysed now (opened before the analysis got to it).
    @State private var analysing = false
    @State private var tags: [String] = []
    @State private var scene: Library.SceneInfo?
    @State private var showFaces = true
    @State private var player: AVPlayer?
    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @GestureState private var pinch: CGFloat = 1
    @GestureState private var drag: CGSize = .zero
    @FocusState private var focused: Bool
    /// The grid under the overlay kept keyboard focus (Space reopened the photo instead of closing it):
    /// the viewer takes focus while open and gives it back on close.
    @State private var previousResponder: NSResponder?

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            HStack(spacing: 0) {
                ZStack {
                    // Clicking the black area around the photo closes the viewer.
                    Color.black.contentShape(Rectangle()).onTapGesture { close() }
                    if let item, item.kind == .video, let player {
                        PlayerView(player: player, onClose: close)
                    } else if let full {
                        photo(full)
                    } else {
                        ProgressView()
                    }
                }
                .clipped()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                InfoPanel(item: item, faces: faces, tags: tags, scene: scene)
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.space) { close(); return .handled }
        .onKeyPress(.return) {
            guard item?.kind == .video else { return .ignored }
            togglePlay()
            return .handled
        }
        .onAppear {
            let window = NSApp.keyWindow
            previousResponder = window?.firstResponder
            DispatchQueue.main.async {
                window?.makeFirstResponder(nil)
                focused = true
            }
        }
        .task(id: model.viewing) { await load() }
        .onChange(of: model.revision) { Task { await loadInfo() } }
        .onDisappear {
            player?.pause()
            if let r = previousResponder { NSApp.keyWindow?.makeFirstResponder(r) }
        }
        .onChange(of: zoom) { if zoom > 1.2 { Task { await loadFullResolution() } } }
    }

    func photo(_ img: NSImage) -> some View {
        let scale = max(1, zoom * pinch)
        return Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
            .overlay(alignment: .topLeading) {
                if showFaces && !(faces.isEmpty && pets.isEmpty) {
                    GeometryReader { g in
                        ForEach(faces.filter { !$0.ignored }) { f in faceBox(f, kind: .face, in: g.size) }
                        ForEach(pets.filter { !$0.ignored }) { f in faceBox(f, kind: .pet, in: g.size) }
                    }
                }
            }
            .scaleEffect(scale)
            .offset(x: pan.width + drag.width, y: pan.height + drag.height)
            .gesture(MagnifyGesture()
                .updating($pinch) { v, st, _ in st = v.magnification }
                .onEnded { v in
                    zoom = min(8, max(1, zoom * v.magnification))
                    if zoom == 1 { pan = .zero }
                })
            .simultaneousGesture(DragGesture(minimumDistance: 3)
                .updating($drag) { v, st, _ in if zoom > 1 { st = v.translation } }
                .onEnded { v in if zoom > 1 { pan.width += v.translation.width; pan.height += v.translation.height } })
            .onTapGesture(count: 2) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if zoom > 1 { zoom = 1; pan = .zero } else { zoom = 2.5 }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Buttons inside the viewer (a toolbar ties a sheet/overlay's size to its content: AttributeGraph cycles).
    var controls: some View {
        HStack(spacing: 12) {
            Button { step(-1) } label: { Image(systemName: "chevron.left") }
                .keyboardShortcut(.leftArrow, modifiers: []).help("Previous (←)")
            Button { step(1) } label: { Image(systemName: "chevron.right") }
                .keyboardShortcut(.rightArrow, modifiers: []).help("Next (→)")
            Text(item?.name ?? " ").font(.headline).lineLimit(1).truncationMode(.middle)
            Spacer()
            if zoom > 1 {
                Button { withAnimation { zoom = 1; pan = .zero } } label: { Text("×\(String(format: "%.1f", zoom))").monospacedDigit() }
                    .help("Back to fit (double-click)")
            }
            if analysing {
                HStack(spacing: 4) { ProgressView().controlSize(.small); Text("Detecting faces…").font(.caption).foregroundStyle(.secondary) }
            }
            Toggle(isOn: $showFaces) { Image(systemName: "person.crop.square") }
                .toggleStyle(.button).help("Show face and pet frames with their names (click one to name it)")
            Button { if let item { Task { await model.toggleStar(item); await load() } } } label: {
                Image(systemName: item?.star == true ? "star.fill" : "star")
            }
            .keyboardShortcut("s", modifiers: []).help("Star (S)").disabled(item == nil)
            Button { if let item { NSWorkspace.shared.activateFileViewerSelecting([item.url]) } } label: { Image(systemName: "folder") }
                .help("Show in Finder").disabled(item == nil)
            Button { NSApp.keyWindow?.toggleFullScreen(nil) } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                .keyboardShortcut("f", modifiers: []).help("Full screen (F)")
            Button("Close") { close() }.keyboardShortcut(.escape, modifiers: [])
            // Space closes like Quick Look, photos and videos alike; Return plays/pauses a video.
            Button("") { close() }.keyboardShortcut(.space, modifiers: [])
                .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
            Button("") { togglePlay() }.keyboardShortcut(.return, modifiers: [])
                .disabled(item?.kind != .video).opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(height: 44)
    }

    func faceBox(_ f: FaceRecord, kind: IdentityKind, in size: CGSize) -> some View {
        let named = f.personId != nil
        let suggested = !named && f.suggestedPersonId != nil
        let color: Color = kind == .pet ? (named ? .orange : suggested ? .yellow : .white.opacity(0.8)) : (named ? .green : (suggested ? .yellow : .white))
        let key = "\(kind.rawValue):\(f.id)"
        let label = named ? (f.personName ?? "") : suggested ? "\(f.personName ?? "")?" : (kind == .face ? "Who?" : "Name?")
        return VStack(alignment: .leading, spacing: 2) {
            Rectangle().stroke(color, style: StrokeStyle(lineWidth: 2, dash: named ? [] : [5, 3]))
                .frame(width: f.w * size.width, height: f.h * size.height)
                .contentShape(Rectangle())
            Text(label).font(.caption.weight(named ? .semibold : .regular))
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 3)).foregroundStyle(color)
        }
        .offset(x: f.x * size.width, y: f.y * size.height)
        .onTapGesture { editing = key }
        .popover(isPresented: Binding(get: { editing == key }, set: { if !$0, editing == key { editing = nil } }), arrowEdge: .bottom) {
            RegionEditor(kind: kind, region: f) {
                editing = nil
                Task { try? await Task.sleep(for: .milliseconds(400)); await loadInfo() }
            }
            .environmentObject(model)
        }
        .contextMenu {
            if !named {
                Button("Ignore this \(kind.itemWord)") { Task { await model.setIgnored(kind, [f.id], true); await loadInfo() } }
            }
        }
        .help(named ? "Rename" : suggested ? "Confirm or reject this suggestion" : "Name this \(kind.itemWord) (right-click to ignore)")
    }

    func togglePlay() {
        guard let player else { return }
        if player.timeControlStatus == .paused { player.play() } else { player.pause() }
    }

    func close() {
        player?.pause()
        model.viewing = nil
    }

    func step(_ d: Int) {
        guard let v = model.viewing, !model.viewerIds.isEmpty else { return }
        model.viewing = min(max(0, v + d), model.viewerIds.count - 1)
    }

    func load() async {
        guard let v = model.viewing, model.viewerIds.indices.contains(v) else { return }
        let id = model.viewerIds[v]
        if item?.id != id { zoom = 1; pan = .zero; fullResLoaded = false; full = model.thumbs.cached(id) }
        player?.pause()
        player = nil
        await loadInfo()
        if let item, item.kind == .video { player = AVPlayer(url: item.url); return }
        guard let item, !fullResLoaded else { return }
        let px = Int((NSScreen.main?.frame.width ?? 2560) * (NSScreen.main?.backingScaleFactor ?? 2))
        let url = item.url
        if let cg = await Task.detached(priority: .userInitiated, operation: { ThumbnailStore.imageThumbnail(url, maxPixel: px) }).value,
           model.viewing == v, !fullResLoaded {
            full = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }
    }

    /// Metadata, faces and analysis of the current item (reloaded live while an analysis runs).
    func loadInfo() async {
        guard let v = model.viewing, model.viewerIds.indices.contains(v) else { return }
        let id = model.viewerIds[v]
        item = try? await model.library.items(ids: [id]).first
        faces = (try? await model.library.faces(mediaId: id)) ?? []
        pets = (try? await model.library.regions(.pet, mediaId: id)) ?? []
        // Not analysed yet (or skipped while the disk was away): detect faces and animals now.
        if !analysing, item?.kind != .video, (try? await model.library.needsAnalysis(id)) == true {
            analysing = true
            let lib = model.library
            _ = try? await Analyzer(library: lib, concurrency: 1).analyze(mediaIds: [id])
            analysing = false
            if model.viewing.map({ model.viewerIds.indices.contains($0) && model.viewerIds[$0] == id }) == true {
                faces = (try? await lib.faces(mediaId: id)) ?? []
                pets = (try? await lib.regions(.pet, mediaId: id)) ?? []
                scene = try? await lib.scene(mediaId: id)
            }
        }
        tags = (try? await model.library.tags(mediaId: id)) ?? []
        scene = try? await model.library.scene(mediaId: id)
    }

    /// Zoomed in: replace the screen-sized preview with the file at full resolution (capped at 12k px).
    func loadFullResolution() async {
        guard !fullResLoaded, let item, item.kind != .video, let v = model.viewing else { return }
        fullResLoaded = true
        let px = min(12_000, max(item.width ?? 0, item.height ?? 0, 4000))
        let url = item.url
        if let cg = await Task.detached(priority: .userInitiated, operation: { ThumbnailStore.imageThumbnail(url, maxPixel: px) }).value,
           model.viewing == v {
            full = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }
    }
}

struct InfoPanel: View {
    @EnvironmentObject private var model: AppModel
    @State private var copies: [String] = []
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
                    if !copies.isEmpty {
                        LabeledContent("Identical copies") {
                            VStack(alignment: .trailing, spacing: 1) {
                                ForEach(copies.prefix(5), id: \.self) { Text($0).font(.caption).lineLimit(1).truncationMode(.head) }
                                if copies.count > 5 { Text("+ \(copies.count - 5) more").font(.caption).foregroundStyle(.secondary) }
                            }
                }
                Section("Picture") {
                    if let t = item.takenAt {
                        LabeledContent("Taken") {
                            VStack(alignment: .trailing, spacing: 1) {
                                Text(t.formatted(date: .long, time: .shortened))
                                if let src = item.dateSource, src != .metadata {
                                    Label("Estimated from the \(src.label)", systemImage: "exclamationmark.triangle")
                                        .font(.caption).foregroundStyle(.orange)
                                        .help("The photo has no date of its own; this one comes from its \(src.label).")
                                }
                            }
                        }
                    }
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
            }
        }
        .task(id: item?.id) {
            guard let id = item?.id else { copies = []; return }
            copies = (try? await model.library.copies(of: id)) ?? []
        }
        .formStyle(.grouped)
        .frame(width: 300)
    }
}

/// Limits concurrent reads of original files (People crops): a grid of faces must not open
/// dozens of originals at once on a network disk.
actor OriginalReads {
    static let shared = OriginalReads(limit: 2)
    private let limit: Int
    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = limit }

    func run<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        if running >= limit { await withCheckedContinuation { waiting.append($0) } } else { running += 1 }
        defer { if waiting.isEmpty { running -= 1 } else { waiting.removeFirst().resume() } }
        return await Task.detached(priority: .utility, operation: body).value
    }
}

/// AppKit's AVPlayerView. SwiftUI's VideoPlayer is avoided: on macOS it crashes when the player
/// is swapped and when the app runs outside an .app bundle (as with `swift run`).
/// Keys are remapped like the photo viewer: Space closes, Return plays/pauses (AVPlayerView would
/// otherwise take Space as play/pause once clicked).
struct PlayerView: NSViewRepresentable {
    let player: AVPlayer
    var onClose: () -> Void = {}

    func makeNSView(context: Context) -> AVPlayerView {
        let v = KeyedPlayerView()
        v.onClose = onClose
        v.controlsStyle = .floating
        v.showsFullScreenToggleButton = true
        v.player = player
        return v
    }

    func updateNSView(_ v: AVPlayerView, context: Context) {
        if v.player !== player { v.player = player }
        (v as? KeyedPlayerView)?.onClose = onClose
    }

    static func dismantleNSView(_ v: AVPlayerView, coordinator: ()) {
        v.player?.pause()
        v.player = nil
    }
}

final class KeyedPlayerView: AVPlayerView {
    var onClose: () -> Void = {}

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 49: onClose() // space
        case 36, 76: // return, keypad enter
            guard let p = player else { return }
            if p.timeControlStatus == .paused { p.play() } else { p.pause() }
        default: super.keyDown(with: event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 49, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty { onClose(); return true }
        return super.performKeyEquivalent(with: event)
    }
}

/// Every label/keyword as a card (best photo as cover); click to open its photos.
struct LabelsView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("grid.showFrames") private var showFrames = true
    static let animalLabels: Set<String> = ["cat", "dog", "animal", "pet", "kitten", "puppy", "feline", "canine", "mammal"]
    @State private var labels: [LabelSummary] = []
    @State private var selected: LabelSummary?
    @State private var rows: [(id: Int64, year: Int)] = []
    @State private var loading = true

    var body: some View {
        Group {
            if let l = selected {
                VStack(spacing: 0) {
                    HStack {
                        Button { selected = nil } label: { Label("Labels", systemImage: "chevron.left") }
                        Text(l.title).font(.title2.bold())
                        Text("\(rows.count) photos").foregroundStyle(.secondary)
                        Spacer()
                        // Labels describe the whole photo; only animal labels have frames (the animals found).
                        if Self.animalLabels.contains(l.label.lowercased()) {
                            FramesToggle(help: "Show the animals found on the thumbnails: solid once named, dashed when not yet")
                        }
                    }.padding(10)
                    YearGrid(ids: rows.map(\.id), sections: GridSection.byYear(rows.map(\.year)), resetKey: l.label,
                             frames: showFrames && Self.animalLabels.contains(l.label.lowercased()) ? .identities(model.library, .pet) : nil)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .task(id: [l.label, String(model.revision)]) { rows = (try? await model.library.mediaIdsAndYears(.label(l.label))) ?? [] }
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
        .task(id: model.revision) { labels = (try? await model.library.labelSummaries()) ?? []; loading = false }
    }
}

/// Square thumbnail of one media item.
struct CoverThumb: View {
    @EnvironmentObject private var model: AppModel
    let mediaId: Int64
    @State private var image: NSImage?
    @State private var shown: Int64?

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let image { Image(nsImage: image).resizable().scaledToFill() }
        }
        .clipped()
        .task(id: [mediaId, Int64(model.revision)]) {
            // The same view can be given another photo (a map pin whose cover changed): reload then.
            guard image == nil || shown != mediaId else { return }
            if shown != mediaId { image = nil }
            image = await model.thumbs.load(mediaId)
            shown = mediaId
        }
    }
}
