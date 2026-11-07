import Foundation

// The multi-step operations shared by picasa-cli and the app (PicasaNext): each command of the CLI
// and each menu of the app calls these, so both do exactly the same thing.

// MARK: - Settings shared by the CLI and the app (saved in the library)

extension Library {
    /// Small images are ignored when indexing (see `classifySmall`): longest side below `minSize`,
    /// or below `thumbSize` without camera EXIF (other apps' thumbnails). 0 disables a rule.
    public static let defaultMinSize = 200
    public static let defaultThumbSize = 512

    public func indexSizes() throws -> (minSize: Int, thumbSize: Int) {
        (try setting("index.minSize").flatMap(Int.init) ?? Self.defaultMinSize,
         try setting("index.thumbSize").flatMap(Int.init) ?? Self.defaultThumbSize)
    }

    public func setIndexSizes(minSize: Int, thumbSize: Int) throws {
        try setSetting("index.minSize", String(max(0, minSize)))
        try setSetting("index.thumbSize", String(max(0, thumbSize)))
    }

    /// Places named per geocode run (Apple throttles requests); nil: no limit.
    public func geocodeLimit() throws -> Int? {
        try setting("geocode.limit").flatMap(Int.init).flatMap { $0 > 0 ? $0 : nil }
    }

    public func setGeocodeLimit(_ n: Int?) throws {
        try setSetting("geocode.limit", String(max(0, n ?? 0)))
    }

    /// An exclusion as stored: absolute (or ~) paths standardized, folder names kept as typed.
    public static func excludePattern(_ s: String) -> String {
        let s = s.trimmingCharacters(in: .whitespaces)
        guard s.hasPrefix("/") || s.hasPrefix("~") else { return s }
        return URL(fileURLWithPath: (s as NSString).expandingTildeInPath).standardizedFileURL.path
    }
}

extension Indexer {
    /// Minimum and thumbnail sizes from the library's settings (picasa-cli flags override them after).
    public mutating func useSavedSizes() async throws {
        (minSize, thumbSize) = try await library.indexSizes()
    }
}

public enum Pipeline {
    /// Name suggestions for animals: cosine to the pet's average print.
    public static let petThreshold: Float = 0.82

    // MARK: Scan

    /// Remembers the exclusions (see `Library.excludePattern`), then scans each root.
    public static func scan(_ library: Library, roots: [URL], excludes: [String] = [], concurrency: Int = 8,
                            progress: ProgressHandler? = nil) async throws -> [(root: String, result: Scanner.Result)] {
        for e in excludes where !e.trimmingCharacters(in: .whitespaces).isEmpty {
            try await library.addExclude(Library.excludePattern(e))
        }
        let scanner = Scanner(library: library, concurrency: concurrency)
        var out: [(String, Scanner.Result)] = []
        for u in roots {
            out.append((u.path, try await scanner.scan(root: u, progress: progress)))
        }
        return out
    }

    /// Scans every known root again; missing ones (unplugged disk) are skipped, never pruned.
    public static func rescan(_ library: Library, concurrency: Int = 8, progress: ProgressHandler? = nil)
        async throws -> (scanned: [(root: String, result: Scanner.Result)], missing: [String]) {
        var present: [URL] = [], missing: [String] = []
        for r in try await library.roots() {
            if FileManager.default.fileExists(atPath: r.path) { present.append(URL(fileURLWithPath: r.path)) } else { missing.append(r.path) }
        }
        return (try await scan(library, roots: present, concurrency: concurrency, progress: progress), missing)
    }

    // MARK: Index

    /// Metadata + thumbnails of pending items (`redoThumbs`: every thumbnail is made again).
    public static func index(_ indexer: Indexer, redoThumbs: Bool = false, log: (@Sendable (String) -> Void)? = nil,
                             progress: ProgressHandler? = nil) async throws -> (metadata: Int, thumbnails: Int) {
        if redoThumbs { log?("thumbnails: \(try await indexer.library.resetThumbnails()) marked for regeneration") }
        return try await indexer.run(progress: progress)
    }

    // MARK: Analysis

    /// What `analyze` did, step by step.
    public struct AnalysisReport: Sendable {
        public var reset: Int?
        public var analyzed = 0, faceSuggestions = 0, petPrints = 0, petSuggestions = 0
        public var similar = SimilarityReport()
    }

    /// One Vision pass on pending images, then name suggestions for people and pets, the pets'
    /// prints, and the similar groups. `redo`: every image again, keeping what a human decided on faces
    /// and animals unless `includeManual`. `log` gets one line per step (as picasa-cli prints them).
    public static func analyze(_ analyzer: Analyzer, redo: Bool = false, includeManual: Bool = false,
                               log: (@Sendable (String) -> Void)? = nil, progress: ProgressHandler? = nil) async throws -> AnalysisReport {
        let library = analyzer.library
        var r = AnalysisReport()
        if redo {
            let n = try await library.resetFaces(includeManual: includeManual)
            _ = try await library.resetAnalysis(includeManual: includeManual)
            r.reset = n
            log?("analysis: \(n) images marked for re-analysis")
        }
        r.analyzed = try await analyzer.run(progress: progress)
        log?("analysis: \(r.analyzed) images")
        r.faceSuggestions = try await FaceEngine(library: library).suggestNames()
        log?("faces: \(r.faceSuggestions) name suggestions")
        r.petPrints = try await Analyzer(library: library, concurrency: analyzer.concurrency).petPrints(progress: progress)
        r.petSuggestions = try await IdentityEngine.suggest(library: library, kind: .pet, threshold: petThreshold)
        log?("pets: \(r.petPrints) photos printed, \(r.petSuggestions) name suggestions")
        r.similar = try await similar(library)
        log?("similar: \(r.similar)")
        return r
    }

    /// Name suggestions for faces and animals, from the prints already computed (no file is read).
    public static func suggest(_ library: Library) async throws -> (faces: Int, pets: Int) {
        (try await FaceEngine(library: library).suggestNames(),
         try await IdentityEngine.suggest(library: library, kind: .pet, threshold: petThreshold))
    }

    /// Bursts and similar / duplicate groups; `threshold` (cosine) is saved first when given.
    public static func similar(_ library: Library, threshold: Float? = nil) async throws -> SimilarityReport {
        if let threshold { try await library.setSimilarThreshold(threshold) }
        return try await library.groupSimilar()
    }

    // MARK: Picasa import

    /// A Picasa db3 folder; names imported on hidden copies go to the photo kept.
    public static func importDB3(_ library: Library, at dir: URL, reuseThumbnails: Bool = true,
                                 progress: ProgressHandler? = nil) async throws -> DB3ImportReport {
        let r = try await library.importDB3(at: dir, reuseThumbnails: reuseThumbnails, progress: progress)
        _ = try await library.mirrorToCopies(.face)
        return r
    }

    /// A whole Picasa2 / Picasa3 folder: contacts.xml (person names) and, when present, db3.
    public static func importPicasaFolder(_ library: Library, at dir: URL, reuseThumbnails: Bool = true,
                                          progress: ProgressHandler? = nil) async throws -> (contacts: Int, db3: DB3ImportReport?) {
        let fm = FileManager.default
        var contacts = 0
        var db3: DB3ImportReport?
        for c in ["contacts/contacts.xml", "contacts.xml"] where fm.fileExists(atPath: dir.appendingPathComponent(c).path) {
            contacts = try await library.importContacts(at: dir.appendingPathComponent(c)); break
        }
        for d in [dir.appendingPathComponent("db3"), dir] where fm.fileExists(atPath: d.appendingPathComponent("thumbindex.db").path) {
            db3 = try await importDB3(library, at: d, reuseThumbnails: reuseThumbnails, progress: progress); break
        }
        if db3 == nil { _ = try await library.mirrorToCopies(.face) }
        _ = try await FaceEngine(library: library).suggestNames()
        return (contacts, db3)
    }

    // MARK: Export

    public enum ExportFormat: String, CaseIterable, Sendable {
        case picasa, xmp, all
        /// "ini" is an old name of picasa.
        public init?(argument: String) {
            if argument == "ini" { self = .picasa } else { self.init(rawValue: argument) }
        }
    }

    public struct ExportReport: Sendable, CustomStringConvertible {
        public var ini: IniExportReport?
        public var xmp: XmpExportReport?
        public var failed: [(path: String, error: String)] { (ini?.failed ?? []) + (xmp?.failed ?? []) }
        public var description: String { [ini?.description, xmp?.description].compactMap { $0 }.joined(separator: "\n") }
    }

    /// The library's edits written next to the photos (`only`: one folder tree); `dryRun` writes nothing.
    public static func export(_ library: Library, format: ExportFormat, dryRun: Bool, only: String? = nil,
                              progress: ProgressHandler? = nil) async throws -> ExportReport {
        var r = ExportReport()
        if format != .xmp { r.ini = try await library.exportIni(dryRun: dryRun, only: only, progress: progress) }
        if format != .picasa { r.xmp = try await library.exportXmp(dryRun: dryRun, only: only, progress: progress) }
        return r
    }

    // MARK: Duplicate names

    /// People and pets sharing a name (case, accents, spaces ignored); the first of each group, the one
    /// with the most photos, is the one kept.
    public static func duplicateNames(_ library: Library) async throws -> [(kind: IdentityKind, groups: [[PersonSummary]])] {
        [(.face, try await library.duplicateOwners(.face)), (.pet, try await library.duplicateOwners(.pet))]
    }

    /// Merges the groups, then refreshes the suggestions of each kind merged. Returns the owners merged.
    @discardableResult
    public static func mergeDuplicates(_ library: Library, _ groups: [(kind: IdentityKind, groups: [[PersonSummary]])]) async throws -> Int {
        var n = 0
        for (k, g) in groups where !g.isEmpty {
            n += try await library.mergeDuplicates(k, g)
            _ = try await IdentityEngine.suggest(library: library, kind: k, threshold: petThreshold) // 0.82, as FaceEngine.suggestThreshold
        }
        return n
    }

    // MARK: Performance plan

    public struct StagePlan: Sendable {
        public var stage: ThroughputStage
        public var plan: ThroughputPlan
        /// Values tuned during the last run on this disk, if any.
        public var lastRun: (concurrency: Int, batch: Int)?
    }

    public struct RootPlan: Sendable {
        public var path: String
        public var volume: VolumeInfo
        public var stages: [StagePlan]
    }

    /// For each root: the disk detected and how each stage will start (and was last tuned) with `profile`.
    public static func plans(_ library: Library, profile: ThroughputProfile) async throws -> [RootPlan] {
        var out: [RootPlan] = []
        for r in try await library.roots() {
            let v = VolumeInfo.of(r.path)
            var stages: [StagePlan] = []
            for stage in [ThroughputStage.metadata, .thumbnails, .analysis] {
                stages.append(StagePlan(stage: stage, plan: ThroughputPlan.make(profile: profile, volume: v.kind, stage: stage),
                                        lastRun: try await library.tuning(stage: stage, profile: profile, volume: v.key)))
            }
            out.append(RootPlan(path: r.path, volume: v, stages: stages))
        }
        return out
    }

    /// The machine as the plans see it: cores, memory, battery, Low Power Mode, heat.
    public static var machineSummary: String {
        HostInfo.current.summary + (HostInfo.onBattery ? ", on battery" : "")
            + (ProcessInfo.processInfo.isLowPowerModeEnabled ? ", Low Power Mode" : "")
            + (ProcessInfo.processInfo.thermalState.rawValue >= 2 ? ", hot (throttled)" : "")
    }
}

extension ThroughputPlan {
    /// "start 4 parallel (2–8), tuned, batches of 16, path order"
    public var summary: String {
        "start \(concurrency) parallel (\(minConcurrency)–\(maxConcurrency))" + (adaptive ? ", tuned" : "")
            + ", batches of \(batch)" + (sortByPath ? ", path order" : "")
    }
}
