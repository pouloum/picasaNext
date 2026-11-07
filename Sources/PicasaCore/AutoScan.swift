import CoreServices
import Foundation

// Automatic scanning of the roots for new items:
//  - while the app is open, an FSEventStream reports the folders that changed; once nothing has moved
//    for a few seconds, only those folders are scanned again (`Scanner.scan(folders:)`);
//  - at launch, the same stream replays the system journal from the last event ID saved in `settings`,
//    which catches what was added while the app was closed. A root falls back to a full rescan when
//    there is nothing to replay from: first launch, another volume or a reset journal, history lost,
//    or a volume without a journal (network share), which is also rescanned periodically.

// MARK: - Targeted scan

extension Scanner {
    /// Scans these folders again (not their known subfolders), as reported by the folder watcher.
    /// New subfolders are walked entirely (a copied folder of folders); gone ones are pruned with their
    /// subtree. `recursive` folders are walked entirely (the watcher lost track of what changed inside).
    /// Same safeguards as a full scan: exclusions, hidden folders, and a root that looks unmounted
    /// (missing, or empty while the library holds media for it) is left untouched.
    public func scan(folders paths: some Sequence<String>, recursive: Set<String> = [],
                     progress: ProgressHandler? = nil) async throws -> Result {
        let roots = try await library.roots()
        let user = try await library.excludes()
        let exclusions = Exclusions(
            names: Library.defaultExcludedNames.union(user.filter { !$0.hasPrefix("/") }.map { $0.lowercased() }),
            prefixes: user.filter { $0.hasPrefix("/") }.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        var result = Result()
        var rootOK: [Int64: Bool] = [:]
        var queue: [(rootId: Int64, path: String, deep: Bool)] = []
        // Paths may come as the root is stored or resolved (FSEvents reports /private/tmp for /tmp).
        // They are written the way a full scan stores them: the root as given, folders below it as
        // listed from it (see `childBase`), so the same folder never gets a second row.
        let forms = roots.map { r in (root: r, prefixes: Array(Set([r.path, FolderWatcher.realPath(r.path)]))) }
        var bases: [Int64: String] = [:]
        func match(_ p: String) -> (root: (id: Int64, path: String), suffix: String)? {
            var best: (root: (id: Int64, path: String), suffix: String, length: Int)?
            for f in forms {
                for pre in f.prefixes where p == pre || p.hasPrefix(pre + "/") {
                    if pre.count > best?.length ?? -1 { best = (f.root, String(p.dropFirst(pre.count)), pre.count) }
                }
            }
            return best.map { ($0.root, $0.suffix) }
        }
        var requested: [(rootId: Int64, path: String, deep: Bool)] = []
        for (p, deep) in Set(paths).subtracting(recursive).map({ ($0, false) }) + recursive.map({ ($0, true) }) {
            let trimmed = p.count > 1 && p.hasSuffix("/") ? String(p.dropLast()) : p
            guard let (root, suffix) = match(trimmed) else { continue }
            if rootOK[root.id] == nil { rootOK[root.id] = try await rootLooksMounted(root) }
            guard rootOK[root.id] == true, !skipped(suffix, under: root.path, exclusions) else { continue }
            if bases[root.id] == nil { bases[root.id] = Self.childBase(root.path) }
            requested.append((root.id, suffix.isEmpty ? root.path : bases[root.id]! + suffix, deep))
        }
        // A folder asked both ways is walked entirely.
        let deepPaths = Set(requested.filter(\.deep).map(\.path))
        queue = requested.filter { $0.deep || !deepPaths.contains($0.path) }
        // Parents first, so a new folder's parent row exists before it (and duplicates are skipped).
        queue.sort { $0.path.count > $1.path.count }
        var seen = Set<String>()
        while let (rootId, path, deep) = queue.popLast() {
            guard seen.insert(path).inserted else { continue }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
                result.removed += try await library.pruneSubtree(path)
                continue
            }
            // Unreadable (permission glitch, disk unplugged mid-listing): kept as it is.
            guard let listing = Self.list(URL(fileURLWithPath: path), skipHidden: skipHiddenFolders, excluded: exclusions) else { continue }
            let r = try await library.apply(listing: listing, rootId: rootId)
            result.folders += 1
            result.added += r.added; result.updated += r.updated; result.removed += r.removed
            if r.iniParsed { result.iniParsed += 1 }
            progress?(LibraryProgress(stage: "scan", done: result.folders, total: nil, current: listing.path))
            // The root's subfolders are stored as its listing names them (`childBase`).
            let isRoot = roots.contains { $0.id == rootId && $0.path == path }
            let parent = isRoot ? (bases[rootId] ?? Self.childBase(path)) : path
            let known = Set(try await library.childFolders(of: parent))
            let present = Set(listing.subfolders.map(\.path))
            for gone in known.subtracting(present) { result.removed += try await library.pruneSubtree(gone) }
            for sub in present where deep || !known.contains(sub) { queue.append((rootId, sub, true)) }
        }
        return result
    }

    /// The unmounted-volume guard of `scan(root:)`: a missing root, or an empty one while the library
    /// holds media for it, is never taken as "everything was deleted".
    func rootLooksMounted(_ root: (id: Int64, path: String)) async throws -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else { return false }
        let empty = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).isEmpty
        if !empty { return true }
        return try await library.mediaCount(rootId: root.id) == 0
    }

    /// True when a folder below `root` (given by its path relative to it) sits in, or is, a folder
    /// a full scan would not descend into.
    func skipped(_ suffix: String, under root: String, _ exclusions: Exclusions) -> Bool {
        var url = URL(fileURLWithPath: root)
        for name in suffix.split(separator: "/").map(String.init) {
            url.appendPathComponent(name)
            if name.hasPrefix(".") && (skipHiddenFolders || name == ".picasaoriginals") { return true }
            if name == "$RECYCLE.BIN" || name == "System Volume Information" || name == "@eaDir" { return true }
            if exclusions.excludes(url) { return true }
            if (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) == true { return true }
        }
        return false
    }

    /// How a full scan writes the folders below a root: as the directory listing of the root returns
    /// them, which can differ from the root as given (/tmp/x → /private/tmp/x/sub).
    static func childBase(_ root: String) -> String {
        let keys: [URLResourceKey] = [.isDirectoryKey]
        let items = (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: root), includingPropertiesForKeys: keys)) ?? []
        return items.first.map { $0.deletingLastPathComponent().path } ?? root
    }
}

extension Library {
    /// Known direct subfolders of a folder.
    func childFolders(of path: String) throws -> [String] {
        try db.all("SELECT path FROM folders WHERE path > ? AND path < ?", [path + "/", path + "0"]) { $0.text(0) }
            .filter { !$0.dropFirst(path.count + 1).contains("/") }
    }

    /// Forgets a folder that is gone from the disk, its subfolders and their media. Returns the media removed.
    func pruneSubtree(_ path: String) throws -> Int {
        let ids = try db.all("SELECT id FROM folders WHERE path = ? OR (path > ? AND path < ?)", [path, path + "/", path + "0"]) { $0.int(0) }
        var removed = 0
        try db.transaction {
            for id in ids {
                let media = try db.all("SELECT id FROM media WHERE folder_id = ?", [id]) { $0.int(0) }
                media.forEach { thumbs.remove(id: $0) }
                removed += media.count
                try db.run("DELETE FROM folders WHERE id = ?", id)
            }
        }
        return removed
    }
}

// MARK: - Watch settings and plan

extension Library {
    /// Settings ▸ Library ▸ Watch folders (on by default).
    public func watchEnabled() throws -> Bool { try setting("watch.enabled") != "0" }
    public func setWatchEnabled(_ on: Bool) throws { try setSetting("watch.enabled", on ? "1" : "0") }

    /// Last FSEvents event ID whose changes are in the library, and the journal (volume) of each root then.
    public func watchCheckpoint() throws -> (eventId: UInt64?, volumes: [String: String]) {
        let id = try setting("watch.eventId").flatMap(UInt64.init)
        var volumes: [String: String] = [:]
        try db.query("SELECT key, value FROM settings WHERE key LIKE 'watch.volume.%'") {
            volumes[String($0.text(0).dropFirst("watch.volume.".count))] = $0.text(1)
        }
        return (id, volumes)
    }

    public func saveWatchCheckpoint(eventId: UInt64, volumes: [String: String]) throws {
        try db.transaction {
            try setSetting("watch.eventId", String(eventId))
            for (root, uuid) in volumes { try setSetting("watch.volume." + root, uuid) }
        }
    }

    /// What to do with each root when watching starts.
    public struct WatchPlan: Sendable {
        /// Roots followed with FSEvents (they have a journal).
        public var watched: [String] = []
        /// Replay the journal from there (nil: start from now).
        public var sinceWhen: UInt64?
        /// Roots to scan entirely first: nothing reliable to replay from.
        public var fullRescan: [String] = []
        /// Roots without a journal (network shares): fully rescanned now and then.
        public var periodic: [String] = []
        /// Journal UUID of each watched root, saved with the next checkpoint.
        public var volumes: [String: String] = [:]
        /// Event ID when the plan was made: the checkpoint after the full rescans.
        public var now: UInt64 = 0
        public init() {}
    }

    /// `catchUp`: at launch, what changed while the app was closed is replayed or rescanned.
    /// Otherwise (watching turned back on, roots added/removed) only roots never seen before are scanned.
    public func watchPlan(catchUp: Bool) throws -> WatchPlan {
        let saved = try watchCheckpoint()
        var plan = WatchPlan()
        plan.now = FolderWatcher.currentEventId()
        let validId = saved.eventId.map { $0 > 0 && $0 <= plan.now } ?? false
        plan.sinceWhen = catchUp && validId ? saved.eventId : nil
        for r in try roots() {
            guard FileManager.default.fileExists(atPath: r.path) else { continue } // unplugged: nothing to do
            guard let uuid = FolderWatcher.journalUUID(for: r.path), VolumeInfo.of(r.path).kind != .network else {
                plan.periodic.append(r.path)
                if catchUp { plan.fullRescan.append(r.path) }
                continue
            }
            plan.watched.append(r.path)
            plan.volumes[r.path] = uuid
            if catchUp && (!validId || saved.volumes[r.path] != uuid) { plan.fullRescan.append(r.path) }
        }
        return plan
    }
}

// MARK: - FSEvents

/// Follows folders with an FSEventStream and reports the changed folders in batches, once nothing
/// has changed for `quiet` seconds (copying 500 photos makes one batch, not 500).
public final class FolderWatcher: @unchecked Sendable {
    public struct Batch: Sendable {
        /// Folders whose content changed (as library paths, i.e. under the roots as given).
        public var folders = Set<String>()
        /// Folders to walk entirely: events were coalesced or dropped, or the journal was lost.
        public var recursive = Set<String>()
        /// Highest event ID in the batch: once applied, the checkpoint to save.
        public var lastEventId: UInt64 = 0
        /// The replay from `sinceWhen` is over (this batch ends it).
        public var historyDone = false
        /// Event IDs wrapped around: every root must be rescanned and the checkpoint started over.
        public var reset = false
        public var isEmpty: Bool { folders.isEmpty && recursive.isEmpty && !reset }
    }

    public static func currentEventId() -> UInt64 { FSEventsGetCurrentEventId() }

    /// UUID of the FSEvents journal of the volume holding `path`. It changes when the journal is reset;
    /// nil when the volume has none (network share, some external file systems).
    public static func journalUUID(for path: String) -> String? {
        var st = stat()
        guard stat(path, &st) == 0, let uuid = FSEventsCopyUUIDForDevice(st.st_dev) else { return nil }
        return CFUUIDCreateString(nil, uuid) as String?
    }

    let roots: [(real: String, library: String)]
    let ignored: [String]
    let sinceWhen: UInt64?
    let latency: TimeInterval
    let quiet: TimeInterval
    let handler: @Sendable (Batch) -> Void
    private let queue = DispatchQueue(label: "picasanext.folder-watcher")
    private var stream: FSEventStreamRef?
    private var pending = Batch()
    private var flush: DispatchWorkItem?

    /// `ignoring`: paths whose changes are not reported (the library's own folder, if under a root).
    public init(roots: [String], sinceWhen: UInt64?, latency: TimeInterval = 1, quiet: TimeInterval = 5,
                ignoring: [String] = [], handler: @escaping @Sendable (Batch) -> Void) {
        // FSEvents reports real paths (/private/var/…, resolved symlinks): mapped back to the roots as stored.
        self.roots = roots.map { (Self.realPath($0), $0) }
        self.ignored = ignoring.map(Self.realPath)
        self.sinceWhen = sinceWhen
        self.latency = latency
        self.quiet = quiet
        self.handler = handler
        queue.setSpecific(key: Self.onQueue, value: true)
    }

    deinit { stop() }

    static func realPath(_ p: String) -> String {
        guard let r = realpath(p, nil) else { return p }
        defer { free(r) }
        return String(cString: r)
    }

    /// The last event ID delivered to this watcher (after the replay: up to date while it is quiet).
    public var latestEventId: UInt64 {
        queue.sync { stream.map { FSEventStreamGetLatestEventId($0) } ?? 0 }
    }

    /// True when no change is waiting for its quiet period.
    public var isIdle: Bool { queue.sync { pending.isEmpty } }

    @discardableResult
    public func start() -> Bool {
        queue.sync {
            guard stream == nil, !roots.isEmpty else { return stream != nil }
            var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
            let callback: FSEventStreamCallback = { _, info, count, paths, flags, ids in
                let me = Unmanaged<FolderWatcher>.fromOpaque(info!).takeUnretainedValue()
                let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
                me.received(Array(zip(list, (0..<count).map { (flags[$0], ids[$0]) })))
            }
            let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot)
            guard let s = FSEventStreamCreate(nil, callback, &ctx, roots.map(\.real) as CFArray,
                                              sinceWhen ?? FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                              latency, flags) else { return false }
            FSEventStreamSetDispatchQueue(s, queue)
            guard FSEventStreamStart(s) else { FSEventStreamInvalidate(s); FSEventStreamRelease(s); return false }
            stream = s
            return true
        }
    }

    public func stop() {
        let stop = { [self] in
            flush?.cancel(); flush = nil
            guard let s = stream else { return }
            FSEventStreamStop(s); FSEventStreamInvalidate(s); FSEventStreamRelease(s)
            stream = nil
        }
        if DispatchQueue.getSpecific(key: Self.onQueue) != nil { stop() } else { queue.sync(execute: stop) }
    }
    private static let onQueue = DispatchSpecificKey<Bool>()

    /// Runs on `queue`.
    private func received(_ events: [(path: String, (flags: FSEventStreamEventFlags, id: FSEventStreamEventId))]) {
        var historyDone = false
        for (rawPath, (f, id)) in events {
            let flags = Int(f)
            pending.lastEventId = max(pending.lastEventId, id)
            if flags & kFSEventStreamEventFlagHistoryDone != 0 { historyDone = true; continue }
            if flags & kFSEventStreamEventFlagEventIdsWrapped != 0 { pending.reset = true; continue }
            let path = rawPath.hasSuffix("/") && rawPath.count > 1 ? String(rawPath.dropLast()) : rawPath
            if ignored.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { continue }
            let deep = flags & (kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
                | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged
                | kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount) != 0
            for r in roots {
                if path == r.real || path.hasPrefix(r.real + "/") {
                    let lib = r.library + path.dropFirst(r.real.count)
                    if deep { pending.recursive.insert(lib) } else { pending.folders.insert(lib) }
                } else if deep && (r.real.hasPrefix(path + "/") || path == "/") {
                    // A change above the root (renamed/remounted, or the history lost): all of it.
                    pending.recursive.insert(r.library)
                }
            }
        }
        if historyDone { pending.historyDone = true }
        flush?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.deliver() }
        flush = work
        // The end of the replay is reported at once; live changes wait for the quiet period.
        queue.asyncAfter(deadline: .now() + (historyDone ? 0 : quiet), execute: work)
    }

    private func deliver() {
        let batch = pending
        pending = Batch()
        flush = nil
        if !batch.isEmpty || batch.historyDone { handler(batch) }
    }
}
