import Accelerate
import CoreGraphics
import Foundation
import ImageIO
import Vision

/// Face detection and name suggestion.
/// Picasa's Neven engine is replaced by Apple Vision: faces are detected on a downscaled copy,
/// each face crop gets a Vision feature print, and unnamed faces are matched to the people
/// already named in Picasa (imported from .picasa.ini) by cosine similarity to per-person centroids.
public struct FaceEngine: Sendable {
    public let library: Library
    public var concurrency: Int
    public var analysisPixels = 1600
    /// Cosine similarity above which a suggestion is recorded.
    public var suggestThreshold: Float = 0.82

    public init(library: Library, concurrency: Int = 4) {
        self.library = library
        self.concurrency = max(1, concurrency)
    }

    struct Detected: Sendable { var rect: NormalizedRect4; var confidence: Float; var print: [Float]? }
    /// x, y, w, h normalized, origin top-left.
    struct NormalizedRect4: Sendable { var x, y, w, h: Double }

    public func detectPending(progress: ProgressHandler? = nil) async throws -> Int {
        try await library.retryUnreadableFaces()
        var done = 0
        while true {
            let work = try await library.pendingFaces(limit: 64)
            if work.isEmpty { break }
            let px = analysisPixels
            let results = await parallelMap(work, concurrency: concurrency) { item in
                (item, Self.analyse(url: item.url, known: item.known, maxPixel: px))
            }
            try await library.storeFaces(results.map { ($0.0.id, $0.0.known.map(\.id), $0.1) })
            done += results.count
            progress?(LibraryProgress(stage: "faces", done: done, total: nil, current: work.last?.url.path))
        }
        return done
    }

    /// Returns (prints for already-known faces, new detections not overlapping known ones). Nil if unreadable.
    static func analyse(url: URL, known: [(id: Int64, rect: NormalizedRect4)], maxPixel: Int) -> (knownPrints: [[Float]?], detected: [Detected])? {
        guard let image = ThumbnailStore.imageThumbnail(url, maxPixel: maxPixel) else { return nil }
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let req = VNDetectFaceRectanglesRequest()
        guard (try? handler.perform([req])) != nil else { return nil }
        // Vision: origin bottom-left → convert to top-left.
        let found = (req.results ?? []).map { o in
            Detected(rect: .init(x: o.boundingBox.minX, y: 1 - o.boundingBox.maxY, w: o.boundingBox.width, h: o.boundingBox.height),
                     confidence: o.confidence, print: nil)
        }.filter { $0.rect.w * Double(image.width) >= 24 }
        let knownPrints = known.map { featurePrint(image: image, rect: $0.rect) }
        let fresh = found.filter { d in !known.contains { iou($0.rect, d.rect) > 0.3 } }
            .map { var d = $0; d.print = featurePrint(image: image, rect: d.rect); return d }
        return (knownPrints, fresh)
    }

    static func iou(_ a: NormalizedRect4, _ b: NormalizedRect4) -> Double {
        let x1 = max(a.x, b.x), y1 = max(a.y, b.y), x2 = min(a.x + a.w, b.x + b.w), y2 = min(a.y + a.h, b.y + b.h)
        let inter = max(0, x2 - x1) * max(0, y2 - y1)
        let union = a.w * a.h + b.w * b.h - inter
        return union > 0 ? inter / union : 0
    }

    /// Feature print of a face crop enlarged by 30% (more context makes prints more stable).
    static func featurePrint(image: CGImage, rect r: NormalizedRect4) -> [Float]? {
        let W = Double(image.width), H = Double(image.height)
        let m = 0.3
        let crop = CGRect(x: (r.x - r.w * m / 2) * W, y: (r.y - r.h * m / 2) * H, width: r.w * (1 + m) * W, height: r.h * (1 + m) * H)
            .intersection(CGRect(x: 0, y: 0, width: W, height: H)).integral
        guard crop.width >= 16, crop.height >= 16, let face = image.cropping(to: crop) else { return nil }
        let req = VNGenerateImageFeaturePrintRequest()
        req.imageCropAndScaleOption = .scaleFill
        guard (try? VNImageRequestHandler(cgImage: face, options: [:]).perform([req])) != nil,
              let obs = req.results?.first, obs.elementType == .float else { return nil }
        var v = obs.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        var norm: Float = 0
        vDSP_svesq(v, 1, &norm, vDSP_Length(v.count))
        norm = sqrt(norm)
        if norm > 0 { vDSP_vsdiv(v, 1, &norm, &v, 1, vDSP_Length(v.count)) }
        return v
    }

    /// For every unnamed face with a print, sets suggested_person_id to the most similar person
    /// (cosine similarity to the person's centroid) when above the threshold and not rejected
    /// by the user for that face. Returns suggestions made.
    public func suggestNames() async throws -> Int {
        let (persons, centroids, dim) = try await library.personCentroids()
        guard !persons.isEmpty, dim > 0 else { return 0 }
        let threshold = suggestThreshold
        var made = 0
        var after: Int64 = 0
        while true {
            let batch = try await library.unnamedPrints(after: after, limit: 4096, dim: dim)
            guard let lastId = try await library.lastUnnamedPrintId(after: after, limit: 4096) else { break }
            after = lastId
            if batch.isEmpty { continue }
            // scores[b × p] = prints[b × d] · centroidsᵀ[d × p]
            let flat = batch.flatMap(\.print)
            var scores = [Float](repeating: 0, count: batch.count * persons.count)
            cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans, Int32(batch.count), Int32(persons.count), Int32(dim),
                        1, flat, Int32(dim), centroids, Int32(dim), 0, &scores, Int32(persons.count))
            var updates: [(Int64, Int64?)] = []
            for (i, f) in batch.enumerated() {
                var best: Float = 0; var idx: vDSP_Length = 0
                scores.withUnsafeBufferPointer { vDSP_maxvi($0.baseAddress! + i * persons.count, 1, &best, &idx, vDSP_Length(persons.count)) }
                let pick = persons[Int(idx)]
                updates.append((f.id, best >= threshold && pick != f.rejected ? pick : nil))
            }
            made += updates.filter { $0.1 != nil }.count
            try await library.storeSuggestions(updates)
        }
        return made
    }
}

extension Library {
    func pendingFaces(limit: Int) throws -> [(id: Int64, url: URL, known: [(id: Int64, rect: FaceEngine.NormalizedRect4)])] {
        let items = try db.all("""
            SELECT m.id, f.path || '/' || m.name FROM media m JOIN folders f ON f.id = m.folder_id
            WHERE m.face_state = 0 LIMIT ?
            """, [limit]) { ($0.int(0), URL(fileURLWithPath: $0.text(1))) }
        return try items.map { item in
            let known = try db.all("SELECT id, x, y, w, h FROM faces WHERE media_id = ? AND print IS NULL", [item.0]) {
                ($0.int(0), FaceEngine.NormalizedRect4(x: $0.double(1), y: $0.double(2), w: $0.double(3), h: $0.double(4)))
            }
            return (item.0, item.1, known.map { (id: $0.0, rect: $0.1) })
        }
    }

    func storeFaces(_ results: [(mediaId: Int64, knownIds: [Int64], result: (knownPrints: [[Float]?], detected: [FaceEngine.Detected])?)]) throws {
        func blob(_ v: [Float]?) -> Data? { v.map { $0.withUnsafeBufferPointer { Data(buffer: $0) } } }
        try db.transaction {
            for r in results {
                guard let res = r.result else {
                    let readable = FileManager.default.isReadableFile(atPath: try mediaPath(r.mediaId))
                    try db.run("UPDATE media SET face_state = ? WHERE id = ?", readable ? 2 : 3, r.mediaId); continue
                }
                for (fid, p) in zip(r.knownIds, res.knownPrints) where p != nil {
                    try db.run("UPDATE faces SET print = ? WHERE id = ?", blob(p), fid)
                }
                for d in res.detected {
                    try db.run("INSERT INTO faces(media_id, x, y, w, h, source, confidence, print) VALUES(?, ?, ?, ?, ?, ?, ?, ?)",
                               r.mediaId, d.rect.x, d.rect.y, d.rect.w, d.rect.h, FaceSource.vision.rawValue, Double(d.confidence), blob(d.print))
                }
                try db.run("UPDATE media SET face_state = 1 WHERE id = ?", r.mediaId)
            }
        }
    }

    func mediaPath(_ id: Int64) throws -> String {
        try db.all("SELECT f.path || '/' || m.name FROM media m JOIN folders f ON f.id = m.folder_id WHERE m.id = ?", [id]) { $0.text(0) }.first ?? ""
    }

    func retryUnreadableFaces() throws {
        try db.run("UPDATE media SET face_state = 0 WHERE face_state = 3 AND kind != 1")
    }

    /// Normalized mean print per named person.
    func personCentroids() throws -> (persons: [Int64], centroids: [Float], dim: Int) {
        var sums: [Int64: [Float]] = [:]
        var dim = 0
        try db.query("SELECT person_id, print FROM faces WHERE person_id IS NOT NULL AND print IS NOT NULL") { r in
            guard let d = r.blob(1) else { return }
            let v = d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            if dim == 0 { dim = v.count }
            guard v.count == dim else { return }
            let pid = r.int(0)
            if var s = sums[pid] { vDSP_vadd(s, 1, v, 1, &s, 1, vDSP_Length(dim)); sums[pid] = s } else { sums[pid] = v }
        }
        var persons: [Int64] = [], flat: [Float] = []
        for (pid, var s) in sums {
            var n: Float = 0
            vDSP_svesq(s, 1, &n, vDSP_Length(dim)); n = sqrt(n)
            if n > 0 { vDSP_vsdiv(s, 1, &n, &s, 1, vDSP_Length(dim)) }
            persons.append(pid); flat.append(contentsOf: s)
        }
        return (persons, flat, dim)
    }

    func unnamedPrints(after: Int64, limit: Int, dim: Int) throws -> [(id: Int64, print: [Float], rejected: Int64?)] {
        try db.all("SELECT id, print, rejected_person_id FROM faces WHERE person_id IS NULL AND print IS NOT NULL AND id > ? ORDER BY id LIMIT ?", [after, limit]) { r in
            (r.int(0), r.blob(1).map { $0.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) } } ?? [], r.optInt(2))
        }.filter { $0.print.count == dim }
    }

    /// Paging cursor independent of the dim filter (so a batch of wrong-sized prints cannot end the loop early).
    func lastUnnamedPrintId(after: Int64, limit: Int) throws -> Int64? {
        try db.scalar("SELECT max(id) FROM (SELECT id FROM faces WHERE person_id IS NULL AND print IS NOT NULL AND id > ? ORDER BY id LIMIT ?)", [after, limit])
    }

    func storeSuggestions(_ s: [(Int64, Int64?)]) throws {
        try db.transaction {
            for (fid, pid) in s { try db.run("UPDATE faces SET suggested_person_id = ? WHERE id = ?", pid, fid) }
        }
    }
}
