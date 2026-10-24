import Foundation
import PicasaFormats

extension FaceSource {
    /// Faces from db3 are stored as `manual` so that re-parsing a `.picasa.ini` (which replaces
    /// `picasa`-sourced faces) keeps them.
    static let picasaDB = FaceSource.manual
}

public struct DB3ImportReport: Sendable, CustomStringConvertible {
    public var entries = 0, matched = 0, unmatched = 0, ambiguous = 0
    public var captions = 0, stars = 0, faces = 0, namedFaces = 0, persons = 0, albums = 0, thumbnails = 0
    public var watchedFolders: [String] = []
    public var columnErrors: [String] = []
    public var description: String {
        var s = """
        thumbindex entries \(entries): matched \(matched), not in library \(unmatched), ambiguous \(ambiguous)
        captions \(captions) · stars \(stars) · faces \(faces) (named \(namedFaces)) · persons \(persons) · albums \(albums) · thumbnails reused \(thumbnails)
        """
        if !watchedFolders.isEmpty { s += "\nPicasa watched folders: " + watchedFolders.joined(separator: ", ") }
        if !columnErrors.isEmpty { s += "\nunreadable columns: " + columnErrors.joined(separator: ", ") }
        return s
    }
}

extension Library {
    /// Imports a Picasa `db3` folder into media already scanned into the library.
    ///
    /// The db3 stores absolute paths from the machine Picasa ran on (often Windows, `C:\…`), so
    /// files are matched to the library by trailing path components (`folder/file`, then longer
    /// suffixes to break ties) and by file size, rather than by absolute path. Run `scan` first.
    public func importDB3(at dir: URL, reuseThumbnails: Bool = true, progress: ProgressHandler? = nil) throws -> DB3ImportReport {
        let db3 = try PicasaDB3(directory: dir)
        var rep = DB3ImportReport()
        rep.columnErrors = db3.images.errors + (db3.albums?.errors ?? [])
        rep.watchedFolders = Self.pathList(dir.appendingPathComponent("watchedfolders.txt"))
        let entries = db3.index.entries
        rep.entries = entries.indices.filter { !entries[$0].isDirectory && !entries[$0].name.isEmpty }.count

        // Library index by lowercase "folder/file" (NFC, as HFS+ names may be NFD).
        var bySuffix: [String: [(id: Int64, path: String, size: Int64)]] = [:]
        try db.query("SELECT m.id, f.path, m.name, m.size FROM media m JOIN folders f ON f.id = m.folder_id") { r in
            let folder = r.text(1), name = r.text(2)
            let key = ((folder as NSString).lastPathComponent + "/" + name).precomposedStringWithCanonicalMapping.lowercased()
            bySuffix[key, default: []].append((r.int(0), (folder + "/" + name).precomposedStringWithCanonicalMapping.lowercased(), r.int(3)))
        }
        func components(_ p: String) -> [String] {
            p.precomposedStringWithCanonicalMapping.split(whereSeparator: { $0 == "\\" || $0 == "/" }).map { $0.lowercased() }
        }
        /// `size` (from thumbindex, 32-bit) rejects same-named files that are different photos,
        /// e.g. a deleted D:\2008\100CANON\IMG_0001.JPG vs the library's 2012/100CANON/IMG_0001.JPG.
        func resolve(_ p: String, size: UInt32? = nil) -> (id: Int64?, ambiguous: Bool) {
            let c = components(p)
            guard c.count >= 2, var cands = bySuffix[c.suffix(2).joined(separator: "/")] else { return (nil, false) }
            if let size, size > 0 { cands = cands.filter { UInt32(truncatingIfNeeded: $0.size) == size } }
            if cands.isEmpty { return (nil, false) }
            if cands.count == 1 { return (cands[0].id, false) }
            guard c.count >= 3 else { return (nil, true) }
            for n in 3...c.count {
                let suffix = "/" + c.suffix(n).joined(separator: "/")
                let hits = cands.filter { $0.path.hasSuffix(suffix) }
                if hits.count == 1 { return (hits[0].id, false) }
                if hits.isEmpty { break }
            }
            return (nil, true)
        }

        var mediaForRow: [Int: Int64] = [:]
        for (i, e) in entries.enumerated() where !e.isDirectory && !e.name.isEmpty {
            guard let p = db3.index.path(of: i) else { rep.unmatched += 1; continue }
            let r = resolve(p, size: e.size)
            if let id = r.id { mediaForRow[i] = id } else if r.ambiguous { rep.ambiguous += 1 } else { rep.unmatched += 1 }
        }
        rep.matched = mediaForRow.count

        // People: imagedata_personalbumid is an albumdata row index (0 = nobody).
        let persons = db3.persons
        let personByRow = Dictionary(persons.map { ($0.row, $0) }, uniquingKeysWith: { a, _ in a })
        let thumbCache = reuseThumbnails ? (try? ThumbCache(directory: dir, set: "bigthumbs")) ?? (try? ThumbCache(directory: dir, set: "thumbs")) : nil

        try db.transaction {
            var personIds: [Int: Int64] = [:]
            func personId(_ p: PicasaDB3.Person) throws -> Int64 {
                if let id = personIds[p.row] { return id }
                let id: Int64
                if let c = p.contactId {
                    id = try PicasaImport.personId(picasaId: c, name: p.name, email: nil, db: db)
                } else if !p.name.isEmpty, let existing = try db.scalar("SELECT coalesce(merged_into, id) FROM persons WHERE name = ? COLLATE NOCASE ORDER BY merged_into IS NOT NULL LIMIT 1", [p.name]) {
                    id = existing
                } else {
                    id = try PicasaImport.personId(picasaId: "db3:\(p.row)", name: p.name, email: nil, db: db)
                }
                personIds[p.row] = id
                return id
            }
            for p in persons where !p.name.isEmpty { _ = try personId(p) }
            rep.persons = persons.count

            for a in db3.userAlbums {
                try db.run("INSERT OR IGNORE INTO albums(name, token, created) VALUES(?, ?, ?)", a.name, a.uid, a.date?.timeIntervalSince1970)
                rep.albums += 1
            }

            var done = 0
            for (row, mediaId) in mediaForRow {
                if let caption = db3.images["caption", row]?.string {
                    try db.run("UPDATE media SET caption = coalesce(caption, ?) WHERE id = ?", caption, mediaId)
                    rep.captions += 1
                }
                if let f = db3.images["filters", row]?.string {
                    try db.run("UPDATE media SET filters = coalesce(filters, ?) WHERE id = ?", f, mediaId)
                }
                if let lat = db3.images["lat", row]?.double, let lon = db3.images["long", row]?.double, lat != 0 || lon != 0 {
                    try db.run("UPDATE media SET lat = coalesce(lat, ?), lon = coalesce(lon, ?) WHERE id = ?", lat, lon, mediaId)
                }
                if let cache = thumbCache, let jpeg = cache.jpeg(row),
                   (try db.scalar("SELECT thumb_state FROM media WHERE id = ?", [mediaId])) == 0 {
                    let dest = thumbs.url(id: mediaId)
                    try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if (try? jpeg.write(to: dest)) != nil {
                        try db.run("UPDATE media SET thumb_state = 1 WHERE id = ?", mediaId)
                        rep.thumbnails += 1
                    }
                }
                done += 1
                if done % 2000 == 0 { progress?(LibraryProgress(stage: "db3", done: done, total: mediaForRow.count, current: nil)) }
            }

            // Stars: starlist.txt lists the paths of the `]star` album (ini `star=yes` is applied at scan).
            for line in Self.pathList(dir.appendingPathComponent("starlist.txt")) {
                if let id = resolve(line).id {
                    try db.run("UPDATE media SET star = 1 WHERE id = ?", id)
                    rep.stars += 1
                }
            }

            // Faces: one virtual entry per face instance, pointing at its real image.
            for (v, e) in entries.enumerated() where e.isVirtual {
                guard let real = e.parent, let mediaId = mediaForRow[real],
                      let raw = db3.images["facerect", v]?.uint, raw > 1,
                      let rect = Rect64.decode(String(raw, radix: 16)) else { continue }
                var pid: Int64?
                if let pa = db3.images["personalbumid", v]?.int, pa > 0, let p = personByRow[Int(pa)] {
                    pid = try personId(p)
                }
                // Skip faces already known from .picasa.ini (same rectangle), but fill a missing name.
                let existing = try db.all("SELECT id, x, y, w, person_id FROM faces WHERE media_id = ?", [mediaId]) {
                    (id: $0.int(0), x: $0.double(1), y: $0.double(2), w: $0.double(3), person: $0.optInt(4))
                }
                if let dup = existing.first(where: { abs($0.x - rect.left) < 0.01 && abs($0.y - rect.top) < 0.01 && abs($0.w - rect.width) < 0.01 }) {
                    if dup.person == nil, let pid { try db.run("UPDATE faces SET person_id = ? WHERE id = ?", pid, dup.id) }
                    continue
                }
                try db.run("INSERT INTO faces(media_id, x, y, w, h, person_id, source) VALUES(?, ?, ?, ?, ?, ?, ?)",
                           mediaId, rect.left, rect.top, rect.width, rect.height, pid, FaceSource.picasaDB.rawValue)
                rep.faces += 1
                if pid != nil { rep.namedFaces += 1 }
            }
        }
        return rep
    }

    /// Plain path-per-line files of the db3 folder (watchedfolders.txt, starlist.txt, scanlist.txt).
    static func pathList(_ url: URL) -> [String] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        return text.split(whereSeparator: \.isNewline).map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}
