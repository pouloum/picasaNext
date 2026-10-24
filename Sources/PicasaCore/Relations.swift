import Foundation

/// The Relations view: named people, and "moments" — the photos grouped by the exact set of named
/// people in them (≥ 2), each linked to its people. People are coloured by community (circles of
/// family / friends found with Louvain on who is photographed with whom).
public struct RelationsGraph: Sendable {
    public struct Person: Sendable, Identifiable {
        public let id: Int64
        public let name: String
        public let photos: Int
        public let coverFaceId: Int64?
        public var community = 0
    }

    public struct Moment: Sendable, Identifiable {
        public var id: String { people.map(String.init).joined(separator: "-") }
        public let people: [Int64]
        public let mediaIds: [Int64] // newest first
        /// Year of each photo of `mediaIds` (0 = unknown), for the year slider.
        public let years: [Int]
        public let coverMediaId: Int64
        public let firstYear: Int?
        public let lastYear: Int?
    }

    public var people: [Person]
    public var moments: [Moment]

    /// Shortest chain of shared moments between two people (breadth-first over people ↔ moments),
    /// restricted to the moments `allowed` (indexes). Returns alternating person / moment node
    /// indexes (people 0..<people.count, moments after them), or nil when they are not connected.
    public func path(from a: Int, to b: Int, allowed: Set<Int>? = nil) -> [Int]? {
        let np = people.count
        let index = Dictionary(uniqueKeysWithValues: people.enumerated().map { ($1.id, $0) })
        var byPerson = [[Int]](repeating: [], count: np)
        for (mi, m) in moments.enumerated() where allowed?.contains(mi) ?? true {
            for p in m.people { if let i = index[p] { byPerson[i].append(np + mi) } }
        }
        var prev: [Int: Int] = [a: a]
        var queue = [a], head = 0
        while head < queue.count {
            let n = queue[head]; head += 1
            if n == b { break }
            let next: [Int] = n < np ? byPerson[n] : moments[n - np].people.compactMap { index[$0] }
            for x in next where prev[x] == nil { prev[x] = n; queue.append(x) }
        }
        guard prev[b] != nil else { return nil }
        var out = [b]
        while out.last! != a { out.append(prev[out.last!]!) }
        return out.reversed()
    }
}

extension Library {
    public func relationsGraph() throws -> RelationsGraph {
        var byMedia: [Int64: Set<Int64>] = [:]
        var info: [Int64: (taken: Double, score: Double)] = [:]
        try db.query("""
            SELECT DISTINCT f.media_id, f.person_id, coalesce(m.taken_at, 0), coalesce(m.aesthetic, 0)
            FROM faces f JOIN media m ON m.id = f.media_id JOIN persons p ON p.id = f.person_id
            WHERE f.person_id IS NOT NULL AND f.ignored = 0 AND m.ignored = 0 AND m.hidden = 0
              AND m.thumb_state = 1 AND p.merged_into IS NULL AND p.name != ''
            """) { r in
            byMedia[r.int(0), default: []].insert(r.int(1))
            info[r.int(0)] = (r.double(2), r.double(3))
        }
        var photos: [Int64: Int] = [:]
        for ps in byMedia.values { for p in ps { photos[p, default: 0] += 1 } }
        var groups: [[Int64]: [Int64]] = [:]
        for (m, ps) in byMedia where ps.count >= 2 { groups[ps.sorted(), default: []].append(m) }

        let cal = Calendar.current
        func year(_ t: Double) -> Int? { t > 0 ? cal.component(.year, from: Date(timeIntervalSince1970: t)) : nil }
        let moments = groups.map { key, ms -> RelationsGraph.Moment in
            let sorted = ms.sorted { info[$0]!.taken > info[$1]!.taken }
            let cover = ms.max { (info[$0]!.score, info[$0]!.taken) < (info[$1]!.score, info[$1]!.taken) }!
            let ys = ms.compactMap { year(info[$0]!.taken) }
            return .init(people: key, mediaIds: sorted, years: sorted.map { year(info[$0]!.taken) ?? 0 }, coverMediaId: cover,
                         firstYear: ys.min(), lastYear: ys.max())
        }.sorted { $0.mediaIds.count > $1.mediaIds.count }

        // Only people listed below may appear in moments (a person without a name, e.g. a Picasa
        // contact never named, is not drawn).
        let inGraph = Set(moments.flatMap(\.people))
        let byId = Dictionary(uniqueKeysWithValues: try owners(.face).map { ($0.id, $0) })
        var people = inGraph.compactMap { id -> RelationsGraph.Person? in
            guard let o = byId[id] else { return nil }
            return .init(id: id, name: o.name, photos: photos[id] ?? 0, coverFaceId: o.coverFaceId)
        }
        let community = Self.communities(people: people.map(\.id), photos: photos, moments: moments)
        for i in people.indices { people[i].community = community[people[i].id] ?? 0 }
        return RelationsGraph(people: people.sorted { $0.photos > $1.photos }, moments: moments)
    }

    /// Louvain, one level (local moving), on the person–person graph. Weights are normalised by how
    /// much each person is photographed, so that very present people do not absorb everybody.
    /// Communities are numbered by size (0 = largest).
    static func communities(people: [Int64], photos: [Int64: Int], moments: [RelationsGraph.Moment]) -> [Int64: Int] {
        var w: [Int64: [Int64: Double]] = [:]
        let label0 = Set(people)
        for m in moments {
            let ps = m.people.filter { label0.contains($0) }
            for a in ps { for b in ps where a != b { w[a, default: [:]][b, default: 0] += Double(m.mediaIds.count) } }
        }
        for (a, row) in w {
            for (b, x) in row { w[a]![b] = x / (Double(photos[a] ?? 1) * Double(photos[b] ?? 1)).squareRoot() }
        }
        let deg = Dictionary(uniqueKeysWithValues: people.map { p in (p, w[p]?.values.reduce(0, +) ?? 0) })
        let m2 = max(deg.values.reduce(0, +), 1e-9)
        var label = Dictionary(uniqueKeysWithValues: people.map { ($0, $0) })
        var tot = deg
        let order = people.sorted { (deg[$0] ?? 0) > (deg[$1] ?? 0) }
        for _ in 0..<30 {
            var moved = false
            for p in order {
                let cur = label[p]!, d = deg[p] ?? 0
                tot[cur, default: 0] -= d
                var links: [Int64: Double] = [:]
                for (q, x) in w[p] ?? [:] { if let l = label[q] { links[l, default: 0] += x } }
                var best = cur, gain = (links[cur] ?? 0) - (tot[cur] ?? 0) * d / m2
                for (c, x) in links {
                    let g = x - (tot[c] ?? 0) * d / m2
                    if g > gain + 1e-12 { best = c; gain = g }
                }
                label[p] = best
                tot[best, default: 0] += d
                if best != cur { moved = true }
            }
            if !moved { break }
        }
        var size: [Int64: Int] = [:]
        for (p, l) in label { size[l, default: 0] += photos[p] ?? 0 }
        let rank = Dictionary(uniqueKeysWithValues: size.keys.sorted { (size[$0] ?? 0, $0) > (size[$1] ?? 0, $1) }.enumerated().map { ($1, $0) })
        return label.mapValues { rank[$0] ?? 0 }
    }
}
