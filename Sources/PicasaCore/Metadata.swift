import AVFoundation
import CryptoKit
import Foundation
import ImageIO

public struct MediaMetadata: Sendable {
    public var width: Int?
    public var height: Int?
    public var orientation: Int?
    public var takenAt: Date?
    public var lat: Double?
    public var lon: Double?
    public var camera: String?
    public var duration: Double?
    public var quickHash: String?
    /// The file carries camera metadata (make/model, capture date or GPS). Thumbnails written by
    /// other applications usually don't, which is how they are told apart from small old photos.
    public var exif = false
}

public enum MetadataReader {
    /// Reads metadata without decoding pixels (ImageIO properties / AVAsset tracks).
    /// Nil when the file cannot be read right now (disk unplugged, permissions): the item stays pending.
    public static func read(url: URL, kind: MediaKind) async -> MediaMetadata? {
        guard FileManager.default.isReadableFile(atPath: url.path) else { return nil }
        var m: MediaMetadata
        switch kind {
        case .image, .raw: m = image(url)
        case .video: m = await video(url)
        }
        m.quickHash = quickHash(url)
        return m
    }

    /// SHA-256 over size + first and last 64 KiB: cheap duplicate detection on 2 TB without reading it all.
    public static func quickHash(_ url: URL) -> String? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        let chunk = 64 * 1024
        guard let size = try? fh.seekToEnd() else { return nil }
        var h = SHA256()
        withUnsafeBytes(of: size.littleEndian) { h.update(bufferPointer: $0) }
        try? fh.seek(toOffset: 0)
        if let head = try? fh.read(upToCount: chunk) { h.update(data: head) }
        if size > UInt64(chunk) {
            try? fh.seek(toOffset: max(UInt64(chunk), size - UInt64(chunk)))
            if let tail = try? fh.read(upToCount: chunk) { h.update(data: tail) }
        }
        return h.finalize().prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    static let exifDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        f.timeZone = .current // EXIF local time without zone, as Picasa did
        return f
    }()

    static func image(_ url: URL) -> MediaMetadata {
        var m = MediaMetadata()
        let opts = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithURL(url as CFURL, opts),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, opts) as? [CFString: Any] else { return m }
        m.width = props[kCGImagePropertyPixelWidth] as? Int
        m.height = props[kCGImagePropertyPixelHeight] as? Int
        m.orientation = props[kCGImagePropertyOrientation] as? Int
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let dateStr = (exif?[kCGImagePropertyExifDateTimeOriginal] as? String)
            ?? (exif?[kCGImagePropertyExifDateTimeDigitized] as? String)
            ?? (tiff?[kCGImagePropertyTIFFDateTime] as? String)
        if let d = dateStr { m.takenAt = exifDate.date(from: d) }
        m.exif = dateStr != nil || tiff?[kCGImagePropertyTIFFModel] != nil || props[kCGImagePropertyGPSDictionary] != nil
        let make = (tiff?[kCGImagePropertyTIFFMake] as? String)?.trimmingCharacters(in: .whitespaces)
        let model = (tiff?[kCGImagePropertyTIFFModel] as? String)?.trimmingCharacters(in: .whitespaces)
        if let model { m.camera = (make.map { model.hasPrefix($0) ? model : "\($0) \(model)" } ?? model) }
        if let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any],
           let lat = gps[kCGImagePropertyGPSLatitude] as? Double, let lon = gps[kCGImagePropertyGPSLongitude] as? Double {
            m.lat = (gps[kCGImagePropertyGPSLatitudeRef] as? String) == "S" ? -lat : lat
            m.lon = (gps[kCGImagePropertyGPSLongitudeRef] as? String) == "W" ? -lon : lon
        }
        return m
    }

    static func video(_ url: URL) async -> MediaMetadata {
        var m = MediaMetadata()
        m.exif = true // videos are never treated as thumbnails
        let asset = AVURLAsset(url: url)
        if let d = try? await asset.load(.duration), d.isNumeric { m.duration = d.seconds }
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let (size, t) = try? await track.load(.naturalSize, .preferredTransform) {
            let r = CGRect(origin: .zero, size: size).applying(t)
            m.width = Int(abs(r.width)); m.height = Int(abs(r.height))
        }
        if let date = try? await asset.load(.creationDate), let v = try? await date.load(.dateValue) {
            m.takenAt = v
        }
        if let items = try? await asset.load(.metadata) {
            for item in items where item.identifier == .quickTimeMetadataLocationISO6709 || item.identifier == .commonIdentifierLocation {
                if let s = try? await item.load(.stringValue), let (lat, lon) = parseISO6709(s) {
                    m.lat = lat; m.lon = lon; break
                }
            }
            for item in items where item.identifier == .quickTimeMetadataModel || item.identifier == .commonIdentifierModel {
                m.camera = try? await item.load(.stringValue)
            }
        }
        return m
    }

    /// "+48.8566+002.3522+035.000/" → (48.8566, 2.3522)
    static func parseISO6709(_ s: String) -> (Double, Double)? {
        let scanner = Foundation.Scanner(string: s)
        guard let lat = scanner.scanDouble(), let lon = scanner.scanDouble() else { return nil }
        return (lat, lon)
    }
}

extension Library {
    /// Pending work for a stage, with absolute paths.
    func pending(stateColumn: String, limit: Int, metadataRead: Bool = false) throws -> [(id: Int64, url: URL, kind: MediaKind)] {
        try db.all("""
            SELECT m.id, f.path || '/' || m.name, m.kind FROM media m JOIN folders f ON f.id = m.folder_id
            WHERE m.\(stateColumn) = 0 AND m.ignored = 0\(metadataRead ? " AND m.meta_state != 0" : "") LIMIT ?
            """, [limit]) { ($0.int(0), URL(fileURLWithPath: $0.text(1)), MediaKind(rawValue: Int($0.int(2))) ?? .image) }
    }

    func store(metadata: [(Int64, MediaMetadata?)]) throws {
        try db.transaction {
            for (id, m) in metadata {
                guard let m else { try db.run("UPDATE media SET meta_state = 3 WHERE id = ?", id); continue }
                try db.run("""
                    UPDATE media SET width=?, height=?, orientation=?, taken_at=coalesce(?, taken_at), lat=coalesce(?, lat),
                    lon=coalesce(?, lon), camera=?, duration=?, quick_hash=?, exif=?, meta_state=1,
                    date_source = CASE WHEN ? IS NOT NULL THEN 0 ELSE date_source END WHERE id=?
                    """, m.width, m.height, m.orientation, m.takenAt?.timeIntervalSince1970, m.lat, m.lon,
                           m.camera, m.duration, m.quickHash, m.exif, m.takenAt?.timeIntervalSince1970, id)
            }
        }
    }

    func markThumbs(_ results: [(Int64, ThumbnailStore.Outcome)]) throws {
        try db.transaction {
            let now = Date().timeIntervalSince1970
            for (id, r) in results {
                // indexed_at: when the item became visible (Library ▸ Last indexed).
                try db.run("UPDATE media SET thumb_state = ?, indexed_at = CASE WHEN ? = 1 THEN ? ELSE indexed_at END WHERE id = ?",
                           r.rawValue, r.rawValue, now, id)
            }
        }
    }

    /// Marks every thumbnail for regeneration (files are overwritten in place as they are redone).
    public func resetThumbnails() throws -> Int {
        try db.run("UPDATE media SET thumb_state = 0 WHERE thumb_state != 0")
        return db.changes
    }

    /// Redo face detection everywhere: drops unnamed Vision faces and all prints, keeps named faces
    /// and Picasa/manual rectangles (their prints are recomputed).
    /// Faces a human named, ignored, confirmed or rejected (faces.human) are kept with their decision
    /// unless `includeManual`, which drops every Vision face and every decision on the others.
    public func resetFaces(includeManual: Bool = false) throws -> Int {
        try db.transaction {
            if includeManual {
                try db.run("DELETE FROM faces WHERE source = ?", FaceSource.vision.rawValue)
                try db.run("UPDATE faces SET ignored = 0, rejected_person_id = NULL, human = 0 WHERE source != ?", FaceSource.picasa.rawValue)
            } else {
                try db.run("DELETE FROM faces WHERE source = ? AND human = 0", FaceSource.vision.rawValue)
            }
            try db.run("UPDATE faces SET print = NULL, suggested_person_id = NULL")
            try db.run("UPDATE media SET face_state = 0 WHERE kind != 1")
            return db.changes
        }
    }

    /// Items skipped because they were unreadable get another chance on each run.
    func retryUnreadable(_ column: String) throws {
        try db.run("UPDATE media SET \(column) = 0 WHERE \(column) = 3")
    }

    /// Flags small images as ignored (no thumbnail, no analysis, hidden from views, kept in the index):
    /// longest side < `minSize`, or < `thumbSize` without camera metadata (typical of thumbnails
    /// written by other apps; small old camera/phone photos have EXIF and are kept). 0 disables a rule.
    /// Re-evaluated on every run, so changing the thresholds takes effect without rescanning.
    public func classifySmall(minSize: Int, thumbSize: Int, ids: [Int64]? = nil) throws -> Int {
        try db.run("""
            UPDATE media SET ignored = CASE
              WHEN kind = 0 AND width IS NOT NULL AND height IS NOT NULL
               AND (max(width, height) < ? OR (max(width, height) < ? AND exif = 0)) THEN 1 ELSE 0 END
            WHERE meta_state IN (1, 2)\(Self.idList(ids))
            """, minSize, thumbSize)
        return Int(try db.scalar("SELECT count(*) FROM media WHERE ignored = 1") ?? 0)
    }

    /// Files without a date in their metadata get one estimated from their name, their folders, or
    /// else the file date (DateGuess), recorded in date_source so the UI can say it is an estimate.
    func fillMissingDates(ids: [Int64]? = nil) throws {
        var rows: [(Int64, String, String, Double)] = []
        try db.query("""
            SELECT m.id, m.name, f.path, m.mtime FROM media m JOIN folders f ON f.id = m.folder_id
            WHERE m.meta_state IN (1, 2) AND (m.taken_at IS NULL OR m.date_source = -1
                   OR (m.date_source IS NULL AND m.taken_at = m.mtime)) -- older builds: file date, unmarked\(Self.idList(ids).replacingOccurrences(of: " id IN", with: " m.id IN"))
            """) { rows.append(($0.int(0), $0.text(1), $0.text(2), $0.double(3))) }
        guard !rows.isEmpty else { return }
        try db.transaction {
            for (id, name, folder, mtime) in rows {
                let g = DateGuess.guess(name: name, folderPath: folder, fileDate: mtime > 0 ? Date(timeIntervalSince1970: mtime) : nil)
                try db.run("UPDATE media SET taken_at = ?, date_source = ? WHERE id = ?", g?.0.timeIntervalSince1970, g?.1.rawValue, id)
            }
        }
    }

    static func idList(_ ids: [Int64]?) -> String {
        guard let ids else { return "" }
        return " AND id IN (\(ids.isEmpty ? "NULL" : ids.map(String.init).joined(separator: ",")))"
    }
}

/// A disk or network share went away during a run. Nothing of the batch was marked unreadable:
/// the run stops, and starting it again once the disk is back carries on where it was.
public struct VolumeUnavailable: Error, CustomStringConvertible {
    public let folder: String
    public var description: String {
        "\(folder) is no longer reachable (disk unmounted or network share disconnected). Stopped without marking anything; run again once it is back."
    }

    /// Items that failed because their folder vanished (the disk, not the file, is the problem).
    static func check(_ failed: [URL]) throws {
        if let u = failed.first(where: { !FileManager.default.fileExists(atPath: $0.deletingLastPathComponent().path) }) {
            throw VolumeUnavailable(folder: u.deletingLastPathComponent().path)
        }
    }
}

/// Runs the metadata and thumbnail stages over everything pending, in bounded parallel batches.
public struct Indexer: Sendable {
    public let library: Library
    public var concurrency: Int
    /// Defaults from Tools/bench-index.swift --real on a NAS: 4 parallel reads reach the share's
    /// throughput (~5–6 photos/s, CPU ~15 %); batches of 8 keep it while committing every 1–2 s,
    /// so new photos show up continuously.
    public static let defaultConcurrency = 4
    public var batch = 8
    /// See `Library.classifySmall`.
    public var minSize = 200
    public var thumbSize = 512

    public init(library: Library, concurrency: Int = Indexer.defaultConcurrency) {
        self.library = library
        self.concurrency = max(1, concurrency)
    }

    public func extractMetadata(progress: ProgressHandler? = nil) async throws -> Int {
        try await library.retryUnreadable("meta_state")
        var done = 0
        while true {
            let work = try await library.pending(stateColumn: "meta_state", limit: batch)
            if work.isEmpty { break }
            let results = await parallelMap(work, concurrency: concurrency) { item in
                (item.id, await MetadataReader.read(url: item.url, kind: item.kind))
            }
            try VolumeUnavailable.check(zip(work, results).filter { $0.1.1 == nil }.map(\.0.url))
            try await library.store(metadata: results)
            done += results.count
            progress?(LibraryProgress(stage: "metadata", done: done, total: nil, current: work.last?.url.path))
        }
        try await library.fillMissingDates()
        _ = try await library.classifySmall(minSize: minSize, thumbSize: thumbSize)
        return done
    }

    /// Metadata and thumbnails batch by batch, so photos become visible (both are needed) all along
    /// the run instead of only once every file's metadata has been read.
    public func run(progress: ProgressHandler? = nil) async throws -> (metadata: Int, thumbnails: Int) {
        try await library.fillMissingDates() // dates left to (re-)estimate by an earlier version
        try await library.retryUnreadable("meta_state")
        try await library.retryUnreadable("thumb_state")
        var (m, t) = (0, 0)
        let store = library.thumbs
        while true {
            let metaWork = try await library.pending(stateColumn: "meta_state", limit: batch)
            if !metaWork.isEmpty {
                let results = await parallelMap(metaWork, concurrency: concurrency) { item in
                    (item.id, await MetadataReader.read(url: item.url, kind: item.kind))
                }
                try VolumeUnavailable.check(zip(metaWork, results).filter { $0.1.1 == nil }.map(\.0.url))
                try await library.store(metadata: results)
                let ids = metaWork.map(\.id)
                try await library.fillMissingDates(ids: ids)
                _ = try await library.classifySmall(minSize: minSize, thumbSize: thumbSize, ids: ids)
                m += results.count
                progress?(LibraryProgress(stage: "metadata", done: m, total: nil, current: metaWork.last?.url.path))
            }
            let thumbWork = try await library.pending(stateColumn: "thumb_state", limit: batch, metadataRead: true)
            if !thumbWork.isEmpty {
                let results = await parallelMap(thumbWork, concurrency: concurrency) { item in
                    (item.id, await store.generate(id: item.id, url: item.url, kind: item.kind))
                }
                try VolumeUnavailable.check(zip(thumbWork, results).filter { $0.1.1 != .done }.map(\.0.url))
                try await library.markThumbs(results)
                t += results.count
                progress?(LibraryProgress(stage: "thumbnails", done: t, total: nil, current: thumbWork.last?.url.path))
            }
            if metaWork.isEmpty && thumbWork.isEmpty { break }
        }
        try await library.fillMissingDates()
        _ = try await library.classifySmall(minSize: minSize, thumbSize: thumbSize)
        return (m, t)
    }

    public func generateThumbnails(progress: ProgressHandler? = nil) async throws -> Int {
        try await library.retryUnreadable("thumb_state")
        var done = 0
        let store = library.thumbs
        while true {
            let work = try await library.pending(stateColumn: "thumb_state", limit: batch)
            if work.isEmpty { break }
            let results = await parallelMap(work, concurrency: concurrency) { item in
                (item.id, await store.generate(id: item.id, url: item.url, kind: item.kind))
            }
            try VolumeUnavailable.check(zip(work, results).filter { $0.1.1 != .done }.map(\.0.url))
            try await library.markThumbs(results)
            done += results.count
            progress?(LibraryProgress(stage: "thumbnails", done: done, total: nil, current: work.last?.url.path))
        }
        return done
    }
}

/// Order-preserving concurrent map with a fixed number of workers.
public func parallelMap<T: Sendable, R: Sendable>(_ items: [T], concurrency: Int, _ f: @escaping @Sendable (T) async -> R) async -> [R] {
    await withTaskGroup(of: (Int, R).self) { group in
        var out = [R?](repeating: nil, count: items.count)
        var next = 0
        for _ in 0..<min(concurrency, items.count) {
            let i = next; next += 1
            group.addTask { (i, await f(items[i])) }
        }
        while let (i, r) = await group.next() {
            out[i] = r
            if next < items.count {
                let j = next; next += 1
                group.addTask { (j, await f(items[j])) }
            }
        }
        return out.map { $0! }
    }
}
