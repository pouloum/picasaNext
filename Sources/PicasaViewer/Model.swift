import AppKit
import Foundation
import UniformTypeIdentifiers
import PicasaCore

enum SidebarItem: Hashable {
    case filter(MediaFilter, String)
    case people
    case pets
    case relations
    case labels
    case places
    /// The root folders added to the library (cards with their counts and progress).
    case roots
}

/// A root folder's card: its counts, and where its volume stands now.
struct RootCard: Identifiable, Equatable {
    var stats: Library.RootStats
    /// False when its disk or share is not mounted (unplugged NAS / disk): its photos stay in the library.
    var available: Bool
    var volume: StorageKind
    var id: Int64 { stats.id }
    var name: String {
        let n = (stats.path as NSString).lastPathComponent
        return n.isEmpty || n == "/" ? stats.path : n
    }
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
    /// The running job's last progress report: its stage and the file (or folder) it was on.
    @Published var jobStage: String?
    @Published var jobDone = 0
    @Published var jobCurrent: String?
    /// Sidebar ▸ Folders: one card per root folder, refreshed with the rest (refreshAll).
    @Published var rootCards: [RootCard] = []
    @Published var error: String?
    /// Bumped each time the library changed (a scan in the app or in picasa-cli): views that load
    /// their own data (people, labels, places) reload on it.
    @Published var revision = 0
    /// The first grid load is done (until then the grid shows a spinner, not "No photos").
    @Published var loaded = false
    /// The library is being written by someone else (picasa-cli in a terminal): changes seen recently.
    @Published var externalActivity = false
    /// Library ▸ Last indexed: photos last indexed, or with the faces / animals / labels found last (remembered).
    @Published var recentKind: RecentKind = RecentKind(rawValue: UserDefaults.standard.string(forKey: "recent.kind") ?? "") ?? .indexed {
        didSet {
            guard recentKind != oldValue else { return }
            UserDefaults.standard.set(recentKind.rawValue, forKey: "recent.kind")
            Task { await reloadGrid() }
        }
    }
    /// The kind the grid's ids were loaded for (switches with them, so the grid resets once, on the new list).
    @Published private(set) var shownRecentKind: RecentKind = .indexed
    /// Processing ▸ Performance Profile: how index / analysis adapt to the machine and the disks.
    /// Saved in the library (shared with picasa-cli), applied from the next batch run.
    @Published var throughputProfile: ThroughputProfile = .auto {
        didSet {
            guard throughputProfile != oldValue else { return }
            let (lib, p) = (library, throughputProfile)
            Task { try? await lib.setThroughputProfile(p) }
        }
    }

    /// Settings ▸ Library ▸ Watch folders for new items (Watch.swift). Saved in the library.
    @Published var watchFolders = true {
        didSet {
            guard watchFolders != oldValue, !loadingWatchSetting else { return }
            let (lib, on) = (library, watchFolders)
            Task {
                try? await lib.setWatchEnabled(on)
                if on { await startWatching(catchUp: true) } else { stopWatching() }
            }
        }
    }
    private var loadingWatchSetting = false
    let autoScan = AutoScanState()

    func forgetTuning() {
        let lib = library
        Task { _ = try? await lib.resetTuning() }
    }
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
            if let p = try? await library.throughputProfile(), p != throughputProfile { throughputProfile = p }
            if let on = try? await library.watchEnabled(), on != watchFolders {
                loadingWatchSetting = true; watchFolders = on; loadingWatchSetting = false
            }
            // The grid first (what the user looks at), then the sidebar and counters.
            await loadRotations()
            await reloadGrid()
            loaded = true
            await refreshAll()
            // Ready before they are asked for: the face groups of People and the Labels cards
            // (each a second or two of work on a large library, done once here instead of on opening).
            // Later and at background priority, so it never competes with the first scrolls of the grid
            // (thumbnail decoding runs at .userInitiated).
            Task(priority: .background) { [weak self] in
                try? await Task.sleep(for: .seconds(20))
                guard let self, self.job == nil else { return }
                _ = await self.clusters(.face, ignored: false, year: nil)
                try? await self.library.refreshLabelInfo()
            }
            // After an upgrade (or on a library indexed by an older picasa-cli): build the groups.
            if (try? await library.groupsNeedRebuild()) == true {
                runJob("Finding duplicates, bursts and similar photos") { lib, _ in _ = try await lib.groupSimilar() }
            }
            // Debugging aid: PICASANEXT_OPEN_FIRST=1 opens the first photo at launch.
            if ProcessInfo.processInfo.environment["PICASANEXT_OPEN_FIRST"] != nil { open(ids, at: 0) }
            // What was added while the app was closed, then new items as they arrive (after the
            // group rebuild above, if any: the scan waits for it).
            await startWatching(catchUp: true)
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
            await loadRootCards()
        } catch { self.error = "\(error)" }
        await reloadGrid()
        revision += 1
    }

    /// The roots' counts (one grouped query), then whether each volume is mounted, read off the main
    /// thread (a network share can be slow to answer; VolumeInfo caches the volume per mount point).
    func loadRootCards() async {
        guard let rows = try? await library.rootStats() else { return }
        let cards = await Task.detached(priority: .utility) {
            rows.map { RootCard(stats: $0, available: FileManager.default.fileExists(atPath: $0.path), volume: VolumeInfo.of($0.path).kind) }
        }.value
        if cards != rootCards { rootCards = cards }
    }

    /// The root the running job is working in (from its last progress report), if any.
    var activeRootId: Int64? {
        guard job != nil, let cur = jobCurrent else { return nil }
        return rootCards.filter { cur == $0.stats.path || cur.hasPrefix($0.stats.path.hasSuffix("/") ? $0.stats.path : $0.stats.path + "/") }
            .max { $0.stats.path.count < $1.stats.path.count }?.id
    }

    func open(_ list: [Int64], at index: Int) {
        guard list.indices.contains(index) else { return }
        viewerIds = list
        viewing = index
    }

    func reloadGrid() async {
        if !isSearching, selection == .people || selection == .pets || selection == .relations || selection == .labels || selection == .places || selection == .roots { return }
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
            let kind = recentKind
            let rows = try await library.mediaIdsAndYears(f, recent: kind)
            let grouped: Bool = { switch f { case .recent: true; default: false } }()
            sections = grouped ? [] : GridSection.byYear(rows.map(\.year))
            if shownRecentKind != kind { shownRecentKind = kind }
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

    /// File ▸ Add Folder…: the panel has an Exclude field (folder names or paths, comma-separated),
    /// remembered like picasa-cli scan --exclude.
    func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add to library"
        let field = NSTextField(string: "")
        field.placeholderString = "e.g. Backups, /Volumes/Photos/Old (comma-separated)"
        field.widthAnchor.constraint(equalToConstant: 360).isActive = true
        let note = NSTextField(labelWithString: "Exclude folders:")
        let row = NSStackView(views: [note, field])
        row.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        panel.accessoryView = row
        panel.isAccessoryViewDisclosed = true
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        let excludes = field.stringValue.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        runJob("Scanning") { lib, report in
            _ = try await Pipeline.scan(lib, roots: urls, excludes: excludes, progress: report)
            try await Self.index(lib, report)
        }
    }

    func rescan() {
        runJob("Rescanning") { lib, report in
            _ = try await Pipeline.rescan(lib, progress: report)
            try await Self.index(lib, report)
        }
    }

    /// Rescans one root folder (Folders card ▸ Scan Again), then indexes what is new.
    func rescan(root path: String) {
        guard FileManager.default.fileExists(atPath: path) else { return }
        runJob("Rescanning") { lib, report in
            _ = try await Pipeline.scan(lib, roots: [URL(fileURLWithPath: path)], progress: report)
            try await Self.index(lib, report)
        }
    }

    /// File ▸ Import Picasa Data…: a Picasa2 / Picasa3 folder (contacts, and db3 if present).
    func importPicasa() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose the Picasa2 / Picasa3 folder (contacts, and db3 if you have it)."
        let reuse = NSButton(checkboxWithTitle: "Reuse Picasa's thumbnails (faster; unchecked: made again from the photos)", target: nil, action: nil)
        reuse.state = .on
        let box = NSStackView(views: [reuse])
        box.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        panel.accessoryView = box
        panel.isAccessoryViewDisclosed = true
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        let thumbs = reuse.state == .on
        runJob("Importing Picasa data") { lib, report in
            _ = try await Pipeline.importPicasaFolder(lib, at: dir, reuseThumbnails: thumbs, progress: report)
        }
    }

    /// File ▸ Import Contacts File…: a Picasa contacts.xml on its own (person names).
    func importContacts() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.xml]
        panel.message = "Choose a Picasa contacts.xml file (person names)."
        guard panel.runModal() == .OK, let file = panel.url else { return }
        runJob("Importing contacts") { lib, _ in
            let n = try await lib.importContacts(at: file)
            _ = try await FaceEngine(library: lib).suggestNames()
            await MainActor.run { [weak self] in self?.notice = "\(n) contacts imported." }
        }
    }

    /// Indexing then analysis of everything pending, with the saved profile and sizes (what a scan runs after).
    nonisolated static func index(_ lib: Library, _ report: @escaping ProgressHandler) async throws {
        try await indexOnly(lib, report)
        try await analyze(lib, report)
    }

    nonisolated static func indexOnly(_ lib: Library, redoThumbs: Bool = false, _ report: @escaping ProgressHandler) async throws {
        // Read here, not passed in: a profile chosen in a terminal (picasa-cli profile) applies too.
        let profile = (try? await lib.throughputProfile()) ?? .auto
        var indexer = Indexer(library: lib, profile: profile)
        try await indexer.useSavedSizes()
        _ = try await Pipeline.index(indexer, redoThumbs: redoThumbs, progress: report)
    }

    nonisolated static func analyze(_ lib: Library, redo: Bool = false, includeManual: Bool = false,
                                    _ report: @escaping ProgressHandler) async throws {
        let profile = (try? await lib.throughputProfile()) ?? .auto
        _ = try await Pipeline.analyze(Analyzer(library: lib, profile: profile), redo: redo, includeManual: includeManual, progress: report)
        try await lib.refreshLabelInfo() // new labels: the Labels cards are rebuilt here, not on opening
    }

    /// Processing ▸ Index Pending Items (picasa-cli index).
    func indexPending(redoThumbs: Bool = false) {
        runJob(redoThumbs ? "Regenerating thumbnails" : "Indexing") { lib, report in
            try await Self.indexOnly(lib, redoThumbs: redoThumbs, report)
        }
    }

    /// Processing ▸ Analyze Pending Images / Redo Analysis… (picasa-cli analyze [--redo [--include-manual]]).
    func analyzePending(redo: Bool = false, includeManual: Bool = false) {
        runJob(redo ? "Analyzing everything again" : "Analyzing") { lib, report in
            try await Self.analyze(lib, redo: redo, includeManual: includeManual, report)
        }
    }

    /// Processing ▸ Find Similar Photos (picasa-cli similar), with the saved threshold.
    func findSimilar() {
        runJob("Finding duplicates, bursts and similar photos") { lib, _ in _ = try await Pipeline.similar(lib) }
    }

    /// Processing ▸ Recompute Name Suggestions (picasa-cli suggest).
    func suggestNames() {
        runJob("Suggesting names") { lib, _ in
            let (f, p) = try await Pipeline.suggest(lib)
            await MainActor.run { [weak self] in self?.notice = "Name suggestions: \(f) faces, \(p) animals." }
        }
    }

    /// Names the places of geotagged photos (background job; slow because Apple throttles requests),
    /// at most the limit set in Settings ▸ Places.
    func geocode() {
        runJob("Naming places") { lib, report in
            let limit = try await lib.geocodeLimit() ?? .max
            let r = try await Geocoder(library: lib).run(limit: limit) { report($0) }
            await MainActor.run { [weak self] in self?.notice = "Places: \(r.named) named, \(r.failed) failed, \(r.left) left." }
        }
    }

    /// People and pets sharing a name, merged in one job (Processing ▸ Merge Duplicate Names…).
    func mergeDuplicateNames(_ groups: [(kind: IdentityKind, groups: [[PersonSummary]])]) {
        runJob("Merging duplicate names") { lib, _ in _ = try await Pipeline.mergeDuplicates(lib, groups) }
    }

    /// A one-line message after a job (contacts imported, places named…), shown in an alert.
    @Published var notice: String?

    /// Sheets opened from the menus (shown by RootView).
    enum Sheet: String, Identifiable {
        case export, mergeNames, plan, redoAnalysis, redoThumbnails
        var id: String { rawValue }
    }
    @Published var sheet: Sheet?

    /// Settings ▸ Library: forgets a root and its index (photos untouched).
    func removeRoot(_ path: String) {
        runJob("Removing \((path as NSString).lastPathComponent)") { lib, _ in _ = try await lib.removeRoot(path) }
    }
    // MARK: - Unnamed groups (People / Animals)

    /// Groups of unnamed (or ignored) faces / animals, kept across visits of the page: recomputed
    /// only when the items changed (identityToken) — not on each switch of the page's filters.
    private var clusterCache: [String: (token: [Int64], clusters: [FaceCluster])] = [:]

    func clusters(_ k: IdentityKind, ignored: Bool, year: Int?) async -> [FaceCluster] {
        let token = (try? await library.identityToken(k)) ?? []
        let key = "\(k.rawValue):\(ignored):\(year ?? 0)"
        if let c = clusterCache[key], c.token == token { return c.clusters }
        let value = (try? await library.identityClusters(k, ignored: ignored, year: year)) ?? []
        clusterCache[key] = (token, value)
        return value
    }

    /// Animals can only be grouped and suggested once they have a print: compute the missing ones
    /// (a few hundred photos at most) when Animals is opened, once per session.
    func ensurePetPrints() async {
        guard !petPrintsTried, job == nil, ((try? await library.animalsMissingPrint()) ?? 0) > 0 else { return }
        petPrintsTried = true
        runJob("Recognising pets") { lib, report in
            _ = try await Analyzer(library: lib).petPrints { report($0) }
            _ = try await IdentityEngine.suggest(library: lib, kind: .pet, threshold: Pipeline.petThreshold)
        }
    }
    private var petPrintsTried = false

    func runJob(_ title: String, _ body: @escaping @Sendable (Library, @escaping ProgressHandler) async throws -> Void) {
        guard job == nil else { return }
        Task { _ = await runJobAwaiting(title, body) }
    }

    /// A background job whose result the caller waits for (an export dry run shown in its sheet):
    /// the toolbar shows its title and progress like any other. nil if another job is running or it failed.
    func runJobAwaiting<T: Sendable>(_ title: String, _ body: @escaping @Sendable (Library, @escaping ProgressHandler) async throws -> T) async -> T? {
        guard job == nil else { return nil }
        job = title
        let lib = library
        let report: ProgressHandler = { p in
            let text = "\(p.stage) \(p.done)\(p.total.map { "/\($0)" } ?? "")"
            Task { @MainActor [weak self] in
                guard let self, self.job != nil else { return } // a late report after the job ended
                self.jobDetail = text
                self.jobStage = p.stage
                self.jobDone = p.done
                if let c = p.current { self.jobCurrent = c }
            }
        }
        var result: T?
        do { result = try await body(lib, report) } catch { self.error = "\(error)" }
        job = nil
        jobDetail = nil
        jobStage = nil
        jobCurrent = nil
        await refreshAll()
        await watchAfterJob()
        return result
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
