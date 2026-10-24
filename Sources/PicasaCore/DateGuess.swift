import Foundation

/// Where a photo's date comes from (media.date_source). Anything but `.metadata` is an estimate.
public enum DateSource: Int, Sendable {
    case metadata = 0   // EXIF / QuickTime / Picasa
    case fileName = 1   // IMG_20160910_162536.jpg, WhatsApp Image 2020-03-01 at 12.00.00.jpeg
    case folder = 2     // …/2019-06-24 vacances/…, …/2017-09 rentrée/…, …/2013/…
    case fileDate = 3   // the file's modification date (often a copy date)

    public var label: String {
        switch self {
        case .metadata: "photo metadata"
        case .fileName: "file name"
        case .folder: "folder name"
        case .fileDate: "file date"
        }
    }
}

/// Dates read from file and folder names, for photos without a date in their metadata.
public enum DateGuess {
    /// 2016-09-10 16:25:36 style dates in a name; digits must not touch other digits (ids are skipped).
    static let full = try! NSRegularExpression(pattern:
        #"(?<!\d)((?:19|20)\d{2})[-_.]?(0[1-9]|1[0-2])[-_.]?(0[1-9]|[12]\d|3[01])(?:[ _T.-]*(?:at[ _]*)?([01]\d|2[0-3])[-_.h:]?([0-5]\d)[-_.m:]?([0-5]\d))?(?!\d)"#)
    static let month = try! NSRegularExpression(pattern: #"(?<!\d)((?:19|20)\d{2})[-_.](0[1-9]|1[0-2])(?![\d])"#)
    static let year = try! NSRegularExpression(pattern: #"^((?:19|20)\d{2})(?!\d)"#)

    /// Best date for a file without metadata date: its name, then its folders (deepest first), then
    /// the file date. A year- or month-only folder keeps the file date when it falls in that period.
    public static func guess(name: String, folderPath: String, fileDate: Date?, calendar: Calendar = .current) -> (Date, DateSource)? {
        let now = Date()
        func valid(_ d: Date?) -> Date? { d.flatMap { $0 <= now.addingTimeInterval(86400) ? $0 : nil } }
        if let d = valid(fullDate(in: name, calendar)) { return (d, .fileName) }
        for component in folderPath.split(separator: "/").reversed().map(String.init) {
            if let d = valid(fullDate(in: component, calendar)) { return (d, .folder) }
            let ns = component as NSString
            if let m = month.firstMatch(in: component, range: NSRange(location: 0, length: ns.length)),
               let y = Int(ns.substring(with: m.range(at: 1))), let mo = Int(ns.substring(with: m.range(at: 2))),
               let start = calendar.date(from: DateComponents(year: y, month: mo, day: 1)) {
                let end = calendar.date(byAdding: .month, value: 1, to: start)!
                if let f = fileDate, f >= start, f < end { return (f, .folder) }
                if let d = valid(start) { return (d, .folder) }
            }
            if let m = year.firstMatch(in: component, range: NSRange(location: 0, length: ns.length)),
               let y = Int(ns.substring(with: m.range(at: 1))),
               let start = calendar.date(from: DateComponents(year: y, month: 1, day: 1)) {
                let end = calendar.date(byAdding: .year, value: 1, to: start)!
                if let f = fileDate, f >= start, f < end { return (f, .folder) }
                if let d = valid(calendar.date(from: DateComponents(year: y, month: 7, day: 1))) { return (d, .folder) }
            }
        }
        return fileDate.map { ($0, .fileDate) }
    }

    static func fullDate(in s: String, _ calendar: Calendar) -> Date? {
        let ns = s as NSString
        guard let m = full.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        func n(_ i: Int) -> Int? { m.range(at: i).location == NSNotFound ? nil : Int(ns.substring(with: m.range(at: i))) }
        guard let y = n(1), let mo = n(2), let d = n(3) else { return nil }
        let c = DateComponents(year: y, month: mo, day: d, hour: n(4) ?? 12, minute: n(5) ?? 0, second: n(6) ?? 0)
        guard let date = calendar.date(from: c), calendar.component(.day, from: date) == d else { return nil } // 31 Feb
        return date
    }
}
