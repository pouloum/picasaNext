import Foundation

public enum MediaKind: Int, Sendable { case image = 0, video = 1, raw = 2 }

/// A photo library: an index database plus a thumbnail cache, kept apart from the media
/// (the media folders are only ever read, never written).
public actor Library {
    public let root: URL
    let db: Database
    public nonisolated let thumbs: ThumbnailStore

    public static let schemaVersion: Int64 = 14

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
        if v < 5 { try migrateV5(db) }
        if v < 6 { try migrateV6(db) }
        if v < 7 { try migrateV7(db) }
        if v < 8 { try migrateV8(db) }
        if v < 9 { try migrateV9(db) }
        if v < 10 { try migrateV10(db) }
        if v < 11 { try migrateV11(db) }
        if v < 12 { try migrateV12(db) }
        if v < 13 { try migrateV13(db) }
        if v < 14 { try migrateV14(db) }
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

    /// v5: merged persons. The merged person is kept as an alias (`merged_into`) so a later Picasa
    /// re-import of its contact id lands on the person it was merged into instead of reappearing.
    static func migrateV5(_ db: Database) throws {
        try db.exec("ALTER TABLE persons ADD COLUMN merged_into INTEGER")
    }

    /// v6: ignored faces, and pets: animals get a print and can be named like faces.
    static func migrateV6(_ db: Database) throws {
        try db.transaction {
            try db.exec("""
            ALTER TABLE faces ADD COLUMN ignored INTEGER NOT NULL DEFAULT 0;
            ALTER TABLE animals ADD COLUMN print BLOB;
            ALTER TABLE animals ADD COLUMN pet_id INTEGER;
            ALTER TABLE animals ADD COLUMN suggested_pet_id INTEGER;
            ALTER TABLE animals ADD COLUMN rejected_pet_id INTEGER;
            ALTER TABLE animals ADD COLUMN ignored INTEGER NOT NULL DEFAULT 0;
            CREATE TABLE IF NOT EXISTS pets(id INTEGER PRIMARY KEY, name TEXT NOT NULL, species TEXT, merged_into INTEGER);
            CREATE INDEX IF NOT EXISTS animals_pet ON animals(pet_id);
            """)
        }
    }

    /// v7: when each item became visible (indexed), for Library ▸ Last indexed.
    static func migrateV7(_ db: Database) throws {
        try db.exec("""
        ALTER TABLE media ADD COLUMN indexed_at REAL;
        CREATE INDEX IF NOT EXISTS media_indexed ON media(indexed_at) WHERE indexed_at IS NOT NULL;
        """)
    }

    /// v8: where each date comes from (DateSource). Dates that were the file date (no metadata date)
    /// are marked -1: re-estimated from file and folder names on the next index run.
    static func migrateV8(_ db: Database) throws {
        try db.exec("""
        ALTER TABLE media ADD COLUMN date_source INTEGER;
        UPDATE media SET date_source = 0 WHERE taken_at IS NOT NULL;
        UPDATE media SET date_source = -1 WHERE taken_at IS NOT NULL AND taken_at = mtime;
        CREATE INDEX IF NOT EXISTS media_date_estimated ON media(date_source) WHERE date_source != 0;
        """)
    }

    /// v9: decisions made by a human on a face / animal (named, ignored, confirmed, rejected) are
    /// flagged with their time, so reruns of the analysis never undo them (unless asked to).
    static func migrateV9(_ db: Database) throws {
        try db.transaction {
            try db.exec("""
            ALTER TABLE faces ADD COLUMN human INTEGER NOT NULL DEFAULT 0;
            ALTER TABLE faces ADD COLUMN human_at REAL;
            ALTER TABLE animals ADD COLUMN human INTEGER NOT NULL DEFAULT 0;
            ALTER TABLE animals ADD COLUMN human_at REAL;
            UPDATE faces SET human = 1 WHERE source = 2 OR ignored = 1 OR rejected_person_id IS NOT NULL OR person_id IS NOT NULL;
            UPDATE animals SET human = 1 WHERE pet_id IS NOT NULL OR ignored = 1 OR rejected_pet_id IS NOT NULL;
            """)
        }
    }

    /// v10: covering indexes, so the startup queries do not read the (large) media rows:
    /// media_visible for the grids and years, media_folder_visible for folder counts and folder grids,
    /// media_stats for the counters (measured on 207k photos: 745 → 131 ms, 286 → 20 ms, 352 → 82 ms).
    static func migrateV10(_ db: Database) throws {
        try db.exec("""
        CREATE INDEX IF NOT EXISTS media_visible ON media(taken_at DESC, id DESC, folder_id, meta_state, thumb_state, ignored, hidden);
        CREATE INDEX IF NOT EXISTS media_folder_visible ON media(folder_id, meta_state, thumb_state, ignored, hidden, taken_at);
        CREATE INDEX IF NOT EXISTS media_stats ON media(kind, size, meta_state, thumb_state, analysis_state, face_state,
            ignored, hidden, star, utility, date_source);
        ANALYZE;
        """)
    }

    /// v11: identical files (media.dup_of = the copy kept) and precomputed groups (group_info: one
    /// row per duplicates / burst / similar group with its cover), so the grouped views open at once.
    /// The covering indexes gain dup_of (copies are hidden from the library views).
    static func migrateV11(_ db: Database) throws {
        try db.transaction {
            try db.exec("""
            ALTER TABLE media ADD COLUMN dup_of INTEGER;
            CREATE INDEX IF NOT EXISTS media_dup ON media(dup_of) WHERE dup_of IS NOT NULL;
            CREATE TABLE IF NOT EXISTS group_info(kind INTEGER NOT NULL, group_id INTEGER NOT NULL, cover_id INTEGER NOT NULL,
                size INTEGER NOT NULL, taken REAL, PRIMARY KEY(kind, group_id));
            CREATE INDEX IF NOT EXISTS group_info_taken ON group_info(kind, taken);
            DROP INDEX IF EXISTS media_visible;
            CREATE INDEX media_visible ON media(taken_at DESC, id DESC, folder_id, meta_state, thumb_state, ignored, hidden, dup_of);
            DROP INDEX IF EXISTS media_stats;
            CREATE INDEX media_stats ON media(kind, size, meta_state, thumb_state, analysis_state, face_state,
                ignored, hidden, star, utility, date_source, dup_of);
            """)
        }
    }

    /// v12: a chosen cover per person / pet, and place names for GPS positions (reverse geocoding,
    /// one row per ~1 km cell).
    static func migrateV12(_ db: Database) throws {
        try db.transaction {
            try db.exec("""
            ALTER TABLE persons ADD COLUMN cover_id INTEGER;
            ALTER TABLE pets ADD COLUMN cover_id INTEGER;
            CREATE TABLE IF NOT EXISTS geo_names(cell TEXT PRIMARY KEY, locality TEXT, area TEXT, country TEXT, at REAL NOT NULL);
            """)
        }
    }

    /// v13: rows of media and faces / animals carry 3 KB feature prints, so any query that reads the
    /// rows themselves drags hundreds of MB through the disk. Covering indexes for what the startup,
    /// People / Animals and Labels read (measured on 207k photos, cold: grid 15 s → 0.05 s, rotations
    /// 12 s → 0 s, identity counts 12 s → 0.04 s, clustering selection 6 s → 0.03 s):
    /// - media_folder_visible gains dup_of (the grid query ended up reading every row for it);
    /// - media_rotated: the few rotated photos, loaded before the first grid;
    /// - media_visible_id: visibility, date and aesthetics by id, for joins from faces / animals / labels;
    /// - faces_ident / animals_ident: owner, ignored, suggestion, photo, size and rejection of each region.
    /// label_info: one row per label / keyword (count, cover), rebuilt when the triggers mark it stale.
    static func migrateV13(_ db: Database) throws {
        try db.transaction {
            try db.exec("""
            DROP INDEX IF EXISTS media_folder_visible;
            CREATE INDEX media_folder_visible ON media(folder_id, meta_state, thumb_state, ignored, hidden, dup_of, taken_at);
            CREATE INDEX IF NOT EXISTS media_rotated ON media(rotate) WHERE rotate % 4 != 0;
            CREATE INDEX IF NOT EXISTS media_visible_id ON media(id, ignored, hidden, dup_of, meta_state, thumb_state, taken_at, aesthetic);
            CREATE INDEX IF NOT EXISTS faces_ident ON faces(person_id, ignored, suggested_person_id, media_id, w, h, rejected_person_id);
            CREATE INDEX IF NOT EXISTS animals_ident ON animals(pet_id, ignored, suggested_pet_id, media_id, w, h, rejected_pet_id);
            """)
            try createLabelInfo(db)
            try db.exec("ANALYZE")
        }
    }

    /// v14: media_root_stats, what the Folders cards count per root (kind, size and every *_state by
    /// folder), so `rootStats()` is one pass over an index instead of the media rows and their prints.
    static func migrateV14(_ db: Database) throws {
        try db.exec("""
        CREATE INDEX IF NOT EXISTS media_root_stats ON media(folder_id, kind, size, meta_state, thumb_state,
            analysis_state, face_state, ignored, dup_of);
        ANALYZE;
        """)
    }

    /// Whether the groups (duplicates, bursts, similar) have to be built (new library, or upgraded).
    public func groupsNeedRebuild() throws -> Bool {
        let groups = try db.scalar("SELECT EXISTS(SELECT 1 FROM group_info)") ?? 0
        let prints = try db.scalar("SELECT EXISTS(SELECT 1 FROM media WHERE quick_hash IS NOT NULL)") ?? 0
        return groups == 0 && prints > 0
    }

    /// Changes whenever the library is written, by this connection (the app's own jobs) or by
    /// another process (picasa-cli scanning in a terminal). Cheap enough to poll every few seconds.
    public func changeToken() throws -> [Int64] {
        [try db.scalar("PRAGMA data_version") ?? 0, db.totalChanges]
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

    /// What a root folder (added with `scan`) holds, for the Folders cards.
    public struct RootStats: Sendable, Equatable, Identifiable {
        public var id: Int64
        public var path: String
        public var folders = 0
        /// Photos (images and raws) and videos, hidden copies of identical files and ignored small images excepted.
        public var photos = 0, videos = 0
        public var bytes: Int64 = 0
        /// Identical files hidden as copies, and small images ignored (thumbnails written by other apps).
        public var copies = 0, ignored = 0
        /// Work left, as counted by `stats()`: metadata, thumbnails, whole-image analysis, faces.
        public var pendingMeta = 0, pendingThumbs = 0, pendingAnalysis = 0, pendingFaces = 0
        public var lastScan: Date?
        public var pending: Int { pendingMeta + pendingThumbs + pendingAnalysis + pendingFaces }
        public init(id: Int64, path: String) { self.id = id; self.path = path }
    }

    /// One row per root, in one statement: the folders table is small; media is read through the
    /// covering index media_root_stats only (its rows hold 3 KB prints, see docs/PERF.md).
    public func rootStats() throws -> [RootStats] {
        try db.all("""
            SELECT r.id, r.path, coalesce(fa.n, 0), fa.scanned,
              coalesce(ma.photos, 0), coalesce(ma.videos, 0), coalesce(ma.bytes, 0), coalesce(ma.copies, 0), coalesce(ma.ignored, 0),
              coalesce(ma.meta, 0), coalesce(ma.thumbs, 0), coalesce(ma.analysis, 0), coalesce(ma.faces, 0)
            FROM roots r
            LEFT JOIN (SELECT root_id, count(*) n, max(nullif(scanned_at, 0)) scanned FROM folders GROUP BY root_id) fa ON fa.root_id = r.id
            LEFT JOIN (
              SELECT f.root_id,
                sum(m.kind != 1 AND m.ignored = 0 AND m.dup_of IS NULL) photos,
                sum(m.kind = 1 AND m.ignored = 0 AND m.dup_of IS NULL) videos,
                sum(m.size) bytes, sum(m.dup_of IS NOT NULL) copies, sum(m.ignored = 1) ignored,
                sum(m.meta_state = 0) meta, sum(m.thumb_state = 0 AND m.ignored = 0) thumbs,
                sum(m.analysis_state = 0 AND m.ignored = 0) analysis, sum(m.face_state = 0 AND m.ignored = 0) faces
              FROM media m INDEXED BY media_root_stats JOIN folders f ON f.id = m.folder_id
              GROUP BY f.root_id
            ) ma ON ma.root_id = r.id
            ORDER BY r.path
            """) { r in
            var s = RootStats(id: r.int(0), path: r.text(1))
            s.folders = Int(r.int(2))
            s.lastScan = r.optDouble(3).map { Date(timeIntervalSince1970: $0) }
            s.photos = Int(r.int(4)); s.videos = Int(r.int(5)); s.bytes = r.int(6)
            s.copies = Int(r.int(7)); s.ignored = Int(r.int(8))
            s.pendingMeta = Int(r.int(9)); s.pendingThumbs = Int(r.int(10))
            s.pendingAnalysis = Int(r.int(11)); s.pendingFaces = Int(r.int(12))
            return s
        }
    }

    /// Run arbitrary work against the database inside the actor.
    public func withDB<T: Sendable>(_ body: @Sendable (Database) throws -> T) rethrows -> T { try body(db) }

    // MARK: - Stats

    public struct Stats: Sendable, CustomStringConvertible {
        public var folders = 0, images = 0, videos = 0, raws = 0, bytes: Int64 = 0
        public var pendingMeta = 0, pendingThumbs = 0, faces = 0, namedFaces = 0, persons = 0, albums = 0, starred = 0
        public var pendingAnalysis = 0, labelled = 0, animals = 0, pets = 0, unnamedFaces = 0, ignoredFaces = 0, similarGroups = 0, similarPhotos = 0, utility = 0, ignored = 0
        public var bursts = 0, burstPhotos = 0
        /// Skipped because the file could not be read (disk not mounted, no permission); retried on each run.
        public var unreadableMeta = 0, unreadableThumbs = 0
        public var thumbnails = 0, analysed = 0
        /// Files not fully indexed yet (metadata or thumbnail missing), small ignored images excepted.
        public var toIndex = 0
        /// Indexed and visible in the grids.
        public var shownPhotos = 0, shownVideos = 0
        public var lastScan: Date?
        /// Dated from a file or folder name, or the file date (no date in the photo's metadata).
        public var estimatedDates = 0
        /// Identical files hidden as copies of another, and the groups they form.
        public var duplicateCopies = 0, duplicateGroups = 0
        public init() {}
        public var description: String {
            let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            return """
            folders \(folders) · images \(images) · raw \(raws) · videos \(videos) · \(size)
            pending metadata \(pendingMeta) · pending thumbnails \(pendingThumbs) · unreadable \(unreadableMeta) metadata / \(unreadableThumbs) thumbnails
            faces \(faces) (named \(namedFaces)) · persons \(persons) · albums \(albums) · starred \(starred)
            pending analysis \(pendingAnalysis) · labelled \(labelled) · with animals \(animals) · screenshots/documents \(utility)
            similar groups \(similarGroups) (\(similarPhotos) photos) · bursts \(bursts) (\(burstPhotos) photos) · small images ignored \(ignored)
            """
        }
    }

    public func stats() throws -> Stats {
        var s = Stats()
        s.folders = Int(try db.scalar("SELECT count(*) FROM folders") ?? 0)
        // One pass over media, on the covering index media_stats (rows hold feature prints and are
        // large: each separate count used to read the whole table, ~0.3 s apiece on 200k photos).
        try db.query("""
            SELECT kind, count(*), coalesce(sum(size), 0),
              sum(meta_state = 0), sum(thumb_state = 0 AND ignored = 0), sum(meta_state = 3), sum(thumb_state = 3 AND ignored = 0),
              sum(date_source IN (1, 2, 3) AND ignored = 0), sum(thumb_state = 1),
              sum(ignored = 0 AND hidden = 0 AND meta_state = 1 AND thumb_state = 1 AND dup_of IS NULL),
              sum(ignored = 0 AND (meta_state != 1 OR thumb_state != 1)), sum(analysis_state = 1), sum(star = 1),
              sum((analysis_state = 0 OR face_state = 0) AND ignored = 0), sum(ignored = 1), sum(utility = 1), sum(dup_of IS NOT NULL)
            FROM media INDEXED BY media_stats GROUP BY kind
            """) { r in
            let n = Int(r.int(1))
            switch MediaKind(rawValue: Int(r.int(0))) {
            case .image: s.images = n
            case .video: s.videos = n
            case .raw: s.raws = n
            case nil: break
            }
            s.bytes += r.int(2)
            s.pendingMeta += Int(r.int(3)); s.pendingThumbs += Int(r.int(4))
            s.unreadableMeta += Int(r.int(5)); s.unreadableThumbs += Int(r.int(6))
            s.estimatedDates += Int(r.int(7)); s.thumbnails += Int(r.int(8))
            if r.int(0) == Int64(MediaKind.video.rawValue) { s.shownVideos += Int(r.int(9)) } else { s.shownPhotos += Int(r.int(9)) }
            s.toIndex += Int(r.int(10)); s.analysed += Int(r.int(11)); s.starred += Int(r.int(12))
            s.pendingAnalysis += Int(r.int(13)); s.ignored += Int(r.int(14)); s.utility += Int(r.int(15))
            s.duplicateCopies += Int(r.int(16))
        }
        s.lastScan = try db.all("SELECT max(scanned_at) FROM folders WHERE scanned_at > 0") { $0.optDouble(0) }.first?.map { Date(timeIntervalSince1970: $0) }
        s.faces = Int(try db.scalar("SELECT count(*) FROM faces") ?? 0)
        // One pass over the covering index faces_ident (the rows hold 3 KB prints).
        try db.query("""
            SELECT count(person_id), coalesce(sum(person_id IS NULL AND ignored = 0), 0), coalesce(sum(ignored = 1), 0)
            FROM faces INDEXED BY faces_ident
            """) { r in s.namedFaces = Int(r.int(0)); s.unnamedFaces = Int(r.int(1)); s.ignoredFaces = Int(r.int(2)) }
        s.persons = Int(try db.scalar("SELECT count(*) FROM persons WHERE merged_into IS NULL") ?? 0)
        s.albums = Int(try db.scalar("SELECT count(*) FROM albums") ?? 0)
        s.bursts = Int(try db.scalar("SELECT count(*) FROM group_info WHERE kind = 1") ?? 0)
        s.duplicateGroups = Int(try db.scalar("SELECT count(*) FROM group_info WHERE kind = 0") ?? 0)
        s.burstPhotos = Int(try db.scalar("SELECT count(*) FROM bursts") ?? 0)
        s.labelled = try labelledPhotos()
        s.animals = Int(try db.scalar("SELECT count(DISTINCT media_id) FROM animals") ?? 0)
        s.pets = Int(try db.scalar("SELECT count(*) FROM pets WHERE merged_into IS NULL") ?? 0)
        s.similarGroups = Int(try db.scalar("SELECT count(*) FROM group_info WHERE kind = 2") ?? 0)
        s.similarPhotos = Int(try db.scalar("SELECT count(*) FROM similar") ?? 0)
        return s
    }
}
