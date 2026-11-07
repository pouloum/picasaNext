import Foundation

/// Labels page: one precomputed row per label / keyword (photo count, best-looking photo as cover).
/// Computing it reads ~1.4M labels and sorts them (2–20 s on 200k photos), so it is kept in
/// `label_info` and rebuilt only when stale. Triggers mark it stale (settings `label_info.dirty`)
/// whenever labels, keywords or the visibility / aesthetics of a photo change.
extension Library {
    static let labelInfoDirty = "label_info.dirty"

    static func createLabelInfo(_ db: Database) throws {
        let mark = "INSERT OR REPLACE INTO settings(key, value) VALUES('\(labelInfoDirty)', '1')"
        let when = "WHEN (SELECT value FROM settings WHERE key = '\(labelInfoDirty)') IS NOT '1'"
        try db.exec("""
        CREATE TABLE IF NOT EXISTS label_info(label TEXT PRIMARY KEY, n INTEGER NOT NULL, cover_id INTEGER NOT NULL);
        \(mark);
        CREATE TRIGGER IF NOT EXISTS label_info_labels_ins AFTER INSERT ON labels \(when) BEGIN \(mark); END;
        CREATE TRIGGER IF NOT EXISTS label_info_labels_del AFTER DELETE ON labels \(when) BEGIN \(mark); END;
        CREATE TRIGGER IF NOT EXISTS label_info_tags_ins AFTER INSERT ON tags \(when) BEGIN \(mark); END;
        CREATE TRIGGER IF NOT EXISTS label_info_tags_del AFTER DELETE ON tags \(when) BEGIN \(mark); END;
        CREATE TRIGGER IF NOT EXISTS label_info_media_del AFTER DELETE ON media \(when) BEGIN \(mark); END;
        CREATE TRIGGER IF NOT EXISTS label_info_media_upd
          AFTER UPDATE OF ignored, hidden, dup_of, meta_state, thumb_state, aesthetic, taken_at ON media \(when) BEGIN \(mark); END;
        """)
    }

    /// Whether `label_info` holds anything yet (it may be stale).
    func hasLabelInfo() throws -> Bool {
        (try db.scalar("SELECT EXISTS(SELECT 1 FROM label_info)") ?? 0) != 0
    }

    /// Whether `label_info` has to be rebuilt.
    public func labelInfoStale() throws -> Bool {
        try setting(Self.labelInfoDirty) != "0"
    }

    /// What `label_info` holds now, possibly stale: shown at once while it is rebuilt.
    public func cachedLabelSummaries() throws -> [LabelSummary] {
        try db.all("SELECT label, n, cover_id FROM label_info ORDER BY n DESC, label") {
            LabelSummary(label: $0.text(0), count: Int($0.int(1)), coverMediaId: $0.int(2))
        }
    }

    /// Rebuilds `label_info` if stale. Counts and covers use the photos the grids show (so a card's
    /// count matches its grid).
    public func refreshLabelInfo() throws {
        guard try labelInfoStale() else { return }
        try db.transaction {
            try db.exec("DELETE FROM label_info")
            try db.run("""
                INSERT INTO label_info(label, n, cover_id)
                SELECT label, n, media_id FROM (
                  SELECT l.label, l.media_id, count(*) OVER (PARTITION BY l.label) n,
                         row_number() OVER (PARTITION BY l.label ORDER BY m.aesthetic DESC NULLS LAST, m.taken_at DESC) rn
                  FROM (SELECT media_id, label FROM labels UNION SELECT media_id, tag FROM tags) l
                  JOIN media m INDEXED BY media_visible_id ON m.id = l.media_id
                  WHERE \(Self.visibleMedia))
                WHERE rn = 1
                """)
            let photos = try db.scalar("SELECT count(DISTINCT media_id) FROM labels") ?? 0
            try setSetting("label_info.photos", String(photos))
            try setSetting(Self.labelInfoDirty, "0")
        }
    }

    /// Every label and keyword with its photo count and the best-looking photo as cover, most used first.
    public func labelSummaries() throws -> [LabelSummary] {
        try refreshLabelInfo()
        return try cachedLabelSummaries()
    }

    /// Photos with at least one Vision label (counter): from the last rebuild, even if stale since
    /// (a scan marks it stale constantly; counting the 1M+ labels each refresh took ~1.5 s).
    func labelledPhotos() throws -> Int {
        if let n = try setting("label_info.photos").flatMap(Int.init) { return n }
        return Int(try db.scalar("SELECT count(DISTINCT media_id) FROM labels") ?? 0)
    }
}
