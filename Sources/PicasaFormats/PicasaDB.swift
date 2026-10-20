import Foundation

/// Little-endian cursor over a byte buffer.
struct ByteReader {
    let data: Data
    var offset: Int
    init(_ data: Data, offset: Int = 0) { self.data = data; self.offset = data.startIndex + offset }
    var remaining: Int { data.endIndex - offset }

    mutating func u8() throws -> UInt8 { try need(1); defer { offset += 1 }; return data[offset] }
    mutating func u16() throws -> UInt16 { UInt16(try int(2)) }
    mutating func u32() throws -> UInt32 { UInt32(try int(4)) }
    mutating func u64() throws -> UInt64 { try int(8) }
    mutating func f64() throws -> Double { Double(bitPattern: try u64()) }

    private mutating func int(_ n: Int) throws -> UInt64 {
        try need(n)
        var v: UInt64 = 0
        for i in 0..<n { v |= UInt64(data[offset + i]) << (8 * UInt64(i)) }
        offset += n
        return v
    }

    /// NUL-terminated (older thumbindex readers also tolerate 0xFF as terminator).
    mutating func cString(alsoFF: Bool = false) throws -> String {
        let start = offset
        while offset < data.endIndex, data[offset] != 0, !(alsoFF && data[offset] == 0xFF) { offset += 1 }
        try need(1)
        let bytes = data[start..<offset]
        offset += 1
        return String(data: bytes, encoding: .utf8) ?? String(decoding: bytes, as: UTF8.self)
    }

    func need(_ n: Int) throws {
        if remaining < n { throw PicasaDBError.truncated(at: offset - data.startIndex) }
    }
}

public enum PicasaDBError: Error, CustomStringConvertible {
    case badMagic(file: String, found: UInt32)
    case badType(file: String, type: UInt16)
    case truncated(at: Int)
    case missing(String)
    public var description: String {
        switch self {
        case let .badMagic(f, m): "\(f): bad magic 0x\(String(m, radix: 16))"
        case let .badType(f, t): "\(f): unknown field type \(t)"
        case let .truncated(o): "truncated data at offset \(o)"
        case let .missing(f): "missing \(f)"
        }
    }
}

/// One value of a PMP column.
public enum PMPValue: Sendable, Equatable, CustomStringConvertible {
    case string(String)
    case uint(UInt64)
    /// Signed columns: type 3 (int8) and 7 (int32).
    case int(Int64)
    /// OLE/Variant date (days since 1899-12-30), also used for plain doubles such as lat/long.
    case double(Double)

    public var string: String? { if case let .string(s) = self { return s.isEmpty ? nil : s }; return nil }
    public var uint: UInt64? {
        switch self {
        case let .uint(v): v
        case let .int(v): v >= 0 ? UInt64(v) : nil
        default: nil
        }
    }
    public var int: Int64? {
        switch self {
        case let .uint(v): v <= UInt64(Int64.max) ? Int64(v) : nil
        case let .int(v): v
        default: nil
        }
    }
    public var double: Double? { if case let .double(v) = self { return v }; return nil }
    /// OLE date → Date.
    public var date: Date? { double.map { Date(timeIntervalSince1970: ($0 - 25569) * 86400) } }
    public var description: String {
        switch self {
        case let .string(s): s
        case let .uint(v): String(v)
        case let .int(v): String(v)
        case let .double(d): String(d)
        }
    }
}

/// A `<table>_<field>.pmp` column file.
/// Header: magic 0x3fcccccd, u16 type, u16 0x1332, u32 2, u16 type, u16 0x1332, u32 count; then `count` packed values.
public struct PMPColumn: Sendable {
    public static let magic: UInt32 = 0x3FCC_CCCD
    public let name: String
    public let type: UInt16
    public let values: [PMPValue]

    public init(url: URL, name: String) throws {
        try self.init(data: Data(contentsOf: url, options: .mappedIfSafe), name: name)
    }

    public init(data: Data, name: String) throws {
        var r = ByteReader(data)
        let magic = try r.u32()
        guard magic == Self.magic else { throw PicasaDBError.badMagic(file: name, found: magic) }
        let type = try r.u16()
        _ = try r.u16() // 0x1332
        _ = try r.u32() // 2
        _ = try r.u16() // type again
        _ = try r.u16() // 0x1332
        let count = Int(try r.u32())
        guard count <= r.remaining else { throw PicasaDBError.truncated(at: data.count) } // ≥ 1 byte per value
        var out: [PMPValue] = []
        out.reserveCapacity(count)
        for _ in 0..<count {
            switch type {
            // 6 is a string column Picasa interns in memory; same bytes on disk.
            case 0, 6: out.append(.string(try r.cString()))
            case 1: out.append(.uint(UInt64(try r.u32())))
            case 7: out.append(.int(Int64(Int32(bitPattern: try r.u32()))))
            case 2: out.append(.double(try r.f64()))
            case 3: out.append(.int(Int64(Int8(bitPattern: try r.u8()))))
            case 4: out.append(.uint(try r.u64()))
            case 5: out.append(.uint(UInt64(try r.u16())))
            default: throw PicasaDBError.badType(file: name, type: type)
            }
        }
        self.name = name; self.type = type; values = out
    }

    /// Rows beyond the column's count read as missing (Picasa returns the default value).
    public subscript(row: Int) -> PMPValue? { row >= 0 && row < values.count ? values[row] : nil }
}

/// A PMP table: all `<table>_*.pmp` columns in a db3 folder. Row N of every column = entity N.
public struct PMPTable: Sendable {
    public let name: String
    public let columns: [String: PMPColumn]
    public let errors: [String]

    public init(directory: URL, table: String) throws {
        let prefix = table + "_"
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "pmp" }
        var cols: [String: PMPColumn] = [:]
        var errs: [String] = []
        for f in files {
            let field = String(f.deletingPathExtension().lastPathComponent.dropFirst(prefix.count))
            do { cols[field] = try PMPColumn(url: f, name: field) } catch { errs.append("\(f.lastPathComponent): \(error)") }
        }
        guard !cols.isEmpty else { throw PicasaDBError.missing("\(table)_*.pmp in \(directory.path)") }
        name = table; columns = cols; errors = errs
    }

    public var rowCount: Int { columns.values.map(\.values.count).max() ?? 0 }
    public subscript(field: String, row: Int) -> PMPValue? { columns[field]?[row] }
}

/// `thumbindex.db`: the path table. Entry i == row i of imagedata and thumbnail i of the caches.
public struct ThumbIndex: Sendable {
    public static let magic: UInt32 = 0x4046_6666

    public struct Entry: Sendable {
        public var name: String
        public var ctime: Date?
        public var mtime: Date?
        public var size: UInt32
        /// Entry kind; 1, 5 (bad directory), 0x19 and 0x3e9 hold a full path (directory-like),
        /// 4 = bad file, 0 = empty; low byte otherwise identifies the file type (2 JPEG, 0x0e PNG, …).
        public var kind: UInt32
        public var valid: Bool
        /// Parent directory index (0xFFFFFFFF = none). For virtual face entries: the real image.
        public var parent: Int?
        public var isDirectory: Bool { [1, 5, 0x19, 0x3E9].contains(kind) || (parent == nil && !name.isEmpty) }
        /// Deleted entries and per-face "virtual images" have an empty name; for the latter
        /// `parent` is the index of the real image.
        public var isVirtual: Bool { name.isEmpty && parent != nil && !isDirectory }
    }

    public let entries: [Entry]

    public init(url: URL) throws { try self.init(data: Data(contentsOf: url, options: .mappedIfSafe)) }

    public init(data: Data) throws {
        var r = ByteReader(data)
        let magic = try r.u32()
        guard magic == Self.magic else { throw PicasaDBError.badMagic(file: "thumbindex.db", found: magic) }
        let count = Int(try r.u32())
        guard count <= r.remaining / 31 else { throw PicasaDBError.truncated(at: data.count) } // ≥ 31 bytes per entry
        var out: [Entry] = []
        out.reserveCapacity(count)
        for _ in 0..<count {
            // name\0, then 30 bytes: ctime(8) mtime(8) size(4) kind(4) dirty(1) valid(1) parent(4)
            let name = try r.cString(alsoFF: true)
            let ctime = Self.timestamp(try r.u64())
            let mtime = Self.timestamp(try r.u64())
            let size = try r.u32()
            let kind = try r.u32()
            _ = try r.u8() // dirty
            let valid = try r.u8() != 0
            let parent = try r.u32()
            out.append(Entry(name: name, ctime: ctime, mtime: mtime, size: size, kind: kind, valid: valid,
                             parent: parent == 0xFFFF_FFFF ? nil : Int(parent)))
        }
        entries = out
    }

    /// Windows Picasa writes FILETIME (100 ns since 1601); Mac Picasa copies a Carbon UTCDateTime
    /// {u16 highSeconds, u32 lowSeconds, u16 fraction} (seconds since 1904). Pick the reading that lands in 1985…2040.
    static func timestamp(_ v: UInt64) -> Date? {
        guard v > 0 else { return nil }
        let plausible = 473_385_600.0...2_208_988_800.0 // 1985-01-01 … 2040-01-01
        let ft = Double(v) / 10_000_000 - 11_644_473_600
        if plausible.contains(ft) { return Date(timeIntervalSince1970: ft) }
        let secs = Double(((v & 0xFFFF) << 32) | ((v >> 16) & 0xFFFF_FFFF)) + Double(v >> 48) / 65536
        let carbon = secs - 2_082_844_800
        return plausible.contains(carbon) ? Date(timeIntervalSince1970: carbon) : nil
    }

    /// Full path of a real file entry: directory entries carry the full path, files their basename.
    public func path(of i: Int) -> String? {
        guard i >= 0, i < entries.count else { return nil }
        let e = entries[i]
        if !e.valid && e.name.isEmpty { return nil }
        if e.isDirectory { return e.name.isEmpty ? nil : e.name }
        guard !e.name.isEmpty, let p = e.parent, p < entries.count, entries[p].isDirectory else { return nil }
        var dir = entries[p].name
        let sep: Character = dir.contains("\\") ? "\\" : "/"
        if dir.last != sep { dir.append(sep) }
        return dir + e.name
    }
}

/// A thumbnail cache: `<set>_index.db` + data files `<set>_0.db`, `<set>_1.db`, …
/// (sets: thumbs, thumbs2, bigthumbs, previews). Index: magic, u32, then three length-prefixed u32
/// arrays: aux[], offset[], packed[] with size = packed & 0xFFFFFF and data file = packed >> 24.
public struct ThumbCache: Sendable {
    public let offsets: [UInt32]
    public let packed: [UInt32]
    let blobs: [Int: Data]

    public init(directory: URL, set: String) throws {
        let idx = directory.appendingPathComponent("\(set)_index.db")
        guard FileManager.default.fileExists(atPath: idx.path) else { throw PicasaDBError.missing("\(set)_index.db") }
        var r = ByteReader(try Data(contentsOf: idx, options: .mappedIfSafe))
        let magic = try r.u32()
        guard magic == PMPColumn.magic else { throw PicasaDBError.badMagic(file: idx.lastPathComponent, found: magic) }
        _ = try r.u32()
        func array() throws -> [UInt32] {
            let n = Int(try r.u32())
            guard n <= r.remaining / 4 else { throw PicasaDBError.truncated(at: r.offset) }
            return try (0..<n).map { _ in try r.u32() }
        }
        _ = try array() // aux values, unused
        offsets = try array()
        packed = try array()
        var blobs: [Int: Data] = [:]
        for n in Set(packed.map { Int($0 >> 24) }) {
            let f = directory.appendingPathComponent("\(set)_\(n).db")
            if let d = try? Data(contentsOf: f, options: .alwaysMapped) { blobs[n] = d }
        }
        guard !blobs.isEmpty else { throw PicasaDBError.missing("\(set)_0.db") }
        self.blobs = blobs
    }

    public var count: Int { min(offsets.count, packed.count) }

    /// JPEG bytes of thumbnail i, if present and plausible.
    public func jpeg(_ i: Int) -> Data? {
        guard i >= 0, i < count else { return nil }
        let size = Int(packed[i] & 0xFF_FFFF)
        guard size > 0, let blob = blobs[Int(packed[i] >> 24)] else { return nil }
        let start = Int(offsets[i]), end = start + size
        guard end <= blob.count else { return nil }
        let d = blob.subdata(in: start..<end)
        return d.starts(with: [0xFF, 0xD8]) ? d : nil
    }
}

/// Convenience over a whole `db3` folder.
public struct PicasaDB3: Sendable {
    public let directory: URL
    public let index: ThumbIndex
    public let images: PMPTable
    public let albums: PMPTable?

    public init(directory: URL) throws {
        self.directory = directory
        index = try ThumbIndex(url: directory.appendingPathComponent("thumbindex.db"))
        images = try PMPTable(directory: directory, table: "imagedata")
        albums = try? PMPTable(directory: directory, table: "albumdata")
    }

    /// A people album. `row` is what `imagedata_personalbumid` refers to (albumdata row index).
    /// 3.9 tokens are `]facealbum:<decimal row>` with the contact id(s) in `albumcontactids`;
    /// older databases put the hex contact id in the token itself.
    public struct Person: Sendable { public var row: Int; public var contactId: String?; public var name: String }

    public var persons: [Person] {
        guard let a = albums else { return [] }
        return (0..<a.rowCount).compactMap { row in
            guard let token = a["token", row]?.string, token.hasPrefix("]facealbum:") else { return nil }
            let suffix = String(token.dropFirst(11))
            var contact: String?
            if let ids = a["albumcontactids", row]?.string {
                contact = ids.split(whereSeparator: { !$0.isHexDigit }).first.map { PicasaContacts.normalizeId(String($0)) }
            }
            if contact == nil, suffix.count >= 9, UInt64(suffix, radix: 16) != nil { contact = PicasaContacts.normalizeId(suffix) }
            return Person(row: row, contactId: contact, name: a["name", row]?.string ?? "")
        }
    }

    public struct Album: Sendable { public var uid: String; public var name: String; public var date: Date? }

    /// Regular user albums (`]album:<uid>`).
    public var userAlbums: [Album] {
        guard let a = albums else { return [] }
        return (0..<a.rowCount).compactMap { row in
            guard let token = a["token", row]?.string, token.hasPrefix("]album:") else { return nil }
            return Album(uid: String(token.dropFirst(7)), name: a["name", row]?.string ?? token, date: a["date", row]?.date)
        }
    }
}
