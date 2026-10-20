import Foundation

/// A face/crop rectangle in normalized coordinates (0…1), origin top-left.
public struct NormalizedRect: Sendable, Equatable, CustomStringConvertible {
    public var left, top, right, bottom: Double
    public init(left: Double, top: Double, right: Double, bottom: Double) {
        self.left = left; self.top = top; self.right = right; self.bottom = bottom
    }
    public var width: Double { right - left }
    public var height: Double { bottom - top }
    public var description: String { String(format: "[%.4f,%.4f → %.4f,%.4f]", left, top, right, bottom) }
}

/// Picasa's `rect64(...)`: up to 16 hex digits = four big-endian UInt16 (left, top, right, bottom) / 65535.
/// Picasa prints it with `%llx`, so leading zeros are dropped and the value is left-padded to 16 digits.
public enum Rect64 {
    public static func decode(_ hex: String) -> NormalizedRect? {
        var h = hex.trimmingCharacters(in: .whitespaces)
        if h.lowercased().hasPrefix("rect64(") { h = String(h.dropFirst(7)) }
        if h.hasSuffix(")") { h.removeLast() }
        guard !h.isEmpty, h.count <= 16, let v = UInt64(h, radix: 16) else { return nil }
        func c(_ shift: UInt64) -> Double { Double((v >> shift) & 0xFFFF) / 65535.0 }
        return NormalizedRect(left: c(48), top: c(32), right: c(16), bottom: c(0))
    }

    public static func encode(_ r: NormalizedRect) -> String {
        func c(_ d: Double) -> UInt64 { UInt64((min(max(d, 0), 1) * 65535).rounded()) }
        let v = c(r.left) << 48 | c(r.top) << 32 | c(r.right) << 16 | c(r.bottom)
        return String(v, radix: 16)
    }
}

/// One edit in a `filters=` chain, e.g. `crop64=1,30a730d2bd3fe4c2` → name "crop64", enabled true, params ["30a730d2bd3fe4c2"].
public struct PicasaFilter: Sendable, Equatable {
    public var name: String
    public var enabled: Bool
    public var params: [String]

    /// Parses `name=1,a,b;name2=1,c;`. Picasa writes a trailing `;`.
    public static func parseChain(_ s: String) -> [PicasaFilter] {
        s.split(separator: ";", omittingEmptySubsequences: true).compactMap { part in
            let kv = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let name = kv.first.map({ String($0).trimmingCharacters(in: .whitespaces) }), !name.isEmpty else { return nil }
            let args = kv.count > 1 ? kv[1].split(separator: ",", omittingEmptySubsequences: false).map(String.init) : []
            return PicasaFilter(name: name, enabled: args.first != "0", params: Array(args.dropFirst()))
        }
    }

    public var cropRect: NormalizedRect? { name == "crop64" ? params.first.flatMap(Rect64.decode) : nil }
}

public struct PicasaFace: Sendable, Equatable {
    public var rect: NormalizedRect
    /// Contact id (hex string); "ffffffffffffffff" means an unnamed detected face.
    public var contactId: String
    public var isUnnamed: Bool { contactId.allSatisfy { $0 == "f" || $0 == "F" } || contactId.isEmpty }
}

public struct PicasaAlbum: Sendable, Equatable {
    public var token: String
    public var name: String?
    public var date: String?
    public var location: String?
    public var description: String?
}

/// Per-file entry of a `.picasa.ini`.
public struct PicasaIniEntry: Sendable {
    /// Section name as written: Picasa replaces `[` / `]` in file names with `(` / `)`.
    public var fileName: String
    public var values: [String: String]

    public var faces: [PicasaFace] {
        guard let raw = values["faces"] else { return [] }
        // faces=rect64(<hex>),<contact>;rect64(<hex>),<contact>
        return raw.split(separator: ";").compactMap { item in
            let parts = item.split(separator: ",", maxSplits: 1)
            guard let r = parts.first.flatMap({ Rect64.decode(String($0)) }) else { return nil }
            return PicasaFace(rect: r, contactId: parts.count > 1 ? PicasaContacts.normalizeId(String(parts[1])) : "")
        }
    }
    public var starred: Bool { values["star"]?.lowercased() == "yes" }
    public var caption: String? { values["caption"].flatMap { $0.isEmpty ? nil : $0 } }
    public var filters: [PicasaFilter] { values["filters"].map(PicasaFilter.parseChain) ?? [] }
    /// Album tokens this file belongs to.
    public var albumTokens: [String] { values["albums"]?.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) } ?? [] }
    public var keywords: [String] { values["keywords"]?.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } ?? [] }
    /// `rotate=rotate(n)`: n quarter turns (0…3); Picasa writes `rotate(-1)` for "unset".
    public var rotation: Int {
        guard let r = values["rotate"], let n = Int(r.filter { $0.isNumber || $0 == "-" }), n > 0 else { return 0 }
        return n % 4
    }
    public var hidden: Bool { values["hidden"]?.lowercased() == "yes" }
}

/// Parsed `.picasa.ini` (or legacy `Picasa.ini`).
public struct PicasaIni: Sendable {
    /// Section name → ordered key/values. Keys are case-sensitive as written by Picasa.
    public private(set) var sections: [(name: String, values: [String: String])] = []

    public init(contentsOf url: URL) throws {
        self.init(data: try Data(contentsOf: url))
    }

    public init(data: Data) {
        self.init(text: Self.decode(data))
    }

    public init(text: String) {
        var current: (name: String, values: [String: String])?
        for rawLine in text.split(omittingEmptySubsequences: true, whereSeparator: { $0 == "\n" || $0 == "\r" || $0 == "\r\n" }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix(";") || line.hasPrefix("#") { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                if let c = current { sections.append(c) }
                current = (String(line.dropFirst().dropLast()), [:])
            } else if let eq = line.firstIndex(of: "=") {
                let k = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
                let v = String(line[line.index(after: eq)...])
                if current == nil { current = ("", [:]) }
                current!.values[k] = v
            }
        }
        if let c = current { sections.append(c) }
    }

    /// Picasa 3.9 writes UTF-8 without BOM and CRLF, starting with `[encoding] utf8=1`;
    /// older versions wrote the ANSI code page.
    static func decode(_ data: Data) -> String {
        var d = data
        if d.starts(with: [0xEF, 0xBB, 0xBF]) { d = d.dropFirst(3) }
        if d.starts(with: [0xFF, 0xFE]) { return String(data: d, encoding: .utf16LittleEndian) ?? "" }
        return String(data: d, encoding: .utf8) ?? String(data: d, encoding: .windowsCP1252) ?? ""
    }

    public func section(_ name: String) -> [String: String]? {
        sections.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.values
    }

    /// Folder-level info ([Picasa] section): name, date, location, description, P2category.
    public var folder: [String: String] { section("Picasa") ?? [:] }

    /// Contacts declared in this folder: [Contacts2] `id=name;email;gaia_id` (3.9) and legacy [Contacts] `id=name`.
    public var contacts: [String: (name: String, email: String?)] {
        var out: [String: (String, String?)] = [:]
        for s in ["Contacts", "Contacts2"] {
            for (id, v) in section(s) ?? [:] {
                let parts = v.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
                guard let name = parts.first, !name.isEmpty else { continue }
                out[PicasaContacts.normalizeId(id)] = (name, parts.count > 1 && !parts[1].isEmpty ? parts[1] : nil)
            }
        }
        return out
    }

    /// Local albums declared in this folder ([.album:<token>] sections, Picasa 3.9).
    public var albums: [PicasaAlbum] {
        sections.compactMap { s in
            guard s.name.hasPrefix(".album:") else { return nil }
            let token = s.values["token"] ?? String(s.name.dropFirst(7))
            return PicasaAlbum(token: token, name: s.values["name"], date: s.values["date"],
                               location: s.values["location"], description: s.values["description"])
        }
    }

    /// Per-file entries: every section that is not a reserved one.
    public var entries: [PicasaIniEntry] {
        let reserved: Set<String> = ["picasa", "contacts", "contacts2", "encoding"]
        return sections.compactMap { s in
            if s.name.isEmpty || reserved.contains(s.name.lowercased()) || s.name.hasPrefix(".album:") { return nil }
            return PicasaIniEntry(fileName: s.name, values: s.values)
        }
    }
}
