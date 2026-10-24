import Foundation
import PicasaFormats

public enum MediaTypes {
    public static let image: Set<String> = ["jpg", "jpeg", "jpe", "png", "gif", "bmp", "tif", "tiff", "heic", "heif", "webp", "psd", "jp2", "avif"]
    public static let raw: Set<String> = ["cr2", "cr3", "crw", "nef", "nrw", "arw", "srf", "sr2", "orf", "rw2", "raf", "dng", "pef", "srw", "x3f", "erf", "mrw", "kdc", "dcr", "3fr", "iiq", "rwl"]
    public static let video: Set<String> = ["mov", "mp4", "m4v", "avi", "mpg", "mpeg", "mts", "m2ts", "3gp", "3g2", "wmv", "mkv", "asf", "dv", "mod", "tod", "webm", "flv"]

    public static func kind(forExtension ext: String) -> MediaKind? {
        let e = ext.lowercased()
        if image.contains(e) { return .image }
        if raw.contains(e) { return .raw }
        if video.contains(e) { return .video }
        return nil
    }
}

/// Progress reported by long-running stages.
public struct LibraryProgress: Sendable {
    public var stage: String
    public var done: Int
    public var total: Int?
    public var current: String?
}

public typealias ProgressHandler = @Sendable (LibraryProgress) -> Void

/// Walks media roots and keeps the `folders` / `media` tables in sync with the disk.
/// Only file-system metadata is read here (no file contents), so a re-scan of 2 TB is
/// bounded by directory listing speed, not by data size.
public struct Scanner: Sendable {
    public let library: Library
    /// Concurrent directory listings. Spinning disks prefer low values, SSD/NAS higher.
    public var concurrency: Int
    public var skipHiddenFolders = true

    public init(library: Library, concurrency: Int = 8) {
        self.library = library
        self.concurrency = max(1, concurrency)
    }

    struct Entry: Sendable { let name: String; let kind: MediaKind; let size: Int64; let mtime: Double }

    /// Folders not to descend into: names (case-insensitive) and absolute path prefixes.
    struct Exclusions: Sendable {
        var names: Set<String>
        var prefixes: [String]
        func excludes(_ url: URL) -> Bool {
            names.contains(url.lastPathComponent.lowercased())
                || prefixes.contains { url.path == $0 || url.path.hasPrefix($0 + "/") }
        }
    }
    struct FolderListing: Sendable {
        let path: String; let mtime: Double; let entries: [Entry]; let subfolders: [URL]
        let ini: (url: URL, mtime: Double)?
    }

    public struct Result: Sendable { public var folders = 0, added = 0, updated = 0, removed = 0, iniParsed = 0 }

    public func scan(root: URL, progress: ProgressHandler? = nil) async throws -> Result {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: root.path])
        }
        let rootId = try await library.addRoot(root)
        let user = try await library.excludes()
        let exclusions = Exclusions(
            names: Library.defaultExcludedNames.union(user.filter { !$0.hasPrefix("/") }.map { $0.lowercased() }),
            prefixes: user.filter { $0.hasPrefix("/") }.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        var result = Result()
        var seenFolders = Set<String>()
        var unreadable: [String] = []
        var queue = [root.standardizedFileURL]

        // An unmounted volume can leave an empty /Volumes/X stub: refuse to treat it as "everything deleted".
        if let rootListing = Self.list(root.standardizedFileURL, skipHidden: skipHiddenFolders, excluded: exclusions),
           rootListing.entries.isEmpty, rootListing.subfolders.isEmpty, try await library.mediaCount(rootId: rootId) > 0 {
            throw CocoaError(.fileReadUnknown, userInfo: [NSLocalizedDescriptionKey:
                "\(root.path) is empty but the library holds media for it (disk not mounted?). Nothing was changed."])
        }

        try await withThrowingTaskGroup(of: (String, FolderListing?).self) { group in
            var inFlight = 0
            func launch() {
                while inFlight < concurrency, let next = queue.popLast() {
                    inFlight += 1
                    group.addTask { [skipHiddenFolders] in (next.path, Self.list(next, skipHidden: skipHiddenFolders, excluded: exclusions)) }
                }
            }
            launch()
            while let (path, listing) = try await group.next() {
                inFlight -= 1
                // An unreadable folder is kept as-is rather than pruned (e.g. a permission glitch).
                seenFolders.insert(path)
                if listing == nil { unreadable.append(path + "/") }
                if let listing {
                    queue.append(contentsOf: listing.subfolders)
                    let r = try await library.apply(listing: listing, rootId: rootId)
                    result.folders += 1
                    result.added += r.added; result.updated += r.updated; result.removed += r.removed
                    if r.iniParsed { result.iniParsed += 1 }
                    progress?(LibraryProgress(stage: "scan", done: result.folders, total: nil, current: listing.path))
                }
                launch()
            }
        }
        result.removed += try await library.pruneFolders(rootId: rootId, keeping: seenFolders, unreadable: unreadable)
        return result
    }

    /// Excluded folders are not listed, so anything indexed under them before is pruned from the library.
    static func list(_ dir: URL, skipHidden: Bool, excluded: Exclusions) -> FolderListing? {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey, .isPackageKey]
        guard let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: []) else { return nil }
        let dirMtime = (try? dir.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate?.timeIntervalSince1970) ?? 0
        var entries: [Entry] = []
        var subs: [URL] = []
        var ini: (URL, Double)?
        for u in items {
            let name = u.lastPathComponent
            // A metadata error mid-listing (disk glitch/unplug) makes the whole folder "unreadable"
            // so nothing in it gets pruned.
            guard let v = try? u.resourceValues(forKeys: Set(keys)) else { return nil }
            if v.isSymbolicLink == true { continue }
            if v.isDirectory == true {
                if v.isPackage == true { continue } // .photoslibrary, .app, …
                if name.hasPrefix(".") && (skipHidden || name == ".picasaoriginals") { continue }
                if name == "$RECYCLE.BIN" || name == "System Volume Information" || name == "@eaDir" { continue }
                if excluded.excludes(u) { continue }
                subs.append(u)
                continue
            }
            let lower = name.lowercased()
            if lower == ".picasa.ini" || lower == "picasa.ini" {
                // .picasa.ini wins over the legacy Picasa.ini.
                if ini == nil || lower == ".picasa.ini" {
                    ini = (u, v.contentModificationDate?.timeIntervalSince1970 ?? 0)
                }
                continue
            }
            if name.hasPrefix("._") { continue } // AppleDouble
            guard let kind = MediaTypes.kind(forExtension: u.pathExtension) else { continue }
            entries.append(Entry(name: name, kind: kind, size: Int64(v.fileSize ?? 0),
                                 mtime: v.contentModificationDate?.timeIntervalSince1970 ?? 0))
        }
        return FolderListing(path: dir.path, mtime: dirMtime, entries: entries, subfolders: subs,
                             ini: ini.map { (url: $0.0, mtime: $0.1) })
    }
}

extension Library {
    struct ApplyResult { var added = 0, updated = 0, removed = 0, iniParsed = false }

    func apply(listing: Scanner.FolderListing, rootId: Int64) throws -> ApplyResult {
        var r = ApplyResult()
        // Parse .picasa.ini only if it changed since the last scan.
        let prevIni = try db.scalar("SELECT CAST(ini_mtime*1000 AS INTEGER) FROM folders WHERE path = ?", [listing.path])
        var ini: PicasaIni?
        if let i = listing.ini, prevIni != Int64(i.mtime * 1000) {
            ini = try? PicasaIni(contentsOf: i.url)
        }
        try db.transaction {
            try db.run("""
                INSERT INTO folders(root_id, path, mtime, scanned_at) VALUES(?, ?, ?, ?)
                ON CONFLICT(path) DO UPDATE SET mtime = excluded.mtime, scanned_at = excluded.scanned_at
                """, rootId, listing.path, listing.mtime, Date().timeIntervalSince1970)
            let folderId = try db.scalar("SELECT id FROM folders WHERE path = ?", [listing.path])!

            var existing: [String: (id: Int64, size: Int64, mtime: Double)] = [:]
            try db.query("SELECT id, name, size, mtime FROM media WHERE folder_id = ?", [folderId]) {
                existing[$0.text(1)] = ($0.int(0), $0.int(2), $0.double(3))
            }
            for e in listing.entries {
                if let old = existing.removeValue(forKey: e.name) {
                    if old.size != e.size || abs(old.mtime - e.mtime) > 0.001 {
                        // Content changed: redo metadata/thumbnail/faces.
                        let na = e.kind == .video ? 3 : 0
                        try db.run("UPDATE media SET size=?, mtime=?, meta_state=0, thumb_state=0, face_state=?, analysis_state=?, print=NULL, aesthetic=NULL, utility=0 WHERE id=?",
                                   e.size, e.mtime, na, na, old.id)
                        try db.run("DELETE FROM labels WHERE media_id = ?", old.id)
                        // Named or ignored animals are kept, like named faces.
                        try db.run("DELETE FROM animals WHERE media_id = ? AND human = 0", old.id)
                        try db.run("UPDATE animals SET print = NULL WHERE media_id = ?", old.id)
                        try db.run("DELETE FROM faces WHERE media_id = ? AND source = ? AND human = 0", old.id, FaceSource.vision.rawValue)
                        try db.run("UPDATE faces SET print = NULL WHERE media_id = ?", old.id)
                        r.updated += 1
                    }
                } else {
                    // face/analysis state 3 = not applicable (videos are not analysed).
                    let na = e.kind == .video ? 3 : 0
                    try db.run("INSERT INTO media(folder_id, name, kind, size, mtime, face_state, analysis_state) VALUES(?, ?, ?, ?, ?, ?, ?)",
                               folderId, e.name, e.kind.rawValue, e.size, e.mtime, na, na)
                    r.added += 1
                }
            }
            for gone in existing.values {
                try db.run("DELETE FROM media WHERE id = ?", gone.id)
                thumbs.remove(id: gone.id)
                r.removed += 1
            }
            if let ini, let i = listing.ini {
                try PicasaImport.apply(ini: ini, folderId: folderId, db: db)
                try db.run("UPDATE folders SET ini_mtime = ? WHERE id = ?", i.mtime, folderId)
                r.iniParsed = true
            }
        }
        return r
    }

    func mediaCount(rootId: Int64) throws -> Int64 {
        try db.scalar("SELECT count(*) FROM media m JOIN folders f ON f.id = m.folder_id WHERE f.root_id = ?", [rootId]) ?? 0
    }

    func pruneFolders(rootId: Int64, keeping seen: Set<String>, unreadable: [String]) throws -> Int {
        var stale: [Int64] = []
        try db.query("SELECT id, path FROM folders WHERE root_id = ?", [rootId]) {
            let path = $0.text(1)
            if !seen.contains(path) && !unreadable.contains(where: { path.hasPrefix($0) }) { stale.append($0.int(0)) }
        }
        var removed = 0
        try db.transaction {
            for id in stale {
                let ids = try db.all("SELECT id FROM media WHERE folder_id = ?", [id]) { $0.int(0) }
                ids.forEach { thumbs.remove(id: $0) }
                removed += ids.count
                try db.run("DELETE FROM folders WHERE id = ?", id)
            }
        }
        return removed
    }
}
