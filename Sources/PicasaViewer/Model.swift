import AppKit
import Foundation
import PicasaCore

enum SidebarItem: Hashable {
    case filter(MediaFilter, String)
    case people
}

@MainActor
final class AppModel: ObservableObject {
    let library: Library
    @Published var selection: SidebarItem? = .filter(.all, "All photos")
    @Published var search = ""
    @Published var ids: [Int64] = []
    @Published var folders: [FolderNode] = []
    @Published var years: [(year: Int, count: Int)] = []
    @Published var persons: [PersonSummary] = []
    @Published var albums: [AlbumSummary] = []
    @Published var stats: Library.Stats?
    /// Viewer state: its own snapshot of ids, so grid reloads cannot shift what is being viewed.
    @Published var viewerIds: [Int64] = []
    @Published var viewing: Int? // index into viewerIds
    @Published var job: String?
    @Published var jobDetail: String?
    @Published var error: String?
    let thumbs: ThumbnailCache

    static var libraryURL: URL {
        if let p = ProcessInfo.processInfo.environment["PICASANEXT_LIBRARY"] { return URL(fileURLWithPath: p) }
        return Library.defaultURL
    }

    init() {
        do { library = try Library(root: Self.libraryURL) } catch { fatalError("Cannot open library: \(error)") }
        thumbs = ThumbnailCache(store: library.thumbs)
        Task { await refreshAll() }
    }

    var currentFilter: MediaFilter {
        if !search.trimmingCharacters(in: .whitespaces).isEmpty { return .search(search) }
        if case let .filter(f, _)? = selection { return f }
        return .all
    }

    func refreshAll() async {
        do {
            folders = try await library.folders()
            years = try await library.years()
            persons = try await library.persons()
            albums = try await library.albums()
            stats = try await library.stats()
        } catch { self.error = "\(error)" }
        await reloadGrid()
    }

    func open(_ list: [Int64], at index: Int) {
        guard list.indices.contains(index) else { return }
        viewerIds = list
        viewing = index
    }

    func reloadGrid() async {
        if case .people? = selection, search.isEmpty { return }
        do { ids = try await library.mediaIds(currentFilter) } catch { self.error = "\(error)"; ids = [] }
    }

    // MARK: - Background jobs

    func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add to library"
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        runJob("Scanning") { lib, report in
            for u in urls {
                _ = try await Scanner(library: lib).scan(root: u) { report($0) }
            }
            try await Self.index(lib, report)
        }
    }

    func rescan() {
        runJob("Rescanning") { lib, report in
            for r in try await lib.roots() {
                _ = try await Scanner(library: lib).scan(root: URL(fileURLWithPath: r.path)) { report($0) }
            }
            try await Self.index(lib, report)
        }
    }

    func importPicasa() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose the Picasa2 / Picasa3 folder (contacts, and db3 if you have it)."
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        runJob("Importing Picasa data") { lib, report in
            let fm = FileManager.default
            // contacts.xml (person names) is enough on its own; db3 is optional.
            for c in ["contacts/contacts.xml", "contacts.xml"] where fm.fileExists(atPath: dir.appendingPathComponent(c).path) {
                _ = try await lib.importContacts(at: dir.appendingPathComponent(c)); break
            }
            for d in [dir.appendingPathComponent("db3"), dir] where fm.fileExists(atPath: d.appendingPathComponent("thumbindex.db").path) {
                _ = try await lib.importDB3(at: d) { report($0) }; break
            }
            _ = try await FaceEngine(library: lib).suggestNames()
        }
    }

    nonisolated static func index(_ lib: Library, _ report: @escaping ProgressHandler) async throws {
        let ix = Indexer(library: lib)
        _ = try await ix.extractMetadata { report($0) }
        _ = try await ix.generateThumbnails { report($0) }
        let faces = FaceEngine(library: lib, concurrency: max(1, ProcessInfo.processInfo.activeProcessorCount / 2))
        _ = try await faces.detectPending { report($0) }
        _ = try await faces.suggestNames()
    }

    private func runJob(_ title: String, _ body: @escaping @Sendable (Library, @escaping ProgressHandler) async throws -> Void) {
        guard job == nil else { return }
        job = title
        let lib = library
        Task {
            let report: ProgressHandler = { p in
                let text = "\(p.stage) \(p.done)\(p.total.map { "/\($0)" } ?? "")"
                Task { @MainActor [weak self] in self?.jobDetail = text }
            }
            do { try await body(lib, report) } catch { self.error = "\(error)" }
            job = nil
            jobDetail = nil
            await refreshAll()
        }
    }

    // MARK: - Edits

    func toggleStar(_ item: MediaItem) async {
        try? await library.setStar([item.id], !item.star)
    }

    func confirmAll(_ p: PersonSummary) async {
        _ = try? await library.confirmSuggestions(personId: p.id)
        await refreshAll()
    }
}

/// In-memory thumbnail cache in front of the on-disk ThumbnailStore.
final class ThumbnailCache: @unchecked Sendable {
    private let cache = NSCache<NSNumber, NSImage>()
    let store: ThumbnailStore

    init(store: ThumbnailStore) {
        self.store = store
        cache.countLimit = 4000
    }

    func cached(_ id: Int64) -> NSImage? { cache.object(forKey: NSNumber(value: id)) }

    func load(_ id: Int64) async -> NSImage? {
        if let i = cached(id) { return i }
        let store = store
        let img = await Task.detached(priority: .userInitiated) { () -> NSImage? in
            guard let cg = store.load(id: id) else { return nil }
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }.value
        if let img { cache.setObject(img, forKey: NSNumber(value: id)) }
        return img
    }
}
