import Foundation
import PicasaFormats

/// Writes the library's edits back into each folder's `.picasa.ini` (picasa-cli export-ini), so the
/// information also lives next to the photos and stays readable by Picasa and by a later re-scan.
/// Existing keys this library does not manage (filters, rotate, hidden, unknown ones) are kept.
public struct IniExportReport: Sendable, CustomStringConvertible {
    public var folders = 0, changed = 0, written = 0, entries = 0
    public var failed: [(path: String, error: String)] = []
    public var dryRun = false
    public var description: String {
        "export-ini: \(folders) folders checked · \(changed) to update" + (dryRun ? " (dry run, nothing written)" : " · \(written) written")
            + " · \(entries) photo entries" + (failed.isEmpty ? "" : " · \(failed.count) failed")
    }
}

extension Library {
    /// Exports stars, captions, named faces (+ [Contacts2]), keywords and album membership.
    /// The previous file is kept as `.picasa.ini.bak`. `only` limits the export to folders under a path.
    public func exportIni(dryRun: Bool = false, only: String? = nil, progress: ProgressHandler? = nil) throws -> IniExportReport {
        var rep = IniExportReport()
        rep.dryRun = dryRun
        let fm = FileManager.default
        // Folders with something to write, or with an ini to keep in sync (a star removed in the app).
        let folders = try db.all("""
            SELECT f.id, f.path FROM folders f WHERE f.ini_mtime > 0
               OR EXISTS (SELECT 1 FROM media m WHERE m.folder_id = f.id AND (m.star = 1 OR m.caption IS NOT NULL
                    OR m.id IN (SELECT media_id FROM faces WHERE person_id IS NOT NULL)
                    OR m.id IN (SELECT media_id FROM tags) OR m.id IN (SELECT media_id FROM album_items)))
            ORDER BY f.path
            """) { ($0.int(0), $0.text(1)) }
            .filter { only == nil || $0.1 == only! || $0.1.hasPrefix(only!.hasSuffix("/") ? only! : only! + "/") }
        for (i, (folderId, path)) in folders.enumerated() {
            progress?(LibraryProgress(stage: "export-ini", done: i + 1, total: folders.count, current: path))
            guard fm.fileExists(atPath: path) else { continue }
            rep.folders += 1
            let url = URL(fileURLWithPath: path).appendingPathComponent(".picasa.ini")
            let legacy = URL(fileURLWithPath: path).appendingPathComponent("Picasa.ini")
            let source = fm.fileExists(atPath: url.path) ? url : (fm.fileExists(atPath: legacy.path) ? legacy : nil)
            let old = source.flatMap { try? Data(contentsOf: $0) }
            var ini = old.map { PicasaIni(data: $0) } ?? PicasaIni()
            let n = try fill(&ini, folderId: folderId)
            ini.removeEmptySections()
            let text = ini.serialized()
            let oldText = old.map { PicasaIni(data: $0).serialized() }
            // Nothing to say and no file yet, or no change: leave the folder alone.
            if (old == nil && n == 0) || text == oldText { continue }
            rep.changed += 1
            rep.entries += n
            if dryRun { continue }
            do {
                if let old { try Self.replace(URL(fileURLWithPath: path).appendingPathComponent(".picasa.ini.bak"), with: old) }
                try Self.replace(url, with: Data(text.utf8))
                // The scanner re-reads an ini only when its mtime moved: record ours, it matches the library.
                let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970 ?? 0
                try db.run("UPDATE folders SET ini_mtime = ? WHERE id = ?", mtime, folderId)
                rep.written += 1
            } catch {
                rep.failed.append((path, "\(error.localizedDescription)"))
            }
        }
        return rep
    }

    /// Atomic write through a temporary file in the same folder (Foundation's `.atomic` goes through a
    /// system temporary directory, which fails on some volumes and in sandboxes).
    static func replace(_ url: URL, with data: Data) throws {
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).picasanext-tmp")
        try data.write(to: tmp)
        guard rename(tmp.path, url.path) == 0 else {
            let e = errno
            try? FileManager.default.removeItem(at: tmp)
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(e))])
        }
    }

    /// Updates the managed keys of every file of a folder. Returns the number of files with data.
    func fill(_ ini: inout PicasaIni, folderId: Int64) throws -> Int {
        struct Entry { var star = false; var caption: String?; var faces: [String] = []; var tags: [String] = []; var albums: [String] = [] }
        var entries: [Int64: Entry] = [:]
        var names: [Int64: String] = [:]
        try db.query("SELECT id, name, star, caption FROM media WHERE folder_id = ?", [folderId]) { r in
            names[r.int(0)] = r.text(1)
            entries[r.int(0)] = Entry(star: r.int(2) != 0, caption: r.optText(3))
        }
        var contacts: [String: String] = [:]
        try db.query("""
            SELECT fa.media_id, fa.x, fa.y, fa.w, fa.h, fa.person_id, fa.source FROM faces fa JOIN media m ON m.id = fa.media_id
            WHERE m.folder_id = ? AND (fa.person_id IS NOT NULL OR fa.source = ?) ORDER BY fa.id
            """, [folderId, FaceSource.picasa.rawValue]) { r in
            var contact = "ffffffffffffffff"
            if let pid = r.optInt(5), let c = try? contactId(person: pid) { contact = c.id; contacts[c.id] = c.line }
            let rect = NormalizedRect(left: r.double(1), top: r.double(2), right: r.double(1) + r.double(3), bottom: r.double(2) + r.double(4))
            entries[r.int(0)]?.faces.append("rect64(\(Rect64.encode(rect))),\(contact)")
        }
        try db.query("SELECT t.media_id, t.tag FROM tags t JOIN media m ON m.id = t.media_id WHERE m.folder_id = ? ORDER BY t.tag", [folderId]) { r in
            entries[r.int(0)]?.tags.append(r.text(1))
        }
        var albums: [String: String] = [:]
        try db.query("""
            SELECT ai.media_id, a.token, a.name FROM album_items ai JOIN albums a ON a.id = ai.album_id JOIN media m ON m.id = ai.media_id
            WHERE m.folder_id = ? AND a.token IS NOT NULL ORDER BY a.token
            """, [folderId]) { r in
            entries[r.int(0)]?.albums.append(r.text(1))
            albums[r.text(1)] = r.text(2)
        }
        var withData = 0
        for (id, e) in entries {
            let section = PicasaIni.sectionName(forFile: names[id]!)
            ini.set(section, "star", e.star ? "yes" : nil)
            ini.set(section, "caption", e.caption)
            ini.set(section, "faces", e.faces.isEmpty ? nil : e.faces.joined(separator: ";"))
            ini.set(section, "keywords", e.tags.isEmpty ? nil : e.tags.joined(separator: ","))
            ini.set(section, "albums", e.albums.isEmpty ? nil : e.albums.joined(separator: ","))
            if e.star || e.caption != nil || !e.faces.isEmpty || !e.tags.isEmpty || !e.albums.isEmpty { withData += 1 }
        }
        for (id, line) in contacts { ini.set("Contacts2", id, line) }
        for (token, name) in albums {
            ini.set(".album:\(token)", "name", name)
            ini.set(".album:\(token)", "token", token)
        }
        return withData
    }

    /// The person's Picasa contact id, created (and stored) for people named only in this app.
    func contactId(person: Int64) throws -> (id: String, line: String) {
        var picasaId: String?, name = "", email: String?
        try db.query("SELECT picasa_id, name, email FROM persons WHERE id = ?", [person]) { r in
            picasaId = r.optText(0); name = r.text(1); email = r.optText(2)
        }
        if picasaId == nil || picasaId!.hasPrefix("db3:") {
            // 16 hex digits like Picasa's ids, derived from the person id so it is stable.
            var h: UInt64 = 0xcbf2_9ce4_8422_2325
            for b in "picasanext:\(person)".utf8 { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
            if h == .max { h -= 1 }
            picasaId = String(format: "%016llx", h)
            try db.run("UPDATE persons SET picasa_id = ? WHERE id = ?", picasaId!, person)
        }
        return (picasaId!, "\(name);\(email ?? "");")
    }
}
