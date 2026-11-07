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

    static func profileLabel(_ p: ThroughputProfile) -> String {
        switch p {
        case .auto: "Automatic (from each disk)"
        case .ssd: "SSD"
        case .hdd: "Hard Disk"
        case .nas: "Network Share (NAS)"
        case .eco: "Economy (1–2 files at a time)"
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
                Button("Rescan Library") { model.rescan() }.keyboardShortcut("r")
                Divider()
                Button("Import Picasa Data…") { model.importPicasa() }
                Button("Import Contacts File…") { model.importContacts() }
                Divider()
                Button("Export Edits to Photo Folders…") { model.sheet = .export }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
            }
            CommandMenu("Processing") {
                // What a scan runs after, one stage at a time (picasa-cli index / analyze / similar / suggest / geocode).
                Group {
                    Button("Index Pending Items") { model.indexPending() }
                    Button("Analyze Pending Images") { model.analyzePending() }
                    Button("Find Similar Photos") { model.findSimilar() }
                    Button("Recompute Name Suggestions") { model.suggestNames() }
                    Button("Name Places (Geocode)") { model.geocode() }
                }
                .disabled(model.job != nil)
                Divider()
                Group {
                    Button("Regenerate All Thumbnails…") { model.sheet = .redoThumbnails }
                    Button("Redo Analysis…") { model.sheet = .redoAnalysis }
                    Button("Merge Duplicate Names…") { model.sheet = .mergeNames }
                }
                .disabled(model.job != nil)
                Divider()
                // Indexing and analysis: parallel files and batch sizes, from the disk of the photos
                // (Automatic) or forced; tuned during each run and remembered per disk.
                Menu("Performance Profile") {
                    Picker("Performance Profile", selection: $model.throughputProfile) {
                        ForEach(ThroughputProfile.allCases, id: \.self) { p in
                            Text(Self.profileLabel(p)).tag(p)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                Divider()
                Button("Show Performance Plan…") { model.sheet = .plan }
                Button("Forget Tuned Values") { model.forgetTuning() }
                    .help("The next run starts again from the values of the profile")
            }
        }
        Settings {
            SettingsView().environmentObject(model)
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
                    else if case .roots? = model.selection { RootsView() }
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
                        HStack(spacing: 14) {
                            Button { model.revealInFinder() } label: { Label("Show in Finder", systemImage: "folder") }
                                .labelStyle(.iconOnly).disabled(!model.canReveal)
                                .help("Show in Finder: the selected photos, or the folder shown (⇧⌘R)")
                                .keyboardShortcut("r", modifiers: [.command, .shift])
                            Button { model.addFolder() } label: { Label("Add Folder", systemImage: "folder.badge.plus") }
                                .labelStyle(.iconOnly).help("Add Folder to Library… (⌘O)")
                        }
                        .frame(width: slot)
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
        .alert("Done", isPresented: Binding(get: { model.notice != nil && model.error == nil }, set: { if !$0 { model.notice = nil } })) {
            Button("OK") { model.notice = nil }
        } message: { Text(model.notice ?? "") }
        .sheet(item: $model.sheet) { sheet in
            ToolSheet(sheet: sheet).environmentObject(model)
        }
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
                Text("Missing thumbnails are made as you browse. To finish everything: Processing ▸ Index Pending Items, then Analyze Pending Images (unreadable files are retried each time).")
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
    func row(_ title: String, _ icon: String, _ tag: SidebarItem, badge: Int = 0, help: String = "", dim: Bool = false,
             reveal: String? = nil) -> some View {
        let on = selection == tag
        return Label { Text(title).fontWeight(on ? .semibold : .regular) } icon: { Image(systemName: icon).symbolVariant(on ? .fill : .none) }
            .foregroundStyle(dim ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            .badge(badge)
            .help(help)
            .contextMenu {
                if let reveal { Button("Show in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: reveal) } }
            }
            .tag(tag)
    }

    var body: some View {
        List(selection: $selection) {
            row("Folders", "externaldrive", SidebarItem.roots, badge: model.rootCards.count,
                help: "The folders added to the library: their photos and videos, last scan and work in progress")
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
                        let title = y.year == 0 ? "No date" : String(y.year)
                        row(title, y.year == 0 ? "calendar.badge.exclamationmark" : "calendar", SidebarItem.filter(.year(y.year), title), badge: y.count,
                            help: y.year == 0 ? "No date in the photo, or a date in the future (camera clock never set). Set one in the viewer's info panel." : "")
                    }
                }
            }
            Section("Folders") {
                ForEach(model.folders) { f in
                    row(f.title, "folder", SidebarItem.filter(.folder(f.id), f.title), badge: f.count, help: f.path, reveal: f.path)
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
    @AppStorage("grid.showFrames") private var showFrames = true
    @AppStorage("grid.frameOnly") private var frameOnly = false

    /// Last indexed (not a search): its filter bar is shown.
    var isRecent: Bool { model.currentFilter == .recent }

    var body: some View {
        VStack(spacing: 0) {
            if isRecent {
                RecentBar()
                Divider()
            }
            grid
        }
    }

    /// Faces / animals of Last indexed: frames on the thumbnails, solid when a person drew, tagged or
    /// confirmed them, dashed and lighter when the detector found them alone.
    var frames: GridFrames? {
        guard isRecent, showFrames else { return nil }
        switch model.shownRecentKind {
        case .faces: return .detections(model.library, .face, crop: frameOnly)
        case .animals: return .detections(model.library, .pet, crop: frameOnly)
        case .indexed, .labels: return nil
        }
    }

    @ViewBuilder var grid: some View {
        if !model.loaded {
            ProgressView("Loading the library…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.ids.isEmpty {
            let e = emptyState
            ContentUnavailableView(e.title, systemImage: e.icon, description: Text(e.message))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                YearGrid(ids: model.ids, sections: model.sections, cellSize: size,
                         resetKey: isRecent ? AnyHashable(model.shownRecentKind) : AnyHashable(model.currentFilter),
                         onSelect: { sel in model.gridSelection = sel.compactMap { $0 < model.ids.count ? model.ids[$0] : nil } },
                         frames: frames,
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
        case .filter(.recent, _)?:
            switch model.recentKind {
            case .indexed: return ("Nothing indexed yet", "clock.badge.checkmark", "Photos show up here as the indexer makes their thumbnails (Processing ▸ Index Pending Items).")
            case .faces: return ("No faces yet", "person.crop.square", "Faces show up here as the analysis finds them (Processing ▸ Analyze Pending Images), or from Picasa data.")
            case .animals: return ("No animals yet", "pawprint", "Cats and dogs show up here as the analysis finds them (Processing ▸ Analyze Pending Images).")
            case .labels: return ("No labels yet", "tag", "Photos show up here as the analysis labels them (Processing ▸ Analyze Pending Images; needs macOS 15 or later).")
            }
        case .filter(.videos, _)?: return ("No videos", "film", "No video files were found in the scanned folders.")
        case .filter(.best, _)?: return ("No scores yet", "sparkles", "Run the analysis (Processing ▸ Analyze Pending Images) to score photos. Needs macOS 15 or later.")
        case .filter(.bursts, _)?: return ("No bursts", "square.stack.3d.forward.dottedline", "No series of look-alike shots taken within 2 seconds were found (Processing ▸ Find Similar Photos).")
        case .filter(.similar, _)?: return ("No similar photos", "square.on.square", "No near-duplicates found (Processing ▸ Analyze Pending Images, then Find Similar Photos).")
        case .filter(.duplicates, _)?: return ("No duplicates", "doc.on.doc", "No identical files found (Processing ▸ Find Similar Photos).")
        case .filter(.animals, _)?: return ("No animals", "pawprint", "No cats or dogs found (run Processing ▸ Analyze Pending Images first).")
        case .filter(.ignored, _)?: return ("No ignored images", "eye.slash", "No small images without camera metadata were found.")
        case .filter(.utility, _)?: return ("No screenshots or documents", "doc.text.viewfinder", "None found (run Processing ▸ Analyze Pending Images first; needs macOS 15 or later).")
        case .filter(.starred, _)?: return ("No starred photos", "star", "Star a photo in the viewer (S), or import stars from Picasa.")
        case let .filter(.album, name)?: return ("Album is empty", "rectangle.stack", "“\(name)” has no photos in the scanned folders.")
        case let .filter(.year, name)?: return ("No photos in \(name)", "calendar", "No photo in the library is dated \(name).")
        case let .filter(.folder, name)?: return ("Empty folder", "folder", "“\(name)” has no photos left (or they are hidden in Picasa).")
        case let .filter(.root, name)?: return ("No photos yet", "externaldrive", "Nothing indexed under “\(name)” yet, or its volume is not mounted.")
        default: return ("No photos", "photo", "Nothing to show here.")
        }
    }
}

/// Filter bar of Library ▸ Last indexed: what the newest-first list is about, and for faces / animals
/// the frames and what their styles mean.
struct RecentBar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 14) {
            Picker("", selection: $model.recentKind) {
                Label("Index", systemImage: "clock.badge.checkmark").tag(RecentKind.indexed)
                    .help("Photos and videos in the order they were indexed")
                Label("Faces", systemImage: "person.crop.square").tag(RecentKind.faces)
                    .help("Photos whose faces were found last")
                Label("Animals", systemImage: "pawprint").tag(RecentKind.animals)
                    .help("Photos whose cats and dogs were found last")
                Label("Labels", systemImage: "tag").tag(RecentKind.labels)
                    .help("Photos labelled last by the analysis")
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            Spacer()
            if model.recentKind == .faces || model.recentKind == .animals {
                HStack(spacing: 10) {
                    legend(dashed: false, "By a person")
                        .help("Drawn or tagged in Picasa, drawn here, or named / confirmed / ignored by a person")
                    legend(dashed: true, "Automatic")
                        .help("Found by the detector, not reviewed by anyone yet")
                }
                .font(.caption).foregroundStyle(.secondary)
                FramesToggle(help: "Show the face / animal frames on the thumbnails: solid when a person made or confirmed them, dashed when automatic")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    func legend(dashed: Bool, _ text: String) -> some View {
        let c = GridFrames.detectionColor(model.recentKind == .faces ? .face : .pet, human: !dashed)
        return HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 1)
                .stroke(Color(nsColor: c), style: StrokeStyle(lineWidth: dashed ? 1.5 : 2.5, dash: dashed ? [3, 2] : []))
                .frame(width: 14, height: 11)
            Text(text)
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
                InfoPanel(item: item, faces: faces, pets: pets, tags: tags, scene: scene)
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.space) { guard !model.typing else { return .ignored }; close(); return .handled }
        .onKeyPress(.return) {
            guard !model.typing else { return .ignored }
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
                .oneKey(.leftArrow, active: !model.typing).help("Previous (←)")
            Button { step(1) } label: { Image(systemName: "chevron.right") }
                .oneKey(.rightArrow, active: !model.typing).help("Next (→)")
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
            Button { rotate(-1) } label: { Image(systemName: "rotate.left") }.oneKey("[", active: !model.typing).help("Rotate left ([)")
            Button { rotate(1) } label: { Image(systemName: "rotate.right") }.oneKey("]", active: !model.typing).help("Rotate right (])")
            Button { if let item { Task { await model.toggleStar(item); await load() } } } label: {
                Image(systemName: item?.star == true ? "star.fill" : "star")
            }
            .oneKey("s", active: !model.typing).help("Star (S)").disabled(item == nil)
            Button { if let item { NSWorkspace.shared.activateFileViewerSelecting([item.url]) } } label: { Image(systemName: "folder") }
                .help("Show in Finder").disabled(item == nil)
            Button { NSApp.keyWindow?.toggleFullScreen(nil) } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                .oneKey("f", active: !model.typing).help("Full screen (F)")
            Button("Close") { close() }.oneKey(.escape, active: !model.typing)
            // Space closes like Quick Look, photos and videos alike; Return plays/pauses a video.
            Button("") { close() }.oneKey(.space, active: !model.typing)
                .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
            Button("") { togglePlay() }.oneKey(.return, active: !model.typing)
                .disabled(item?.kind != .video).opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(height: 44)
    }

    func faceBox(_ f0: FaceRecord, kind: IdentityKind, in size: CGSize) -> some View {
        // Boxes are stored for the unturned picture: turn them like the photo.
        let (bx, by, bw, bh) = Turn.rect(f0.x, f0.y, f0.w, f0.h, item?.rotate ?? 0)
        let f = (x: bx, y: by, w: bw, h: bh, personId: f0.personId, suggestedPersonId: f0.suggestedPersonId, personName: f0.personName, id: f0.id)
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
            RegionEditor(kind: kind, region: f0) {
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

    /// Turns the photo (stored in the library, the file is untouched); grids follow.
    func rotate(_ q: Int) {
        guard let item, item.kind != .video else { return }
        Task {
            await model.rotate([item.id], by: q)
            fullResLoaded = false
            full = nil
            await load()
        }
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
        let q = item.rotate
        if let cg = await Task.detached(priority: .userInitiated, operation: { ThumbnailStore.imageThumbnail(url, maxPixel: px).map { Turn.image($0, q) } }).value,
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
        let q = item.rotate
        if let cg = await Task.detached(priority: .userInitiated, operation: { ThumbnailStore.imageThumbnail(url, maxPixel: px).map { Turn.image($0, q) } }).value,
           model.viewing == v {
            full = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }
    }
}

struct InfoPanel: View {
    @EnvironmentObject private var model: AppModel
    @State private var copies: [String] = []
    @State private var exif: [(String, String)] = []
    @State private var editingDate = false
    @State private var placeName: String?
    @State private var newDate = Date()
    let item: MediaItem?
    let faces: [FaceRecord]
    var pets: [FaceRecord] = []
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
                    }
                }
                Section("Picture") {
                    LabeledContent("Taken") {
                        VStack(alignment: .trailing, spacing: 1) {
                            HStack(spacing: 4) {
                                Text(item.takenAt.map { $0.timeIntervalSinceNow > 2 * 86400 ? "No date (\($0.formatted(date: .abbreviated, time: .omitted)))" : $0.formatted(date: .long, time: .shortened) } ?? "No date")
                                Button { newDate = item.takenAt ?? Date(); editingDate = true } label: { Image(systemName: "pencil") }
                                    .buttonStyle(.borderless).help("Change the date the photo was taken")
                                    .popover(isPresented: $editingDate, arrowEdge: .leading) { dateEditor(item) }
                            }
                            if let src = item.dateSource, src == .manual {
                                Label("Set by hand", systemImage: "hand.point.up.left").font(.caption).foregroundStyle(.secondary)
                            } else if let src = item.dateSource, src != .metadata {
                                Label("Estimated from the \(src.label)", systemImage: "exclamationmark.triangle")
                                    .font(.caption).foregroundStyle(.orange)
                                    .help("The photo has no date of its own; this one comes from its \(src.label).")
                            }
                        }
                    }
                    if let c = item.camera { LabeledContent("Camera", value: c) }
                    if let lat = item.lat, let lon = item.lon {
                        LabeledContent("Place") {
                            VStack(alignment: .trailing, spacing: 1) {
                                if let n = placeName { Text(n) }
                                Button(String(format: "%.5f, %.5f", lat, lon)) {
                                    model.go(to: .places, place: GeoPoint(id: item.id, lat: lat, lon: lon, score: 0))
                                }
                                .buttonStyle(.link).help("Show on the map (Places)")
                            }
                        }
                    }
                    if let c = item.caption { LabeledContent("Caption", value: c) }
                    if !tags.isEmpty { LabeledContent("Tags") { links(tags.map { ($0, $0) }) { model.go(to: .labels, label: $0) } } }
                    // People and pets: each name opens their page.
                    let people = Dictionary(faces.compactMap { f in f.personId.flatMap { id in f.personName.map { (id, $0) } } }, uniquingKeysWith: { a, _ in a })
                    if !people.isEmpty {
                        LabeledContent("People") {
                            links(people.sorted { $0.value < $1.value }.map { (String($0.key), $0.value) }) { id in
                                if let i = Int64(id) { model.go(to: .people, owner: .init(kind: .face, id: i)) }
                            }
                        }
                    }
                    let named = Dictionary(pets.compactMap { f in f.personId.flatMap { id in f.personName.map { (id, $0) } } }, uniquingKeysWith: { a, _ in a })
                    if !named.isEmpty {
                        LabeledContent("Pets") {
                            links(named.sorted { $0.value < $1.value }.map { (String($0.key), $0.value) }) { id in
                                if let i = Int64(id) { model.go(to: .pets, owner: .init(kind: .pet, id: i)) }
                            }
                        }
                    }
                }
                if !exif.isEmpty {
                    Section("Shooting") {
                        ForEach(exif, id: \.0) { k, v in LabeledContent(k, value: v) }
                    }
                }
                if let scene, !(scene.labels.isEmpty && scene.animals.isEmpty && scene.aesthetic == nil) {
                    Section("Detected") {
                        if !scene.animals.isEmpty {
                            LabeledContent("Animals") { links(Array(Set(scene.animals)).sorted().map { ($0, $0) }) { model.go(to: .labels, label: $0) } }
                        }
                        if !scene.labels.isEmpty {
                            LabeledContent("Labels") {
                                links(scene.labels.prefix(10).map { ($0, LabelSummary.display($0)) }) { model.go(to: .labels, label: $0) }
                            }
                        }
                        if let a = scene.aesthetic { LabeledContent("Aesthetics", value: String(format: "%.2f", a) + (scene.utility ? " · document/screenshot" : "")) }
                        if scene.similarCount > 0 { LabeledContent("Similar", value: "\(scene.similarCount) other photo\(scene.similarCount > 1 ? "s" : "")") }
                        if scene.burstCount > 0 { LabeledContent("Burst", value: "\(scene.burstCount) shots") }
                    }
                }
            }
        }
        .task(id: item?.id) {
            guard let id = item?.id, let url = item?.url else { copies = []; exif = []; return }
            copies = (try? await model.library.copies(of: id)) ?? []
            placeName = nil
            if let lat = item?.lat, let lon = item?.lon { placeName = try? await model.library.placeName(lat: lat, lon: lon) }
            exif = item?.kind == .video ? [] : await Task.detached(priority: .utility) { ExifDetails.read(url) }.value
        }
        .formStyle(.grouped)
        .frame(width: 300)
    }

    /// Clickable values (key, title), wrapped on several lines.
    func links(_ items: [(String, String)], _ open: @escaping (String) -> Void) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            ForEach(items, id: \.0) { key, title in
                Button(title) { open(key) }.buttonStyle(.link)
            }
        }
    }

    func dateEditor(_ item: MediaItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Date taken").font(.headline)
            DatePicker("", selection: $newDate, displayedComponents: [.date, .hourAndMinute])
                .datePickerStyle(.field).labelsHidden()
            HStack {
                Spacer()
                Button("Cancel") { editingDate = false }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    let (id, d) = (item.id, newDate)
                    editingDate = false
                    Task { try? await model.library.setTakenDate([id], d); await model.refreshAll() }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14).frame(width: 260)
        .onAppear { model.typing = true }
        .onDisappear { model.typing = false }
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
    @AppStorage("grid.frameOnly") private var frameOnly = false
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
                             frames: showFrames && Self.animalLabels.contains(l.label.lowercased()) ? .identities(model.library, .pet, crop: frameOnly) : nil)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .task(id: [l.label, String(model.revision)]) { rows = (try? await model.library.mediaIdsAndYears(.label(l.label))) ?? [] }
            } else if labels.isEmpty && !loading {
                ContentUnavailableView("No labels yet", systemImage: "tag",
                                       description: Text("Run the analysis (Processing ▸ Analyze Pending Images) or import Picasa keywords."))
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
        .task(id: model.revision) { await load() }
        .onChange(of: model.openLabel) { openRequested() }
    }
}

extension LabelsView {
    /// The precomputed cards at once; rebuilt first when stale — except while a scan keeps changing
    /// labels (a rebuild takes seconds on a large library): the last cards stay shown meanwhile.
    func load() async {
        let lib = model.library
        let cached = (try? await lib.cachedLabelSummaries()) ?? []
        if !cached.isEmpty { labels = cached; loading = false; openRequested() }
        let busy = model.job != nil || model.externalActivity
        if cached.isEmpty || !busy, (try? await lib.labelInfoStale()) == true {
            labels = (try? await lib.labelSummaries()) ?? labels
        }
        loading = false
        openRequested()
    }

    /// A link (info panel) asked for a label: open its card, or search it if it has none.
    func openRequested() {
        guard let want = model.openLabel, !labels.isEmpty || !loading else { return }
        model.openLabel = nil
        if let l = labels.first(where: { $0.label.caseInsensitiveCompare(want) == .orderedSame }) { selected = l }
        else { model.setQuery(tokens: [.label(want)], text: "") }
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

extension View {
    /// A shortcut on a single key (no modifier), switched off while typing in a popup.
    @ViewBuilder func oneKey(_ key: KeyEquivalent, active: Bool) -> some View {
        if active { keyboardShortcut(key, modifiers: []) } else { self }
    }
}
