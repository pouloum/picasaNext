import Foundation

/// `contacts.xml` from the Picasa2/contacts folder (attribute set from Picasa 3.9's writer):
/// ```xml
/// <contacts>
///   <contact id="d5a3ba4f3c09a5c1" name="Jane Doe" modified_time="2012-05-01T10:00" email0="…" email1="…"
///            local_contact="1" hidden_contact="0" gaia_id="…" google_plus_id="…" focus_ids="a;b">
///     <subject user="me@gmail.com" sync_enabled="1"/>
///   </contact>
/// </contacts>
/// ```
/// `id` is `%llx` (lowercase, unpadded): normalize with `PicasaContacts.normalizeId`.
public struct PicasaContacts: Sendable {
    public struct Contact: Sendable, Equatable {
        public var id: String
        public var name: String
        public var emails: [String]
        public var hidden: Bool
        public var email: String? { emails.first }
    }

    /// Contact ids are 64-bit values printed without padding; compare them as numbers.
    public static func normalizeId(_ s: String) -> String {
        UInt64(s.trimmingCharacters(in: .whitespaces), radix: 16).map { String($0, radix: 16) } ?? s.lowercased()
    }

    public private(set) var contacts: [Contact] = []

    public init(contentsOf url: URL) throws {
        try self.init(data: Data(contentsOf: url))
    }

    public init(data: Data) throws {
        let p = Parser()
        let xml = XMLParser(data: data)
        xml.delegate = p
        guard xml.parse() else { throw xml.parserError ?? CocoaError(.fileReadCorruptFile) }
        contacts = p.out
    }

    private final class Parser: NSObject, XMLParserDelegate {
        var out: [Contact] = []
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
            switch name {
            case "contact":
                guard let id = a["id"] else { return }
                let emails = a.filter { $0.key.hasPrefix("email") && !$0.value.isEmpty }.sorted { $0.key < $1.key }.map(\.value)
                out.append(Contact(id: PicasaContacts.normalizeId(id), name: a["name"] ?? "", emails: emails,
                                   hidden: a["hidden_contact"] == "1"))
            default: break
            }
        }
    }
}
