import Foundation

public enum MediaKind: Int, Sendable { case image = 0, video = 1, raw = 2 }

/// A photo library: an index database plus a thumbnail cache, kept apart from the media
/// (the media folders are only ever read, never written).
public actor Library {
    public let root: URL
    let db: Database
    public nonisolated let thumbs: ThumbnailStore

    public static let schemaVersion: Int64 = 4

    /// Default location. Deliberately not named like the source folder, so deleting one is never
    /// mistaken for deleting the other.
    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PicasaNext Library", isDirectory: true)
    }

    public init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        db = try Database(path: root.appendingPathComponent("library.sqlite").path)
        thumbs = try ThumbnailStore(root: root.appendingPathComponent("thumbs"))
        try Self.migrate(db)
    }

    static func migrate(_ db: Database) throws {
        let v = try db.scalar("PRAGMA user_version") ?? 0
        guard v < schemaVersion else { return }
        if v < 1 { try createV1(db) }
        if v < 2 { try migrateV2(db) }
        if v < 3 { try migrateV3(db) }
        if v < 4 { try migrateV4(db) }
        try db.exec("PRAGMA user_version = \(schemaVersion)")
    }

    /// v2: whole-image analysis (labels, animals, image print, aesthetics) and similar-photo groups.
    static func migrateV2(_ db: Database) throws {
        try db.transaction {
            try db.exec("""
            ALTER TABLE media ADD COLUMN analysis_state INTEGER NOT NULL DEFAULT 0;
            ALTER TABLE media ADD COLUMN print BLOB;
            ALTER TABLE media ADD COLUMN aesthetic REAL;
            ALTER TABLE media ADD COLUMN utility INTEGER NOT NULL DEFAULT 0;
            UPDATE media SET analysis_state = 3 WHERE kind = 1;
            CREATE INDEX IF NOT EXISTS media_analysis_pending ON media(analysis_state) WHERE analysis_state = 0;
            CREATE INDEX IF NOT EXISTS media_aesthetic ON media(aesthetic) WHERE aesthetic IS NOT NULL;
            CREATE TABLE IF NOT EXISTS labels(
                media_id INTEGER NOT NULL REFERENCES media(id) ON DELETE CASCADE,
                label TEXT NOT NULL, confidence REAL NOT NULL, PRIMARY KEY(media_id, label));
            CREATE INDEX IF NOT EXISTS labels_label ON labels(label);
            CREATE TABLE IF NOT EXISTS animals(
                id INTEGER PRIMARY KEY, media_id INTEGER NOT NULL REFERENCES media(id) ON DELETE CASCADE,
                species TEXT NOT NULL, confidence REAL NOT NULL, x REAL NOT NULL, y REAL NOT NULL, w REAL NOT NULL, h REAL NOT NULL);
            CREATE INDEX IF NOT EXISTS animals_media ON animals(media_id);
            CREATE TABLE IF NOT EXISTS similar(
                media_id INTEGER PRIMARY KEY REFERENCES media(id) ON DELETE CASCADE,
                group_id INTEGER NOT NULL, exact INTEGER NOT NULL DEFAULT 0);
            CREATE INDEX IF NOT EXISTS similar_group ON similar(group_id);
            """)
        }
    }

    /// v3: folder exclusions and "ignored" small images (thumbnails made by other apps).
    static func migrateV3(_ db: Database) throws {
        try db.transaction {
            try db.exec("""
            CREATE TABLE IF NOT EXISTS excludes(pattern TEXT PRIMARY KEY, added_at REAL NOT NULL);
            ALTER TABLE media ADD COLUMN ignored INTEGER NOT NULL DEFAULT 0;
            ALTER TABLE media ADD COLUMN exif INTEGER NOT NULL DEFAULT 0;
            CREATE INDEX IF NOT EXISTS media_ignored ON media(ignored) WHERE ignored = 1;
            -- Small images were read before the camera flag existed: re-read just those.
            UPDATE media SET meta_state = 0 WHERE kind = 0 AND max(coalesce(width, 0), coalesce(height, 0)) < 1024;
            """)
        }
    }

    /// v4: persisted settings (similarity threshold…) and burst sequences.
    static func migrateV4(_ db: Database) throws {
        try db.exec("""
        CREATE TABLE IF NOT EXISTS settings(key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS bursts(
            media_id INTEGER PRIMARY KEY REFERENCES media(id) ON DELETE CASCADE,
            burst_id INTEGER NOT NULL, position INTEGER NOT NULL);
        CREATE INDEX IF NOT EXISTS bursts_burst ON bursts(burst_id);
        """)
    }

    // MARK: - Settings

    public func setting(_ key: String) throws -> String? {
        try db.all("SELECT value FROM settings WHERE key = ?", [key]) { $0.text(0) }.first
    }

    public func setSetting(_ key: String, _ value: String) throws {
        try db.run("INSERT INTO settings(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", key, value)
    }

    /// Near-duplicate threshold (cosine of Vision image prints), remembered per library.
    public static let defaultSimilarThreshold: Float = 0.97

    public func similarThreshold() throws -> Float {
        try setting("similar.threshold").flatMap(Float.init) ?? Self.defaultSimilarThreshold
    }

    public func setSimilarThreshold(_ t: Float) throws {
        try setSetting("similar.threshold", String(t))
    }

    // MARK: - Folder exclusions

    /// Folder names always skipped (caches and previews written by other apps; Picasa skipped `thumbs` too).
    public static let defaultExcludedNames: Set<String> = ["thumbs", "thumbnails", "previews", "cache", "caches"]

    /// User exclusions: a folder name (matched case-insensitively anywhere) or an absolute path prefix.
    public func excludes() throws -> [String] {
        try db.all("SELECT pattern FROM excludes ORDER BY pattern") { $0.text(0) }
    }

    public func addExclude(_ pattern: String) throws {
        try db.run("INSERT OR IGNORE INTO excludes(pattern, added_at) VALUES(?, ?)", pattern, Date().timeIntervalSince1970)
    }

    public func removeExclude(_ pattern: String) throws -> Bool {
        try db.run("DELETE FROM excludes WHERE pattern = ?", pattern)
        return db.changes > 0
    }

    static func createV1(_ db: Database) throws {
        try db.exec("""
        CREATE TABLE IF NOT EXISTS roots(
            id INTEGER PRIMARY KEY, path TEXT NOT NULL UNIQUE, added_at REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS folders(
            id INTEGER PRIMARY KEY, root_id INTEGER NOT NULL REFERENCES roots(id) ON DELETE CASCADE,
            path TEXT NOT NULL UNIQUE, mtime REAL NOT NULL DEFAULT 0, ini_mtime REAL NOT NULL DEFAULT 0,
            scanned_at REAL NOT NULL DEFAULT 0, hidden INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE IF NOT EXISTS media(
            id INTEGER PRIMARY KEY, folder_id INTEGER NOT NULL REFERENCES folders(id) ON DELETE CASCADE,
            name TEXT NOT NULL, kind INTEGER NOT NULL, size INTEGER NOT NULL, mtime REAL NOT NULL,
            width INTEGER, height INTEGER, orientation INTEGER, taken_at REAL,
            lat REAL, lon REAL, camera TEXT, duration REAL,
            -- *_state: 0 pending, 1 done, 2 failed (undecodable), 3 skipped/unreadable (retried next run)
            quick_hash TEXT, meta_state INTEGER NOT NULL DEFAULT 0, thumb_state INTEGER NOT NULL DEFAULT 0,
            face_state INTEGER NOT NULL DEFAULT 0,
            star INTEGER NOT NULL DEFAULT 0, caption TEXT, rotate INTEGER NOT NULL DEFAULT 0,
            filters TEXT, hidden INTEGER NOT NULL DEFAULT 0,
            UNIQUE(folder_id, name));
        CREATE INDEX IF NOT EXISTS media_taken ON media(taken_at);
        CREATE INDEX IF NOT EXISTS media_hash ON media(quick_hash);
        CREATE INDEX IF NOT EXISTS media_meta_pending ON media(meta_state) WHERE meta_state = 0;
        CREATE INDEX IF NOT EXISTS media_thumb_pending ON media(thumb_state) WHERE thumb_state = 0;
        CREATE INDEX IF NOT EXISTS media_face_pending ON media(face_state) WHERE face_state = 0;
        CREATE INDEX IF NOT EXISTS media_star ON media(star) WHERE star = 1;
        CREATE INDEX IF NOT EXISTS media_folder ON media(folder_id);
        CREATE TABLE IF NOT EXISTS persons(
            id INTEGER PRIMARY KEY, name TEXT NOT NULL, picasa_id TEXT UNIQUE, email TEXT);
        CREATE TABLE IF NOT EXISTS faces(
            id INTEGER PRIMARY KEY, media_id INTEGER NOT NULL REFERENCES media(id) ON DELETE CASCADE,
            x REAL NOT NULL, y REAL NOT NULL, w REAL NOT NULL, h REAL NOT NULL,
            person_id INTEGER REFERENCES persons(id) ON DELETE SET NULL,
            source INTEGER NOT NULL, confidence REAL, print BLOB, suggested_person_id INTEGER,
            rejected_person_id INTEGER);
        CREATE INDEX IF NOT EXISTS faces_media ON faces(media_id);
        CREATE INDEX IF NOT EXISTS faces_person ON faces(person_id);
        CREATE INDEX IF NOT EXISTS faces_suggested ON faces(suggested_person_id) WHERE person_id IS NULL;
        CREATE TABLE IF NOT EXISTS albums(
            id INTEGER PRIMARY KEY, name TEXT NOT NULL, token TEXT UNIQUE, created REAL, description TEXT);
        CREATE TABLE IF NOT EXISTS album_items(
            album_id INTEGER NOT NULL REFERENCES albums(id) ON DELETE CASCADE,
            media_id INTEGER NOT NULL REFERENCES media(id) ON DELETE CASCADE,
            PRIMARY KEY(album_id, media_id));
        CREATE INDEX IF NOT EXISTS album_items_media ON album_items(media_id);
        CREATE TABLE IF NOT EXISTS tags(
            media_id INTEGER NOT NULL REFERENCES media(id) ON DELETE CASCADE, tag TEXT NOT NULL,
            PRIMARY KEY(media_id, tag));
        CREATE INDEX IF NOT EXISTS tags_tag ON tags(tag);
        """)
    }

    // MARK: - Roots

    public func addRoot(_ url: URL) throws -> Int64 {
        let path = url.standardizedFileURL.path
        try db.run("INSERT OR IGNORE INTO roots(path, added_at) VALUES(?, ?)", path, Date().timeIntervalSince1970)
        return try db.scalar("SELECT id FROM roots WHERE path = ?", [path])!
    }

    /// Forgets a root and everything indexed under it (the photos themselves are untouched).
    public func removeRoot(_ path: String) throws -> Int {
        let p = URL(fileURLWithPath: path).standardizedFileURL.path
        guard let id = try db.scalar("SELECT id FROM roots WHERE path = ?", [p]) else { return -1 }
        let n = Int(try mediaCount(rootId: id))
        try db.transaction {
            for m in try db.all("SELECT m.id FROM media m JOIN folders f ON f.id = m.folder_id WHERE f.root_id = ?", [id], { $0.int(0) }) {
                thumbs.remove(id: m)
            }
            try db.run("DELETE FROM roots WHERE id = ?", id)
        }
        return n
    }

    public func roots() throws -> [(id: Int64, path: String)] {
        try db.all("SELECT id, path FROM roots ORDER BY path") { ($0.int(0), $0.text(1)) }
    }

    /// Run arbitrary work against the database inside the actor.
    public func withDB<T: Sendable>(_ body: @Sendable (Database) throws -> T) rethrows -> T { try body(db) }

    // MARK: - Stats

    public struct Stats: Sendable, CustomStringConvertible {
        public var folders = 0, images = 0, videos = 0, raws = 0, bytes: Int64 = 0
        public var pendingMeta = 0, pendingThumbs = 0, faces = 0, namedFaces = 0, persons = 0, albums = 0, starred = 0
        public var pendingAnalysis = 0, labelled = 0, animals = 0, similarGroups = 0, similarPhotos = 0, utility = 0, ignored = 0
        public var bursts = 0, burstPhotos = 0
        public var description: String {
            let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            return """
            folders \(folders) · images \(images) · raw \(raws) · videos \(videos) · \(size)
            pending metadata \(pendingMeta) · pending thumbnails \(pendingThumbs)
            faces \(faces) (named \(namedFaces)) · persons \(persons) · albums \(albums) · starred \(starred)
            pending analysis \(pendingAnalysis) · labelled \(labelled) · with animals \(animals) · screenshots/documents \(utility)
            similar groups \(similarGroups) (\(similarPhotos) photos) · bursts \(bursts) (\(burstPhotos) photos) · small images ignored \(ignored)
            """
        }
    }

    public func stats() throws -> Stats {
        var s = Stats()
        s.folders = Int(try db.scalar("SELECT count(*) FROM folders") ?? 0)
        try db.query("SELECT kind, count(*), coalesce(sum(size),0) FROM media GROUP BY kind") { r in
            switch MediaKind(rawValue: Int(r.int(0))) {
            case .image: s.images = Int(r.int(1))
            case .video: s.videos = Int(r.int(1))
            case .raw: s.raws = Int(r.int(1))
            case nil: break
            }
            s.bytes += r.int(2)
        }
        s.pendingMeta = Int(try db.scalar("SELECT count(*) FROM media WHERE meta_state = 0") ?? 0)
        s.pendingThumbs = Int(try db.scalar("SELECT count(*) FROM media WHERE thumb_state = 0 AND ignored = 0") ?? 0)
        s.faces = Int(try db.scalar("SELECT count(*) FROM faces") ?? 0)
        s.namedFaces = Int(try db.scalar("SELECT count(*) FROM faces WHERE person_id IS NOT NULL") ?? 0)
        s.persons = Int(try db.scalar("SELECT count(*) FROM persons") ?? 0)
        s.albums = Int(try db.scalar("SELECT count(*) FROM albums") ?? 0)
        s.starred = Int(try db.scalar("SELECT count(*) FROM media WHERE star = 1") ?? 0)
        s.pendingAnalysis = Int(try db.scalar("SELECT count(*) FROM media WHERE (analysis_state = 0 OR face_state = 0) AND ignored = 0") ?? 0)
        s.ignored = Int(try db.scalar("SELECT count(*) FROM media WHERE ignored = 1") ?? 0)
        s.bursts = Int(try db.scalar("SELECT count(DISTINCT burst_id) FROM bursts") ?? 0)
        s.burstPhotos = Int(try db.scalar("SELECT count(*) FROM bursts") ?? 0)
        s.labelled = Int(try db.scalar("SELECT count(DISTINCT media_id) FROM labels") ?? 0)
        s.animals = Int(try db.scalar("SELECT count(DISTINCT media_id) FROM animals") ?? 0)
        s.utility = Int(try db.scalar("SELECT count(*) FROM media WHERE utility = 1") ?? 0)
        s.similarGroups = Int(try db.scalar("SELECT count(DISTINCT group_id) FROM similar") ?? 0)
        s.similarPhotos = Int(try db.scalar("SELECT count(*) FROM similar") ?? 0)
        return s
    }
}
