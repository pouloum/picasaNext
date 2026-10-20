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

    struct Animal: Sendable { var species: String; var confidence: Float; var rect: FaceEngine.NormalizedRect4 }

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
            let work = try await library.pendingAnalysis(limit: 64)
            if work.isEmpty { break }
            let results = await parallelMap(work, concurrency: concurrency) { w in
                (w, await Self.analyse(w, maxPixel: px, labelPrecision: precision))
            }
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
                return Animal(species: l.identifier.lowercased(), confidence: l.confidence,
                              rect: .init(x: o.boundingBox.minX, y: 1 - o.boundingBox.maxY, w: o.boundingBox.width, h: o.boundingBox.height))
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

    static func normalized(_ v: [Float]) -> [Float] {
        var v = v, n: Float = 0
        vDSP_svesq(v, 1, &n, vDSP_Length(v.count)); n = sqrt(n)
        if n > 0 { vDSP_vsdiv(v, 1, &n, &v, 1, vDSP_Length(v.count)) }
        return v
    }
}

extension Library {
    func pendingAnalysis(limit: Int) throws -> [Analyzer.Work] {
        let items = try db.all("""
            SELECT m.id, f.path || '/' || m.name, m.face_state, m.analysis_state FROM media m JOIN folders f ON f.id = m.folder_id
            WHERE (m.face_state = 0 OR m.analysis_state = 0) AND m.ignored = 0 LIMIT ?
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
                    try db.run("DELETE FROM animals WHERE media_id = ?", w.id)
                    for a in res.animals {
                        try db.run("INSERT INTO animals(media_id, species, confidence, x, y, w, h) VALUES(?, ?, ?, ?, ?, ?, ?)",
                                   w.id, a.species, Double(a.confidence), a.rect.x, a.rect.y, a.rect.w, a.rect.h)
                    }
                    try db.run("UPDATE media SET print = ?, aesthetic = ?, utility = ?, analysis_state = 1 WHERE id = ?",
                               blob(res.print), res.aesthetic.map(Double.init), res.utility, w.id)
                }
            }
        }
    }

    func retryUnreadableAnalysis() throws {
        try db.run("UPDATE media SET face_state = 0 WHERE face_state = 3 AND kind != 1")
        try db.run("UPDATE media SET analysis_state = 0 WHERE analysis_state = 3 AND kind != 1")
    }

    /// Redo the whole-image analysis (labels, animals, print, aesthetics) everywhere.
    public func resetAnalysis() throws -> Int {
        try db.run("UPDATE media SET analysis_state = 0 WHERE kind != 1")
        return db.changes
    }
}
