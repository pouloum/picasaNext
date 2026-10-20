import Foundation

/// Read-side queries used by the viewer. Results are small value types, paged where lists can be huge.
public struct MediaItem: Sendable, Identifiable, Hashable {
    public let id: Int64
    public let path: String
    public let name: String
    public let kind: MediaKind
    public let width: Int?
    public let height: Int?
    public let takenAt: Date?
    public let star: Bool
    public let caption: String?
    public let rotate: Int
    public let duration: Double?
    public let lat: Double?
    public let lon: Double?
    public let camera: String?
    public let size: Int64
    public var url: URL { URL(fileURLWithPath: path) }
}

public struct FolderNode: Sendable, Identifiable, Hashable {
    public let id: Int64
    public let path: String
    public let count: Int
    public let title: String
    public var name: String { (path as NSString).lastPathComponent }
}

public struct PersonSummary: Sendable, Identifiable, Hashable {
    public let id: Int64
    public let name: String
    public let faces: Int
    public let suggestions: Int
    public let coverFaceId: Int64?
}

public struct AlbumSummary: Sendable, Identifiable, Hashable {
    public let id: Int64
    public let name: String
    public let count: Int
}

public struct FaceRecord: Sendable, Identifiable, Hashable {
    public let id: Int64
    public let mediaId: Int64
    public let x, y, w, h: Double
    public let personId: Int64?
    public let suggestedPersonId: Int64?
    public let personName: String?
}

/// A structured search criterion (a search token in the UI). Several are combined with AND.
public enum SearchTerm: Sendable, Hashable, Identifiable {
    case person(Int64, String)
    /// A Vision scene label or a Picasa keyword.
    case label(String)
    case album(Int64, String)

    public var id: String {
        switch self {
        case let .person(i, _): "p\(i)"
        case let .label(l): "l\(l)"
        case let .album(i, _): "a\(i)"
        }
    }
    public var title: String {
        switch self {
        case let .person(_, n), let .album(_, n): n
        case let .label(l): LabelSummary.display(l)
        }
    }
}

public struct LabelSummary: Sendable, Identifiable, Hashable {
    public var id: String { label }
    public let label: String
    public let count: Int
    /// Best-looking photo carrying the label (highest aesthetics score).
    public let coverMediaId: Int64
    public var title: String { Self.display(label) }
    /// Vision identifiers look like `musical_instrument`.
    public static func display(_ l: String) -> String {
        let s = l.replacingOccurrences(of: "_", with: " ")
        return s.prefix(1).uppercased() + s.dropFirst()
    }
}

/// What the grid shows.
public enum MediaFilter: Sendable, Hashable {
    case all
    case folder(Int64)
    case person(Int64)
    case personSuggestions(Int64)
    case album(Int64)
    case starred
    case videos
    case search(String)
    case year(Int)
    /// Top 10 % by Vision aesthetics score, screenshots/documents excluded.
    case best
    /// Photos that have near-duplicates or exact duplicates, grouped together.
    case similar
    case animals
    /// Screenshots, receipts, documents (Vision "utility" images).
    case utility
    /// Small images set aside as probable thumbnails of other apps.
    case ignored
    /// Burst sequences (≥ 3 shots ≤ 2 s apart, same camera and folder).
    case bursts
    /// One label or keyword.
    case label(String)
    /// Search: every term AND every word of the free text must match.
    case query([SearchTerm], String)
}

extension Library {
    static let mediaColumns = """
        m.id, f.path || '/' || m.name, m.name, m.kind, m.width, m.height, m.taken_at, m.star, m.caption,
        m.rotate, m.duration, m.lat, m.lon, m.camera, m.size
        """

    static func item(_ r: Database.Row) -> MediaItem {
        MediaItem(id: r.int(0), path: r.text(1), name: r.text(2), kind: MediaKind(rawValue: Int(r.int(3))) ?? .image,
                  width: r.optInt(4).map(Int.init), height: r.optInt(5).map(Int.init),
                  takenAt: r.optDouble(6).map { Date(timeIntervalSince1970: $0) }, star: r.int(7) != 0,
                  caption: r.optText(8), rotate: Int(r.int(9)), duration: r.optDouble(10),
                  lat: r.optDouble(11), lon: r.optDouble(12), camera: r.optText(13), size: r.int(14))
    }

    func whereClause(_ f: MediaFilter) -> (String, [SQLBindable]) {
        switch f {
        case .all: return ("1", [])
        case let .folder(id): return ("m.folder_id = ?", [id])
        case let .person(id): return ("m.id IN (SELECT media_id FROM faces WHERE person_id = ?)", [id])
        case let .personSuggestions(id): return ("m.id IN (SELECT media_id FROM faces WHERE person_id IS NULL AND suggested_person_id = ?)", [id])
        case let .album(id): return ("m.id IN (SELECT media_id FROM album_items WHERE album_id = ?)", [id])
        case .starred: return ("m.star = 1", [])
        case .videos: return ("m.kind = 1", [])
        case .best:
            return ("""
                m.utility = 0 AND m.aesthetic IS NOT NULL AND m.aesthetic >= coalesce((
                  SELECT aesthetic FROM media WHERE utility = 0 AND aesthetic IS NOT NULL ORDER BY aesthetic DESC
                  LIMIT 1 OFFSET (SELECT count(*) / 10 FROM media WHERE utility = 0 AND aesthetic IS NOT NULL)), -1)
                """, [])
        case .similar: return ("m.id IN (SELECT media_id FROM similar)", [])
        case .animals: return ("m.id IN (SELECT media_id FROM animals)", [])
        case .utility: return ("m.utility = 1", [])
        case .ignored: return ("m.ignored = 1", [])
        case .bursts: return ("m.id IN (SELECT media_id FROM bursts)", [])
        case let .label(l): return labelClause(l)
        case let .query(terms, text):
            var parts: [String] = [], args: [SQLBindable] = []
            for t in terms {
                let (c, a) = termClause(t); parts.append(c); args += a
            }
            for word in text.split(whereSeparator: \.isWhitespace) {
                let (c, a) = textClause(String(word)); parts.append(c); args += a
            }
            return (parts.isEmpty ? "1" : parts.joined(separator: " AND "), args)
        case let .year(y):
            let start = DateComponents(calendar: .current, year: y).date!.timeIntervalSince1970
            let end = DateComponents(calendar: .current, year: y + 1).date!.timeIntervalSince1970
            return ("m.taken_at >= ? AND m.taken_at < ?", [start, end])
        case let .search(q): return textClause(q)
        }
    }

    func labelClause(_ l: String) -> (String, [SQLBindable]) {
        ("(m.id IN (SELECT media_id FROM labels WHERE label = ?) OR m.id IN (SELECT media_id FROM tags WHERE tag = ? COLLATE NOCASE))", [l, l])
    }

    func termClause(_ t: SearchTerm) -> (String, [SQLBindable]) {
        switch t {
        case let .person(id, _): ("m.id IN (SELECT media_id FROM faces WHERE person_id = ?)", [id])
        case let .label(l): labelClause(l)
        case let .album(id, _): ("m.id IN (SELECT media_id FROM album_items WHERE album_id = ?)", [id])
        }
    }

    /// Free text, matched (LIKE) against names, folders, captions, cameras, keywords, labels, animals, people, albums.
    func textClause(_ q: String) -> (String, [SQLBindable]) {
        let like = "%" + q.replacingOccurrences(of: "%", with: "") + "%"
        let clause = """
            (m.name LIKE ? OR f.path LIKE ? OR m.caption LIKE ? OR m.camera LIKE ?
             OR m.id IN (SELECT media_id FROM tags WHERE tag LIKE ?)
             OR m.id IN (SELECT media_id FROM labels WHERE label LIKE ?)
             OR m.id IN (SELECT media_id FROM animals WHERE species LIKE ?)
             OR m.id IN (SELECT fa.media_id FROM faces fa JOIN persons p ON p.id = fa.person_id WHERE p.name LIKE ?)
             OR m.id IN (SELECT ai.media_id FROM album_items ai JOIN albums a ON a.id = ai.album_id WHERE a.name LIKE ?))
            """
        return (clause, Array(repeating: like, count: 9))
    }

    /// Every label and keyword with its photo count and the best-looking photo as cover, most used first.
    public func labelSummaries() throws -> [LabelSummary] {
        try db.all("""
            SELECT label, n, media_id FROM (
              SELECT l.label, l.media_id, count(*) OVER (PARTITION BY l.label) n,
                     row_number() OVER (PARTITION BY l.label ORDER BY m.aesthetic DESC NULLS LAST, m.taken_at DESC) rn
              FROM (SELECT media_id, label FROM labels UNION SELECT media_id, tag FROM tags) l
              JOIN media m ON m.id = l.media_id
              WHERE m.ignored = 0 AND m.hidden = 0)
            WHERE rn = 1 ORDER BY n DESC, label
            """) { LabelSummary(label: $0.text(0), count: Int($0.int(1)), coverMediaId: $0.int(2)) }
    }

    /// Everything that can become a search token, most used first: named people, labels/keywords, albums.
    /// Small enough (a few thousand entries) to keep in memory for instant autocompletion.
    public func searchVocabulary() throws -> [SearchTerm] {
        var out: [SearchTerm] = []
        out += try db.all("""
            SELECT p.id, p.name FROM persons p WHERE p.name != ''
            ORDER BY (SELECT count(*) FROM faces WHERE person_id = p.id) DESC
            """) { .person($0.int(0), $0.text(1)) }
        out += try db.all("""
            SELECT label FROM (SELECT label, count(*) n FROM labels GROUP BY label UNION ALL SELECT tag, count(*) FROM tags GROUP BY tag)
            GROUP BY label ORDER BY sum(n) DESC
            """) { .label($0.text(0)) }
        out += try db.all("SELECT id, name FROM albums ORDER BY name") { .album($0.int(0), $0.text(1)) }
        return out
    }

    /// Search suggestions for what the user is typing: people, labels/keywords, albums (prefix matches first).
    public func suggestions(for text: String, limit: Int = 12) throws -> [SearchTerm] {
        let q = text.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        let prefix = q.replacingOccurrences(of: "%", with: "") + "%", inner = "%" + prefix
        // Vision labels use underscores ("musical_instrument"): let "musical inst" match too.
        let (lp, li) = (prefix.replacingOccurrences(of: " ", with: "_"), inner.replacingOccurrences(of: " ", with: "_"))
        var out: [SearchTerm] = []
        out += try db.all("""
            SELECT p.id, p.name FROM persons p WHERE p.name != '' AND p.name LIKE ?
            ORDER BY p.name NOT LIKE ?, (SELECT count(*) FROM faces WHERE person_id = p.id) DESC LIMIT 5
            """, [inner, prefix]) { .person($0.int(0), $0.text(1)) }
        out += try db.all("""
            SELECT label FROM (SELECT label, count(*) n FROM labels WHERE label LIKE ? GROUP BY label
                               UNION ALL SELECT tag, count(*) FROM tags WHERE tag LIKE ? GROUP BY tag)
            GROUP BY label ORDER BY label NOT LIKE ?, sum(n) DESC LIMIT 6
            """, [li, inner, lp]) { .label($0.text(0)) }
        out += try db.all("SELECT id, name FROM albums WHERE name LIKE ? ORDER BY name NOT LIKE ?, name LIMIT 4", [inner, prefix]) {
            .album($0.int(0), $0.text(1))
        }
        return Array(out.prefix(limit))
    }

    /// Media ids for a filter, newest first. Ids are cheap (8 bytes each) so even 1M items fit; rows are loaded per page.
    public func mediaIds(_ filter: MediaFilter) throws -> [Int64] {
        var (w, args) = whereClause(filter)
        if case .folder = filter {} else { w = "(\(w)) AND m.hidden = 0" } // Picasa-hidden photos only show in their folder
        if case .ignored = filter {} else { w = "(\(w)) AND m.ignored = 0" }
        if case .bursts = filter {
            // Each burst in shooting order; bursts newest first.
            return try db.all("""
                SELECT m.id FROM media m JOIN folders f ON f.id = m.folder_id JOIN bursts b ON b.media_id = m.id
                WHERE \(w) ORDER BY (SELECT max(m2.taken_at) FROM bursts b2 JOIN media m2 ON m2.id = b2.media_id WHERE b2.burst_id = b.burst_id) DESC,
                  b.burst_id, b.position
                """, args) { $0.int(0) }
        }
        if case .similar = filter {
            // Group members next to each other, best-looking first; groups newest first.
            return try db.all("""
                SELECT m.id FROM media m JOIN folders f ON f.id = m.folder_id JOIN similar s ON s.media_id = m.id
                WHERE \(w) ORDER BY (SELECT max(m2.taken_at) FROM similar s2 JOIN media m2 ON m2.id = s2.media_id WHERE s2.group_id = s.group_id) DESC,
                  s.group_id, m.aesthetic DESC, m.size DESC
                """, args) { $0.int(0) }
        }
        return try db.all("SELECT m.id FROM media m JOIN folders f ON f.id = m.folder_id WHERE \(w) ORDER BY m.taken_at DESC, m.id DESC", args) { $0.int(0) }
    }

    public func items(ids: [Int64]) throws -> [MediaItem] {
        guard !ids.isEmpty else { return [] }
        let list = ids.map(String.init).joined(separator: ",")
        let rows = try db.all("SELECT \(Self.mediaColumns) FROM media m JOIN folders f ON f.id = m.folder_id WHERE m.id IN (\(list))", [], Self.item)
        let byId = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        return ids.compactMap { byId[$0] }
    }

    public func folders() throws -> [FolderNode] {
        try db.all("""
            SELECT f.id, f.path, count(m.id) FROM folders f JOIN media m ON m.folder_id = f.id
            GROUP BY f.id ORDER BY max(m.taken_at) DESC
            """) { r in
            let path = r.text(1)
            return FolderNode(id: r.int(0), path: path, count: Int(r.int(2)), title: (path as NSString).lastPathComponent)
        }
    }

    public func years() throws -> [(year: Int, count: Int)] {
        try db.all("SELECT CAST(strftime('%Y', taken_at, 'unixepoch', 'localtime') AS INTEGER) y, count(*) FROM media WHERE taken_at IS NOT NULL GROUP BY y ORDER BY y DESC") {
            (Int($0.int(0)), Int($0.int(1)))
        }
    }

    public func persons() throws -> [PersonSummary] {
        try db.all("""
            SELECT p.id, p.name,
              (SELECT count(*) FROM faces WHERE person_id = p.id),
              (SELECT count(*) FROM faces WHERE person_id IS NULL AND suggested_person_id = p.id),
              (SELECT id FROM faces WHERE person_id = p.id ORDER BY w DESC LIMIT 1)
            FROM persons p WHERE p.name != '' ORDER BY 3 DESC
            """) { PersonSummary(id: $0.int(0), name: $0.text(1), faces: Int($0.int(2)), suggestions: Int($0.int(3)), coverFaceId: $0.optInt(4)) }
    }

    public func albums() throws -> [AlbumSummary] {
        try db.all("SELECT a.id, a.name, count(ai.media_id) FROM albums a LEFT JOIN album_items ai ON ai.album_id = a.id GROUP BY a.id ORDER BY a.name") {
            AlbumSummary(id: $0.int(0), name: $0.text(1), count: Int($0.int(2)))
        }
    }

    public func faces(mediaId: Int64) throws -> [FaceRecord] {
        try db.all("""
            SELECT fa.id, fa.media_id, fa.x, fa.y, fa.w, fa.h, fa.person_id, fa.suggested_person_id, p.name
            FROM faces fa LEFT JOIN persons p ON p.id = coalesce(fa.person_id, fa.suggested_person_id) WHERE fa.media_id = ?
            """, [mediaId]) {
            FaceRecord(id: $0.int(0), mediaId: $0.int(1), x: $0.double(2), y: $0.double(3), w: $0.double(4), h: $0.double(5),
                       personId: $0.optInt(6), suggestedPersonId: $0.optInt(7), personName: $0.optText(8))
        }
    }

    public func face(id: Int64) throws -> FaceRecord? {
        try db.all("SELECT id, media_id, x, y, w, h, person_id, suggested_person_id, NULL FROM faces WHERE id = ?", [id]) {
            FaceRecord(id: $0.int(0), mediaId: $0.int(1), x: $0.double(2), y: $0.double(3), w: $0.double(4), h: $0.double(5),
                       personId: $0.optInt(6), suggestedPersonId: $0.optInt(7), personName: nil)
        }.first
    }

    public func tags(mediaId: Int64) throws -> [String] {
        try db.all("SELECT tag FROM tags WHERE media_id = ? ORDER BY tag", [mediaId]) { $0.text(0) }
    }

    /// What Vision found in the image, for the info panel.
    public struct SceneInfo: Sendable {
        public var labels: [String] = []
        public var animals: [String] = []
        public var aesthetic: Double?
        public var utility = false
        public var similarCount = 0
        public var burstCount = 0
    }

    public func scene(mediaId: Int64) throws -> SceneInfo {
        var s = SceneInfo()
        s.labels = try db.all("SELECT label FROM labels WHERE media_id = ? ORDER BY confidence DESC", [mediaId]) { $0.text(0) }
        s.animals = try db.all("SELECT species FROM animals WHERE media_id = ?", [mediaId]) { $0.text(0) }
        try db.query("SELECT aesthetic, utility FROM media WHERE id = ?", [mediaId]) { s.aesthetic = $0.optDouble(0); s.utility = $0.int(1) != 0 }
        s.similarCount = max(0, try similarGroup(of: mediaId).count - 1)
        s.burstCount = Int(try db.scalar("SELECT count(*) FROM bursts WHERE burst_id = (SELECT burst_id FROM bursts WHERE media_id = ?)", [mediaId]) ?? 0)
        return s
    }

    // MARK: - Edits (library only; media files are never modified)

    public func setStar(_ ids: [Int64], _ on: Bool) throws {
        try db.transaction { for id in ids { try db.run("UPDATE media SET star = ? WHERE id = ?", on, id) } }
    }

    public func setCaption(_ id: Int64, _ caption: String?) throws {
        try db.run("UPDATE media SET caption = ? WHERE id = ?", caption, id)
    }

    /// Names a face; creates the person if needed. Returns the person id.
    @discardableResult
    public func nameFace(_ faceId: Int64, name: String) throws -> Int64 {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        var pid = try db.scalar("SELECT id FROM persons WHERE name = ? COLLATE NOCASE", [trimmed])
        if pid == nil { pid = try db.run("INSERT INTO persons(name) VALUES(?)", trimmed) }
        // Named by the user: `manual`, so a later .picasa.ini re-import does not replace it.
        try db.run("UPDATE faces SET person_id = ?, suggested_person_id = NULL, source = ? WHERE id = ?", pid!, FaceSource.manual.rawValue, faceId)
        return pid!
    }

    /// Accepts all current suggestions for a person.
    public func confirmSuggestions(personId: Int64) throws -> Int {
        try db.run("UPDATE faces SET person_id = suggested_person_id, suggested_person_id = NULL WHERE person_id IS NULL AND suggested_person_id = ?", personId)
        return db.changes
    }

    public func rejectSuggestion(faceId: Int64) throws {
        try db.run("UPDATE faces SET rejected_person_id = suggested_person_id, suggested_person_id = NULL WHERE id = ?", faceId)
    }
}
