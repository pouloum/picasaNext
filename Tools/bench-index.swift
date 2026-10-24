// Index batch-size benchmark: how the batch size changes throughput and how often new photos
// become visible (one commit per thumbnail batch).
//   swiftc -O -parse-as-library -I build/release -L build/release Tools/bench-index.swift -lPicasaCore -lPicasaFormats -lsqlite3 -o build/bench-index
//   build/bench-index WORKDIR [N_IMAGES] [BATCH...]          synthetic local images
//   build/bench-index --real LISTFILE WORKDIR                  real files (one path per line), each run
//                                                             on files not read by the previous runs
import CoreGraphics
import Foundation
import ImageIO
import PicasaCore

let args = CommandLine.arguments
let work = URL(fileURLWithPath: args.count > 1 ? args[1] : NSTemporaryDirectory() + "bench-index")
let count = args.count > 2 ? Int(args[2]) ?? 1200 : 1200
let batches = args.count > 3 ? args[3...].compactMap(Int.init) : [1, 2, 4, 8, 16, 32, 64, 96, 160, 256]
let media = work.appendingPathComponent("media")

// Camera-like JPEGs (4000×3000, ~2–4 MB, with EXIF), generated once.
func makeImages() throws {
    let fm = FileManager.default
    let existing = (try? fm.contentsOfDirectory(atPath: media.path))?.count ?? 0
    guard existing < count else { return }
    try fm.createDirectory(at: media, withIntermediateDirectories: true)
    let w = 4000, h = 3000
    for i in existing..<count {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let base = CGFloat(i % 97) / 97
        for b in 0..<60 { // bands + blocks: enough detail for realistic JPEG sizes
            ctx.setFillColor(CGColor(red: base, green: CGFloat(b) / 60, blue: CGFloat((i * 7 + b) % 50) / 50, alpha: 1))
            ctx.fill(CGRect(x: (b * 131 + i * 17) % w, y: (b * 53) % h, width: 300 + b * 20, height: 200 + (b * 37) % 900))
        }
        let url = media.appendingPathComponent(String(format: "IMG_%05d.JPG", i))
        let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil)!
        let exif: [CFString: Any] = [kCGImagePropertyExifDateTimeOriginal: "2019:06:24 12:00:\(String(format: "%02d", i % 60))"]
        let tiff: [CFString: Any] = [kCGImagePropertyTIFFModel: "Bench Camera"]
        CGImageDestinationAddImage(dest, ctx.makeImage()!, [kCGImagePropertyExifDictionary: exif, kCGImagePropertyTIFFDictionary: tiff,
                                                            kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        CGImageDestinationFinalize(dest)
        if i % 100 == 0 { print("generating \(i)/\(count)") }
    }
}

final class Gaps: @unchecked Sendable {
    let lock = NSLock()
    var stamps: [Double] = []
    func tick() { lock.lock(); stamps.append(Date().timeIntervalSince1970); lock.unlock() }
}

func run(batch: Int) async throws -> (secs: Double, commits: Int, meanGap: Double, maxGap: Double) {
    let libURL = work.appendingPathComponent("lib-\(batch)")
    try? FileManager.default.removeItem(at: libURL)
    let lib = try Library(root: libURL)
    _ = try await Scanner(library: lib).scan(root: media)
    var ix = Indexer(library: lib)
    ix.batch = batch
    let gaps = Gaps()
    let start = Date()
    _ = try await ix.run { p in if p.stage == "thumbnails" { gaps.tick() } }
    let secs = Date().timeIntervalSince(start)
    var g: [Double] = []
    var prev = start.timeIntervalSince1970
    for s in gaps.stamps { g.append(s - prev); prev = s }
    try? FileManager.default.removeItem(at: libURL)
    return (secs, gaps.stamps.count, g.isEmpty ? 0 : g.reduce(0, +) / Double(g.count), g.max() ?? 0)
}

/// Real files: each configuration indexes its own slice of the list (no cache effects), in a fresh
/// library whose rows are inserted directly (no scan of the whole folders).
func realBench(list: URL, work: URL) async throws {
    var paths = try String(contentsOf: list, encoding: .utf8).split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    func take(_ n: Int) -> [String] { let s = Array(paths.prefix(n)); paths.removeFirst(min(n, paths.count)); return s }
    func cpu() -> Double {
        var u = rusage(); getrusage(RUSAGE_SELF, &u)
        return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6
    }
    func one(_ files: [String], concurrency: Int, batch: Int) async throws -> String {
        let libURL = work.appendingPathComponent("real-\(concurrency)-\(batch)")
        try? FileManager.default.removeItem(at: libURL)
        let lib = try Library(root: libURL)
        var bytes: Int64 = 0
        try await lib.withDB { db in
            let root = try db.run("INSERT INTO roots(path, added_at) VALUES('/bench', 0)")
            var folders: [String: Int64] = [:]
            for p in files {
                let dir = (p as NSString).deletingLastPathComponent, name = (p as NSString).lastPathComponent
                if folders[dir] == nil { folders[dir] = try db.run("INSERT INTO folders(root_id, path) VALUES(?, ?)", root, dir) }
                let ext = (name as NSString).pathExtension.lowercased()
                let kind = ["mov", "mp4", "m4v", "avi", "mts"].contains(ext) ? 1 : (["arw", "cr2", "nef", "dng", "raf", "orf"].contains(ext) ? 2 : 0)
                let size = ((try? FileManager.default.attributesOfItem(atPath: p))?[.size] as? NSNumber)?.int64Value ?? 0
                _ = try db.run("INSERT INTO media(folder_id, name, kind, size, mtime) VALUES(?, ?, ?, ?, 0)", folders[dir]!, name, kind, size)
            }
        }
        bytes = try await lib.withDB { try $0.scalar("SELECT sum(size) FROM media") ?? 0 }
        var ix = Indexer(library: lib, concurrency: concurrency)
        ix.batch = batch
        let gaps = Gaps()
        let (start, c0) = (Date(), cpu())
        _ = try await ix.run { p in if p.stage == "thumbnails" { gaps.tick() } }
        let secs = Date().timeIntervalSince(start), cpuSecs = cpu() - c0
        var g: [Double] = []
        var prev = start.timeIntervalSince1970
        for t in gaps.stamps { g.append(t - prev); prev = t }
        try? FileManager.default.removeItem(at: libURL)
        let rate = Double(files.count) / secs
        return String(format: "%4d | %5d | %5d | %7.1f | %8.2f | %10.2f | %6.0f %% | %6.1f | %8.2f",
                      concurrency, batch, files.count, secs, rate, Double(concurrency) * secs / Double(files.count),
                      cpuSecs / secs * 100, Double(bytes) / secs / 1e6, g.isEmpty ? 0 : g.reduce(0, +) / Double(g.count))
    }
    let header = "  -j | batch | files |  time s | photos/s | s per file | CPU    |  MB/s  | gap s"
    // BENCH_J="1,4,6" picks the parallel reads to sweep; each sweeps the batch sizes.
    let js = (ProcessInfo.processInfo.environment["BENCH_J"] ?? "1,4,6").split(separator: ",").compactMap { Int($0) }
    for c in js {
        print("\nBatch size with -j \(c)\n" + header)
        for b in [1, 2, 4, 8, 16, 32, 64, 96, 160, 256] { print(try await one(take(max(b, 12 * c)), concurrency: c, batch: b)) }
    }
}

@main
struct Bench {
    static func main() async throws {
        if CommandLine.arguments.count > 3, CommandLine.arguments[1] == "--real" {
            try await realBench(list: URL(fileURLWithPath: CommandLine.arguments[2]), work: URL(fileURLWithPath: CommandLine.arguments[3]))
            return
        }
        try makeImages()
        print("cores \(ProcessInfo.processInfo.activeProcessorCount), \(count) images\n")
        print("batch |  time s | photos/s | commits | mean gap s | max gap s")
        for b in batches {
            let r = try await run(batch: b)
            let rate = Double(count) / r.secs
            print(String(format: "%5d | %7.1f | %8.1f | %7d | %10.3f | %9.3f", b, r.secs, rate, r.commits, r.meanGap, r.maxGap))
        }
    }
}
