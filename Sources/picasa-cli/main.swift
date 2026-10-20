import Foundation
import PicasaCore

let usage = """
usage: picasa-cli [--library DIR] [-j N] <command> [args]

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
  index [--redo-thumbs] [--min-size N] [--thumb-size N]
                          extract metadata + generate thumbnails for pending items
                          (--redo-thumbs: regenerate every thumbnail). Small images are ignored:
                          longest side < --min-size (200), or < --thumb-size (512) without camera
                          EXIF (other apps' thumbnails). 0 disables a rule
  analyze [--redo]        one Vision pass on pending images: faces, labels, animals, aesthetics,
                          similar-photo prints; then name suggestions and similar groups
                          (--redo: redo everywhere; named faces are kept). Alias: faces
  import-contacts FILE    import Picasa contacts.xml (person names)
  import-db3 DIR          import a Picasa db3 folder (captions, stars, faces); --no-thumbs to skip its thumbnails
  stats                   library summary
  similar [--threshold T] rebuild bursts and similar/duplicate groups (T: cosine, saved; default 0.97)
  all ROOT...             scan + index + analyze

default library: ~/Library/Application Support/PicasaNext Library
(only the index + thumbnails; deleting it never touches your photos or this program)
"""

var args = Array(CommandLine.arguments.dropFirst())
var libraryURL = Library.defaultURL
var jobs = ProcessInfo.processInfo.activeProcessorCount

@MainActor func value(for option: String) -> String {
    guard !args.isEmpty else { FileHandle.standardError.write("\(option) needs a value\n".data(using: .utf8)!); exit(2) }
    return args.removeFirst()
}
while let first = args.first, first.hasPrefix("-") {
    args.removeFirst()
    switch first {
    case "--library", "-l": libraryURL = URL(fileURLWithPath: (value(for: first) as NSString).expandingTildeInPath)
    case "-j": jobs = max(1, Int(value(for: first)) ?? jobs)
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
let parsed = split(rest, options: ["--exclude", "--min-size", "--thumb-size", "--threshold"])

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
    func elapsed() -> String { String(format: "%.1fs", Date().timeIntervalSince(t0)) }

    func scan(_ roots: [String]) async throws {
        guard !roots.isEmpty else { print(usage); exit(2) }
        for e in parsed.values["--exclude"] ?? [] {
            let pattern = e.hasPrefix("/") || e.hasPrefix("~") ? URL(fileURLWithPath: (e as NSString).expandingTildeInPath).standardizedFileURL.path : e
            try await library.addExclude(pattern)
            print("exclude: \(pattern)")
        }
        let scanner = Scanner(library: library, concurrency: min(jobs, 16))
        for r in roots {
            let url = URL(fileURLWithPath: (r as NSString).expandingTildeInPath)
            let res = try await scanner.scan(root: url) { tick($0) }
            tick.end()
            print("scan \(url.path): \(res.folders) folders, +\(res.added) ~\(res.updated) -\(res.removed), \(res.iniParsed) .picasa.ini (\(elapsed()))")
        }
    }
    func index() async throws {
        if rest.contains("--redo-thumbs") { print("thumbnails: \(try await library.resetThumbnails()) marked for regeneration") }
        var indexer = Indexer(library: library, concurrency: jobs)
        if let v = parsed.values["--min-size"]?.last.flatMap(Int.init) { indexer.minSize = v }
        if let v = parsed.values["--thumb-size"]?.last.flatMap(Int.init) { indexer.thumbSize = v }
        let m = try await indexer.extractMetadata { tick($0) }
        tick.end(); print("metadata: \(m) items (\(elapsed()))")
        let t = try await indexer.generateThumbnails { tick($0) }
        tick.end(); print("thumbnails: \(t) items (\(elapsed()))")
    }
    func analyze() async throws {
        if rest.contains("--redo") {
            let n = try await library.resetFaces()
            _ = try await library.resetAnalysis()
            print("analysis: \(n) images marked for re-analysis")
        }
        let n = try await Analyzer(library: library, concurrency: max(1, jobs / 2)).run { tick($0) }
        tick.end(); print("analysis: \(n) images (\(elapsed()))")
        let s = try await FaceEngine(library: library).suggestNames()
        print("faces: \(s) name suggestions (\(elapsed()))")
        try await similar()
    }
    func similar() async throws {
        // --threshold T: cosine similarity for near-duplicates, remembered in the library
        // (calibrate with Tools/calibrate-similar.swift).
        if let t = parsed.values["--threshold"]?.last.flatMap(Float.init) {
            try await library.setSimilarThreshold(t)
            print("similar: threshold \(t) saved")
        }
        let r = try await library.groupSimilar()
        print("similar: \(r) (\(elapsed()))")
    }

    switch command {
    case "scan": try await scan(parsed.positional)
    case "rescan":
        for r in try await library.roots() {
            guard FileManager.default.fileExists(atPath: r.path) else { print("skip (not found): \(r.path)"); continue }
            try await scan([r.path])
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
        let r = try await library.importDB3(at: URL(fileURLWithPath: (d as NSString).expandingTildeInPath),
                                            reuseThumbnails: !rest.contains("--no-thumbs")) { tick($0) }
        tick.end(); print("db3: \(r)")
    case "stats": break
    default: print(usage); exit(2)
    }
    print(try await library.stats())
}

do { try await run() } catch {
    FileHandle.standardError.write("error: \(error)\n".data(using: .utf8)!)
    exit(1)
}
