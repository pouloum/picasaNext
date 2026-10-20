// Minimal test runner (built by `TESTS=1 ./build.sh debug`): no XCTest/swift-testing dependency.
import CoreGraphics
import Foundation
import ImageIO
import PicasaCore
import PicasaFormats

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var passed = 0
func check(_ cond: @autoclosure () -> Bool, _ msg: String, line: Int = #line) {
    if cond() { passed += 1 } else { failures += 1; print("FAIL line \(line): \(msg)") }
}
func near(_ a: Double, _ b: Double, _ eps: Double = 1e-3) -> Bool { abs(a - b) < eps }

// MARK: rect64
do {
    let r = Rect64.decode("3f845bcb59418507")!
    check(near(r.left, 0.248) && near(r.top, 0.359) && near(r.right, 0.349) && near(r.bottom, 0.520), "rect64 sample \(r)")
    let short = Rect64.decode("5bcb59418507")! // leading zeros omitted → left = 0
    check(short.left == 0 && near(short.top, 0.359), "rect64 short form")
    check(Rect64.decode(Rect64.encode(r))! == r, "rect64 round trip")
    check(Rect64.decode("rect64(3f845bcb59418507)") == r, "rect64() wrapper")
}

// MARK: .picasa.ini
do {
    let ini = PicasaIni(text: """
    [encoding]\r
    utf8=1\r
    [Picasa]\r
    name=Vacances\r
    [Contacts2]\r
    d5a3ba4f3c09a5c1=Jane Doe;jane@example.com;\r
    0e32c49663dba60c=John Doe;;\r
    [.album:a69213fd86eaf86a9efb18b412c70b0c]\r
    name=Best of\r
    token=a69213fd86eaf86a9efb18b412c70b0c\r
    date=2011-12-02T08:50:47-08:00\r
    [IMG_0001.JPG]\r
    star=yes\r
    faces=rect64(3f845bcb59418507),d5a3ba4f3c09a5c1;rect64(4b60342679997e1a),ffffffffffffffff\r
    filters=crop64=1,30a730d2bd3fe4c2;tilt=1,0.280632,0.000000;enhance=1;\r
    albums=a69213fd86eaf86a9efb18b412c70b0c\r
    rotate=rotate(3)\r
    keywords=beach, sun\r
    [IMG_0002.JPG]\r
    rotate=rotate(-1)\r
    """)
    check(ini.folder["name"] == "Vacances", "folder name")
    check(ini.contacts["d5a3ba4f3c09a5c1"]?.name == "Jane Doe" && ini.contacts["d5a3ba4f3c09a5c1"]?.email == "jane@example.com", "contacts2 with email")
    check(ini.contacts["e32c49663dba60c"]?.email == nil, "contacts2 id normalized (leading zero), no email")
    check(ini.albums.first?.name == "Best of", "album section")
    check(ini.entries.count == 2, "two file entries ([encoding] reserved), got \(ini.entries.count)")
    let e = ini.entries[0]
    check(e.starred && e.rotation == 3 && e.keywords == ["beach", "sun"], "entry flags")
    check(ini.entries[1].rotation == 0, "rotate(-1) means unset")
    check(e.faces.count == 2 && !e.faces[0].isUnnamed && e.faces[1].isUnnamed, "faces")
    check(e.filters.map(\.name) == ["crop64", "tilt", "enhance"], "filter chain \(e.filters.map(\.name))")
    check(e.filters[0].cropRect != nil && e.filters[1].params == ["0.280632", "0.000000"], "filter params")
    check(e.albumTokens == ["a69213fd86eaf86a9efb18b412c70b0c"], "album tokens")
    let latin1 = PicasaIni(data: "[Picasa]\nname=\u{E9}t\u{E9}\n".data(using: .windowsCP1252)!)
    check(latin1.folder["name"] == "été", "ANSI fallback")
}

// MARK: contacts.xml
do {
    let xml = """
    <?xml version="1.0" encoding="utf-8"?>
    <contacts><contact id="0d5a3ba4f3c09a5c" name="Jane Doe" email0="jane@example.com" local_contact="1">
    <subject user="me@gmail.com" sync_enabled="1"/></contact></contacts>
    """
    let c = try PicasaContacts(data: Data(xml.utf8))
    check(c.contacts.first?.id == "d5a3ba4f3c09a5c" && c.contacts.first?.email == "jane@example.com", "contacts.xml \(c.contacts)")
} catch { check(false, "contacts.xml threw \(error)") }

// MARK: PMP / thumbindex (synthetic files)
func le<T: FixedWidthInteger>(_ v: T) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
func pmp(type: UInt16, count: UInt32, payload: Data) -> Data {
    le(UInt32(0x3FCC_CCCD)) + le(type) + le(UInt16(0x1332)) + le(UInt32(2)) + le(type) + le(UInt16(0x1332)) + le(count) + payload
}
func entry(_ name: String, parent: UInt32, kind: UInt32, size: UInt32 = 0) -> Data {
    Data(name.utf8) + Data([0]) + le(UInt64(130_000_000_000_000_000)) + le(UInt64(130_000_000_000_000_000))
        + le(size) + le(kind) + Data([0, 1]) + le(parent)
}
do {
    let s = try PMPColumn(data: pmp(type: 0, count: 2, payload: Data("hello\0wörld\0".utf8)), name: "caption")
    check(s.values == [.string("hello"), .string("wörld")], "pmp strings")
    let u = try PMPColumn(data: pmp(type: 4, count: 1, payload: le(UInt64(0x3f845bcb59418507))), name: "facerect")
    check(u[0]?.uint == 0x3f845bcb59418507, "pmp uint64")
    let d = try PMPColumn(data: pmp(type: 2, count: 1, payload: le((25569.5).bitPattern)), name: "date")
    check(d[0]?.date == Date(timeIntervalSince1970: 43200), "pmp OLE date")
    let i8 = try PMPColumn(data: pmp(type: 3, count: 1, payload: Data([0xFF])), name: "flag")
    check(i8[0]?.int == -1, "pmp int8 is signed")
    check((try? PMPColumn(data: le(UInt32(1)) + Data(count: 16), name: "x")) == nil, "pmp bad magic rejected")
    check((try? PMPColumn(data: pmp(type: 1, count: 0xFFFF_FFFF, payload: Data()), name: "x")) == nil, "pmp absurd count rejected")

    let ti = le(UInt32(0x4046_6666)) + le(UInt32(4))
        + entry("C:\\Users\\me\\Pictures\\2010\\", parent: 0xFFFF_FFFF, kind: 1)
        + entry("IMG_0001.JPG", parent: 0, kind: 2) + entry("", parent: 1, kind: 2) + entry("", parent: 0xFFFF_FFFF, kind: 0)
    let index = try ThumbIndex(data: ti)
    check(index.entries.count == 4, "thumbindex count")
    check(index.path(of: 1) == "C:\\Users\\me\\Pictures\\2010\\IMG_0001.JPG", "thumbindex path \(index.path(of: 1) ?? "nil")")
    check(index.entries[2].isVirtual && index.entries[2].parent == 1, "virtual face entry")
    check(index.entries[1].mtime != nil, "FILETIME decoded")
    check((try? ThumbIndex(data: le(UInt32(0x4046_6666)) + le(UInt32(0xFFFF_FFFF)))) == nil, "thumbindex absurd count rejected")
}

// MARK: Library end-to-end on a temp tree
let tmp = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory())
    .appendingPathComponent("picasanext-tests-\(getpid())")
defer { try? FileManager.default.removeItem(at: tmp) }
do {
    let media = tmp.appendingPathComponent("media/2010")
    try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
    // 64×48 JPEG generated with CoreGraphics.
    let ctx = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
    let dest = CGImageDestinationCreateWithURL(media.appendingPathComponent("IMG_0001.JPG") as CFURL, "public.jpeg" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil); CGImageDestinationFinalize(dest)
    try "[IMG_0001.JPG]\nstar=yes\nfaces=rect64(3f845bcb59418507),d5a3ba4f3c09a5c1\n[Contacts2]\nd5a3ba4f3c09a5c1=Jane;;\n"
        .write(to: media.appendingPathComponent(".picasa.ini"), atomically: false, encoding: .utf8)

    let lib = try Library(root: tmp.appendingPathComponent("lib"))
    let r1 = try await Scanner(library: lib).scan(root: tmp.appendingPathComponent("media"))
    check(r1.added == 1 && r1.iniParsed == 1, "scan adds 1 file + ini: \(r1)")
    let r2 = try await Scanner(library: lib).scan(root: tmp.appendingPathComponent("media"))
    check(r2.added == 0 && r2.updated == 0 && r2.iniParsed == 0, "rescan is a no-op: \(r2)")
    _ = try await Indexer(library: lib).extractMetadata()
    _ = try await Indexer(library: lib).generateThumbnails()
    let s = try await lib.stats()
    check(s.images == 1 && s.starred == 1 && s.namedFaces == 1 && s.pendingThumbs == 0, "stats \(s)")
    let ids = try await lib.mediaIds(.search("jane"))
    check(ids.count == 1, "search by person name")
    let item = try await lib.items(ids: ids).first
    check(item?.width == 64 && item?.height == 48, "metadata dims")
    check(lib.thumbs.exists(id: ids[0]), "thumbnail written")

    // Synthetic db3 written on "Windows": one folder, the image, one virtual face entry for person row 1.
    let db3 = tmp.appendingPathComponent("db3")
    try FileManager.default.createDirectory(at: db3, withIntermediateDirectories: true)
    try (le(UInt32(0x4046_6666)) + le(UInt32(3)) + entry("D:\\Photos\\2010\\", parent: 0xFFFF_FFFF, kind: 1)
         + entry("img_0001.jpg", parent: 0, kind: 2) + entry("", parent: 1, kind: 2)).write(to: db3.appendingPathComponent("thumbindex.db"))
    func str(_ v: [String]) -> Data { v.reduce(Data()) { $0 + Data($1.utf8) + Data([0]) } }
    try pmp(type: 0, count: 3, payload: str(["", "Rouge", ""])).write(to: db3.appendingPathComponent("imagedata_caption.pmp"))
    try pmp(type: 4, count: 3, payload: le(UInt64(1)) + le(UInt64(1)) + le(UInt64(0x1000_1000_5000_6000))).write(to: db3.appendingPathComponent("imagedata_facerect.pmp"))
    try pmp(type: 1, count: 3, payload: le(UInt32(0)) + le(UInt32(0)) + le(UInt32(1))).write(to: db3.appendingPathComponent("imagedata_personalbumid.pmp"))
    try pmp(type: 0, count: 2, payload: str(["]star", "]facealbum:1"])).write(to: db3.appendingPathComponent("albumdata_token.pmp"))
    try pmp(type: 0, count: 2, payload: str(["", "Bob"])).write(to: db3.appendingPathComponent("albumdata_name.pmp"))
    try "D:\\Photos\\2010\\img_0001.jpg\n".write(to: db3.appendingPathComponent("starlist.txt"), atomically: false, encoding: .utf8)
    let rep = try await lib.importDB3(at: db3, reuseThumbnails: false)
    check(rep.matched == 1 && rep.faces == 1 && rep.namedFaces == 1 && rep.stars == 1 && rep.captions == 1, "db3 import: \(rep)")
    let bob = try await lib.mediaIds(.search("bob"))
    check(bob == ids, "db3 person searchable")
    let caption = try await lib.items(ids: ids).first?.caption
    check(caption == "Rouge", "db3 caption")

    // Accented name stored NFD on disk, NFC in .picasa.ini.
    let nfd = "e\u{301}te\u{301}.jpg"
    try FileManager.default.copyItem(at: media.appendingPathComponent("IMG_0001.JPG"), to: media.appendingPathComponent(nfd))
    try "[\u{E9}t\u{E9}.jpg]\ncaption=Accent\n[IMG_0001.JPG]\nstar=yes\nfaces=rect64(3f845bcb59418507),d5a3ba4f3c09a5c1\n"
        .write(to: media.appendingPathComponent(".picasa.ini"), atomically: false, encoding: .utf8)
    _ = try await Scanner(library: lib).scan(root: tmp.appendingPathComponent("media"))
    let accent = try await lib.mediaIds(.search("Accent"))
    check(accent.count == 1, "NFC ini section matches NFD file name")

    // Unmounted-disk stub: root exists but is empty → refuse, keep everything.
    let stub = tmp.appendingPathComponent("stub")
    try FileManager.default.createDirectory(at: stub.appendingPathComponent("a"), withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: media.appendingPathComponent("IMG_0001.JPG"), to: stub.appendingPathComponent("a/x.jpg"))
    _ = try await Scanner(library: lib).scan(root: stub)
    try FileManager.default.removeItem(at: stub.appendingPathComponent("a"))
    let before = try await lib.stats().images
    let threw = (try? await Scanner(library: lib).scan(root: stub)) == nil
    let after = try await lib.stats().images
    check(threw && before == after, "empty root stub is not pruned (\(before) → \(after))")

    try FileManager.default.removeItem(at: media.appendingPathComponent(nfd))
    try FileManager.default.removeItem(at: media.appendingPathComponent("IMG_0001.JPG"))
    let r3 = try await Scanner(library: lib).scan(root: tmp.appendingPathComponent("media"))
    check(r3.removed == 2, "deleted files pruned: \(r3)")
} catch { check(false, "library e2e threw \(error)") }

print("\(passed) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
