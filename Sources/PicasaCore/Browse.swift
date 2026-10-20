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
        case let .year(y):
            let start = DateComponents(calendar: .current, year: y).date!.timeIntervalSince1970
            let end = DateComponents(calendar: .current, year: y + 1).date!.timeIntervalSince1970
            return ("m.taken_at >= ? AND m.taken_at < ?", [start, end])
        case let .search(q):
            let like = "%" + q.replacingOccurrences(of: "%", with: "") + "%"
            return ("""
                (m.name LIKE ?1 OR f.path LIKE ?1 OR m.caption LIKE ?1 OR m.camera LIKE ?1
                 OR m.id IN (SELECT media_id FROM tags WHERE tag LIKE ?1)
                 OR m.id IN (SELECT fa.media_id FROM faces fa JOIN persons p ON p.id = fa.person_id WHERE p.name LIKE ?1)
                 OR m.id IN (SELECT ai.media_id FROM album_items ai JOIN albums a ON a.id = ai.album_id WHERE a.name LIKE ?1))
                """, [like])
        }
    }

    /// Media ids for a filter, newest first. Ids are cheap (8 bytes each) so even 1M items fit; rows are loaded per page.
    public func mediaIds(_ filter: MediaFilter) throws -> [Int64] {
        var (w, args) = whereClause(filter)
        if case .folder = filter {} else { w = "(\(w)) AND m.hidden = 0" } // Picasa-hidden photos only show in their folder
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
