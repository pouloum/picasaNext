import AppKit
import Foundation
import PicasaCore

enum SidebarItem: Hashable {
    case filter(MediaFilter, String)
    case people
    case pets
    case relations
    case labels
    case places
}

@MainActor
final class AppModel: ObservableObject {
    let library: Library
    @Published var selection: SidebarItem? = .filter(.all, "All photos")
    @Published var search = ""
    /// Search tokens (people, labels, albums), combined with AND, plus the free text in `search`.
    @Published var tokens: [SearchTerm] = []
    /// Known people/labels/albums for autocompletion in the token field.
    @Published var vocabulary: [SearchTerm] = []
    @Published var ids: [Int64] = []
    /// Year sections of `ids` (empty for groupings where years are not contiguous: similar, bursts).
    @Published var sections: [GridSection] = []
    /// Grouped views (duplicates, bursts, similar): one cover per group, expanded on demand.
    @Published var groups: [MediaGroup] = []
    @Published var expanded: Set<Int64> = []
    /// Navigation requests from the info panel's links (a person, a pet, a label, a place).
    struct OwnerRequest: Equatable { let kind: IdentityKind; let id: Int64 }
    @Published var openOwner: OwnerRequest?
    @Published var openLabel: String?
    @Published var openPlace: GeoPoint?

    /// Info panel link: closes the viewer and opens the right page.
    func go(to target: SidebarItem, owner: OwnerRequest? = nil, label: String? = nil, place: GeoPoint? = nil) {
        viewing = nil
        clearSearch()
        selection = target
        // Set after the page appears so its onChange sees it.
        DispatchQueue.main.async {
            if let owner { self.openOwner = owner }
            if let label { self.openLabel = label }
            if let place { self.openPlace = place }
        }
    }

    /// A text field of a popup (naming, date) has the keyboard: the viewer's one-key shortcuts
    /// (space, S, F, [, ], arrows, Esc…) must not fire while typing.
    @Published var typing = false

    /// Photos selected in the main grid (for Show in Finder).
    @Published var gridSelection: [Int64] = []
    var groupBadges: [Int64: Int] { Dictionary(uniqueKeysWithValues: groups.map { ($0.cover, $0.members.count) }) }
    /// Members shown under an expanded cover (tinted in the grid).
    var expandedMembers: Set<Int64> { Set(groups.filter { expanded.contains($0.cover) }.flatMap { $0.members.dropFirst() }) }
    @Published var folders: [FolderNode] = []
    @Published var years: [(year: Int, count: Int)] = []
    @Published var albums: [AlbumSummary] = []
    @Published var stats: Library.Stats?
    /// Viewer state: its own snapshot of ids, so grid reloads cannot shift what is being viewed.
    @Published var viewerIds: [Int64] = []
    @Published var viewing: Int? // index into viewerIds
    @Published var job: String?
    @Published var jobDetail: String?
    @Published var error: String?
    /// Bumped each time the library changed (a scan in the app or in picasa-cli): views that load
    /// their own data (people, labels, places) reload on it.
    @Published var revision = 0
    /// The first grid load is done (until then the grid shows a spinner, not "No photos").
    @Published var loaded = false
    /// The library is being written by someone else (picasa-cli in a terminal): changes seen recently.
    @Published var externalActivity = false
    let thumbs: ThumbnailCache
    private var lastToken: [Int64] = []
    private var refreshing = false
    private var refreshCost: TimeInterval = 0
    private var lastChange = Date.distantPast

    static var libraryURL: URL {
        if let p = ProcessInfo.processInfo.environment["PICASANEXT_LIBRARY"] { return URL(fileURLWithPath: p) }
        return Library.defaultURL
    }

    init() {
        do { library = try Library(root: Self.libraryURL) } catch { fatalError("Cannot open library: \(error)") }
        thumbs = ThumbnailCache(store: library.thumbs)
        Task {
            // The grid first (what the user looks at), then the sidebar and counters.
            await loadRotations()
            await reloadGrid()
            loaded = true
            await refreshAll()
            // After an upgrade (or on a library indexed by an older picasa-cli): build the groups.
            if (try? await library.groupsNeedRebuild()) == true {
                runJob("Finding duplicates, bursts and similar photos") { lib, _ in _ = try await lib.groupSimilar() }
            }
            // Debugging aid: PICASANEXT_OPEN_FIRST=1 opens the first photo at launch.
            if ProcessInfo.processInfo.environment["PICASANEXT_OPEN_FIRST"] != nil { open(ids, at: 0) }
            await watchLibrary()
        }
    }

    /// Polls the library's change token and refreshes everything when it moved, so the grid,
    /// sidebar counts and other sections follow a running scan/index/analysis (here or in a terminal).
    private func watchLibrary() async {
        lastToken = (try? await library.changeToken()) ?? []
        var lastRefresh = Date.distantPast
        var gridToken = lastToken
        while !Task.isCancelled {
            // The check itself is two integers read from SQLite (microseconds), so it can run often:
            // every second on Last indexed (new photos land there), every 2 s elsewhere.
            let live = !isSearching && currentFilter == .recent
            try? await Task.sleep(for: .seconds(live ? 1 : 2))
            let busy = job == nil && Date().timeIntervalSince(lastChange) < 20
            if busy != externalActivity { externalActivity = busy }
            // Last indexed: only its grid is reloaded right away (one indexed query, 2 000 rows max);
            // the rest of the app follows the slower full refresh below.
            if live, let t = try? await library.changeToken(), t != gridToken, !refreshing {
                gridToken = t
                if t.first != lastToken.first { lastChange = Date() }
                await reloadGrid()
            }
            guard let t = try? await library.changeToken(), t != lastToken, !refreshing else { continue }
            if t.first != lastToken.first { lastChange = Date() } // data_version: written by another process
            // The refresh re-runs the sidebar/grid queries: a first change shows up within 2 s, then
            // while a scan keeps writing, at most every 10 s (more when a refresh itself is slow).
            let start = Date()
            if start.timeIntervalSince(lastRefresh) < max(10, refreshCost * 10) { continue }
            await refreshAll()
            refreshCost = Date().timeIntervalSince(start)
            lastRefresh = Date()
        }
    }

    var isSearching: Bool { !tokens.isEmpty || !search.trimmingCharacters(in: .whitespaces).isEmpty }

    var currentFilter: MediaFilter {
        if isSearching { return .query(tokens, search) }
        if case let .filter(f, _)? = selection { return f }
        return .all
    }

    func refreshAll() async {
        refreshing = true
        defer { refreshing = false }
        if let t = try? await library.changeToken() { lastToken = t }
        do {
            folders = try await library.folders()
            years = try await library.years()
            vocabulary = try await library.searchVocabulary()
            albums = try await library.albums()
            stats = try await library.stats()
        } catch { self.error = "\(error)" }
        await reloadGrid()
        revision += 1
    }

    func open(_ list: [Int64], at index: Int) {
        guard list.indices.contains(index) else { return }
        viewerIds = list
        viewing = index
    }

    func reloadGrid() async {
        if !isSearching, selection == .people || selection == .pets || selection == .relations || selection == .labels || selection == .places { return }
        let f = currentFilter
        let kind: GroupKind? = { switch f { case .bursts: .burst; case .similar: .similar; case .duplicates: .duplicates; default: nil } }()
        if let kind {
            do {
                let g = try await library.mediaGroups(kind)
                if g.map(\.cover) != groups.map(\.cover) { expanded = expanded.intersection(g.map(\.cover)) }
                groups = g
                sections = []
                ids = flattenGroups()
            } catch { self.error = "\(error)"; ids = []; groups = [] }
            return
        }
        groups = []
        do {
            let rows = try await library.mediaIdsAndYears(f)
            let grouped: Bool = { switch f { case .recent: true; default: false } }()
            sections = grouped ? [] : GridSection.byYear(rows.map(\.year))
            ids = rows.map(\.id)
        } catch { self.error = "\(error)"; ids = []; sections = [] }
    }

    /// Show in Finder: the selected photos, or else the folder being shown.
    func revealInFinder() {
        Task {
            if !gridSelection.isEmpty, let items = try? await library.items(ids: Array(gridSelection.prefix(200))) {
                NSWorkspace.shared.activateFileViewerSelecting(items.map(\.url))
            } else if case let .filter(.folder(id), _)? = selection, let f = folders.first(where: { $0.id == id }) {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: f.path)
            }
        }
    }

    var canReveal: Bool {
        if !gridSelection.isEmpty { return true }
        if case .filter(.folder, _)? = selection { return true }
        return false
    }

    /// Names the places of geotagged photos (background job; slow because Apple throttles requests).
    func geocode() {
        runJob("Naming places") { lib, report in _ = try await Geocoder(library: lib).run { report($0) } }
    }

    func flattenGroups() -> [Int64] {
        groups.flatMap { expanded.contains($0.cover) ? $0.members : [$0.cover] }
    }

    /// Opens / closes a group in a grouped view (its badge, or a double-click on its cover).
    func toggleGroup(_ cover: Int64) {
        if expanded.contains(cover) { expanded.remove(cover) } else { expanded.insert(cover) }
        ids = flattenGroups()
    }

    /// Called by the token field on every edit.
    func setQuery(tokens: [SearchTerm], text: String) {
        guard tokens != self.tokens || text != search else { return }
        self.tokens = tokens
        search = text
        Task { await reloadGrid() }
    }

    /// Choosing another sidebar entry leaves the search.
    func clearSearch() {
        guard isSearching else { return }
        tokens = []
        search = ""
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
            // Missing roots (unplugged disk) are skipped, never pruned.
            for r in try await lib.roots() where FileManager.default.fileExists(atPath: r.path) {
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
            // Names imported on a hidden copy go to the photo kept (and on to its other copies).
            try await lib.mirrorToCopies(.face)
            _ = try await FaceEngine(library: lib).suggestNames()
        }
    }

    nonisolated static func index(_ lib: Library, _ report: @escaping ProgressHandler) async throws {
        let ix = Indexer(library: lib)
        _ = try await ix.run { report($0) }
        _ = try await Analyzer(library: lib, concurrency: max(1, ProcessInfo.processInfo.activeProcessorCount / 2)).run { report($0) }
        _ = try await FaceEngine(library: lib).suggestNames()
        _ = try await Analyzer(library: lib).petPrints { report($0) }
        _ = try await IdentityEngine.suggest(library: lib, kind: .pet, threshold: 0.82)
        try await lib.groupSimilar()
    }

    /// Animals can only be grouped and suggested once they have a print: compute the missing ones
    /// (a few hundred photos at most) when Animals is opened, once per session.
    func ensurePetPrints() async {
        guard !petPrintsTried, job == nil, ((try? await library.animalsMissingPrint()) ?? 0) > 0 else { return }
        petPrintsTried = true
        runJob("Recognising pets") { lib, report in
            _ = try await Analyzer(library: lib).petPrints { report($0) }
            _ = try await IdentityEngine.suggest(library: lib, kind: .pet, threshold: 0.82)
        }
    }
    private var petPrintsTried = false

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

    /// Bumped when rotations change: visible thumbnails are redrawn.
    @Published var thumbVersion = 0

    func loadRotations() async {
        thumbs.rotations = (try? await library.rotations()) ?? [:]
    }

    func rotate(_ ids: [Int64], by quarters: Int) async {
        try? await library.rotate(ids, by: quarters)
        await loadRotations()
        thumbVersion += 1
    }

    func toggleStar(_ item: MediaItem) async {
        try? await library.setStar([item.id], !item.star)
    }

    // People and pets share these (IdentityKind): every change re-runs the suggestions of that kind.

    /// Runs an edit, then refreshes suggestions so similar faces / animals get proposed.
    func identityEdit(_ k: IdentityKind, _ body: @escaping @Sendable (Library) async throws -> Void) async {
        do {
            let since = Date().timeIntervalSince1970
            try await body(library)
            try await library.mirrorToCopies(k, since: since) // only the photos just edited
            _ = try await IdentityEngine.suggest(library: library, kind: k, threshold: 0.82)
        } catch { self.error = "\(error)" }
        await refreshAll()
    }

    func name(_ k: IdentityKind, _ ids: [Int64], as name: String) async {
        await identityEdit(k) { _ = try await $0.nameItems(k, ids, name: name) }
    }

    /// Drag and drop: a person onto another merges them.
    func merge(_ k: IdentityKind, _ source: PersonSummary, into target: PersonSummary) async {
        await identityEdit(k) { try await $0.merge(k, source.id, into: target.id) }
    }

    /// Drag and drop: an unnamed group onto a person names the group.
    func assign(_ k: IdentityKind, _ ids: [Int64], to owner: PersonSummary) async {
        await identityEdit(k) { try await $0.assign(k, ids, to: owner.id) }
    }

    func setIgnored(_ k: IdentityKind, _ ids: [Int64], _ on: Bool) async {
        await identityEdit(k) { _ = try await $0.setIgnored(k, ids, on) }
    }

    func confirmAll(_ k: IdentityKind, _ p: PersonSummary) async {
        await identityEdit(k) { _ = try await $0.confirm(k, owner: p.id) }
    }

    /// Merging people sharing a name rewrites many faces: a background job with the toolbar spinner.
    func mergeDuplicates(_ k: IdentityKind, _ groups: [[PersonSummary]]) {
        runJob("Merging \(k == .face ? "people" : "pets")") { lib, _ in
            _ = try await lib.mergeDuplicates(k, groups)
            _ = try await IdentityEngine.suggest(library: lib, kind: k, threshold: 0.82)
        }
    }

    /// Renaming to an existing name merges into that person / pet.
    func rename(_ k: IdentityKind, _ p: PersonSummary, to name: String) async {
        await identityEdit(k) { lib in
            let all = try await lib.owners(k)
            if let other = all.first(where: { $0.id != p.id && $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                try await lib.merge(k, p.id, into: other.id)
            } else {
                try await lib.renameOwner(k, p.id, to: name)
            }
        }
    }
}

/// Quarter-turn rotations (clockwise) of pictures and of normalized rectangles (top-left origin).
enum Turn {
    static func image(_ cg: CGImage, _ q: Int) -> CGImage {
        let q = ((q % 4) + 4) % 4
        guard q != 0 else { return cg }
        let (w, h) = (cg.width, cg.height)
        let (ow, oh) = q % 2 == 1 ? (h, w) : (w, h)
        guard let ctx = CGContext(data: nil, width: ow, height: oh, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return cg }
        // Core Graphics is bottom-left based: a clockwise turn on screen is a negative angle here.
        ctx.translateBy(x: CGFloat(ow) / 2, y: CGFloat(oh) / 2)
        ctx.rotate(by: -CGFloat(q) * .pi / 2)
        ctx.draw(cg, in: CGRect(x: -CGFloat(w) / 2, y: -CGFloat(h) / 2, width: CGFloat(w), height: CGFloat(h)))
        return ctx.makeImage() ?? cg
    }

    static func nsImage(_ img: NSImage, _ q: Int) -> NSImage {
        guard q % 4 != 0, let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return img }
        let r = image(cg, q)
        return NSImage(cgImage: r, size: NSSize(width: r.width, height: r.height))
    }

    /// (x, y, w, h) in the unturned picture → in the picture turned `q` quarters clockwise.
    static func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ q: Int) -> (Double, Double, Double, Double) {
        switch ((q % 4) + 4) % 4 {
        case 1: (1 - y - h, x, h, w)
        case 2: (1 - x - w, 1 - y - h, w, h)
        case 3: (y, 1 - x - w, h, w)
        default: (x, y, w, h)
        }
    }
}

/// In-memory thumbnail cache in front of the on-disk ThumbnailStore. Thumbnails are only made by
/// the indexer (picasa-cli index / the app's jobs); the grids only show items that have one.
/// `load` gives the picture as shown (turned by the photo's rotation); `loadRaw` as stored (for crops
/// computed from face / animal boxes, which are in the unturned picture).
final class ThumbnailCache: @unchecked Sendable {
    private let cache = NSCache<NSNumber, NSImage>()
    let store: ThumbnailStore
    /// id → quarter turns clockwise (photos rotated in Picasa or here).
    var rotations: [Int64: Int] = [:]

    init(store: ThumbnailStore) {
        self.store = store
        cache.countLimit = 4000
    }

    func rotation(_ id: Int64) -> Int { rotations[id] ?? 0 }
    private func key(_ id: Int64, _ q: Int) -> NSNumber { NSNumber(value: id * 4 + Int64(q)) }

    func cached(_ id: Int64) -> NSImage? { cache.object(forKey: key(id, rotation(id))) }

    func loadRaw(_ id: Int64) async -> NSImage? {
        if let i = cache.object(forKey: key(id, 0)) { return i }
        let store = store
        let img = await Task.detached(priority: .userInitiated) { () -> NSImage? in
            guard let cg = store.load(id: id) else { return nil }
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }.value
        if let img { cache.setObject(img, forKey: key(id, 0)) }
        return img
    }

    func load(_ id: Int64) async -> NSImage? {
        let q = rotation(id)
        if let i = cache.object(forKey: key(id, q)) { return i }
        guard let raw = await loadRaw(id) else { return nil }
        guard q != 0 else { return raw }
        let turned = Turn.nsImage(raw, q)
        cache.setObject(turned, forKey: key(id, q))
        return turned
    }
}
