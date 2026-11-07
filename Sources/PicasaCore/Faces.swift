import Accelerate
import CoreGraphics
import Foundation
import ImageIO
import Vision

/// Face recognition helpers and name suggestion.
/// Picasa's Neven engine is replaced by Apple Vision: faces are detected by `Analyzer` on a downscaled
/// copy, each face crop gets a Vision feature print, and unnamed faces are matched to the people
/// already named (in Picasa or here) by cosine similarity to their nearest named face.
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
    /// (cosine similarity to their nearest named face) when above the threshold and not rejected
    /// by the user for that face. Returns suggestions made.
    public func suggestNames() async throws -> Int {
        try await IdentityEngine.suggest(library: library, kind: .face, threshold: suggestThreshold)
    }
}

/// Name suggestions shared by faces and pets: each unnamed item goes to the person / pet owning the
/// most similar named item (nearest example) when above the threshold and not rejected for it.
public enum IdentityEngine {
    /// How much closer to a known counter-example than to the person's nearest face a face must be
    /// for that person to be ruled out.
    static let counterMargin: Float = 0
    /// Unnamed items scored per matrix product: keeps the score matrix to a few tens of MB.
    static let chunkSize = 512

    /// Suggests a name for every unnamed face (animal): the person owning the most similar named
    /// face, above `threshold`. Nearest example rather than each person's average face: the prints
    /// are generic image prints, so a person's looks are spread out and an average matches only the
    /// faces near its middle (one named face found ~4% of that person's others, vs ~70% this way).
    /// Faces a human said were *not* someone (rejected, or taken away from them) are counter-examples:
    /// a face that looks more like one of them than like the person's nearest face is not suggested
    /// for that person — so correcting a few wrong suggestions also clears their look-alikes — and
    /// the next best person is tried instead.
    public static func suggest(library: Library, kind: IdentityKind, threshold: Float) async throws -> Int {
        let (persons, examples, starts, dim) = try await library.namedExamples(kind)
        guard !persons.isEmpty, dim > 0 else { return 0 }
        let np = persons.count, ne = starts[np]
        let column = Dictionary(uniqueKeysWithValues: persons.enumerated().map { ($1, $0) })
        // examplesᵀ [dim × examples] for vDSP_mmul.
        var examplesT = [Float](repeating: 0, count: examples.count)
        vDSP_mtrans(examples, 1, &examplesT, 1, vDSP_Length(dim), vDSP_Length(ne))
        // Counter-examples: prints of faces rejected for a person, with that person.
        let negatives = try await library.counterExamples(kind, dim: dim).filter { column[$0.owner] != nil }
        var negT = [Float](repeating: 0, count: negatives.count * dim)
        if !negatives.isEmpty {
            vDSP_mtrans(negatives.flatMap(\.print), 1, &negT, 1, vDSP_Length(dim), vDSP_Length(negatives.count))
        }
        let negColumn = negatives.map { column[$0.owner]! }
        let nn = negatives.count
        var made = 0
        var after: Int64 = 0
        var scores = [Float](repeating: 0, count: chunkSize * ne)
        var neg = [Float](repeating: 0, count: chunkSize * nn)
        var row = [Float](repeating: 0, count: np), worst = [Float](repeating: -1, count: np)
        while true {
            let batch = try await library.unnamedPrints(kind, after: after, limit: 4096, dim: dim)
            guard let lastId = try await library.lastUnnamedPrintId(kind, after: after, limit: 4096) else { break }
            after = lastId
            var updates: [(Int64, Int64?)] = []
            for c in stride(from: 0, to: batch.count, by: chunkSize) {
                let chunk = batch[c ..< min(c + chunkSize, batch.count)]
                let nb = chunk.count
                let flat = chunk.flatMap(\.print)
                // scores[b × e] = prints[b × d] · examplesᵀ[d × e]
                vDSP_mmul(flat, 1, examplesT, 1, &scores, 1, vDSP_Length(nb), vDSP_Length(ne), vDSP_Length(dim))
                // neg[b × n]: similarity to each counter-example.
                if nn > 0 {
                    vDSP_mmul(flat, 1, negT, 1, &neg, 1, vDSP_Length(nb), vDSP_Length(nn), vDSP_Length(dim))
                }
                for (i, f) in chunk.enumerated() {
                    // Similarity to each person: that of their nearest named example.
                    scores.withUnsafeBufferPointer { s in
                        for p in 0..<np {
                            var m: Float = -1
                            vDSP_maxv(s.baseAddress! + i * ne + starts[p], 1, &m, vDSP_Length(starts[p + 1] - starts[p]))
                            row[p] = m
                        }
                    }
                    // Closest counter-example per person for this face.
                    for p in 0..<np { worst[p] = -1 }
                    for k in 0..<nn where neg[i * nn + k] > worst[negColumn[k]] { worst[negColumn[k]] = neg[i * nn + k] }
                    // Best person not ruled out (rejected for this very face, or closer to a counter-example).
                    var pick: Int64?
                    for p in row.indices.sorted(by: { row[$0] > row[$1] }).prefix(3) {
                        guard row[p] >= threshold else { break }
                        if persons[p] == f.rejected { continue }
                        if worst[p] > -1, worst[p] >= row[p] + counterMargin { continue }
                        pick = persons[p]; break
                    }
                    updates.append((f.id, pick))
                }
            }
            made += updates.filter { $0.1 != nil }.count
            if !updates.isEmpty { try await library.storeSuggestions(kind, updates) }
        }
        return made
    }
}

/// A group of similar unnamed faces, to be named in one go (Picasa's "unnamed people").
public struct FaceCluster: Sendable, Identifiable, Hashable {
    public var id: Int64 { coverFaceId }
    public let coverFaceId: Int64
    public let faceIds: [Int64]
    public init(coverFaceId: Int64, faceIds: [Int64]) { self.coverFaceId = coverFaceId; self.faceIds = faceIds }
}

extension Library {
    /// Unnamed faces grouped by similarity (see `identityClusters`).
    public func unnamedClusters(threshold: Float = 0.8, maxFaces: Int = 5_000) throws -> [FaceCluster] {
        try identityClusters(.face, threshold: threshold, maxItems: maxFaces)
    }

    /// Names several faces at once (user action → `manual`). Returns the person id.
    @discardableResult
    public func nameFaces(_ faceIds: [Int64], name: String) throws -> Int64? { try nameItems(.face, faceIds, name: name) }

    /// Changes when faces are added, removed, named, suggested or ignored (to skip re-clustering otherwise).
    public func facesToken() throws -> [Int64] { try identityToken(.face) }

    /// Merges `source` into `target` (Picasa: drop a person onto another).
    public func mergePerson(_ source: Int64, into target: Int64) throws { try merge(.face, source, into: target) }

    /// Assigns faces to an existing person (drop an unnamed group onto a person), as a user action.
    public func assignFaces(_ faceIds: [Int64], to personId: Int64) throws { try assign(.face, faceIds, to: personId) }

    func mediaPath(_ id: Int64) throws -> String {
        try db.all("SELECT f.path || '/' || m.name FROM media m JOIN folders f ON f.id = m.folder_id WHERE m.id = ?", [id]) { $0.text(0) }.first ?? ""
    }
}
