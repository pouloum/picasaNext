import Foundation
import PicasaCore

let usage = """
usage: picasa-cli [--library DIR] [-j N] <command> [args]

commands:
  scan ROOT...            index folders (incremental; reads .picasa.ini, never writes to ROOT)
  index                   extract metadata + generate thumbnails for pending items
  faces                   detect faces (Vision) on pending items, then suggest names
  import-contacts FILE    import Picasa contacts.xml (person names)
  import-db3 DIR          import a Picasa db3 folder (captions, stars, faces); --no-thumbs to skip its thumbnails
  stats                   library summary
  all ROOT...             scan + index + faces

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
        let scanner = Scanner(library: library, concurrency: min(jobs, 16))
        for r in roots {
            let url = URL(fileURLWithPath: (r as NSString).expandingTildeInPath)
            let res = try await scanner.scan(root: url) { tick($0) }
            tick.end()
            print("scan \(url.path): \(res.folders) folders, +\(res.added) ~\(res.updated) -\(res.removed), \(res.iniParsed) .picasa.ini (\(elapsed()))")
        }
    }
    func index() async throws {
        let indexer = Indexer(library: library, concurrency: jobs)
        let m = try await indexer.extractMetadata { tick($0) }
        tick.end(); print("metadata: \(m) items (\(elapsed()))")
        let t = try await indexer.generateThumbnails { tick($0) }
        tick.end(); print("thumbnails: \(t) items (\(elapsed()))")
    }
    func faces() async throws {
        let engine = FaceEngine(library: library, concurrency: max(1, jobs / 2))
        let n = try await engine.detectPending { tick($0) }
        tick.end(); print("faces: \(n) images analysed (\(elapsed()))")
        let s = try await engine.suggestNames()
        print("faces: \(s) suggestions from named Picasa faces (\(elapsed()))")
    }

    switch command {
    case "scan": try await scan(rest)
    case "index": try await index()
    case "faces": try await faces()
    case "all": try await scan(rest); try await index(); try await faces()
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
