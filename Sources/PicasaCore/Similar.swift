import Accelerate
import Foundation

public struct SimilarityReport: Sendable, CustomStringConvertible {
    public var groups = 0, photos = 0, exactDuplicates = 0, bursts = 0, burstPhotos = 0
    public var threshold: Float = 0
    public var description: String {
        "\(groups) groups of similar photos (\(photos) photos, \(exactDuplicates) exact duplicates, threshold \(threshold)) · \(bursts) bursts (\(burstPhotos) photos)"
    }
}

extension Library {
    /// Rebuilds the `similar` table: exact duplicates (same quick hash + size, anywhere in the library)
    /// and near-duplicates (whole-image prints with cosine ≥ `threshold`, compared only with photos taken
    /// within `window` seconds — bursts, re-saves, edited copies). Streaming in date order keeps memory
    /// bounded to the window, so it scales to hundreds of thousands of photos.
    /// Rebuilds the `bursts` table: at least `minCount` photos from the same camera, in the same folder,
    /// each taken at most `maxGap` seconds after the previous one. Needs camera metadata (`exif`), so
    /// files dated by their modification time never form bursts.
    @discardableResult
    func detectBursts(maxGap: Double = 2, minCount: Int = 3) throws -> (bursts: Int, photos: Int) {
        var runs: [[Int64]] = []
        var cur: [Int64] = []
        var last: (folder: Int64, camera: String, t: Double)?
        try db.query("""
            SELECT id, folder_id, coalesce(camera, ''), taken_at FROM media
            WHERE exif = 1 AND ignored = 0 AND kind != 1 AND taken_at IS NOT NULL
            ORDER BY folder_id, coalesce(camera, ''), taken_at, name
            """) { r in
            let (id, folder, camera, t) = (r.int(0), r.int(1), r.text(2), r.double(3))
            if let l = last, l.folder == folder, l.camera == camera, t - l.t <= maxGap {
                cur.append(id)
            } else {
                if cur.count >= minCount { runs.append(cur) }
                cur = [id]
            }
            last = (folder, camera, t)
        }
        if cur.count >= minCount { runs.append(cur) }
        try db.transaction {
            try db.run("DELETE FROM bursts")
            for run in runs {
                for (i, id) in run.enumerated() {
                    try db.run("INSERT INTO bursts(media_id, burst_id, position) VALUES(?, ?, ?)", id, run[0], i)
                }
            }
        }
        return (runs.count, runs.reduce(0) { $0 + $1.count })
    }

    /// Rebuilds bursts, then similar groups. Burst shots are left out of near-duplicate grouping
    /// (bursts have their own category); exact duplicates are always grouped.
    /// `threshold` nil = the library's remembered value (`similarThreshold()`).
    @discardableResult
    public func groupSimilar(threshold: Float? = nil, window: TimeInterval = 600, maxNeighbors: Int = 40) throws -> SimilarityReport {
        let threshold = try threshold ?? similarThreshold()
        let (burstCount, burstPhotos) = try detectBursts()
        var burstOf: [Int64: Int64] = [:]
        try db.query("SELECT media_id, burst_id FROM bursts") { burstOf[$0.int(0)] = $0.int(1) }
        var parent: [Int64: Int64] = [:]
        func find(_ x: Int64) -> Int64 {
            var r = x
            while let p = parent[r], p != r { r = p }
            var c = x
            while let p = parent[c], p != r { parent[c] = r; c = p }
            return r
        }
        func union(_ a: Int64, _ b: Int64) {
            if parent[a] == nil { parent[a] = a }
            if parent[b] == nil { parent[b] = b }
            let (ra, rb) = (find(a), find(b))
            if ra != rb { parent[max(ra, rb)] = min(ra, rb) }
        }

        // Exact duplicates.
        var exact = Set<Int64>()
        try db.query("""
            SELECT group_concat(id) FROM media WHERE quick_hash IS NOT NULL AND ignored = 0
            GROUP BY quick_hash, size HAVING count(*) > 1
            """) { r in
            let ids = r.text(0).split(separator: ",").compactMap { Int64($0) }
            for id in ids.dropFirst() { union(ids[0], id) }
            exact.formUnion(ids)
        }

        // Near-duplicates in a sliding time window. A photo joins a group only if it is similar to the
        // group's first photo (its leader), not merely to a neighbour: otherwise a long series shot in
        // sequence chains into one giant group (A≈B≈C≈… while A and Z differ).
        func dot(_ a: [Float], _ b: [Float]) -> Float {
            var s: Float = 0; vDSP_dotpr(a, 1, b, 1, &s, vDSP_Length(a.count)); return s
        }
        var recent: [(id: Int64, t: Double, print: [Float], leader: Int64)] = []
        var leaders: [Int64: (print: [Float], last: Double)] = [:]
        try db.query("SELECT id, taken_at, print FROM media WHERE print IS NOT NULL AND taken_at IS NOT NULL AND ignored = 0 ORDER BY taken_at") { r in
            guard let d = r.blob(2) else { return }
            let id = r.int(0), t = r.double(1)
            if burstOf[id] != nil { return } // burst shots live in their own category
            let v = d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            recent.removeAll { $0.t < t - window }
            if leaders.count > 4 * maxNeighbors { leaders = leaders.filter { $0.value.last >= t - window } }
            var best: Int64?, bestScore = threshold
            for o in recent.suffix(maxNeighbors) where o.print.count == v.count && dot(v, o.print) >= threshold {
                guard let l = leaders[o.leader], l.print.count == v.count else { continue }
                let s = dot(v, l.print)
                if s >= bestScore { best = o.leader; bestScore = s }
            }
            if let g = best {
                union(g, id)
                leaders[g]?.last = t
                recent.append((id, t, v, g))
            } else {
                leaders[id] = (v, t)
                recent.append((id, t, v, id))
            }
        }

        var groups: [Int64: [Int64]] = [:]
        for id in parent.keys { groups[find(id), default: []].append(id) }
        var rep = SimilarityReport()
        rep.threshold = threshold
        rep.bursts = burstCount
        rep.burstPhotos = burstPhotos
        try db.transaction {
            try db.run("DELETE FROM similar")
            for (root, members) in groups where members.count > 1 {
                rep.groups += 1
                for m in members {
                    try db.run("INSERT INTO similar(media_id, group_id, exact) VALUES(?, ?, ?)", m, root, exact.contains(m))
                    rep.photos += 1
                    if exact.contains(m) { rep.exactDuplicates += 1 }
                }
            }
        }
        return rep
    }

    /// Other photos in the same similar group (for the viewer).
    public func similarGroup(of mediaId: Int64) throws -> [Int64] {
        try db.all("""
            SELECT s2.media_id FROM similar s1 JOIN similar s2 ON s2.group_id = s1.group_id JOIN media m ON m.id = s2.media_id
            WHERE s1.media_id = ? ORDER BY m.aesthetic DESC, m.size DESC
            """, [mediaId]) { $0.int(0) }
    }
}
