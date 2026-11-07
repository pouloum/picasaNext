import Accelerate
import Foundation

/// Faces and animals are identified the same way: each detected region has a feature print, can be
/// named (a person / a pet), gets suggestions, can be rejected for a name, or ignored altogether.
/// faces → persons(person_id…), animals → pets(pet_id…).
public enum IdentityKind: String, Sendable, Hashable {
    case face, pet

    var table: String { self == .face ? "faces" : "animals" }
    var owners: String { self == .face ? "persons" : "pets" }
    var col: String { self == .face ? "person_id" : "pet_id" }
    var suggested: String { "suggested_" + col }
    var rejected: String { "rejected_" + col }
    /// Covering index of the regions (owner, ignored, suggestion, photo, size, rejection): the rows
    /// themselves hold 3 KB feature prints and must not be read for counts and lists.
    var identIndex: String { self == .face ? "faces_ident" : "animals_ident" }
    /// A person drew, tagged or decided on the region (faces from Picasa or drawn by hand included).
    var humanSQL: String { self == .face ? "(t.human = 1 OR t.source != \(FaceSource.vision.rawValue))" : "t.human = 1" }
}

extension Library {
    /// Local-time bounds of a calendar year, as stored in `media.taken_at`.
    static func yearRange(_ y: Int) -> (Double, Double) {
        (DateComponents(calendar: .current, year: y).date!.timeIntervalSince1970,
         DateComponents(calendar: .current, year: y + 1).date!.timeIntervalSince1970)
    }

    /// Photos shown in the library (what the grids list): counts and groups use the same set, so a
    /// card's numbers match its lists — hidden copies, ignored and unindexed files are left out.
    static let visibleMedia = "m.ignored = 0 AND m.hidden = 0 AND m.dup_of IS NULL AND m.meta_state = 1 AND m.thumb_state = 1"

    /// Regions joined to their (visible) photos through covering indexes only (v13): SQLite would
    /// otherwise probe the media rows by id, each one a 4 KB page because of its print.
    static func regionsOfVisible(_ k: IdentityKind) -> String {
        "\(k.table) t INDEXED BY \(k.identIndex) JOIN media m INDEXED BY media_visible_id ON m.id = t.media_id"
    }

    /// Regions of photos that are not hidden copies: a copy shares its kept photo's decisions, so the
    /// suggestion engine reads each picture once (no suggestions for copies, no doubled examples).
    static let notCopy = "media_id NOT IN (SELECT id FROM media WHERE dup_of IS NOT NULL)"

    func yearClause(_ year: Int?, column: String = "m.taken_at") -> (String, [SQLBindable]) {
        guard let year else { return ("", []) }
        let (a, b) = Self.yearRange(year)
        return (" AND \(column) >= ? AND \(column) < ?", [a, b])
    }

    /// Named people / pets with their item counts (optionally within one year), most items first.
    /// People imported from Picasa contacts without any face in the library are left out.
    public func owners(_ k: IdentityKind, year: Int? = nil) throws -> [PersonSummary] {
        let (yc, ya) = yearClause(year)
        let t = k.table
        let regions = Self.regionsOfVisible(k)
        return try db.all("""
            SELECT * FROM (
              SELECT p.id, p.name,
                (SELECT count(DISTINCT t.media_id) FROM \(regions)
                 WHERE t.\(k.col) = p.id AND t.ignored = 0 AND \(Self.visibleMedia)\(yc)) n,
                (SELECT count(DISTINCT t.media_id) FROM \(regions)
                 WHERE t.\(k.col) IS NULL AND t.ignored = 0 AND t.\(k.suggested) = p.id AND \(Self.visibleMedia)\(yc)) s,
                coalesce((SELECT t.id FROM \(t) t WHERE t.id = p.cover_id AND t.\(k.col) = p.id),
                         (SELECT t.id FROM \(regions) WHERE t.\(k.col) = p.id AND \(Self.visibleMedia)\(yc)
                          ORDER BY coalesce(m.aesthetic, 0) DESC, t.w DESC LIMIT 1))
              FROM \(k.owners) p WHERE p.name != '' AND p.merged_into IS NULL)
            WHERE n > 0 OR s > 0 ORDER BY n DESC
            """, ya + ya + ya) {
            PersonSummary(id: $0.int(0), name: $0.text(1), faces: Int($0.int(2)), suggestions: Int($0.int(3)), coverFaceId: $0.optInt(4))
        }
    }

    /// Unnamed items without a pending suggestion (or, with `ignored`, the ignored ones) grouped by
    /// feature-print similarity: leader clustering, an item joins the first group whose leader is
    /// within `threshold`. Largest regions first, at most `maxItems`, so it stays interactive.
    public func identityClusters(_ k: IdentityKind, ignored: Bool = false, year: Int? = nil,
                                 threshold: Float = 0.8, maxItems: Int = 5_000) throws -> [FaceCluster] {
        let (yc, ya) = yearClause(year)
        // Which regions: chosen on the covering indexes (ids only), largest first; then the prints of
        // just those (reading the prints of every unnamed face to keep 5 000 used to take seconds).
        let ids = try db.all("""
            SELECT t.id FROM \(Self.regionsOfVisible(k))
            WHERE t.\(k.col) IS NULL AND t.ignored = ? \(ignored ? "" : "AND t.\(k.suggested) IS NULL") AND \(Self.visibleMedia)\(yc)
            ORDER BY t.w * t.h DESC, t.id LIMIT ?
            """, [ignored ? 1 : 0] + ya + [maxItems]) { $0.int(0) }
        guard !ids.isEmpty else { return [] }
        var prints: [Int64: [Float]] = [:]
        // One statement text whatever the ids (the prepared-statement cache is keyed by SQL text).
        let list = "[" + ids.map(String.init).joined(separator: ",") + "]"
        try db.query("SELECT id, print FROM \(k.table) WHERE id IN (SELECT value FROM json_each(?))", [list]) { r in
            if let d = r.blob(1) { prints[r.int(0)] = d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) } }
        }
        let items: [(id: Int64, print: [Float]?)] = ids.map { ($0, prints[$0]) }
        guard !items.isEmpty else { return [] }
        let dim = items.compactMap(\.print).first { !$0.isEmpty }?.count ?? 0
        // Leaders in one flat row-major matrix: each item is scored against all of them in a single
        // matrix-vector product (vDSP_mmul) instead of one dot-product call per leader.
        var leaders: [Float] = []
        var members: [[Int64]] = []
        var scores: [Float] = []
        var loose: [Int64] = [] // ignored items without a print: one group of their own
        var single: [[Int64]] = [] // unnamed items without a print (not analysed yet): one card each
        for f in items {
            guard let p = f.print, dim > 0, p.count == dim else { if ignored { loose.append(f.id) } else { single.append([f.id]) }; continue }
            let n = members.count
            var best = -1
            if n > 0 {
                if scores.count < n { scores = [Float](repeating: 0, count: max(n, scores.count * 2)) }
                vDSP_mmul(leaders, 1, p, 1, &scores, 1, vDSP_Length(n), 1, vDSP_Length(dim))
                var top: Float = 0
                var at: vDSP_Length = 0
                vDSP_maxvi(scores, 1, &top, &at, vDSP_Length(n))
                if top >= threshold { best = Int(at) }
            }
            if best >= 0 { members[best].append(f.id) } else { leaders.append(contentsOf: p); members.append([f.id]) }
        }
        if !loose.isEmpty { members.append(loose) }
        // Without a print an item cannot be grouped, but it can still be named: after the groups.
        return members.map { FaceCluster(coverFaceId: $0[0], faceIds: $0) }
            .sorted { $0.faceIds.count > $1.faceIds.count } + single.map { FaceCluster(coverFaceId: $0[0], faceIds: $0) }
    }

    /// Named, unnamed (to identify) and ignored items, optionally within one year: for the filter badges.
    public func identityCounts(_ k: IdentityKind, year: Int? = nil) throws -> (named: Int, unnamed: Int, ignored: Int) {
        let (yc, ya) = yearClause(year)
        return try db.all("""
            SELECT coalesce(sum(t.\(k.col) IS NOT NULL AND t.ignored = 0), 0), coalesce(sum(t.\(k.col) IS NULL AND t.ignored = 0), 0),
                   coalesce(sum(t.ignored), 0)
            FROM \(Self.regionsOfVisible(k)) WHERE \(Self.visibleMedia)\(yc)
            """, ya) { (Int($0.int(0)), Int($0.int(1)), Int($0.int(2))) }.first ?? (0, 0, 0)
    }

    /// Names items (creates the person / pet if needed). Returns its id.
    @discardableResult
    public func nameItems(_ k: IdentityKind, _ ids: [Int64], name: String) throws -> Int64? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !ids.isEmpty else { return nil }
        return try db.transaction {
            var pid = try db.scalar("SELECT coalesce(merged_into, id) FROM \(k.owners) WHERE name = ? COLLATE NOCASE ORDER BY merged_into IS NOT NULL LIMIT 1", [trimmed])
            if pid == nil {
                if k == .pet {
                    let species = try db.all("SELECT species FROM animals WHERE id = ?", [ids[0]]) { $0.text(0) }.first
                    pid = try db.run("INSERT INTO pets(name, species) VALUES(?, ?)", trimmed, species)
                } else {
                    pid = try db.run("INSERT INTO persons(name) VALUES(?)", trimmed)
                }
            }
            try assignRows(k, ids, to: pid!)
            return pid
        }
    }

    /// Gives items to an existing person / pet, as a user action.
    public func assign(_ k: IdentityKind, _ ids: [Int64], to owner: Int64) throws {
        try db.transaction { try assignRows(k, ids, to: owner) }
    }

    private func assignRows(_ k: IdentityKind, _ ids: [Int64], to owner: Int64) throws {
        for id in ids {
            if k == .face {
                // Named by the user: `manual`, so a later .picasa.ini re-import does not replace it.
                try db.run("UPDATE faces SET person_id = ?, suggested_person_id = NULL, ignored = 0, source = ?, human = 1, human_at = ? WHERE id = ?", owner, FaceSource.manual.rawValue, Date().timeIntervalSince1970, id)
            } else {
                try db.run("UPDATE animals SET pet_id = ?, suggested_pet_id = NULL, ignored = 0, human = 1, human_at = ? WHERE id = ?", owner, Date().timeIntervalSince1970, id)
            }
        }
    }

    /// Merges `source` into `target`: its items, suggestions and rejections move over; it stays as an
    /// alias (`merged_into`) so names and Picasa re-imports keep landing on the target.
    public func merge(_ k: IdentityKind, _ source: Int64, into target: Int64) throws {
        guard source != target else { return }
        let t = k.table
        try db.transaction {
            try db.run("UPDATE \(t) SET \(k.col) = ? WHERE \(k.col) = ?", target, source)
            try db.run("UPDATE \(t) SET \(k.suggested) = ? WHERE \(k.suggested) = ?", target, source)
            try db.run("UPDATE \(t) SET \(k.rejected) = ? WHERE \(k.rejected) = ?", target, source)
            // An item suggested for the target that had been rejected for it stays unsuggested.
            try db.run("UPDATE \(t) SET \(k.suggested) = NULL WHERE \(k.suggested) = \(k.rejected)")
            try db.run("UPDATE \(k.owners) SET merged_into = ? WHERE id = ? OR merged_into = ?", target, source, source)
        }
    }

    /// People (pets) whose names are the same once case, accents and spacing are ignored — typically
    /// the same person imported from several Picasa contacts. Each group: the one with the most
    /// photos first (the one the others would be merged into).
    public func duplicateOwners(_ k: IdentityKind) throws -> [[PersonSummary]] {
        Self.duplicateGroups(try owners(k))
    }

    /// `duplicateOwners` from an already loaded `owners(k)` (all years).
    public nonisolated static func duplicateGroups(_ owners: [PersonSummary]) -> [[PersonSummary]] {
        func key(_ n: String) -> String {
            n.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        let groups = Dictionary(grouping: owners, by: { key($0.name) }).values.filter { $0.count > 1 }
        return groups.map { $0.sorted { ($0.faces + $0.suggestions, -$0.id) > ($1.faces + $1.suggestions, -$1.id) } }
            .sorted { $0.map(\.faces).reduce(0, +) > $1.map(\.faces).reduce(0, +) }
    }

    /// Merges each group into its first member. Returns the number of people merged away.
    @discardableResult
    public func mergeDuplicates(_ k: IdentityKind, _ groups: [[PersonSummary]]) throws -> Int {
        var n = 0
        for g in groups where g.count > 1 {
            for o in g.dropFirst() { try merge(k, o.id, into: g[0].id); n += 1 }
        }
        return n
    }

    /// The face / animal shown on a person's / pet's card (default: the one in their best-looking photo).
    public func setCover(_ k: IdentityKind, owner: Int64, region: Int64?) throws {
        try db.run("UPDATE \(k.owners) SET cover_id = ? WHERE id = ?", region, owner)
    }

    public func renameOwner(_ k: IdentityKind, _ id: Int64, to name: String) throws {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        try db.run("UPDATE \(k.owners) SET name = ? WHERE id = ?", n, id)
    }

    /// Hidden copies (identical files, the same picture resized) and the photo kept share their
    /// decisions: each face / animal on a copy is paired with the nearest one of about the same size
    /// on the kept photo, and the pair takes the latest human decision made on either side (name,
    /// ignore, rejection — undoing one included), else the kept photo's, else a name found on a copy
    /// (e.g. imported from Picasa in the copy's folder). Copies get no suggestions of their own.
    /// `since`: only the groups with a decision made since then (after an edit); nil: all of them
    /// (after grouping, after an import). Returns the regions changed.
    @discardableResult
    public func mirrorToCopies(_ k: IdentityKind, since: Double? = nil) throws -> Int {
        struct Region {
            let id: Int64, keep: Int64, media: Int64, copy: Bool, x, y, w, h: Double
            let owner: Int64?, rejected: Int64?, ignored: Bool, human: Bool, at: Double?, suggested: Bool
            var state: [Int64?] { [owner, rejected, ignored ? 1 : 0, human ? 1 : 0] }
        }
        let t = k.table
        let scope = since == nil ? "" : """
             AND coalesce(m.dup_of, m.id) IN (SELECT coalesce(m2.dup_of, m2.id) FROM \(t) t2 JOIN media m2 ON m2.id = t2.media_id WHERE t2.human_at >= ?)
            """
        return try db.transaction {
            let rows = try db.all("""
                SELECT t.id, coalesce(m.dup_of, m.id), m.id, m.dup_of IS NOT NULL, t.x, t.y, t.w, t.h,
                       t.\(k.col), t.\(k.rejected), t.ignored, t.human, t.human_at, t.\(k.suggested) IS NOT NULL
                FROM \(t) t JOIN media m ON m.id = t.media_id
                WHERE (m.dup_of IS NOT NULL OR m.id IN (SELECT dup_of FROM media WHERE dup_of IS NOT NULL))\(scope)
                """, since.map { [$0] } ?? []) {
                Region(id: $0.int(0), keep: $0.int(1), media: $0.int(2), copy: $0.int(3) != 0,
                       x: $0.double(4), y: $0.double(5), w: $0.double(6), h: $0.double(7),
                       owner: $0.optInt(8), rejected: $0.optInt(9), ignored: $0.int(10) != 0, human: $0.int(11) != 0,
                       at: $0.optDouble(12), suggested: $0.int(13) != 0)
            }
            var n = 0
            var written = Set<Int64>()
            // Copies lose any suggestion; the kept photo keeps its own unless it is now named,
            // ignored, or rejected for that name.
            func write(_ r: Region, from s: Region) throws {
                guard r.state != s.state || r.at != s.at || (r.copy && r.suggested) else { return }
                try db.run("""
                    UPDATE \(t) SET \(k.col) = ?, \(k.rejected) = ?, ignored = ?, human = ?, human_at = ?,
                      \(k.suggested) = CASE WHEN ? OR \(k.suggested) IS ? THEN NULL ELSE \(k.suggested) END WHERE id = ?
                    """, s.owner, s.rejected, s.ignored, s.human, s.at, r.copy || s.owner != nil || s.ignored, s.rejected, r.id)
                written.insert(r.id)
                n += 1
            }
            for (_, group) in Dictionary(grouping: rows, by: \.keep) {
                let kept = group.filter { !$0.copy }
                // Pairs: per copy, nearest first, each region used once; same place = centres closer
                // than a quarter of the region's width, widths within 25 %.
                var pairs: [Int64: [Region]] = [:] // kept region → its copies' regions
                for (_, regions) in Dictionary(grouping: group.filter(\.copy), by: \.media) {
                    var cands: [(d: Double, c: Region, o: Region)] = []
                    for c in regions {
                        for o in kept {
                            let size = max(c.w, o.w), d = hypot(c.x + c.w / 2 - o.x - o.w / 2, c.y + c.h / 2 - o.y - o.h / 2)
                            if d < size / 4, abs(c.w - o.w) < size / 4 { cands.append((d, c, o)) }
                        }
                    }
                    var used = Set<Int64>()
                    for p in cands.sorted(by: { $0.d < $1.d }) where !used.contains(p.c.id) && !used.contains(p.o.id) {
                        used.insert(p.c.id); used.insert(p.o.id)
                        pairs[p.o.id, default: []].append(p.c)
                    }
                }
                for o in kept {
                    guard let copies = pairs[o.id] else { continue }
                    let all = [o] + copies
                    // The latest human decision (the kept photo on a tie), else the kept one's, else a copy's name.
                    let source = all.filter(\.human).max { ($0.at ?? 0, $0.copy ? 0 : 1) < ($1.at ?? 0, $1.copy ? 0 : 1) }
                        ?? ((o.owner != nil || o.ignored || o.rejected != nil) ? o : nil)
                        ?? copies.first { $0.owner != nil && !$0.ignored }
                    if let s = source { for r in all where r.id != s.id { try write(r, from: s) } }
                }
                // Copies' regions not rewritten above (no counterpart, no decision): no suggestion either.
                for c in group where c.copy && c.suggested && !written.contains(c.id) {
                    try db.run("UPDATE \(t) SET \(k.suggested) = NULL WHERE id = ?", c.id)
                    n += 1
                }
            }
            return n
        }
    }

    /// Ignores (or restores) unnamed items: ignored ones are never suggested nor grouped with the
    /// unnamed, and only show up in the "Ignored" filter.
    @discardableResult
    public func setIgnored(_ k: IdentityKind, _ ids: [Int64], _ on: Bool) throws -> Int {
        try db.transaction {
            var n = 0
            for id in ids {
                try db.run("UPDATE \(k.table) SET ignored = ?, \(k.suggested) = NULL, human = 1, human_at = ? WHERE id = ? AND \(k.col) IS NULL", on, Date().timeIntervalSince1970, id)
                n += db.changes
            }
            return n
        }
    }

    /// Accepts the current suggestions of a person / pet, for some photos or all of them.
    @discardableResult
    public func confirm(_ k: IdentityKind, owner: Int64, mediaIds: [Int64]? = nil) throws -> Int {
        try db.transaction {
            let now = Date().timeIntervalSince1970
            let set = (k == .face ? "person_id = suggested_person_id, suggested_person_id = NULL, source = \(FaceSource.manual.rawValue)"
                                  : "pet_id = suggested_pet_id, suggested_pet_id = NULL") + ", human = 1, human_at = \(now)"
            guard let mediaIds else {
                try db.run("UPDATE \(k.table) SET \(set) WHERE \(k.col) IS NULL AND \(k.suggested) = ?", owner)
                return db.changes
            }
            var n = 0
            for m in mediaIds {
                try db.run("UPDATE \(k.table) SET \(set) WHERE media_id = ? AND \(k.col) IS NULL AND \(k.suggested) = ?", m, owner)
                n += db.changes
            }
            return n
        }
    }

    /// Takes faces / animals away from a person / pet (a wrong confirmation): they become unnamed
    /// again, remembered as "not this one" so they are not suggested back, as a human decision.
    @discardableResult
    public func unassign(_ k: IdentityKind, _ ids: [Int64]) throws -> Int {
        try db.transaction {
            var n = 0
            for id in ids {
                try db.run("""
                    UPDATE \(k.table) SET \(k.rejected) = \(k.col), \(k.col) = NULL, \(k.suggested) = NULL, human = 1, human_at = ?
                    WHERE id = ? AND \(k.col) IS NOT NULL
                    """, Date().timeIntervalSince1970, id)
                n += db.changes
            }
            return n
        }
    }

    /// The faces / animals of a person / pet in some photos (to act on photos selected in a grid).
    public func regionIds(_ k: IdentityKind, owner: Int64, mediaIds: [Int64]) throws -> [Int64] {
        guard !mediaIds.isEmpty else { return [] }
        return try db.all("SELECT id FROM \(k.table) WHERE \(k.col) = ? AND media_id IN (\(mediaIds.map(String.init).joined(separator: ",")))",
                          [owner]) { $0.int(0) }
    }

    /// Rejects a person's / pet's suggestions in some photos; remembered so they are not proposed again.
    @discardableResult
    public func reject(_ k: IdentityKind, owner: Int64, mediaIds: [Int64]) throws -> Int {
        try db.transaction {
            var n = 0
            for m in mediaIds {
                try db.run("""
                    UPDATE \(k.table) SET \(k.rejected) = \(k.suggested), \(k.suggested) = NULL, human = 1, human_at = \(Date().timeIntervalSince1970)
                    WHERE media_id = ? AND \(k.col) IS NULL AND \(k.suggested) = ?
                    """, m, owner)
                n += db.changes
            }
            return n
        }
    }

    /// One region (face or animal) with its name, for crops and the viewer.
    public func region(_ k: IdentityKind, id: Int64) throws -> FaceRecord? {
        try db.all("""
            SELECT t.id, t.media_id, t.x, t.y, t.w, t.h, t.\(k.col), t.\(k.suggested), p.name, t.ignored, \(k.humanSQL)
            FROM \(k.table) t LEFT JOIN \(k.owners) p ON p.id = coalesce(t.\(k.col), t.\(k.suggested)) WHERE t.id = ?
            """, [id], Self.region).first
    }

    /// Every region of a photo (faces or animals), ignored ones included (flagged).
    public func regions(_ k: IdentityKind, mediaId: Int64) throws -> [FaceRecord] {
        try db.all("""
            SELECT t.id, t.media_id, t.x, t.y, t.w, t.h, t.\(k.col), t.\(k.suggested), p.name, t.ignored, \(k.humanSQL)
            FROM \(k.table) t LEFT JOIN \(k.owners) p ON p.id = coalesce(t.\(k.col), t.\(k.suggested)) WHERE t.media_id = ?
            """, [mediaId], Self.region)
    }

    static func region(_ r: Database.Row) -> FaceRecord {
        FaceRecord(id: r.int(0), mediaId: r.int(1), x: r.double(2), y: r.double(3), w: r.double(4), h: r.double(5),
                   personId: r.optInt(6), suggestedPersonId: r.optInt(7), personName: r.optText(8), ignored: r.int(9) != 0,
                   human: r.int(10) != 0)
    }

    /// Changes when items are added, removed, named, suggested or ignored.
    public func identityToken(_ k: IdentityKind) throws -> [Int64] {
        // Read on the covering index (not the rows and their prints). Face prints arrive with the face
        // analysis of a photo (face_state 0 → 1, tiny partial index); animal prints are made later
        // (petPrints), on a small table, so they are counted directly.
        var token = try db.all("""
            SELECT count(*), coalesce(max(id), 0), count(\(k.col)), count(\(k.suggested)), count(\(k.rejected)), coalesce(sum(ignored), 0)
            FROM \(k.table) INDEXED BY \(k.identIndex)
            """) { [$0.int(0), $0.int(1), $0.int(2), $0.int(3), $0.int(4), $0.int(5)] }.first ?? []
        token.append(k == .face
            ? try db.scalar("SELECT count(*) FROM media WHERE face_state = 0") ?? 0
            : try db.scalar("SELECT count(print) FROM animals") ?? 0)
        return token
    }

    // MARK: - Suggestion engine data

    /// Prints of the named faces / animals, grouped by person / pet: person `i` owns rows
    /// `starts[i] ..< starts[i + 1]` of `examples` (flat, `dim` floats per row). At most `cap` per
    /// person, evenly spread over its faces (by id, roughly by date): the few people named on
    /// thousands of faces would otherwise make most of the work for little gain.
    func namedExamples(_ k: IdentityKind, cap: Int = 1000) throws -> (persons: [Int64], examples: [Float], starts: [Int], dim: Int) {
        var persons: [Int64] = [], examples: [Float] = [], starts: [Int] = []
        var dim = 0
        var current: [[Float]] = []
        func flush() {
            guard !current.isEmpty else { return }
            starts.append(examples.count / dim)
            let n = current.count, keep = min(n, cap)
            for j in 0..<keep { examples.append(contentsOf: current[keep == 1 ? 0 : j * (n - 1) / (keep - 1)]) }
            current.removeAll(keepingCapacity: true)
        }
        try db.query("SELECT \(k.col), print FROM \(k.table) WHERE \(k.col) IS NOT NULL AND print IS NOT NULL AND \(Self.notCopy) ORDER BY \(k.col), id") { r in
            guard let d = r.blob(1) else { return }
            let v = d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            guard !v.isEmpty else { return } // animal crop that gave no print
            if dim == 0 { dim = v.count }
            guard v.count == dim else { return }
            let pid = r.int(0)
            if persons.last != pid { flush(); persons.append(pid) }
            current.append(v)
        }
        flush()
        starts.append(dim > 0 ? examples.count / dim : 0)
        return (persons, examples, starts, dim)
    }

    /// Faces / animals a human said are not someone (rejected suggestion, or taken away), with their print.
    func counterExamples(_ k: IdentityKind, dim: Int) throws -> [(owner: Int64, print: [Float])] {
        try db.all("SELECT \(k.rejected), print FROM \(k.table) WHERE \(k.rejected) IS NOT NULL AND print IS NOT NULL AND \(Self.notCopy)") { r in
            (r.int(0), r.blob(1).map { $0.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) } } ?? [])
        }.filter { $0.print.count == dim }
    }

    func unnamedPrints(_ k: IdentityKind, after: Int64, limit: Int, dim: Int) throws -> [(id: Int64, print: [Float], rejected: Int64?)] {
        try db.all("""
            SELECT id, print, \(k.rejected) FROM \(k.table) WHERE \(k.col) IS NULL AND ignored = 0 AND print IS NOT NULL AND id > ?
              AND \(Self.notCopy) ORDER BY id LIMIT ?
            """, [after, limit]) { r in
            (r.int(0), r.blob(1).map { $0.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) } } ?? [], r.optInt(2))
        }.filter { $0.print.count == dim }
    }

    /// Paging cursor independent of the dim filter (so a batch of wrong-sized prints cannot end the loop early).
    func lastUnnamedPrintId(_ k: IdentityKind, after: Int64, limit: Int) throws -> Int64? {
        try db.scalar("""
            SELECT max(id) FROM (SELECT id FROM \(k.table) WHERE \(k.col) IS NULL AND ignored = 0 AND print IS NOT NULL AND id > ?
              AND \(Self.notCopy) ORDER BY id LIMIT ?)
            """, [after, limit])
    }

    func storeSuggestions(_ k: IdentityKind, _ s: [(Int64, Int64?)]) throws {
        try db.transaction {
            for (id, pid) in s { try db.run("UPDATE \(k.table) SET \(k.suggested) = ? WHERE id = ?", pid, id) }
        }
    }
}
