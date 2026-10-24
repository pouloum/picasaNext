import Foundation
import PicasaFormats

public enum FaceSource: Int, Sendable { case picasa = 0, vision = 1, manual = 2 }

/// Maps Picasa data (per-folder .picasa.ini, global contacts.xml, db3) into the library.
/// Picasa data is read-only input: nothing is ever written back to the media folders.
public enum PicasaImport {
    static func personId(picasaId: String, name: String?, email: String?, db: Database) throws -> Int64 {
        try db.run("INSERT OR IGNORE INTO persons(name, picasa_id, email) VALUES(?, ?, ?)", name ?? "", picasaId, email)
        if let name, !name.isEmpty {
            try db.run("UPDATE persons SET name = ?, email = coalesce(?, email) WHERE picasa_id = ? AND name = ''", name, email, picasaId)
        }
        return try db.scalar("SELECT coalesce(merged_into, id) FROM persons WHERE picasa_id = ?", [picasaId])!
    }

    /// Intersection over union of a stored face box and an ini rectangle.
    static func overlap(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ r: NormalizedRect) -> Double {
        let iw = max(0, min(x + w, r.right) - max(x, r.left)), ih = max(0, min(y + h, r.bottom) - max(y, r.top))
        let inter = iw * ih, union = w * h + r.width * r.height - inter
        return union > 0 ? inter / union : 0
    }

    /// Applies one folder's .picasa.ini. Runs inside the caller's transaction.
    static func apply(ini: PicasaIni, folderId: Int64, db: Database) throws {
        for (id, c) in ini.contacts {
            _ = try personId(picasaId: id, name: c.name, email: c.email, db: db)
        }
        var albumIds: [String: Int64] = [:]
        for a in ini.albums {
            try db.run("""
                INSERT INTO albums(name, token, description) VALUES(?, ?, ?)
                ON CONFLICT(token) DO UPDATE SET name = coalesce(excluded.name, albums.name),
                    description = coalesce(excluded.description, albums.description)
                """, a.name ?? a.token, a.token, a.description)
            albumIds[a.token] = try db.scalar("SELECT id FROM albums WHERE token = ?", [a.token])
        }
        // Section names → media ids. Keys are NFC + lowercased (Windows writes NFC, HFS+ names may be NFD),
        // and Picasa writes `[`/`]` of file names as `(`/`)` in section headers.
        func key(_ s: String) -> String { s.precomposedStringWithCanonicalMapping.lowercased() }
        var byName: [String: Int64] = [:]
        try db.query("SELECT id, name FROM media WHERE folder_id = ?", [folderId]) { r in
            let n = r.text(1)
            byName[key(n.replacingOccurrences(of: "[", with: "(").replacingOccurrences(of: "]", with: ")"))] = r.int(0)
            byName[key(n)] = r.int(0)
        }
        for e in ini.entries {
            guard let mediaId = byName[key(e.fileName)] else { continue }
            let filters = e.values["filters"]
            try db.run("UPDATE media SET star = ?, caption = coalesce(?, caption), rotate = ?, filters = ?, hidden = ? WHERE id = ?",
                       e.starred, e.caption, e.rotation, filters, e.hidden, mediaId)
            // Picasa faces are re-imported as a whole; Vision faces and faces the user named (manual) are kept.
            // …but a Picasa face a human decided on here (ignored, confirmed…) is kept, and matched below.
            try db.run("DELETE FROM faces WHERE media_id = ? AND source = ? AND human = 0", mediaId, FaceSource.picasa.rawValue)
            // Faces found by Vision or named here and written back by export-ini come back in the ini:
            // match them to the existing face (same box) instead of adding a duplicate.
            let existing = try db.all("SELECT id, x, y, w, h, person_id FROM faces WHERE media_id = ?", [mediaId]) {
                (id: $0.int(0), x: $0.double(1), y: $0.double(2), w: $0.double(3), h: $0.double(4), person: $0.optInt(5))
            }
            for f in e.faces {
                let pid: Int64? = f.isUnnamed ? nil : try personId(picasaId: f.contactId, name: nil, email: nil, db: db)
                if let same = existing.first(where: { overlap($0.x, $0.y, $0.w, $0.h, f.rect) > 0.5 }) {
                    if same.person == nil, let pid { try db.run("UPDATE faces SET person_id = ?, suggested_person_id = NULL WHERE id = ?", pid, same.id) }
                    continue
                }
                try db.run("INSERT INTO faces(media_id, x, y, w, h, person_id, source) VALUES(?, ?, ?, ?, ?, ?, ?)",
                           mediaId, f.rect.left, f.rect.top, f.rect.width, f.rect.height, pid, FaceSource.picasa.rawValue)
            }
            for token in e.albumTokens {
                var aid = albumIds[token]
                if aid == nil {
                    // Album defined in another folder's ini (or only in db3): create a placeholder.
                    try db.run("INSERT OR IGNORE INTO albums(name, token) VALUES(?, ?)", token, token)
                    aid = try db.scalar("SELECT id FROM albums WHERE token = ?", [token])
                    albumIds[token] = aid
                }
                if let aid { try db.run("INSERT OR IGNORE INTO album_items(album_id, media_id) VALUES(?, ?)", aid, mediaId) }
            }
            for k in e.keywords {
                try db.run("INSERT OR IGNORE INTO tags(media_id, tag) VALUES(?, ?)", mediaId, k)
            }
        }
    }
}

extension Library {
    /// Imports the global contacts.xml (person names for the contact ids used in .picasa.ini files).
    public func importContacts(at url: URL) throws -> Int {
        let contacts = try PicasaContacts(contentsOf: url)
        try db.transaction {
            for c in contacts.contacts {
                _ = try PicasaImport.personId(picasaId: c.id, name: c.name, email: c.email, db: db)
                if !c.name.isEmpty {
                    try db.run("UPDATE persons SET name = ? WHERE picasa_id = ?", c.name, c.id)
                }
            }
        }
        return contacts.contacts.count
    }
}
