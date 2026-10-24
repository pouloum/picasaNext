import Accelerate
import Foundation

public struct SimilarityReport: Sendable, CustomStringConvertible {
    public var groups = 0, photos = 0, duplicateGroups = 0, duplicates = 0, bursts = 0, burstPhotos = 0
    public var threshold: Float = 0
    public var description: String {
        "\(duplicateGroups) groups of identical files (\(duplicates) extra copies hidden) · \(bursts) bursts (\(burstPhotos) photos) · "
            + "\(groups) groups of similar photos (\(photos) photos, threshold \(threshold))"
    }
}

/// The three kinds of photo groups shown with one cover each (and expanded on demand).
public enum GroupKind: Int, Sendable, Hashable {
    case duplicates = 0, burst = 1, similar = 2
}

/// A group of photos: the cover (the copy kept / the best shot) first, then the others.
public struct MediaGroup: Sendable, Identifiable, Hashable {
    public let id: Int64
    public let members: [Int64]
    public var cover: Int64 { members[0] }
}

extension Library {
    /// Folder names that usually hold copies: the copy kept is preferably elsewhere.
    static let copyMarkers = ["__duplicate", "duplicate", "doublon", "_a_trier", "a trier", "recuva", "#recycle", "recycle",
                              "backup", "sauvegarde", "copie", "copy", "old", "tmp", "temp", "export"]

    struct Shot {
        let id: Int64, folder: Int64, path: String, name: String, camera: String, t: Double, metadataDate: Bool, exif: Bool
        let pixels: Int, score: Double, lat: Double?, lon: Double?
        let hasPrint: Bool
    }

    /// The metadata the grouping needs, in date order. Prints (3 KB each) are not loaded here: they
    /// are read on demand (`prints`), a time window at a time.
    func shots() throws -> [Shot] {
        try db.all("""
            SELECT m.id, m.folder_id, f.path, m.name, coalesce(m.camera, ''), m.taken_at, coalesce(m.date_source, 0) = 0, m.exif,
                   coalesce(m.width, 0) * coalesce(m.height, 0), coalesce(m.aesthetic, 0), m.lat, m.lon, length(m.print) > 0
            FROM media m JOIN folders f ON f.id = m.folder_id
            WHERE m.ignored = 0 AND m.kind != 1 AND m.taken_at IS NOT NULL ORDER BY m.taken_at, m.id
            """) { r in
            Shot(id: r.int(0), folder: r.int(1), path: r.text(2), name: r.text(3), camera: r.text(4), t: r.double(5), metadataDate: r.int(6) != 0,
                 exif: r.int(7) != 0, pixels: Int(r.int(8)), score: r.double(9), lat: r.optDouble(10), lon: r.optDouble(11),
                 hasPrint: r.int(12) != 0)
        }
    }

    func prints(_ ids: [Int64]) throws -> [Int64: [Float]] {
        var out: [Int64: [Float]] = [:]
        for chunk in stride(from: 0, to: ids.count, by: 500).map({ Array(ids[$0..<min(ids.count, $0 + 500)]) }) {
            try db.query("SELECT id, print FROM media WHERE id IN (\(chunk.map(String.init).joined(separator: ","))) AND length(print) > 0") { r in
                if let d = r.blob(1) { out[r.int(0)] = d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) } }
            }
        }
        return out
    }

    static func likeness(_ a: [Float]?, _ b: [Float]?) -> Float? {
        guard let a, let b, a.count == b.count, !a.isEmpty else { return nil }
        var s: Float = 0; vDSP_dotpr(a, 1, b, 1, &s, vDSP_Length(a.count)); return s
    }

    static func meters(_ a: Shot, _ b: Shot) -> Double? {
        guard let la = a.lat, let oa = a.lon, let lb = b.lat, let ob = b.lon, la != 0 || oa != 0, lb != 0 || ob != 0 else { return nil }
        let dy = (la - lb) * 111_320, dx = (oa - ob) * 111_320 * cos(la * .pi / 180)
        return (dx * dx + dy * dy).squareRoot()
    }

    /// Duplicates: identical files (same quick hash + size) and the same picture in another file
    /// (resized, recompressed, re-exported: same capture time and the image nearly identical).
    /// In each group one copy is kept — the largest picture, outside folders that look like copies,
    /// the shallowest path, the first indexed — and the others get `dup_of` = the kept one: hidden
    /// from the library views (they stay in their folder's view and in Duplicates). Files are never touched.
    @discardableResult
    func markDuplicates(_ shots: [Shot], visualLikeness: Float = 0.985) throws -> (groups: Int, copies: Int) {
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
        try db.query("""
            SELECT group_concat(id) FROM media WHERE quick_hash IS NOT NULL AND ignored = 0
            GROUP BY quick_hash, size HAVING count(*) > 1
            """) { r in
            let ids = r.text(0).split(separator: ",").compactMap { Int64($0) }
            for id in ids.dropFirst() { union(ids[0], id) }
        }
        // Same capture instant (to the second) and the same picture: a copy, not a second shot.
        var i = 0
        while i < shots.count {
            var j = i
            while j + 1 < shots.count && shots[j + 1].t == shots[i].t { j += 1 }
            if j > i && j - i < 200 { // a few files sharing an instant (not a whole folder dated by its name)
                let p = try prints(shots[i...j].filter(\.hasPrint).map(\.id))
                for a in i..<j { for b in (a + 1)...j where (Self.likeness(p[shots[a].id], p[shots[b].id]) ?? 0) >= visualLikeness {
                    union(shots[a].id, shots[b].id)
                } }
            }
            i = j + 1
        }
        let byId = Dictionary(uniqueKeysWithValues: shots.map { ($0.id, $0) })
        var paths: [Int64: String] = [:]
        let missing = parent.keys.filter { byId[$0] == nil }
        if !missing.isEmpty {
            try db.query("SELECT m.id, f.path FROM media m JOIN folders f ON f.id = m.folder_id WHERE m.id IN (\(missing.map(String.init).joined(separator: ",")))") {
                paths[$0.int(0)] = $0.text(1)
            }
        }
        func penalty(_ id: Int64) -> Int {
            let l = (byId[id]?.path ?? paths[id] ?? "").lowercased()
            return Self.copyMarkers.filter { l.contains($0) }.count
        }
        func depth(_ id: Int64) -> Int { (byId[id]?.path ?? paths[id] ?? "").split(separator: "/").count }
        var groups: [Int64: [Int64]] = [:]
        for id in parent.keys { groups[find(id), default: []].append(id) }
        var copies = 0
        try db.transaction {
            try db.run("UPDATE media SET dup_of = NULL WHERE dup_of IS NOT NULL")
            try db.run("DELETE FROM group_info WHERE kind = ?", GroupKind.duplicates.rawValue)
            for (_, g) in groups where g.count > 1 {
                let keep = g.min { (-(byId[$0]?.pixels ?? 0), penalty($0), depth($0), $0) < (-(byId[$1]?.pixels ?? 0), penalty($1), depth($1), $1) }!
                for c in g where c != keep { try db.run("UPDATE media SET dup_of = ? WHERE id = ?", keep, c); copies += 1 }
                try db.run("INSERT INTO group_info(kind, group_id, cover_id, size) VALUES(?, ?, ?, ?)", GroupKind.duplicates.rawValue, keep, keep, g.count)
            }
        }
        return (groups.values.filter { $0.count > 1 }.count, copies)
    }

    /// Bursts: shots from the same camera, each at most `maxGap` seconds after the previous one and
    /// looking like it (prints ≥ `minLikeness`, or ≥ 0.92 for photos without camera metadata), dated
    /// by the photo itself — plus time-lapses: at least `lapseMin` shots at a regular interval (up to
    /// `lapseGap` s, ±15 %). Only copies kept are considered (a burst copied to another folder is one
    /// burst). Cover: the best-looking shot.
    @discardableResult
    func detectBursts(_ all: [Shot], maxGap: Double = 3, minCount: Int = 2, minLikeness: Float = 0.85,
                      lapseGap: Double = 60, lapseMin: Int = 5) throws -> (bursts: Int, photos: Int) {
        var dup = Set<Int64>()
        try db.query("SELECT id FROM media WHERE dup_of IS NOT NULL") { dup.insert($0.int(0)) }
        let shots = all.filter { $0.metadataDate && !dup.contains($0.id) }
            .sorted { ($0.camera, $0.t, $0.id) < ($1.camera, $1.t, $1.id) }
        // Prints of the shots that have a neighbour from the same camera within the gap.
        var candidates: [Int64] = []
        for (k, s) in shots.enumerated() where s.hasPrint {
            let prev = k > 0 ? shots[k - 1] : nil, next = k + 1 < shots.count ? shots[k + 1] : nil
            if (prev.map { $0.camera == s.camera && s.t - $0.t <= lapseGap } ?? false) || (next.map { $0.camera == s.camera && $0.t - s.t <= lapseGap } ?? false) {
                candidates.append(s.id)
            }
        }
        let p = try prints(candidates)
        var runs: [[Shot]] = []
        /// A run is kept if it is a burst (all gaps ≤ maxGap) or a time-lapse (long enough); otherwise
        /// its burst parts (gaps ≤ maxGap) are kept.
        func close(_ run: [Shot]) {
            let gaps = zip(run, run.dropFirst()).map { $1.t - $0.t }
            if run.count >= minCount && (gaps.allSatisfy { $0 <= maxGap } || run.count >= lapseMin) { runs.append(run); return }
            var part: [Shot] = []
            for s in run {
                if let l = part.last, s.t - l.t > maxGap { if part.count >= minCount { runs.append(part) }; part = [] }
                part.append(s)
            }
            if part.count >= minCount { runs.append(part) }
        }
        var cur: [Shot] = []
        for s in shots {
            var linked = false
            if let l = cur.last, l.camera == s.camera {
                let gap = s.t - l.t
                let like = Self.likeness(p[l.id], p[s.id]) ?? (s.exif ? 1 : 0)
                if gap <= maxGap && like >= (s.exif && l.exif ? minLikeness : 0.92) {
                    linked = true
                } else if gap <= lapseGap && like >= 0.80 {
                    // Time-lapse: the same interval as before (or the first interval of a new run).
                    if cur.count >= 2 {
                        let prevGap = l.t - cur[cur.count - 2].t
                        linked = prevGap > maxGap && abs(gap - prevGap) <= max(1, 0.15 * prevGap)
                    } else {
                        linked = gap > maxGap
                    }
                }
            }
            if linked { cur.append(s) } else { close(cur); cur = [s] }
        }
        close(cur)
        // Camera files without a capture date (e.g. GoPro time-lapses): in file-number order within
        // their folder, a long run of look-alike shots from the same camera is a burst.
        let undated = all.filter { !$0.metadataDate && $0.exif && !$0.camera.isEmpty && $0.hasPrint && !dup.contains($0.id) }
        for (_, files) in Dictionary(grouping: undated, by: { "\($0.folder)|\($0.camera)" }) where files.count >= lapseMin {
            let ordered = files.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            let pu = try prints(ordered.map(\.id))
            var run: [Shot] = []
            for f in ordered {
                if let l = run.last, (Self.likeness(pu[l.id], pu[f.id]) ?? 0) >= 0.80 { run.append(f) }
                else { if run.count >= lapseMin { runs.append(run) }; run = [f] }
            }
            if run.count >= lapseMin { runs.append(run) }
        }
        try db.transaction {
            try db.run("DELETE FROM bursts")
            try db.run("DELETE FROM group_info WHERE kind = ?", GroupKind.burst.rawValue)
            for run in runs {
                for (i, s) in run.enumerated() {
                    try db.run("INSERT INTO bursts(media_id, burst_id, position) VALUES(?, ?, ?)", s.id, run[0].id, i)
                }
                // Best-looking shot; on a tie the first one.
                let cover = run.enumerated().max { ($0.1.score, -$0.0) < ($1.1.score, -$1.0) }?.1.id ?? run[0].id
                try db.run("INSERT INTO group_info(kind, group_id, cover_id, size) VALUES(?, ?, ?, ?)", GroupKind.burst.rawValue, run[0].id, cover, run.count)
            }
        }
        return (runs.count, runs.reduce(0) { $0 + $1.count })
    }

    /// Rebuilds the three kinds of groups: duplicates (identical files and the same picture in other
    /// files), bursts, then similar photos — "the same scene", among copies kept and outside bursts.
    /// Two photos are linked when, besides looking alike, their metadata says they belong together:
    /// same camera ≤ 2 min apart (prints ≥ 0.75), ≤ 10 min apart (≥ 0.88), or taken ≤ 100 m apart
    /// within 30 min (≥ 0.90); photos dated by file or folder only by look (≥ `threshold`) in the same
    /// folder. A group never drifts far from its first photo (≥ 0.72), so a long series is not chained.
    /// (Measured on a real library: groups next to each other in time share ~0.79 in median; two
    /// random photos 0.50, and 0.70 for the closest 1 %.)
    /// `threshold` nil = the library's remembered value (default 0.97).
    @discardableResult
    public func groupSimilar(threshold: Float? = nil, window: TimeInterval = 1800, maxNeighbors: Int = 60) throws -> SimilarityReport {
        let threshold = try threshold ?? similarThreshold()
        var rep = SimilarityReport()
        rep.threshold = threshold
        let all = try shots()
        (rep.duplicateGroups, rep.duplicates) = try markDuplicates(all)
        (rep.bursts, rep.burstPhotos) = try detectBursts(all)
        var excluded = Set<Int64>()
        try db.query("SELECT media_id FROM bursts UNION SELECT id FROM media WHERE dup_of IS NOT NULL") { excluded.insert($0.int(0)) }
        let shots = all.filter { $0.hasPrint && !excluded.contains($0.id) }
        // Prints are read a chunk ahead and dropped once out of the time window (bounded memory).
        var cache: [Int64: [Float]] = [:]
        var loadedUpTo = 0

        var leaderLast: [Int64: Double] = [:] // a group's latest photo time
        var leaderOf: [Int64: Int64] = [:] // photo → its group's first photo
        var leaderPrint: [Int64: [Float]] = [:]
        var members: [Int64: [Int64]] = [:]
        var recent: [Shot] = []
        for (k, s) in shots.enumerated() {
            if k >= loadedUpTo {
                let end = min(shots.count, k + 2000)
                cache.merge(try prints(shots[k..<end].map(\.id))) { $1 }
                loadedUpTo = end
            }
            let dropped = recent.filter { $0.t < s.t - window }
            recent.removeAll { $0.t < s.t - window }
            for d in dropped where leaderPrint[d.id] == nil { cache[d.id] = nil }
            var best: (leader: Int64, score: Float)?
            for o in recent.suffix(maxNeighbors) {
                guard let sim = Self.likeness(cache[s.id], cache[o.id]) else { continue }
                let dt = s.t - o.t
                let sameCamera = !s.camera.isEmpty && s.camera == o.camera
                let near = Self.meters(s, o).map { $0 <= 100 } ?? false
                let linked: Bool
                if s.metadataDate && o.metadataDate {
                    linked = (sameCamera && dt <= 120 && sim >= 0.75) || (sameCamera && dt <= 600 && sim >= 0.88)
                        || (near && dt <= 1800 && sim >= 0.90) || (dt <= 600 && sim >= threshold)
                } else {
                    linked = s.folder == o.folder && sim >= threshold
                }
                guard linked, let leader = leaderOf[o.id], let lp = leaderPrint[leader],
                      (Self.likeness(cache[s.id], lp) ?? 0) >= 0.72 else { continue }
                if best == nil || sim > best!.score { best = (leader, sim) }
            }
            if let b = best {
                leaderOf[s.id] = b.leader
                leaderLast[b.leader] = s.t
                members[b.leader, default: []].append(s.id)
            } else {
                leaderOf[s.id] = s.id
                leaderPrint[s.id] = cache[s.id]
                leaderLast[s.id] = s.t
                members[s.id] = [s.id]
            }
            recent.append(s)
            // Groups with no photo in the window will not get new members: forget their leader's print.
            if k % 2000 == 0 {
                let horizon = s.t - window
                for (l, last) in leaderLast where last < horizon { leaderPrint[l] = nil; leaderLast[l] = nil }
            }
        }

        let score = Dictionary(uniqueKeysWithValues: shots.map { ($0.id, $0.score) })
        try db.transaction {
            try db.run("DELETE FROM similar")
            try db.run("DELETE FROM group_info WHERE kind = ?", GroupKind.similar.rawValue)
            for (root, ms) in members where ms.count > 1 {
                rep.groups += 1
                for m in ms {
                    try db.run("INSERT INTO similar(media_id, group_id, exact) VALUES(?, ?, 0)", m, root)
                    rep.photos += 1
                }
                let cover = ms.max { (score[$0] ?? 0, -$0) < (score[$1] ?? 0, -$1) } ?? root
                try db.run("INSERT INTO group_info(kind, group_id, cover_id, size) VALUES(?, ?, ?, ?)", GroupKind.similar.rawValue, root, cover, ms.count)
            }
            // Group dates (newest photo), for ordering the covers.
            try db.run("UPDATE group_info SET taken = (SELECT max(m.taken_at) FROM media m WHERE m.id = group_info.cover_id)")
        }
        return rep
    }

    /// Groups of one kind, newest first; each with its cover first then the other members (bursts in
    /// shooting order, similar photos best first, duplicates: the copy kept then the copies). Only
    /// photos visible in the library are counted; groups left with one photo are dropped.
    public func mediaGroups(_ kind: GroupKind) throws -> [MediaGroup] {
        let visible = "m.ignored = 0 AND m.hidden = 0 AND m.meta_state = 1 AND m.thumb_state = 1"
        let sql: String
        switch kind {
        case .burst:
            sql = """
                SELECT g.group_id, g.cover_id, b.media_id FROM group_info g JOIN bursts b ON b.burst_id = g.group_id
                JOIN media m ON m.id = b.media_id WHERE g.kind = 1 AND \(visible) ORDER BY g.taken DESC, g.group_id, b.position
                """
        case .similar:
            sql = """
                SELECT g.group_id, g.cover_id, s.media_id FROM group_info g JOIN similar s ON s.group_id = g.group_id
                JOIN media m ON m.id = s.media_id WHERE g.kind = 2 AND \(visible) ORDER BY g.taken DESC, g.group_id, m.aesthetic DESC, m.size DESC
                """
        case .duplicates:
            sql = """
                SELECT g.group_id, g.cover_id, m.id FROM group_info g JOIN media m ON (m.id = g.group_id OR m.dup_of = g.group_id)
                WHERE g.kind = 0 AND \(visible) ORDER BY g.taken DESC, g.group_id, m.dup_of IS NOT NULL, m.id
                """
        }
        var out: [MediaGroup] = []
        var cur: (id: Int64, cover: Int64, members: [Int64])?
        func flush() {
            guard let c = cur, c.members.count > 1 else { return }
            let cover = c.members.contains(c.cover) ? c.cover : c.members[0]
            out.append(MediaGroup(id: c.id, members: [cover] + c.members.filter { $0 != cover }))
        }
        try db.query(sql) { r in
            let (gid, cover, mid) = (r.int(0), r.int(1), r.int(2))
            if cur?.id != gid { flush(); cur = (gid, cover, []) }
            cur!.members.append(mid)
        }
        flush()
        return out
    }

    /// Other photos in the same similar group (for the viewer).
    public func similarGroup(of mediaId: Int64) throws -> [Int64] {
        try db.all("""
            SELECT s2.media_id FROM similar s1 JOIN similar s2 ON s2.group_id = s1.group_id JOIN media m ON m.id = s2.media_id
            WHERE s1.media_id = ? ORDER BY m.aesthetic DESC, m.size DESC
            """, [mediaId]) { $0.int(0) }
    }

    /// Where the other copies of an identical file are (for the info panel).
    public func copies(of mediaId: Int64) throws -> [String] {
        try db.all("""
            SELECT f.path || '/' || m.name FROM media m JOIN folders f ON f.id = m.folder_id
            WHERE m.id != ?1 AND (m.dup_of = (SELECT coalesce(dup_of, id) FROM media WHERE id = ?1) OR m.id = (SELECT dup_of FROM media WHERE id = ?1))
            ORDER BY m.dup_of IS NOT NULL
            """, [mediaId]) { $0.text(0) }
    }
}
