import Accelerate
import CoreGraphics
import Foundation
import ImageIO
import Vision

/// Face recognition helpers and name suggestion.
/// Picasa's Neven engine is replaced by Apple Vision: faces are detected by `Analyzer` on a downscaled
/// copy, each face crop gets a Vision feature print, and unnamed faces are matched to the people
/// already named (in Picasa or here) by cosine similarity to per-person centroids.
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
        // centroidsᵀ [dim × persons] for vDSP_mmul.
        var centroidsT = [Float](repeating: 0, count: centroids.count)
        vDSP_mtrans(centroids, 1, &centroidsT, 1, vDSP_Length(dim), vDSP_Length(persons.count))
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
            vDSP_mmul(flat, 1, centroidsT, 1, &scores, 1,
                      vDSP_Length(batch.count), vDSP_Length(persons.count), vDSP_Length(dim))
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

/// A group of similar unnamed faces, to be named in one go (Picasa's "unnamed people").
public struct FaceCluster: Sendable, Identifiable, Hashable {
    public var id: Int64 { coverFaceId }
    public let coverFaceId: Int64
    public let faceIds: [Int64]
}

extension Library {
    /// Groups unnamed faces without a pending suggestion by feature-print similarity
    /// (leader clustering: a face joins the first cluster whose leader is within `threshold`).
    /// Largest faces first, at most `maxFaces` of them, so it stays interactive on huge libraries.
    public func unnamedClusters(threshold: Float = 0.8, maxFaces: Int = 5_000) throws -> [FaceCluster] {
        var faces: [(id: Int64, print: [Float])] = []
        try db.query("""
            SELECT id, print FROM faces WHERE person_id IS NULL AND suggested_person_id IS NULL AND print IS NOT NULL
              AND media_id NOT IN (SELECT id FROM media WHERE ignored = 1)
            ORDER BY w * h DESC LIMIT ?
            """, [maxFaces]) { r in
            if let d = r.blob(1) { faces.append((r.int(0), d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) })) }
        }
        guard let dim = faces.first?.print.count, dim > 0 else { return [] }
        var leaders: [[Float]] = []
        var members: [[Int64]] = []
        for f in faces where f.print.count == dim {
            var best = -1, bestScore: Float = threshold
            for (i, l) in leaders.enumerated() {
                var s: Float = 0
                vDSP_dotpr(f.print, 1, l, 1, &s, vDSP_Length(dim))
                if s >= bestScore { best = i; bestScore = s }
            }
            if best >= 0 { members[best].append(f.id) } else { leaders.append(f.print); members.append([f.id]) }
        }
        return members.map { FaceCluster(coverFaceId: $0[0], faceIds: $0) }
            .sorted { $0.faceIds.count > $1.faceIds.count }
    }

    /// Names several faces at once (user action → `manual`). Returns the person id.
    @discardableResult
    public func nameFaces(_ faceIds: [Int64], name: String) throws -> Int64? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !faceIds.isEmpty else { return nil }
        return try db.transaction {
            var pid = try db.scalar("SELECT id FROM persons WHERE name = ? COLLATE NOCASE", [trimmed])
            if pid == nil { pid = try db.run("INSERT INTO persons(name) VALUES(?)", trimmed) }
            for f in faceIds {
                try db.run("UPDATE faces SET person_id = ?, suggested_person_id = NULL, source = ? WHERE id = ?", pid!, FaceSource.manual.rawValue, f)
            }
            return pid
        }
    }

    func mediaPath(_ id: Int64) throws -> String {
        try db.all("SELECT f.path || '/' || m.name FROM media m JOIN folders f ON f.id = m.folder_id WHERE m.id = ?", [id]) { $0.text(0) }.first ?? ""
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
