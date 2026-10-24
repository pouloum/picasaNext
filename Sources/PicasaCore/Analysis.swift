import Accelerate
import CoreGraphics
import Foundation
import Vision

/// One Vision pass per image, on a single decoded 1600 px copy:
/// faces (+ a print per face), scene labels, animals, a whole-image feature print (for similar
/// photos) and, on macOS 15+, an aesthetics score with the "utility" flag (screenshots, receipts…).
/// Faces and the rest have separate states, so a library analysed for faces only gets just the new parts.
public struct Analyzer: Sendable {
    public let library: Library
    public var concurrency: Int
    public var analysisPixels = 1600
    /// Photos per batch: results are saved after each batch (small = steady progress, a slow file
    /// holds back few others; same reasoning as Indexer.batch).
    public var batch = 8
    /// Labels kept: those Vision can report at 90 % precision (Apple's recommended filter).
    public var labelPrecision: Float = 0.9

    public init(library: Library, concurrency: Int = 4) {
        self.library = library
        self.concurrency = max(1, concurrency)
    }

    struct Work: Sendable {
        let id: Int64, url: URL, faces: Bool, scene: Bool
        let known: [(id: Int64, rect: FaceEngine.NormalizedRect4)]
    }

    struct Animal: Sendable { var species: String; var confidence: Float; var rect: FaceEngine.NormalizedRect4; var print: [Float]? }

    struct Result: Sendable {
        var knownPrints: [[Float]?] = []
        var faces: [FaceEngine.Detected] = []
        var labels: [(String, Float)] = []
        var animals: [Animal] = []
        var print: [Float]?
        var aesthetic: Float?
        var utility = false
    }

    public func run(progress: ProgressHandler? = nil) async throws -> Int {
        try await library.retryUnreadableAnalysis()
        var done = 0
        let (px, precision) = (analysisPixels, labelPrecision)
        while true {
            let work = try await library.pendingAnalysis(limit: batch)
            if work.isEmpty { break }
            let results = await parallelMap(work, concurrency: concurrency) { w in
                (w, await Self.analyse(w, maxPixel: px, labelPrecision: precision))
            }
            try VolumeUnavailable.check(results.filter { $0.1 == nil }.map(\.0.url))
            try await library.storeAnalysis(results)
            done += results.count
            progress?(LibraryProgress(stage: "analysis", done: done, total: nil, current: work.last?.url.path))
        }
        return done
    }

    static func analyse(_ w: Work, maxPixel: Int, labelPrecision: Float) async -> Result? {
        guard let image = ThumbnailStore.imageThumbnail(w.url, maxPixel: maxPixel) else { return nil }
        let faceReq = VNDetectFaceRectanglesRequest()
        let classifyReq = VNClassifyImageRequest()
        let printReq = VNGenerateImageFeaturePrintRequest()
        let animalReq = VNRecognizeAnimalsRequest()
        var reqs: [VNRequest] = []
        if w.faces { reqs.append(faceReq) }
        if w.scene { reqs += [classifyReq, printReq, animalReq] }
        guard (try? VNImageRequestHandler(cgImage: image, options: [:]).perform(reqs)) != nil else { return nil }

        var r = Result()
        if w.faces {
            // Vision: origin bottom-left → convert to top-left.
            let found = (faceReq.results ?? []).map { o in
                FaceEngine.Detected(rect: .init(x: o.boundingBox.minX, y: 1 - o.boundingBox.maxY, w: o.boundingBox.width, h: o.boundingBox.height),
                                    confidence: o.confidence, print: nil)
            }.filter { $0.rect.w * Double(image.width) >= 24 }
            r.knownPrints = w.known.map { FaceEngine.featurePrint(image: image, rect: $0.rect) }
            r.faces = found.filter { d in !w.known.contains { FaceEngine.iou($0.rect, d.rect) > 0.3 } }
                .map { var d = $0; d.print = FaceEngine.featurePrint(image: image, rect: d.rect); return d }
        }
        if w.scene {
            r.labels = (classifyReq.results ?? [])
                .filter { $0.hasMinimumRecall(0.01, forPrecision: labelPrecision) }
                .prefix(20).map { ($0.identifier, $0.confidence) }
            r.animals = (animalReq.results ?? []).compactMap { o in
                guard let l = o.labels.first else { return nil }
                let rect = FaceEngine.NormalizedRect4(x: o.boundingBox.minX, y: 1 - o.boundingBox.maxY, w: o.boundingBox.width, h: o.boundingBox.height)
                // A print of the animal crop, to tell individual pets apart (same method as faces).
                return Animal(species: l.identifier.lowercased(), confidence: l.confidence, rect: rect,
                              print: FaceEngine.featurePrint(image: image, rect: rect))
            }
            if let obs = printReq.results?.first, obs.elementType == .float {
                r.print = normalized(obs.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) })
            }
            if #available(macOS 15.0, *) {
                if let a = try? await CalculateImageAestheticsScoresRequest().perform(on: image) {
                    r.aesthetic = a.overallScore
                    r.utility = a.isUtility
                }
            }
        }
        return r
    }

    /// Prints for animals found before pets existed (no print yet): one decode per photo.
    public func petPrints(progress: ProgressHandler? = nil) async throws -> Int {
        var done = 0
        let px = analysisPixels
        var after: Int64 = 0
        while true {
            let work = try await library.animalsWithoutPrint(after: after, limit: 64)
            guard let last = work.last else { break }
            after = last.mediaId
            let results = await parallelMap(work, concurrency: concurrency) { w -> [(Int64, [Float]?)] in
                guard let image = ThumbnailStore.imageThumbnail(w.url, maxPixel: px) else {
                // Disk gone: leave these for the next run rather than marking them as "no print".
                if !FileManager.default.fileExists(atPath: w.url.deletingLastPathComponent().path) { return [] }
                return w.animals.map { ($0.id, nil) }
            }
                return w.animals.map { ($0.id, FaceEngine.featurePrint(image: image, rect: $0.rect)) }
            }
            try await library.storeAnimalPrints(results.flatMap { $0 })
            done += work.count
            progress?(LibraryProgress(stage: "pet prints", done: done, total: nil, current: last.url.path))
        }
        return done
    }

    /// Analyses some photos right away (the viewer, on a photo not analysed yet or skipped while its
    /// disk was away). Returns false when the file cannot be read now.
    public func analyze(mediaIds ids: [Int64]) async throws -> Bool {
        try await library.markForAnalysis(ids)
        let work = try await library.pendingAnalysis(limit: ids.count, ids: ids)
        guard !work.isEmpty else { return true }
        let (px, precision) = (analysisPixels, labelPrecision)
        let results = await parallelMap(work, concurrency: concurrency) { w in (w, await Self.analyse(w, maxPixel: px, labelPrecision: precision)) }
        try await library.storeAnalysis(results)
        return results.allSatisfy { $0.1 != nil }
    }

    static func normalized(_ v: [Float]) -> [Float] {
        var v = v, n: Float = 0
        vDSP_svesq(v, 1, &n, vDSP_Length(v.count)); n = sqrt(n)
        if n > 0 { vDSP_vsdiv(v, 1, &n, &v, 1, vDSP_Length(v.count)) }
        return v
    }
}

extension Library {
    func pendingAnalysis(limit: Int, ids: [Int64]? = nil) throws -> [Analyzer.Work] {
        let only = ids.map { " AND m.id IN (\($0.isEmpty ? "NULL" : $0.map(String.init).joined(separator: ",")))" } ?? ""
        let items = try db.all("""
            SELECT m.id, f.path || '/' || m.name, m.face_state, m.analysis_state FROM media m JOIN folders f ON f.id = m.folder_id
            WHERE (m.face_state = 0 OR m.analysis_state = 0) AND m.ignored = 0\(only) LIMIT ?
            """, [limit]) { ($0.int(0), URL(fileURLWithPath: $0.text(1)), $0.int(2) == 0, $0.int(3) == 0) }
        return try items.map { item in
            let known = item.2 ? try db.all("SELECT id, x, y, w, h FROM faces WHERE media_id = ? AND print IS NULL", [item.0]) {
                (id: $0.int(0), rect: FaceEngine.NormalizedRect4(x: $0.double(1), y: $0.double(2), w: $0.double(3), h: $0.double(4)))
            } : []
            return Analyzer.Work(id: item.0, url: item.1, faces: item.2, scene: item.3, known: known)
        }
    }

    func storeAnalysis(_ results: [(Analyzer.Work, Analyzer.Result?)]) throws {
        func blob(_ v: [Float]?) -> Data? { v.map { $0.withUnsafeBufferPointer { Data(buffer: $0) } } }
        try db.transaction {
            for (w, result) in results {
                guard let res = result else {
                    // 2 = undecodable, 3 = unreadable right now (retried next run).
                    let state = FileManager.default.isReadableFile(atPath: w.url.path) ? 2 : 3
                    if w.faces { try db.run("UPDATE media SET face_state = ? WHERE id = ?", state, w.id) }
                    if w.scene { try db.run("UPDATE media SET analysis_state = ? WHERE id = ?", state, w.id) }
                    continue
                }
                if w.faces {
                    for (fid, p) in zip(w.known.map(\.id), res.knownPrints) where p != nil {
                        try db.run("UPDATE faces SET print = ? WHERE id = ?", blob(p), fid)
                    }
                    for d in res.faces {
                        try db.run("INSERT INTO faces(media_id, x, y, w, h, source, confidence, print) VALUES(?, ?, ?, ?, ?, ?, ?, ?)",
                                   w.id, d.rect.x, d.rect.y, d.rect.w, d.rect.h, FaceSource.vision.rawValue, Double(d.confidence), blob(d.print))
                    }
                    try db.run("UPDATE media SET face_state = 1 WHERE id = ?", w.id)
                }
                if w.scene {
                    try db.run("DELETE FROM labels WHERE media_id = ?", w.id)
                    for (l, c) in res.labels {
                        try db.run("INSERT OR REPLACE INTO labels(media_id, label, confidence) VALUES(?, ?, ?)", w.id, l, Double(c))
                    }
                    // Named / ignored animals survive a re-analysis: matched by box, they only get a fresh print.
                    try db.run("DELETE FROM animals WHERE media_id = ? AND human = 0", w.id)
                    let kept = try db.all("SELECT id, x, y, w, h FROM animals WHERE media_id = ?", [w.id]) {
                        (id: $0.int(0), rect: FaceEngine.NormalizedRect4(x: $0.double(1), y: $0.double(2), w: $0.double(3), h: $0.double(4)))
                    }
                    for a in res.animals {
                        if let k = kept.first(where: { FaceEngine.iou($0.rect, a.rect) > 0.3 }) {
                            try db.run("UPDATE animals SET print = coalesce(?, print) WHERE id = ?", blob(a.print), k.id)
                            continue
                        }
                        try db.run("INSERT INTO animals(media_id, species, confidence, x, y, w, h, print) VALUES(?, ?, ?, ?, ?, ?, ?, ?)",
                                   w.id, a.species, Double(a.confidence), a.rect.x, a.rect.y, a.rect.w, a.rect.h, blob(a.print))
                    }
                    try db.run("UPDATE media SET print = ?, aesthetic = ?, utility = ?, analysis_state = 1 WHERE id = ?",
                               blob(res.print), res.aesthetic.map(Double.init), res.utility, w.id)
                }
            }
        }
    }

    /// Animals without a usable print (never computed, or computed while their disk was away).
    public func animalsMissingPrint() throws -> Int {
        Int(try db.scalar("SELECT count(*) FROM animals a JOIN media m ON m.id = a.media_id WHERE (a.print IS NULL OR length(a.print) = 0) AND m.ignored = 0") ?? 0)
    }

    struct AnimalWork: Sendable { let mediaId: Int64; let url: URL; let animals: [(id: Int64, rect: FaceEngine.NormalizedRect4)] }

    func animalsWithoutPrint(after: Int64, limit: Int) throws -> [AnimalWork] {
        var byMedia: [(Int64, URL)] = []
        try db.query("""
            SELECT DISTINCT m.id, f.path || '/' || m.name FROM animals a JOIN media m ON m.id = a.media_id JOIN folders f ON f.id = m.folder_id
            WHERE (a.print IS NULL OR length(a.print) = 0) AND m.ignored = 0 AND m.id > ? ORDER BY m.id LIMIT ?
            """, [after, limit]) { byMedia.append(($0.int(0), URL(fileURLWithPath: $0.text(1)))) }
        return try byMedia.map { m in
            AnimalWork(mediaId: m.0, url: m.1, animals: try db.all("SELECT id, x, y, w, h FROM animals WHERE media_id = ? AND (print IS NULL OR length(print) = 0)", [m.0]) {
                (id: $0.int(0), rect: FaceEngine.NormalizedRect4(x: $0.double(1), y: $0.double(2), w: $0.double(3), h: $0.double(4)))
            })
        }
    }

    func storeAnimalPrints(_ prints: [(Int64, [Float]?)]) throws {
        try db.transaction {
            for (id, p) in prints {
                // An empty blob marks "tried, no usable crop" so the pass does not retry it forever.
                try db.run("UPDATE animals SET print = ? WHERE id = ?", p.map { $0.withUnsafeBufferPointer { Data(buffer: $0) } } ?? Data(), id)
            }
        }
    }

    /// Puts photos skipped as unreadable back in the analysis queue (done ones are left alone).
    func markForAnalysis(_ ids: [Int64]) throws {
        for id in ids {
            try db.run("UPDATE media SET face_state = 0 WHERE id = ? AND face_state = 3 AND kind != 1", id)
            try db.run("UPDATE media SET analysis_state = 0 WHERE id = ? AND analysis_state = 3 AND kind != 1", id)
        }
    }

    /// Whether faces and the scene of a photo still have to be analysed.
    public func needsAnalysis(_ id: Int64) throws -> Bool {
        (try db.scalar("SELECT count(*) FROM media WHERE id = ? AND kind != 1 AND ignored = 0 AND (face_state IN (0, 3) OR analysis_state IN (0, 3))", [id]) ?? 0) > 0
    }

    func retryUnreadableAnalysis() throws {
        try db.run("UPDATE media SET face_state = 0 WHERE face_state = 3 AND kind != 1")
        try db.run("UPDATE media SET analysis_state = 0 WHERE analysis_state = 3 AND kind != 1")
    }

    /// Redo the whole-image analysis (labels, animals, print, aesthetics) everywhere. Animals a human
    /// named, ignored or corrected are kept unless `includeManual`.
    public func resetAnalysis(includeManual: Bool = false) throws -> Int {
        if includeManual { try db.run("DELETE FROM animals") }
        try db.run("UPDATE media SET analysis_state = 0 WHERE kind != 1")
        return db.changes
    }
}
