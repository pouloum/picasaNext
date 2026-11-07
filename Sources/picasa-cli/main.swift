import Foundation
import PicasaCore

let usage = """
usage: picasa-cli [--library DIR] [-j N] <command> [args]

-j N and --batch N fix the parallel files and the batch size; without them index and analyze adapt to
the machine and to the disk of the photos (see the profile command), tuned while they run.

commands:
  scan ROOT... [--exclude NAME|/PATH]...
                          index folders (incremental; reads .picasa.ini, never writes to ROOT).
                          --exclude is remembered: a folder name anywhere, or an absolute path.
                          Always skipped: folders named thumbs, thumbnails, previews, cache, caches
  rescan                  scan every known root again (missing ones, e.g. unplugged disks, are skipped)
  roots                   list known roots
  remove-root PATH        forget a root and its index (photos untouched)
  excludes                list remembered exclusions
  unexclude NAME|/PATH    forget an exclusion (rescan to index that folder again)
  index [--redo-thumbs] [--min-size N] [--thumb-size N] [--batch N] [--profile NAME]
                          extract metadata + generate thumbnails for pending items, batch by batch
                          (--profile: this run only, instead of the saved one; -j / --batch: fixed values)
                          (--redo-thumbs: regenerate every thumbnail). Small images are ignored:
                          longest side < --min-size (200), or < --thumb-size (512) without camera
                          EXIF (other apps' thumbnails). 0 disables a rule. Without them: the sizes
                          saved in the library (PicasaNext ▸ Settings ▸ Processing)
  analyze [--redo [--include-manual]] [--batch N] [--profile NAME]
                          one Vision pass on pending images: faces, labels, animals (+ a print per
                          animal, to recognise pets), aesthetics, similar-photo prints; then name
                          suggestions for people and pets, and similar groups
                          (--redo: redo everywhere, keeping what a human decided on faces and
                          animals: names, ignores, confirmations, rejections; --include-manual
                          drops those decisions too). Alias: faces
  profile [auto|ssd|hdd|nas|eco] [--reset-tuning]
                          show (or set, remembered in the library, shared with the app) the performance
                          profile, and the plan per root: disk detected, parallel files, batch size.
                          auto: from the disk (internal/external SSD, hard disk, network share);
                          ssd/hdd/nas: force a disk kind; eco: 1-2 files at a time.
                          Values tuned during runs are kept per disk; --reset-tuning forgets them
  import-contacts FILE    import Picasa contacts.xml (person names)
  import-db3 DIR          import a Picasa db3 folder (captions, stars, faces); --no-thumbs to skip its thumbnails
  export [--format picasa|xmp|all] [--dry-run] [PATH]
                          write the library's edits next to the photos (opt-in; nothing else ever writes there).
                          picasa (default): stars, captions, named faces (+ contacts), keywords, albums into
                            each folder's .picasa.ini (previous file kept as .picasa.ini.bak; rotate/filters
                            and unknown keys kept)
                          xmp: one IMG_0001.xmp sidecar per photo: rating, caption, keywords, people and pets
                            as named regions (MWG) and People|/Pets|/Albums| keywords. Sidecars made by
                            other programs are left alone
                          PATH limits it to one folder tree. Alias: export-ini
  merge-duplicates [--apply]
                          people (pets) with the same name (case, accents, spaces ignored), e.g. one
                          person imported from several Picasa contacts: listed, merged with --apply
                          into the one with the most photos
  geocode [--limit N]     (default: the limit saved in the app's Settings, else none) name the places of geotagged photos (town, region, country) with Apple's
                          geocoder: network needed, one request per ~2 km area, throttled by Apple
                          (slow, resumable; names become searchable and show in the viewer)
  suggest                 recompute name suggestions for faces and animals (no file is read)
  stats                   library summary
  similar [--threshold T] rebuild bursts and similar/duplicate groups (T: cosine, saved; default 0.97)
  all ROOT...             scan + index + analyze

default library: ~/Library/Application Support/PicasaNext Library
(only the index + thumbnails; deleting it never touches your photos or this program)
"""

var args = Array(CommandLine.arguments.dropFirst())
var libraryURL = Library.defaultURL
var jobs = ProcessInfo.processInfo.activeProcessorCount
var jobsGiven = false

@MainActor func value(for option: String) -> String {
    guard !args.isEmpty else { FileHandle.standardError.write("\(option) needs a value\n".data(using: .utf8)!); exit(2) }
    return args.removeFirst()
}
while let first = args.first, first.hasPrefix("-") {
    args.removeFirst()
    switch first {
    case "--library", "-l": libraryURL = URL(fileURLWithPath: (value(for: first) as NSString).expandingTildeInPath)
    case "-j": jobs = max(1, Int(value(for: first)) ?? jobs); jobsGiven = true
    case "-h", "--help": print(usage); exit(0)
    default: FileHandle.standardError.write("unknown option \(first)\n".data(using: .utf8)!); exit(2)
    }
}
guard let command = args.first else { print(usage); exit(2) }
let rest = Array(args.dropFirst())

/// Values of a repeatable `--name VALUE` option, and the remaining positional arguments.
func split(_ a: [String], options: Set<String>) -> (positional: [String], values: [String: [String]]) {
    var pos: [String] = [], vals: [String: [String]] = [:]
    var i = 0
    while i < a.count {
        if options.contains(a[i]), i + 1 < a.count { vals[a[i], default: []].append(a[i + 1]); i += 2 }
        else if a[i].hasPrefix("--") { i += 1 } // flags handled by each command
        else { pos.append(a[i]); i += 1 }
    }
    return (pos, vals)
}
let parsed = split(rest, options: ["--exclude", "--min-size", "--thumb-size", "--threshold", "--batch", "--limit", "--profile"])

/// One-line, rate-limited progress on stderr.
final class Ticker: @unchecked Sendable {
    private var last = Date.distantPast
    private let lock = NSLock()
    func callAsFunction(_ p: LibraryProgress) {
        lock.lock(); defer { lock.unlock() }
        guard Date().timeIntervalSince(last) > 0.5 else { return }
        last = Date()
        let cur = p.current.map { " " + String($0.suffix(70)) } ?? ""
        FileHandle.standardError.write("\r\u{1B}[K[\(p.stage)] \(p.done)\(p.total.map { "/\($0)" } ?? "")\(cur)".data(using: .utf8)!)
    }
    func end() { FileHandle.standardError.write("\r\u{1B}[K".data(using: .utf8)!) }
}

@MainActor func run() async throws {
    let library = try Library(root: libraryURL)
    let jobs = jobs
    let tick = Ticker()
    let t0 = Date()
    @Sendable func elapsed() -> String { String(format: "%.1fs", Date().timeIntervalSince(t0)) }

    func scan(_ roots: [String]) async throws {
        guard !roots.isEmpty else { print(usage); exit(2) }
        let excludes = parsed.values["--exclude"] ?? []
        for e in excludes { print("exclude: \(Library.excludePattern(e))") }
        let urls = roots.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        for (u, i) in zip(urls, urls.indices) {
            // One root at a time, so each prints its line when done.
            let res = try await Pipeline.scan(library, roots: [u], excludes: i == 0 ? excludes : [], concurrency: min(jobs, 16)) { tick($0) }[0].result
            tick.end()
            print("scan \(u.path): \(res.folders) folders, +\(res.added) ~\(res.updated) -\(res.removed), \(res.iniParsed) .picasa.ini (\(elapsed()))")
        }
    }
    /// nil when -j or --batch fix the values; otherwise --profile, or the one saved in the library.
    func profile() async throws -> ThroughputProfile? {
        if jobsGiven || parsed.values["--batch"] != nil { return nil }
        if let name = parsed.values["--profile"]?.last {
            guard let p = ThroughputProfile(rawValue: name) else { print("unknown profile \(name): auto, ssd, hdd, nas, eco"); exit(2) }
            return p
        }
        return try await library.throughputProfile()
    }
    let planLine: @Sendable (String) -> Void = { FileHandle.standardOutput.write("\r\u{1B}[K\($0)\n".data(using: .utf8)!) }
    func index() async throws {
        var indexer = Indexer(library: library, concurrency: jobsGiven ? jobs : Indexer.defaultConcurrency)
        indexer.profile = try await profile()
        indexer.onPlan = planLine
        try await indexer.useSavedSizes()
        if let v = parsed.values["--batch"]?.last.flatMap(Int.init) { indexer.batch = max(1, v) }
        if let v = parsed.values["--min-size"]?.last.flatMap(Int.init) { indexer.minSize = v }
        if let v = parsed.values["--thumb-size"]?.last.flatMap(Int.init) { indexer.thumbSize = v }
        let r = try await Pipeline.index(indexer, redoThumbs: rest.contains("--redo-thumbs"), log: { print($0) }) { tick($0) }
        tick.end(); print("index: metadata \(r.metadata) · thumbnails \(r.thumbnails) items (\(elapsed()))")
    }
    func analyze() async throws {
        var analyzer = Analyzer(library: library, concurrency: max(1, jobs / 2))
        analyzer.profile = try await profile()
        analyzer.onPlan = planLine
        if let v = parsed.values["--batch"]?.last.flatMap(Int.init) { analyzer.batch = max(1, v) }
        if let t = threshold() { try await library.setSimilarThreshold(t) }
        _ = try await Pipeline.analyze(analyzer, redo: rest.contains("--redo"), includeManual: rest.contains("--include-manual"),
                                       log: { tick.end(); print("\($0) (\(elapsed()))") }) { tick($0) }
    }
    /// --threshold T: cosine similarity for near-duplicates, remembered in the library
    /// (calibrate with Tools/calibrate-similar.swift).
    func threshold() -> Float? {
        guard let t = parsed.values["--threshold"]?.last.flatMap(Float.init) else { return nil }
        print("similar: threshold \(t) saved")
        return t
    }
    func similar() async throws {
        let r = try await Pipeline.similar(library, threshold: threshold())
        print("similar: \(r) (\(elapsed()))")
    }

    switch command {
    case "scan": try await scan(parsed.positional)
    case "rescan":
        let r = try await Pipeline.rescan(library, concurrency: min(jobs, 16)) { tick($0) }
        tick.end()
        for m in r.missing { print("skip (not found): \(m)") }
        for (root, res) in r.scanned {
            print("scan \(root): \(res.folders) folders, +\(res.added) ~\(res.updated) -\(res.removed), \(res.iniParsed) .picasa.ini (\(elapsed()))")
        }
    case "roots":
        for r in try await library.roots() {
            print((FileManager.default.fileExists(atPath: r.path) ? "  " : "! ") + r.path)
        }
    case "remove-root":
        guard let p = parsed.positional.first else { print(usage); exit(2) }
        let n = try await library.removeRoot((p as NSString).expandingTildeInPath)
        print(n < 0 ? "\(p) is not a known root" : "removed \(p) (\(n) items dropped from the index)")
    case "excludes":
        let ex = try await library.excludes()
        print("always skipped: " + Library.defaultExcludedNames.sorted().joined(separator: ", "))
        print(ex.isEmpty ? "no user exclusions" : ex.map { "excluded: \($0)" }.joined(separator: "\n"))
    case "unexclude":
        guard let p = parsed.positional.first else { print(usage); exit(2) }
        print(try await library.removeExclude(p) ? "removed \(p) — rescan to index it again" : "\(p) was not excluded")
    case "profile":
        if rest.contains("--reset-tuning") { print("tuning: \(try await library.resetTuning()) saved values forgotten") }
        if let name = parsed.positional.first {
            guard let p = ThroughputProfile(rawValue: name) else { print("unknown profile \(name): auto, ssd, hdd, nas, eco"); exit(2) }
            try await library.setThroughputProfile(p)
        }
        let p = try await library.throughputProfile()
        print("profile: \(p.rawValue) (\(p.title)) · machine: \(Pipeline.machineSummary)")
        for r in try await Pipeline.plans(library, profile: p) {
            print("\(r.path): \(r.volume.fileSystem), \(r.volume.kind.rawValue) (\(r.volume.mountPoint))")
            for s in r.stages {
                print("  \(s.stage.rawValue): \(s.plan.summary)"
                      + (s.lastRun.map { " · last run: \($0.concurrency) parallel, batches of \($0.batch)" } ?? ""))
            }
        }
        if jobsGiven { print("(-j given: index and analyze use fixed values instead)") }
        exit(0)
    case "index": try await index()
    case "analyze", "faces": try await analyze()
    case "similar": try await similar()
    case "all": try await scan(parsed.positional); try await index(); try await analyze()
    case "import-contacts":
        guard let f = rest.first else { print(usage); exit(2) }
        let n = try await library.importContacts(at: URL(fileURLWithPath: (f as NSString).expandingTildeInPath))
        print("contacts: \(n) imported")
    case "import-db3":
        guard let d = rest.first else { print(usage); exit(2) }
        let r = try await Pipeline.importDB3(library, at: URL(fileURLWithPath: (d as NSString).expandingTildeInPath),
                                             reuseThumbnails: !rest.contains("--no-thumbs")) { tick($0) }
        tick.end(); print("db3: \(r)")
    case "export", "export-ini":
        var format = "picasa"
        var dry = false, only: String?
        var i = 0
        while i < rest.count {
            switch rest[i] {
            case "--format": i += 1; format = i < rest.count ? rest[i] : format
            case "--dry-run": dry = true
            default: only = URL(fileURLWithPath: (rest[i] as NSString).expandingTildeInPath).standardizedFileURL.path
            }
            i += 1
        }
        guard let f = Pipeline.ExportFormat(argument: format) else { print(usage); exit(2) }
        let r = try await Pipeline.export(library, format: f, dryRun: dry, only: only) { tick($0) }
        tick.end(); print(r)
        for f in r.failed { print("  failed: \(f.path): \(f.error)") }
    case "geocode":
        let saved = try await library.geocodeLimit()
        let n = parsed.values["--limit"]?.last.flatMap(Int.init) ?? saved ?? .max
        let r = try await Geocoder(library: library).run(limit: n) { tick($0) }
        tick.end(); print(r)
    case "suggest":
        let (f, p) = try await Pipeline.suggest(library)
        print("suggestions: \(f) faces, \(p) animals (\(elapsed()))")
    case "merge-duplicates":
        let all = try await Pipeline.duplicateNames(library)
        for (k, groups) in all {
            for g in groups {
                print("\(k == .face ? "person" : "pet") “\(g[0].name)”: " + g.map { "#\($0.id) (\($0.faces) photos)" }.joined(separator: " + ")
                      + " → #\(g[0].id)")
            }
        }
        if rest.contains("--apply") {
            print("merged \(try await Pipeline.mergeDuplicates(library, all)) people and pets")
        } else if all.contains(where: { !$0.groups.isEmpty }) {
            print("(dry run: add --apply to merge)")
        }
    case "stats": break
    default: print(usage); exit(2)
    }
    print(try await library.stats())
}

do { try await run() } catch {
    FileHandle.standardError.write("error: \(error)\n".data(using: .utf8)!)
    exit(1)
}
