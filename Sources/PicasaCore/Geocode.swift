import CoreLocation
import Foundation

/// Place names for GPS positions (reverse geocoding with Apple's geocoder, network needed). One
/// lookup per ~2 km cell (`geo_names`), so tens of thousands of geotagged photos need a few
/// thousand requests; Apple throttles them, so the pass is slow, resumable and backs off.
public struct Geocoder: Sendable {
    public let library: Library
    public init(library: Library) { self.library = library }

    /// Cell of a position: rounded to 1/50 of a degree (~2 km); the same expression in SQL and Swift.
    static let cellSQL = "printf('%.2f:%.2f', round(lat * 50) / 50.0, round(lon * 50) / 50.0)"

    public struct Report: Sendable, CustomStringConvertible {
        public var named = 0, failed = 0, left = 0
        public var lastError: String?
        public var description: String {
            "geocode: \(named) places named · \(failed) failed · \(left) left" + (lastError.map { " (last error: \($0))" } ?? "")
        }
    }

    /// Names the cells that have none yet (at most `limit`), politely: one request at a time,
    /// a pause between them, a long pause when throttled, stop after repeated failures.
    public func run(limit: Int = .max, pause: Double = 1.2, progress: ProgressHandler? = nil) async throws -> Report {
        var rep = Report()
        let cells = try await library.unnamedGeoCells()
        let geocoder = CLGeocoder()
        var errorsInARow = 0
        for (i, c) in cells.prefix(limit).enumerated() {
            do {
                let marks = try await geocoder.reverseGeocodeLocation(CLLocation(latitude: c.lat, longitude: c.lon))
                let p = marks.first
                try await library.storeGeoName(cell: c.cell, locality: p?.locality ?? p?.subAdministrativeArea ?? p?.name,
                                               area: p?.administrativeArea, country: p?.country)
                rep.named += 1
                errorsInARow = 0
            } catch {
                rep.failed += 1
                rep.lastError = "\(error.localizedDescription)"
                errorsInARow += 1
                if errorsInARow >= 8 { break } // offline, or throttled for good: resume later
                try? await Task.sleep(for: .seconds(30 * errorsInARow))
                continue
            }
            progress?(LibraryProgress(stage: "geocode", done: i + 1, total: min(limit, cells.count), current: c.cell))
            try? await Task.sleep(for: .seconds(pause))
        }
        rep.left = try await library.unnamedGeoCells().count
        return rep
    }
}

extension Library {
    /// Cells with geotagged photos and no place name yet, the most photographed first.
    func unnamedGeoCells() throws -> [(cell: String, lat: Double, lon: Double)] {
        try db.all("""
            SELECT \(Geocoder.cellSQL) c, avg(lat), avg(lon) FROM media
            WHERE lat IS NOT NULL AND lon IS NOT NULL AND (lat != 0 OR lon != 0) AND ignored = 0
              AND \(Geocoder.cellSQL) NOT IN (SELECT cell FROM geo_names)
            GROUP BY c ORDER BY count(*) DESC
            """) { ($0.text(0), $0.double(1), $0.double(2)) }
    }

    func storeGeoName(cell: String, locality: String?, area: String?, country: String?) throws {
        try db.run("INSERT OR REPLACE INTO geo_names(cell, locality, area, country, at) VALUES(?, ?, ?, ?, ?)",
                   cell, locality, area, country, Date().timeIntervalSince1970)
    }

    /// "Caen, Normandie, France" for a position, if its cell has been named.
    public func placeName(lat: Double, lon: Double) throws -> String? {
        try db.all("SELECT locality, area, country FROM geo_names WHERE cell = printf('%.2f:%.2f', round(? * 50) / 50.0, round(? * 50) / 50.0)",
                   [lat, lon]) { r in
            [r.optText(0), r.optText(1), r.optText(2)].compactMap { $0 }.filter { !$0.isEmpty }
        }.first.flatMap { parts in
            var seen = Set<String>()
            let unique = parts.filter { seen.insert($0).inserted }
            return unique.isEmpty ? nil : unique.joined(separator: ", ")
        }
    }

    public func geoCellCounts() throws -> (named: Int, unnamed: Int) {
        let named = Int(try db.scalar("SELECT count(*) FROM geo_names") ?? 0)
        return (named, try unnamedGeoCells().count)
    }
}
