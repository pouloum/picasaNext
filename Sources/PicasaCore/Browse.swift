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
    /// Where `takenAt` comes from; anything but `.metadata` is an estimate.
    public var dateSource: DateSource? = nil
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
    public var ignored = false
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

/// A geotagged photo, as plotted on the map.
public struct GeoPoint: Sendable, Hashable {
    public let id: Int64
    public let lat: Double
    public let lon: Double
    /// Used to pick a cluster's cover (best-looking photo).
    public let score: Double
    /// Year taken (0 = unknown), for the map's year filter.
    public var year = 0
    public init(id: Int64, lat: Double, lon: Double, score: Double, year: Int = 0) {
        self.id = id; self.lat = lat; self.lon = lon; self.score = score; self.year = year
    }
}

/// Photos close together on screen, drawn as one pin.
public struct GeoCluster: Sendable, Identifiable, Hashable {
    public var id: String
    public let lat: Double
    public let lon: Double
    public let count: Int
    public let coverId: Int64
    public let ids: [Int64]

    /// Groups `points` inside the visible box into a grid of about `cells` cells across the larger span.
    /// Pure and fast (one pass), so it can run on every map move even with 100k+ points.
    public static func cluster(_ points: [GeoPoint], latRange: ClosedRange<Double>, lonRange: ClosedRange<Double>, cells: Double = 10) -> [GeoCluster] {
        let size = max(latRange.upperBound - latRange.lowerBound, lonRange.upperBound - lonRange.lowerBound, 1e-6) / cells
        struct Acc { var lat = 0.0, lon = 0.0, n = 0, best = -Double.infinity, cover: Int64 = 0, ids: [Int64] = [] }
        struct Cell: Hashable { let y, x: Int }
        var acc: [Cell: Acc] = [:]
        for p in points where latRange.contains(p.lat) && lonRange.contains(p.lon) {
            let key = Cell(y: Int((p.lat / size).rounded(.down)), x: Int((p.lon / size).rounded(.down)))
            // Mutated in place: copying the cell out and back made every append copy its id list
            // (quadratic, a freeze on cells of thousands of photos).
            acc[key, default: Acc()].lat += p.lat
            acc[key]!.lon += p.lon
            acc[key]!.n += 1
            acc[key]!.ids.append(p.id)
            if p.score > acc[key]!.best { acc[key]!.best = p.score; acc[key]!.cover = p.id }
        }
        return acc.map { k, a in
            GeoCluster(id: "\(k.y):\(k.x)", lat: a.lat / Double(a.n), lon: a.lon / Double(a.n), count: a.n, coverId: a.cover, ids: a.ids)
        }.sorted { $0.count > $1.count }
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
    /// Most recently indexed (Library ▸ Last indexed), newest first.
    case recent
    /// Identical files: the copy kept and its copies (Discover ▸ Duplicates).
    case duplicates
    /// Dates estimated from a file or folder name, or the file date (Discover ▸ Estimated dates).
    case estimatedDates
    case pet(Int64)
    case petSuggestions(Int64)
    /// People / Animals "Photos" view: photos with named, unnamed and/or ignored faces (or animals).
    case identities(IdentityKind, named: Bool, unnamed: Bool, ignored: Bool, year: Int?)
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
        m.rotate, m.duration, m.lat, m.lon, m.camera, m.size, m.date_source
        """

    static func item(_ r: Database.Row) -> MediaItem {
        MediaItem(id: r.int(0), path: r.text(1), name: r.text(2), kind: MediaKind(rawValue: Int(r.int(3))) ?? .image,
                  width: r.optInt(4).map(Int.init), height: r.optInt(5).map(Int.init),
                  takenAt: r.optDouble(6).map { Date(timeIntervalSince1970: $0) }, star: r.int(7) != 0,
                  caption: r.optText(8), rotate: Int(r.int(9)), duration: r.optDouble(10),
                  lat: r.optDouble(11), lon: r.optDouble(12), camera: r.optText(13), size: r.int(14),
                  dateSource: r.optInt(15).flatMap { DateSource(rawValue: Int($0)) })
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
        case .recent: return ("m.indexed_at IS NOT NULL", [])
        case .duplicates: return ("(m.dup_of IS NOT NULL OR m.id IN (SELECT group_id FROM group_info WHERE kind = 0))", [])
        case .estimatedDates: return ("m.date_source IN (1, 2, 3)", [])
        case let .pet(id): return ("m.id IN (SELECT media_id FROM animals WHERE pet_id = ?)", [id])
        case let .petSuggestions(id): return ("m.id IN (SELECT media_id FROM animals WHERE pet_id IS NULL AND suggested_pet_id = ?)", [id])
        case let .identities(k, named, unnamed, ignored, year):
            var kinds: [String] = []
            if named { kinds.append("(t.\(k.col) IS NOT NULL AND t.ignored = 0)") }
            if unnamed { kinds.append("(t.\(k.col) IS NULL AND t.ignored = 0)") }
            if ignored { kinds.append("t.ignored = 1") }
            guard !kinds.isEmpty else { return ("0", []) }
            let (yc, ya) = yearClause(year)
            return ("m.id IN (SELECT t.media_id FROM \(k.table) t WHERE \(kinds.joined(separator: " OR ")))" + yc, ya)
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
        case .year(0):
            // No date: none at all, or one in the future (a camera clock never set).
            return ("(m.taken_at IS NULL OR m.taken_at > ?)", [Date().timeIntervalSince1970 + 2 * 86400])
        case let .year(y):
            let (start, end) = Self.yearRange(y)
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
             OR m.id IN (SELECT a.media_id FROM animals a JOIN pets p ON p.id = a.pet_id WHERE p.name LIKE ?)
             OR m.id IN (SELECT fa.media_id FROM faces fa JOIN persons p ON p.id = fa.person_id WHERE p.name LIKE ?)
             OR m.id IN (SELECT ai.media_id FROM album_items ai JOIN albums a ON a.id = ai.album_id WHERE a.name LIKE ?)
             OR (m.lat IS NOT NULL AND printf('%.2f:%.2f', round(m.lat * 50) / 50.0, round(m.lon * 50) / 50.0) IN
                 (SELECT cell FROM geo_names WHERE locality LIKE ? OR area LIKE ? OR country LIKE ?)))
            """
        return (clause, Array(repeating: like, count: 13))
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
            SELECT p.id, p.name FROM persons p WHERE p.name != '' AND p.merged_into IS NULL
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
            SELECT p.id, p.name FROM persons p WHERE p.name != '' AND p.merged_into IS NULL AND p.name LIKE ?
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
    public func mediaIds(_ filter: MediaFilter) throws -> [Int64] { try mediaIdsAndYears(filter).map(\.id) }

    /// Same as `mediaIds`, with each item's year (0 = undated), for year sections in the grids.
    public func mediaIdsAndYears(_ filter: MediaFilter) throws -> [(id: Int64, year: Int)] {
        var (w, args) = whereClause(filter)
        let row: (Database.Row) -> (id: Int64, year: Int) = { ($0.int(0), Int($0.int(1))) }
        // Dates in the future (a camera clock never set: 2037…) count as no date: section "No date", at the end.
        let future = Int(Date().timeIntervalSince1970) + 2 * 86400
        let year = "CASE WHEN m.taken_at IS NULL OR m.taken_at > \(future) THEN 0 ELSE CAST(strftime('%Y', m.taken_at, 'unixepoch', 'localtime') AS INTEGER) END"
        if case .folder = filter {} else { w = "(\(w)) AND m.hidden = 0" } // Picasa-hidden photos only show in their folder
        // Only indexed items (metadata read and thumbnail made): the rest appear as the indexer gets to them.
        if case .ignored = filter {} else { w = "(\(w)) AND m.ignored = 0 AND m.meta_state = 1 AND m.thumb_state = 1" }
        // Copies of identical files are hidden, except in their folder and in Duplicates.
        switch filter { case .folder, .duplicates, .ignored: break; default: w += " AND m.dup_of IS NULL" }
        // Grouped views: the precomputed groups, flattened (the app shows one cover per group).
        let grouped: GroupKind? = { switch filter { case .bursts: .burst; case .similar: .similar; case .duplicates: .duplicates; default: nil } }()
        if let k = grouped { return try mediaGroups(k).flatMap(\.members).map { ($0, 0) } }
        if case .recent = filter {
            return try db.all("""
                SELECT m.id, \(year) FROM media m JOIN folders f ON f.id = m.folder_id WHERE \(w)
                ORDER BY m.indexed_at DESC, m.id DESC LIMIT 2000
                """, args, row)
        }
        if case .similar = filter {
            // Group members next to each other, best-looking first; groups newest first.
            return try db.all("""
                SELECT m.id, \(year) FROM media m JOIN folders f ON f.id = m.folder_id JOIN similar s ON s.media_id = m.id
                WHERE \(w) ORDER BY (SELECT max(m2.taken_at) FROM similar s2 JOIN media m2 ON m2.id = s2.media_id WHERE s2.group_id = s.group_id) DESC,
                  s.group_id, m.aesthetic DESC, m.size DESC
                """, args, row)
        }
        return try db.all("SELECT m.id, \(year) FROM media m JOIN folders f ON f.id = m.folder_id WHERE \(w) "
                          + "ORDER BY (m.taken_at IS NULL OR m.taken_at > \(future)), m.taken_at DESC, m.id DESC", args, row)
    }

    /// Every geotagged, visible photo or video (newest first).
    public func geoPoints() throws -> [GeoPoint] {
        try db.all("""
            SELECT id, lat, lon, coalesce(aesthetic, 0), coalesce(CAST(strftime('%Y', taken_at, 'unixepoch', 'localtime') AS INTEGER), 0)
            FROM media
            WHERE lat IS NOT NULL AND lon IS NOT NULL AND (lat != 0 OR lon != 0) AND ignored = 0 AND hidden = 0 AND dup_of IS NULL
              AND meta_state = 1 AND thumb_state = 1
            ORDER BY taken_at DESC
            """) { GeoPoint(id: $0.int(0), lat: $0.double(1), lon: $0.double(2), score: $0.double(3), year: Int($0.int(4))) }
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
            WHERE m.meta_state = 1 AND m.thumb_state = 1 AND m.ignored = 0
            GROUP BY f.id ORDER BY max(m.taken_at) DESC
            """) { r in
            let path = r.text(1)
            return FolderNode(id: r.int(0), path: path, count: Int(r.int(2)), title: (path as NSString).lastPathComponent)
        }
    }

    /// Years with photos, newest first, then year 0 = "No date" (none, or in the future) if any.
    public func years() throws -> [(year: Int, count: Int)] {
        let future = Date().timeIntervalSince1970 + 2 * 86400
        let visible = "meta_state = 1 AND thumb_state = 1 AND ignored = 0 AND hidden = 0 AND dup_of IS NULL"
        var out: [(year: Int, count: Int)] = try db.all("""
            SELECT CAST(strftime('%Y', taken_at, 'unixepoch', 'localtime') AS INTEGER) y, count(*) FROM media
            WHERE taken_at IS NOT NULL AND taken_at <= ? AND \(visible) GROUP BY y ORDER BY y DESC
            """, [future]) { (Int($0.int(0)), Int($0.int(1))) }
        let undated = Int(try db.scalar("SELECT count(*) FROM media WHERE (taken_at IS NULL OR taken_at > ?) AND \(visible)", [future]) ?? 0)
        if undated > 0 { out.append((0, undated)) }
        return out
    }


    public func persons() throws -> [PersonSummary] { try owners(.face) }

    public func albums() throws -> [AlbumSummary] {
        try db.all("SELECT a.id, a.name, count(ai.media_id) FROM albums a LEFT JOIN album_items ai ON ai.album_id = a.id GROUP BY a.id ORDER BY a.name") {
            AlbumSummary(id: $0.int(0), name: $0.text(1), count: Int($0.int(2)))
        }
    }

    public func faces(mediaId: Int64) throws -> [FaceRecord] { try regions(.face, mediaId: mediaId) }

    public func face(id: Int64) throws -> FaceRecord? { try region(.face, id: id) }

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

    /// Turns photos by quarter turns (+1 = 90° clockwise), like Picasa's rotate (files untouched).
    public func rotate(_ ids: [Int64], by quarters: Int) throws {
        try db.transaction {
            for id in ids { try db.run("UPDATE media SET rotate = ((rotate + ?) % 4 + 4) % 4 WHERE id = ?", quarters, id) }
        }
    }

    /// Photos shown turned (Picasa or here): id → quarter turns clockwise.
    public func rotations() throws -> [Int64: Int] {
        Dictionary(uniqueKeysWithValues: try db.all("SELECT id, rotate FROM media WHERE rotate % 4 != 0") { ($0.int(0), Int($0.int(1)) % 4) })
    }

    /// Sets the date a photo was taken by hand (date_source = manual; kept by later index runs).
    public func setTakenDate(_ ids: [Int64], _ date: Date) throws {
        try db.transaction {
            for id in ids { try db.run("UPDATE media SET taken_at = ?, date_source = 4 WHERE id = ?", date.timeIntervalSince1970, id) }
        }
    }

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
        var pid = try db.scalar("SELECT coalesce(merged_into, id) FROM persons WHERE name = ? COLLATE NOCASE ORDER BY merged_into IS NOT NULL LIMIT 1", [trimmed])
        if pid == nil { pid = try db.run("INSERT INTO persons(name) VALUES(?)", trimmed) }
        // Named by the user: `manual`, so a later .picasa.ini re-import does not replace it.
        try db.run("UPDATE faces SET person_id = ?, suggested_person_id = NULL, source = ?, human = 1, human_at = ? WHERE id = ?", pid!, FaceSource.manual.rawValue, Date().timeIntervalSince1970, faceId)
        return pid!
    }

    /// Accepts all current suggestions for a person.
    public func confirmSuggestions(personId: Int64) throws -> Int { try confirm(.face, owner: personId) }

    public func rejectSuggestion(faceId: Int64) throws {
        try db.run("UPDATE faces SET rejected_person_id = suggested_person_id, suggested_person_id = NULL, human = 1, human_at = ? WHERE id = ?", Date().timeIntervalSince1970, faceId)
    }

    /// Confirms a person's suggested faces in the given photos (user action → `manual`).
    @discardableResult
    public func confirmSuggestions(personId: Int64, mediaIds: [Int64]) throws -> Int { try confirm(.face, owner: personId, mediaIds: mediaIds) }

    /// Rejects a person's suggested faces in the given photos; remembered so they are not proposed again.
    @discardableResult
    public func rejectSuggestions(personId: Int64, mediaIds: [Int64]) throws -> Int { try reject(.face, owner: personId, mediaIds: mediaIds) }

    /// Confirms one suggested face.
    public func confirmSuggestion(faceId: Int64) throws {
        try db.run("""
            UPDATE faces SET person_id = suggested_person_id, suggested_person_id = NULL, source = ?, human = 1, human_at = ?
            WHERE id = ? AND suggested_person_id IS NOT NULL
            """, FaceSource.manual.rawValue, Date().timeIntervalSince1970, faceId)
    }
}
