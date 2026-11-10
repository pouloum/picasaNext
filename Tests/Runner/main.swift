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

// MARK: Map clustering
do {
    let pts = [GeoPoint(id: 1, lat: 48.85, lon: 2.35, score: 0.1), GeoPoint(id: 2, lat: 48.86, lon: 2.34, score: 0.9),
               GeoPoint(id: 3, lat: 43.30, lon: 5.37, score: 0.5), GeoPoint(id: 4, lat: 40.71, lon: -74.0, score: 0.5)]
    let france = GeoCluster.cluster(pts, latRange: 42...51, lonRange: -5...9, cells: 10)
    check(france.count == 2 && france[0].count == 2 && france[0].coverId == 2, "Paris photos share a pin with the best cover: \(france)")
    check(!france.flatMap(\.ids).contains(4), "points outside the view are not clustered")
    let paris = GeoCluster.cluster(pts, latRange: 48.84...48.87, lonRange: 2.33...2.36, cells: 10)
    check(paris.count == 2, "zooming in splits a pin: \(paris.map(\.count))")
}

// MARK: Library end-to-end on a temp tree
let tmp = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory())
    .appendingPathComponent("picasanext-tests-\(getpid())")
defer { try? FileManager.default.removeItem(at: tmp) }
do {
    let media = tmp.appendingPathComponent("media/2010")
    try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
    // 640×480 (large enough not to be ignored as a thumbnail) JPEG generated with CoreGraphics.
    let ctx = CGContext(data: nil, width: 640, height: 480, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 640, height: 480))
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
    check(item?.width == 640 && item?.height == 480, "metadata dims")
    check(lib.thumbs.exists(id: ids[0]), "thumbnail written")
    let recent = try await lib.mediaIds(.recent)
    check(recent == ids, "indexed items listed in Last indexed: \(recent)")
    let recentFaces = try await lib.mediaIdsAndYears(.recent, recent: .faces).map(\.id)
    check(recentFaces == ids, "Last indexed ▸ Faces lists the photo with the Picasa face: \(recentFaces)")
    let recentAnimals = try await lib.mediaIdsAndYears(.recent, recent: .animals), recentLabels = try await lib.mediaIdsAndYears(.recent, recent: .labels)
    check(recentAnimals.isEmpty && recentLabels.isEmpty, "Last indexed ▸ Animals / Labels empty before any analysis")
    let picasaFace = try await lib.faces(mediaId: ids[0])
    check(picasaFace.count == 1 && picasaFace[0].human, "a Picasa face counts as made by a person: \(picasaFace)")
    _ = try await lib.withDB { db in try db.run("UPDATE media SET lat = 48.85, lon = 2.35 WHERE id = ?", ids[0]) }
    let geo = try await lib.geoPoints()
    check(geo.map(\.id) == [ids[0]], "geotagged photos listed for the map: \(geo)")

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

    // Name suggestions: two named persons with synthetic prints, one unnamed face close to Bob.
    func blob(_ v: [Float]) -> Data { v.withUnsafeBufferPointer { Data(buffer: $0) } }
    let mid = ids[0]
    let (bobId, janeId) = try await lib.withDB { db in
        (try db.scalar("SELECT id FROM persons WHERE name = 'Bob'")!, try db.scalar("SELECT id FROM persons WHERE name = 'Jane'")!)
    }
    let (pBob, pJane, pNear) = (blob([1, 0, 0]), blob([0, 1, 0]), blob([0.95, 0.31, 0]))
    let unnamed = try await lib.withDB { db -> Int64 in
        try db.run("INSERT INTO faces(media_id,x,y,w,h,person_id,source,print) VALUES(?,0,0,.1,.1,?,1,?)", mid, bobId, pBob)
        try db.run("INSERT INTO faces(media_id,x,y,w,h,person_id,source,print) VALUES(?,0,0,.1,.1,?,1,?)", mid, janeId, pJane)
        return try db.run("INSERT INTO faces(media_id,x,y,w,h,source,print) VALUES(?,.5,.5,.1,.1,1,?)", mid, pNear)
    }
    let made = try await FaceEngine(library: lib).suggestNames()
    let suggested = try await lib.withDB { try $0.scalar("SELECT suggested_person_id FROM faces WHERE id = ?", [unnamed]) }
    check(made == 1 && suggested == bobId, "suggestion goes to nearest person (made \(made), got \(String(describing: suggested)))")
    try await lib.rejectSuggestion(faceId: unnamed)
    _ = try await FaceEngine(library: lib).suggestNames()
    let again = try await lib.withDB { try $0.scalar("SELECT suggested_person_id FROM faces WHERE id = ?", [unnamed]) }
    check(again == nil, "rejected suggestion is not proposed again")

    // Per-photo confirm / reject from a person's "Suggested" grid.
    let (s1, s2) = try await lib.withDB { db -> (Int64, Int64) in
        (try db.run("INSERT INTO faces(media_id,x,y,w,h,source,suggested_person_id) VALUES(?,.6,.6,.1,.1,1,?)", mid, bobId),
         try db.run("INSERT INTO faces(media_id,x,y,w,h,source,suggested_person_id) VALUES(?,.7,.7,.1,.1,1,?)", mid, janeId))
    }
    let rejected = try await lib.rejectSuggestions(personId: bobId, mediaIds: [mid])
    let confirmed = try await lib.confirmSuggestions(personId: janeId, mediaIds: [mid])
    let states = try await lib.withDB { db in
        (try db.scalar("SELECT rejected_person_id FROM faces WHERE id = ?", [s1]), try db.scalar("SELECT person_id FROM faces WHERE id = ?", [s2]))
    }
    check(rejected == 1 && confirmed == 1 && states.0 == bobId && states.1 == janeId, "per-photo reject/confirm of suggestions: \(states)")

    // A JPEG with a small embedded EXIF thumbnail must still give a full-size preview.
    let big = tmp.appendingPathComponent("big.jpg")
    let bctx = CGContext(data: nil, width: 2400, height: 1600, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                         bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    bctx.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1)); bctx.fill(CGRect(x: 0, y: 0, width: 2400, height: 1600))
    let bdest = CGImageDestinationCreateWithURL(big as CFURL, "public.jpeg" as CFString, 1, nil)!
    CGImageDestinationAddImage(bdest, bctx.makeImage()!, [kCGImageDestinationEmbedThumbnail: true] as CFDictionary)
    CGImageDestinationFinalize(bdest)
    let preview = ThumbnailStore.imageThumbnail(big, maxPixel: 1600)
    check(preview?.width == 1600 && preview?.height == 1067, "preview is decoded at requested size, not the embedded thumbnail (\(preview?.width ?? 0)×\(preview?.height ?? 0))")
    let small = ThumbnailStore.imageThumbnail(big, maxPixel: 4000)
    check(small?.width == 2400, "preview never upscales beyond the original")

    // Clustering unnamed faces, then naming a whole cluster.
    let (c1, c2, c3) = (blob([0, 0, 1]), blob([0, 0.1, 0.995]), blob([0.7, 0.7, 0.14]))
    let clusterFaces = try await lib.withDB { db -> [Int64] in
        [try db.run("INSERT INTO faces(media_id,x,y,w,h,source,print) VALUES(?,.1,.1,.3,.3,1,?)", mid, c1),
         try db.run("INSERT INTO faces(media_id,x,y,w,h,source,print) VALUES(?,.2,.2,.2,.2,1,?)", mid, c2),
         try db.run("INSERT INTO faces(media_id,x,y,w,h,source,print) VALUES(?,.3,.3,.1,.1,1,?)", mid, c3)]
    }
    let clusters = try await lib.unnamedClusters()
    let grouped = clusters.first { $0.faceIds.contains(clusterFaces[0]) }
    check(grouped?.faceIds.sorted() == [clusterFaces[0], clusterFaces[1]].sorted(), "similar faces grouped, different one apart: \(clusters.map(\.faceIds))")
    let carol = try await lib.nameFaces(grouped?.faceIds ?? [], name: "Carol")
    let carolFaces = try await lib.withDB { try $0.scalar("SELECT count(*) FROM faces WHERE person_id = ?", [carol!]) }
    check(carolFaces == 2, "naming a cluster names all its faces")

    // Drag and drop in People: a person onto another merges them; a group onto a person names it.
    let tokenBefore = try await lib.changeToken()
    try await lib.mergePerson(carol!, into: bobId)
    let tokenAfter = try await lib.changeToken()
    check(tokenBefore != tokenAfter, "a write moves the change token the app polls")
    // Same check from a second connection, as when picasa-cli scans while the app is open.
    let watcher = try Library(root: tmp.appendingPathComponent("lib"))
    let seen = try await watcher.changeToken()
    _ = try await lib.withDB { db in try db.run("UPDATE media SET star = 1 - star WHERE id = ?", mid) }
    let seenAfter = try await watcher.changeToken()
    check(seen != seenAfter, "a write from another connection moves the token too")
    let names = try await lib.persons().map(\.name)
    let bobCount = try await lib.withDB { try $0.scalar("SELECT count(*) FROM faces WHERE person_id = ?", [bobId]) }
    check(!names.contains("Carol") && names.contains("Bob") && (bobCount ?? 0) >= 3, "merged person disappears, faces move: \(names) \(bobCount ?? 0)")
    let alias = try await lib.nameFace(clusterFaces[2], name: "carol")
    check(alias == bobId, "naming a face with a merged name lands on the person it was merged into")
    let loose = try await lib.withDB { db in try db.run("INSERT INTO faces(media_id,x,y,w,h,source) VALUES(?,.8,.8,.1,.1,1)", mid) }
    try await lib.assignFaces([loose], to: janeId)
    let assigned = try await lib.withDB { try $0.scalar("SELECT person_id FROM faces WHERE id = ?", [loose]) }
    check(assigned == janeId, "dropping a group onto a person names its faces")

    // export-ini: edits written back next to the photos, then read again without duplicating faces.
    let facesBefore = try await lib.stats().faces
    let dry = try await lib.exportIni(dryRun: true)
    let iniURL = media.appendingPathComponent(".picasa.ini")
    let untouched = try String(contentsOf: iniURL, encoding: .utf8)
    check(dry.changed == 1 && untouched.hasPrefix("[IMG_0001.JPG]"), "dry run writes nothing: \(dry)")
    let exp = try await lib.exportIni()
    let written = PicasaIni(data: try Data(contentsOf: iniURL))
    let entry = written.entries.first { $0.fileName == "IMG_0001.JPG" }
    let bobContact = try await lib.withDB { try $0.all("SELECT picasa_id FROM persons WHERE id = ?", [bobId]) { $0.text(0) }.first }
    check(exp.written == 1 && FileManager.default.fileExists(atPath: media.appendingPathComponent(".picasa.ini.bak").path), "ini written with a backup: \(exp) \(exp.failed)")
    check(entry?.caption == "Rouge" && entry?.faces.contains { $0.contactId == bobContact } == true
          && written.contacts[bobContact ?? ""]?.name == "Bob", "stars/captions/named faces/contacts exported: \(written.serialized())")
    let again2 = try await lib.exportIni()
    check(again2.changed == 0, "a second export changes nothing")
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: iniURL.path)
    let reread = try await Scanner(library: lib).scan(root: tmp.appendingPathComponent("media"))
    let facesAfter = try await lib.stats().faces
    check(reread.iniParsed == 1 && facesAfter == facesBefore, "re-reading the exported ini does not duplicate faces (\(facesBefore) → \(facesAfter))")

    // Ignored faces: out of the groups to identify and of suggestions, listed apart, restorable.
    let (fp1, fp2) = (blob([0, 0.6, 0.8]), blob([0, 0.61, 0.79]))
    let (i1, i2) = try await lib.withDB { db -> (Int64, Int64) in
        (try db.run("INSERT INTO faces(media_id,x,y,w,h,source,print) VALUES(?,.15,.15,.3,.3,1,?)", mid, fp1),
         try db.run("INSERT INTO faces(media_id,x,y,w,h,source,print) VALUES(?,.16,.16,.3,.3,1,?)", mid, fp2))
    }
    let grpBefore = try await lib.identityClusters(.face).flatMap(\.faceIds)
    try await lib.setIgnored(.face, [i1, i2], true)
    let grpAfter = try await lib.identityClusters(.face).flatMap(\.faceIds)
    let ignoredGroups = try await lib.identityClusters(.face, ignored: true)
    check(grpBefore.contains(i1) && !grpAfter.contains(i1) && ignoredGroups.first?.faceIds.sorted() == [i1, i2], "ignored faces leave the groups and form their own: \(ignoredGroups)")
    let counts = try await lib.identityCounts(.face)
    check(counts.ignored == 2, "ignored faces counted: \(counts)")
    let ignoredPhotos = try await lib.mediaIds(.identities(.face, named: false, unnamed: false, ignored: true, year: nil))
    check(ignoredPhotos == [mid], "Photos view filter on ignored faces")
    try await lib.setIgnored(.face, [i1], false)
    let restored = try await lib.identityClusters(.face).flatMap(\.faceIds)
    check(restored.contains(i1), "restored face is back in the groups")

    // Pets: animals named like faces, suggestions from prints, year sections.
    let (ap1, ap2, ap3) = (blob([1, 0, 0]), blob([0.98, 0.2, 0]), blob([0, 0, 1]))
    let (a1, a2, a3) = try await lib.withDB { db -> (Int64, Int64, Int64) in
        (try db.run("INSERT INTO animals(media_id,species,confidence,x,y,w,h,print) VALUES(?,'cat',.9,.1,.1,.4,.4,?)", mid, ap1),
         try db.run("INSERT INTO animals(media_id,species,confidence,x,y,w,h,print) VALUES(?,'cat',.9,.5,.5,.3,.3,?)", mid, ap2),
         try db.run("INSERT INTO animals(media_id,species,confidence,x,y,w,h,print) VALUES(?,'dog',.9,.6,.1,.3,.3,?)", mid, ap3))
    }
    let petGroups = try await lib.identityClusters(.pet)
    check(petGroups.contains { $0.faceIds.sorted() == [a1, a2] }, "similar animals grouped: \(petGroups.map(\.faceIds))")
    let minette = try await lib.nameItems(.pet, [a1], name: "Minette")
    let ps = try await IdentityEngine.suggest(library: lib, kind: .pet, threshold: 0.82)
    let petSug = try await lib.region(.pet, id: a2)
    let dog = try await lib.region(.pet, id: a3)
    check(ps == 1 && petSug?.suggestedPersonId == minette && dog?.suggestedPersonId == nil, "pet suggestion goes to the similar animal only (\(ps))")
    let petOwners = try await lib.owners(.pet)
    check(petOwners.map(\.name) == ["Minette"] && petOwners.first?.suggestions == 1, "pets listed with suggestions: \(petOwners)")
    let byPet = try await lib.mediaIds(.search("minette"))
    check(byPet == [mid], "search finds pets by name")
    _ = try await lib.withDB { db in try db.run("UPDATE media SET taken_at = ? WHERE id = ?", DateComponents(calendar: .current, year: 2011, month: 6, day: 1).date!.timeIntervalSince1970, mid) }
    let yearRows = try await lib.mediaIdsAndYears(.pet(minette!))
    let in2011 = try await lib.owners(.pet, year: 2011).count, in2012 = try await lib.owners(.pet, year: 2012).count
    check(yearRows.first?.year == 2011 && in2011 == 1 && in2012 == 0, "years for sections and the year filter (\(yearRows), \(in2011)/\(in2012))")

    // XMP sidecars: written next to the photo, other programs' sidecars left alone.
    let xmpRep = try await lib.exportXmp()
    let sidecar = media.appendingPathComponent("IMG_0001.xmp")
    let xml = (try? String(contentsOf: sidecar, encoding: .utf8)) ?? ""
    check(xmpRep.written == 1 && xml.contains("Rouge") && xml.contains("<mwg-rs:Name>Bob</mwg-rs:Name>")
          && xml.contains("<mwg-rs:Type>Pet</mwg-rs:Type>") && xml.contains("People|Jane") && xml.contains("Rouge"), "xmp sidecar content: \(xmpRep)\n\(xml)")
    let xmpAgain = try await lib.exportXmp()
    check(xmpAgain.changed == 0, "second xmp export changes nothing")
    try "<x:xmpmeta>someone else</x:xmpmeta>".write(to: sidecar, atomically: false, encoding: .utf8)
    let foreign = try await lib.exportXmp()
    let kept = (try? String(contentsOf: sidecar, encoding: .utf8)) ?? ""
    check(foreign.foreign == 1 && kept.contains("someone else"), "a sidecar from another program is never overwritten")
    // Animals without a usable print (analysed while the disk was away) can still be named, one by one.
    let lonely = try await lib.withDB { db in try db.run("INSERT INTO animals(media_id,species,confidence,x,y,w,h,print) VALUES(?,'dog',.9,.2,.6,.2,.2,?)", mid, Data()) }
    let petGroups2 = try await lib.identityClusters(.pet)
    check(petGroups2.contains { $0.faceIds == [lonely] }, "an animal without print is offered to name on its own: \(petGroups2.map(\.faceIds))")
    // A Picasa contact never named, with a face next to named people, must not break the graph.
    _ = try await lib.withDB { db in
        let anon = try db.run("INSERT INTO persons(name, picasa_id) VALUES('', 'deadbeefdeadbeef')")
        _ = try db.run("INSERT INTO faces(media_id,x,y,w,h,person_id,source) VALUES(?,.9,.9,.05,.05,?,0)", mid, anon)
    }
    // Relations: Bob and Jane appear together on IMG_0001 → one moment linking both.
    let rg = try await lib.relationsGraph()
    check(!rg.people.contains { $0.name.isEmpty }, "people without a name stay out of the relations graph")
    let relNames = Dictionary(uniqueKeysWithValues: rg.people.map { ($0.id, $0.name) })
    check(rg.moments.contains { Set($0.people.compactMap { relNames[$0] }).isSuperset(of: ["Bob", "Jane"]) && $0.mediaIds == [mid] },
          "relations: people photographed together form a moment: \(rg.moments.map { $0.people.compactMap { relNames[$0] } })")
    if let b = rg.people.firstIndex(where: { $0.name == "Bob" }), let j = rg.people.firstIndex(where: { $0.name == "Jane" }) {
        let chain = rg.path(from: b, to: j)
        check(chain?.count == 3 && chain?.first == b && chain?.last == j, "relations: path Bob → moment → Jane: \(chain ?? [])")
    } else { check(false, "relations: Bob and Jane in the graph") }
    // A wrong confirmation is undone: the face is unnamed again and not suggested back to that person.
    let wrong = try await lib.withDB { db in try db.run("INSERT INTO faces(media_id,x,y,w,h,source,print,person_id) VALUES(?,.4,.1,.1,.1,1,?,?)", mid, Data([0,0,128,63,0,0,0,0,0,0,0,0]), bobId) }
    let undone = try await lib.unassign(.face, try await lib.regionIds(.face, owner: bobId, mediaIds: [mid]).filter { $0 == wrong })
    _ = try await FaceEngine(library: lib).suggestNames()
    let afterUndo = try await lib.region(.face, id: wrong)
    check(undone == 1 && afterUndo?.personId == nil && afterUndo?.suggestedPersonId != bobId, "unassigned face is unnamed and not suggested back: \(String(describing: afterUndo))")
    // Counter-examples: a face rejected for someone rules them out for its look-alikes.
    let (z1, cx1, cx2) = (blob([0, -1, 0]), blob([0.12, -0.99, 0.05]), blob([0.13, -0.988, 0.06]))
    let (zedFace, twinA, twinB) = try await lib.withDB { db -> (Int64, Int64, Int64) in
        (try db.run("INSERT INTO faces(media_id,x,y,w,h,source,print) VALUES(?,.05,.4,.1,.1,1,?)", mid, z1),
         try db.run("INSERT INTO faces(media_id,x,y,w,h,source,print) VALUES(?,.05,.6,.1,.1,1,?)", mid, cx1),
         try db.run("INSERT INTO faces(media_id,x,y,w,h,source,print) VALUES(?,.05,.8,.1,.1,1,?)", mid, cx2))
    }
    let zed = try await lib.nameFaces([zedFace], name: "Zed")
    _ = try await FaceEngine(library: lib).suggestNames()
    let beforeNeg = try await lib.region(.face, id: twinB)?.suggestedPersonId
    _ = try await lib.reject(.face, owner: zed!, mediaIds: [mid])   // rejects both twins' suggestions…
    _ = try await lib.withDB { db in try db.run("UPDATE faces SET rejected_person_id = NULL WHERE id = ?", twinB) } // …keep only twinA as the example
    _ = try await FaceEngine(library: lib).suggestNames()
    let afterNeg = try await lib.region(.face, id: twinB)?.suggestedPersonId
    check(beforeNeg == zed && afterNeg != zed, "rejecting one face clears its look-alike's suggestion (\(String(describing: beforeNeg)) → \(String(describing: afterNeg)))")
    // Same person imported twice ("Bob" and "bob "): found, then merged into the one with more photos.
    _ = try await lib.withDB { db in
        let dup = try db.run("INSERT INTO persons(name) VALUES('bob ')")
        _ = try db.run("INSERT INTO faces(media_id,x,y,w,h,person_id,source) VALUES(?,.95,.05,.03,.03,?,2)", mid, dup)
    }
    let dups = try await lib.duplicateOwners(.face)
    check(dups.count == 1 && dups[0].first?.id == bobId && dups[0].count == 2, "same name twice is found, Bob first: \(dups.map { $0.map(\.name) })")
    _ = try await lib.mergeDuplicates(.face, dups)
    let leftDups = try await lib.duplicateOwners(.face)
    check(leftDups.isEmpty, "duplicates merged")
    // Rotation (quarter turns, wraps), manual date, future dates sorted as "No date" at the end.
    try await lib.rotate([mid], by: -1)
    let rot = try await lib.rotations()[mid]
    check(rot == 3, "rotate left from 0 is 3 quarter turns: \(String(describing: rot))")
    try await lib.rotate([mid], by: 1)
    let rot0 = try await lib.rotations()[mid]
    check(rot0 == nil, "back to no rotation")
    let when = DateComponents(calendar: .current, year: 2012, month: 7, day: 14).date!
    try await lib.setTakenDate([mid], when)
    let dated = try await lib.items(ids: [mid]).first
    check(dated?.takenAt == when && dated?.dateSource == .manual, "date set by hand")
    let future = try await lib.withDB { db -> Int64 in
        let folder = try db.scalar("SELECT folder_id FROM media WHERE id = ?", [mid])!
        return try db.run("INSERT INTO media(folder_id, name, kind, size, mtime, taken_at, meta_state, thumb_state) VALUES(?, 'clock2037.jpg', 0, 1, 0, ?, 1, 1)",
                          folder, 2_130_000_000.0)
    }
    let rows = try await lib.mediaIdsAndYears(.all)
    check(rows.last?.id == future && rows.last?.year == 0, "a 2037 date is listed last, as no date: \(rows.suffix(2))")
    let yearsList = try await lib.years().map(\.year)
    check(!yearsList.contains(2037), "no 2037 year in the sidebar: \(yearsList)")
    let noDate = try await lib.mediaIds(.year(0))
    check(yearsList.last == 0 && noDate.contains(future), "a No date entry lists it: \(yearsList.suffix(2)) \(noDate)")
    _ = try await lib.withDB { db in try db.run("DELETE FROM media WHERE id = ?", future) }
    // Place names from the geocoding cache; covers default to the best-looking photo, or the one chosen.
    _ = try await lib.withDB { db in
        try db.run("UPDATE media SET lat = 49.18, lon = -0.37 WHERE id = ?", mid)
        try db.run("INSERT INTO geo_names(cell, locality, area, country, at) VALUES(printf('%.2f:%.2f', round(49.18 * 50) / 50.0, round(-0.37 * 50) / 50.0), 'Caen', 'Normandie', 'France', 0)")
    }
    let place = try await lib.placeName(lat: 49.18, lon: -0.37)
    check(place == "Caen, Normandie, France", "place name for a position: \(String(describing: place))")
    let caen = try await lib.mediaIds(.search("caen"))
    check(caen.contains(mid), "search finds photos by town")
    let someFace = try await lib.withDB { try $0.scalar("SELECT id FROM faces WHERE person_id = ? ORDER BY id DESC LIMIT 1", [bobId]) }!
    try await lib.setCover(.face, owner: bobId, region: someFace)
    let cover = try await lib.owners(.face).first { $0.id == bobId }?.coverFaceId
    check(cover == someFace, "chosen cover shown on the card")

    // A hidden copy follows the kept photo: same face, same name; copies are not counted on cards.
    let (copyMedia, copyFace, keptFace) = try await lib.withDB { db -> (Int64, Int64, Int64) in
        let folder = try db.scalar("SELECT folder_id FROM media WHERE id = ?", [mid])!
        let cm = try db.run("INSERT INTO media(folder_id, name, kind, size, mtime, taken_at, meta_state, thumb_state, dup_of) VALUES(?, 'IMG_0001 copie.JPG', 0, 1, 0, 0, 1, 1, ?)", folder, mid)
        let named = try db.all("SELECT id, x, y, w, h FROM faces WHERE media_id = ? AND person_id = ? LIMIT 1", [mid, bobId]) { ($0.int(0), $0.double(1), $0.double(2), $0.double(3), $0.double(4)) }.first!
        // Saved so the face is put back as it was for the tests below.
        try db.run("CREATE TEMP TABLE kept_face AS SELECT * FROM faces WHERE id = ?", named.0)
        // The copy is the same picture resized: its face is at about the same place.
        let cf = try db.run("INSERT INTO faces(media_id,x,y,w,h,source) VALUES(?,?,?,?,?,1)", cm, named.1 + 0.004, named.2 - 0.004, named.3 * 1.02, named.4 * 1.02)
        return (cm, cf, named.0)
    }
    let bobBefore = try await lib.owners(.face).first { $0.id == bobId }?.faces
    _ = try await lib.mirrorToCopies(.face)
    let mirrored = try await lib.region(.face, id: copyFace)?.personId
    let bobAfter = try await lib.owners(.face).first { $0.id == bobId }?.faces
    check(mirrored == bobId && bobBefore == bobAfter, "the copy's face takes the name; the card does not count the copy (\(String(describing: bobBefore)) → \(String(describing: bobAfter)))")
    func faceState(_ id: Int64) async throws -> (person: Int64?, rejected: Int64?, ignored: Bool) {
        try await lib.withDB { db in
            try db.all("SELECT person_id, rejected_person_id, ignored FROM faces WHERE id = ?", [id]) { ($0.optInt(0), $0.optInt(1), $0.int(2) != 0) }.first!
        }
    }
    // Taking the name away on the kept photo sticks: the copy does not give it back, it follows.
    var since = Date().timeIntervalSince1970
    _ = try await lib.unassign(.face, [keptFace])
    _ = try await lib.mirrorToCopies(.face, since: since)
    var keptF = try await faceState(keptFace), copy = try await faceState(copyFace)
    check(keptF.person == nil && keptF.rejected == bobId && copy.person == nil && copy.rejected == bobId,
          "unassign on the kept photo is not undone by its copy: kept \(keptF), copy \(copy)")
    // Ignoring, then restoring, on the kept photo: the copy follows both ways.
    since = Date().timeIntervalSince1970
    _ = try await lib.setIgnored(.face, [keptFace], true)
    _ = try await lib.mirrorToCopies(.face, since: since)
    copy = try await faceState(copyFace)
    check(copy.ignored, "ignoring on the kept photo reaches the copy")
    since = Date().timeIntervalSince1970
    _ = try await lib.setIgnored(.face, [keptFace], false)
    _ = try await lib.mirrorToCopies(.face, since: since)
    keptF = try await faceState(keptFace); copy = try await faceState(copyFace)
    check(!keptF.ignored && !copy.ignored, "restoring on the kept photo reaches the copy: kept \(keptF), copy \(copy)")
    // A name given on the copy (folder view) is not reverted: it goes to the kept photo.
    since = Date().timeIntervalSince1970
    try await lib.assign(.face, [copyFace], to: bobId)
    _ = try await lib.mirrorToCopies(.face, since: since)
    keptF = try await faceState(keptFace); copy = try await faceState(copyFace)
    check(keptF.person == bobId && copy.person == bobId, "a name given on the copy reaches the kept photo: kept \(keptF), copy \(copy)")
    // A neighbouring face (a group photo) is not taken for the copy's face.
    let neighbour = try await lib.withDB { db -> Int64 in
        let f = try db.all("SELECT x, y, w, h FROM faces WHERE id = ?", [keptFace]) { ($0.double(0), $0.double(1), $0.double(2), $0.double(3)) }.first!
        return try db.run("INSERT INTO faces(media_id,x,y,w,h,source) VALUES(?,?,?,?,?,1)", copyMedia, f.0 + f.2 * 1.1, f.1, f.2, f.3)
    }
    _ = try await lib.mirrorToCopies(.face)
    let next = try await faceState(neighbour)
    check(next.person == nil, "the face next to it on the copy stays unnamed")
    _ = try await lib.withDB { db in
        try db.run("DELETE FROM media WHERE id = ?", copyMedia)
        try db.run("""
            UPDATE faces SET (person_id, rejected_person_id, suggested_person_id, ignored, human, human_at, source) =
              (SELECT person_id, rejected_person_id, suggested_person_id, ignored, human, human_at, source FROM temp.kept_face) WHERE id = ?
            """, keptFace)
        try db.run("DROP TABLE temp.kept_face")
    }

    // Reruns keep human decisions: an ignored Vision face survives --redo, not --redo --include-manual.
    _ = try await lib.resetFaces()
    let keptIgnored = try await lib.withDB { try $0.scalar("SELECT ignored FROM faces WHERE id = ?", [i2]) }
    check(keptIgnored == 1, "a face ignored by a human survives a re-analysis")
    _ = try await lib.resetFaces(includeManual: true)
    let gone = try await lib.withDB { try $0.scalar("SELECT count(*) FROM faces WHERE id = ?", [i2]) }
    check(gone == 0, "--include-manual redoes human decisions too")
    _ = try await lib.withDB { db in try db.run("DELETE FROM animals WHERE media_id = ?", mid) } // keep the Discover tests below independent

    // Similar groups + Discover filters on synthetic analysis results.
    let (pA, pB, pC) = (blob([1, 0, 0]), blob([0.99, 0.141, 0]), blob([0, 1, 0]))
    let synth = try await lib.withDB { db -> [Int64] in
        let folder = try db.scalar("SELECT folder_id FROM media LIMIT 1")!
        func add(_ name: String, _ t: Double, _ p: Data?, hash: String? = nil, aesthetic: Double? = nil, utility: Bool = false) throws -> Int64 {
            try db.run("""
                INSERT INTO media(folder_id, name, kind, size, mtime, taken_at, print, quick_hash, aesthetic, utility, meta_state, thumb_state, face_state, analysis_state)
                VALUES(?, ?, 0, 1000, 0, ?, ?, ?, ?, ?, 1, 1, 1, 1)
                """, folder, name, t, p, hash, aesthetic, utility)
        }
        return [try add("burst1.jpg", 1000, pA, aesthetic: 0.9),           // near-dup of burst2 (60 s apart)
                try add("burst2.jpg", 1060, pB, aesthetic: 0.2),
                try add("other.jpg", 1100, pC, aesthetic: 0.1),            // same window, different picture
                try add("copy1.jpg", 5_000_000, pC, hash: "h1"),           // exact duplicates far apart in time
                try add("copy2.jpg", 9_000_000, nil, hash: "h1"),
                try add("receipt.jpg", 2000, pC, aesthetic: 0.95, utility: true)]
    }
    try await lib.withDB { db in
        try db.run("INSERT INTO animals(media_id, species, confidence, x, y, w, h) VALUES(?, 'cat', 0.9, 0, 0, .5, .5)", synth[2])
        try db.run("INSERT INTO labels(media_id, label, confidence) VALUES(?, 'beach', 0.8)", synth[0])
    }
    let sim = try await lib.groupSimilar()
    check(sim.groups == 1 && sim.duplicateGroups == 1 && sim.duplicates == 1, "similar groups: \(sim)")
    let simIds = try await lib.mediaIds(.similar)
    check(simIds == [synth[0], synth[1]], "similar: near-duplicates only, best first: \(simIds)")
    let dupIds = try await lib.mediaIds(.duplicates)
    check(dupIds == [synth[3], synth[4]], "duplicates: the copy kept, then its copy: \(dupIds)")
    let allIds = try await lib.mediaIds(.all)
    check(allIds.contains(synth[3]) && !allIds.contains(synth[4]), "copies are hidden from the library views")
    let groupsSim = try await lib.mediaGroups(.similar)
    check(groupsSim.count == 1 && groupsSim[0].cover == synth[0], "one similar group, the best photo as cover")
    let group = try await lib.similarGroup(of: synth[0])
    check(group.first == synth[0], "best-looking photo first in its group")
    let best = try await lib.mediaIds(.best)
    check(best.contains(synth[0]) && !best.contains(synth[5]), "best excludes documents: \(best)")
    let util = try await lib.mediaIds(.utility), pets = try await lib.mediaIds(.animals)
    check(util == [synth[5]], "utility filter")
    check(pets == [synth[2]], "animals filter")
    let (cat, beach) = (try await lib.mediaIds(.search("cat")), try await lib.mediaIds(.search("beach")))
    check(cat == [synth[2]] && beach == [synth[0]], "search finds animals and labels")
    // Labels, suggestions and multi-term search (synth[0] = beach + trip, synth[1] = trip).
    try await lib.withDB { db in
        try db.run("INSERT INTO tags(media_id, tag) VALUES(?, 'trip'), (?, 'trip')", synth[0], synth[1])
        try db.run("INSERT INTO labels(media_id, label, confidence) VALUES(?, 'musical_instrument', 0.9)", synth[1])
    }
    let summaries = try await lib.labelSummaries()
    let trip = summaries.first { $0.label == "trip" }
    check(trip?.count == 2 && trip?.coverMediaId == synth[0], "label card: count and best-looking cover (\(String(describing: trip)))")
    check(summaries.first { $0.label == "musical_instrument" }?.title == "Musical instrument", "label display name")
    // label_info: precomputed, marked stale by triggers (labels, keywords, photo visibility).
    let fresh = try await lib.labelInfoStale()
    check(!fresh, "label_info fresh after labelSummaries")
    try await lib.withDB { db in try db.run("INSERT INTO tags(media_id, tag) VALUES(?, 'trip')", synth[2]) }
    let stale = try await lib.labelInfoStale()
    check(stale, "a new keyword marks label_info stale")
    let cachedTrip = try await lib.cachedLabelSummaries().first { $0.label == "trip" }?.count
    check(cachedTrip == 2, "cached cards stay until rebuilt")
    let rebuiltTrip = try await lib.labelSummaries().first { $0.label == "trip" }?.count
    check(rebuiltTrip == 3, "rebuilt with the new keyword: \(String(describing: rebuiltTrip))")
    try await lib.withDB { db in try db.run("UPDATE media SET hidden = 1 WHERE id = ?", synth[2]) }
    let hiddenTrip = try await lib.labelSummaries().first { $0.label == "trip" }?.count
    check(hiddenTrip == 2, "hiding a photo updates its labels' counts")
    try await lib.withDB { db in
        try db.run("UPDATE media SET hidden = 0 WHERE id = ?", synth[2])
        try db.run("DELETE FROM tags WHERE media_id = ? AND tag = 'trip'", synth[2])
    }
    let removedTrip = try await lib.labelSummaries().first { $0.label == "trip" }?.count
    check(removedTrip == 2, "removing a keyword updates the card")
    let sugg = try await lib.suggestions(for: "musical inst")
    check(sugg.contains(.label("musical_instrument")), "suggestions match labels with spaces: \(sugg)")
    let janeSugg = try await lib.suggestions(for: "jan")
    check(janeSugg.contains { if case .person(_, "Jane") = $0 { true } else { false } }, "suggestions include people: \(janeSugg)")
    let both = try await lib.mediaIds(.query([.label("trip"), .label("beach")], ""))
    check(both == [synth[0]], "tokens are combined with AND: \(both)")
    let withText = try await lib.mediaIds(.query([.label("trip")], "burst2"))
    check(withText == [synth[1]], "token + free text: \(withText)")
    let vocab = try await lib.searchVocabulary()
    check(vocab.contains(.label("trip")) && vocab.contains(.label("musical_instrument"))
          && vocab.contains { if case .person(_, "Jane") = $0 { true } else { false } }, "search vocabulary: \(vocab.prefix(8))")
    let words = try await lib.mediaIds(.query([], "burst beach"))
    check(words == [synth[0]], "every free-text word must match: \(words)")

    try await lib.withDB { db in for id in synth { try db.run("DELETE FROM media WHERE id = ?", id) } }

    // A series shot in sequence: each photo ≈ the previous one (cos ≈ 0.99), first vs last far apart.
    // It must not chain into a single group.
    let chain = (0..<12).map { i -> Data in let a = Float(i) * 0.14; return blob([cos(a), sin(a), 0]) }
    let chainIds = try await lib.withDB { db -> [Int64] in
        let folder = try db.scalar("SELECT folder_id FROM media LIMIT 1")!
        return try chain.enumerated().map { i, p in
            try db.run("""
                INSERT INTO media(folder_id, name, kind, size, mtime, taken_at, print, meta_state, thumb_state, face_state, analysis_state)
                VALUES(?, ?, 0, 1000, 0, ?, ?, 1, 1, 1, 1)
                """, folder, "series_\(i).jpg", 20_000 + Double([0, 5, 18, 25, 45, 54, 69, 75, 93, 104, 112, 126][i]), p) // irregular: not a time-lapse
        }
    }
    _ = try await lib.groupSimilar()
    let biggest = try await lib.withDB { db in
        try db.scalar("SELECT max(n) FROM (SELECT count(*) n FROM similar WHERE media_id IN (\(chainIds.map(String.init).joined(separator: ","))) GROUP BY group_id)") ?? 0
    }
    check(biggest > 0 && biggest <= 6, "a sequential series is split into small groups, not chained (largest \(biggest))")
    try await lib.withDB { db in for id in chainIds { try db.run("DELETE FROM media WHERE id = ?", id) } }

    // Bursts: 4 shots ≤ 2 s apart (same camera/folder, identical prints) → one burst, not a "similar" group.
    // A 5th shot 30 s later and a photo without EXIF are not part of it.
    let same = blob([0, 0, 1])
    let burstIds = try await lib.withDB { db -> [Int64] in
        let folder = try db.scalar("SELECT folder_id FROM media LIMIT 1")!
        func add(_ n: String, _ t: Double, exif: Bool = true) throws -> Int64 {
            try db.run("""
                INSERT INTO media(folder_id, name, kind, size, mtime, taken_at, print, camera, exif, meta_state, thumb_state, face_state, analysis_state)
                VALUES(?, ?, 0, 1000, 0, ?, ?, ?, ?, 1, 1, 1, 1)
                """, folder, n, t, same, exif ? "Canon EOS" : nil, exif)
        }
        return [try add("b1.jpg", 50_000), try add("b2.jpg", 50_000.5), try add("b3.jpg", 50_002), try add("b4.jpg", 50_003),
                try add("later.jpg", 50_033), try add("noexif.jpg", 50_001, exif: false)]
    }
    let rb = try await lib.groupSimilar()
    let burstList = try await lib.mediaIds(.bursts)
    check(rb.bursts == 1 && burstList == Array(burstIds.prefix(4)), "burst detected in shooting order: \(rb) \(burstList)")
    let simAfter = try await lib.mediaIds(.similar)
    check(!burstIds.prefix(4).contains { simAfter.contains($0) } && simAfter.contains(burstIds[4]) && simAfter.contains(burstIds[5]),
          "burst shots stay out of near-duplicates; the other two look-alikes are grouped: \(simAfter)")
    try await lib.withDB { db in for id in burstIds { try db.run("DELETE FROM media WHERE id = ?", id) } }

    // A time-lapse (a shot every 10 s, same camera, look-alike) is a burst, not "similar" photos.
    let lapse = blob([0.3, 0.3, 0.9])
    let lapseIds = try await lib.withDB { db -> [Int64] in
        let folder = try db.scalar("SELECT folder_id FROM media LIMIT 1")!
        return try (0..<8).map { i in
            try db.run("""
                INSERT INTO media(folder_id, name, kind, size, mtime, taken_at, print, camera, exif, meta_state, thumb_state, face_state, analysis_state)
                VALUES(?, ?, 0, 1000, 0, ?, ?, 'GoPro', 1, 1, 1, 1, 1)
                """, folder, "G\(i).JPG", 90_000 + Double(i) * 10, lapse)
        }
    }
    _ = try await lib.groupSimilar()
    let lapseGroups = try await lib.mediaGroups(.burst)
    check(lapseGroups.contains { Set($0.members) == Set(lapseIds) }, "a time-lapse is one burst: \(lapseGroups.map(\.members.count))")
    try await lib.withDB { db in for id in lapseIds { try db.run("DELETE FROM media WHERE id = ?", id) } }

    // Threshold is remembered.
    let t0 = try await lib.similarThreshold()
    try await lib.setSimilarThreshold(0.93)
    let t1 = try await lib.similarThreshold()
    let rt = try await lib.groupSimilar()
    check(t0 == 0.97 && t1 == 0.93 && rt.threshold == 0.93, "similarity threshold persisted (\(t0) → \(t1), used \(rt.threshold))")

    // Pipeline settings shared by picasa-cli and the app's Settings window.
    let s0 = try await lib.indexSizes()
    try await lib.setIndexSizes(minSize: 0, thumbSize: 300)
    var ix = Indexer(library: lib)
    try await ix.useSavedSizes()
    check(s0 == (200, 512) && ix.minSize == 0 && ix.thumbSize == 300, "index sizes saved and applied (\(s0) → \(ix.minSize), \(ix.thumbSize))")
    try await lib.setIndexSizes(minSize: Library.defaultMinSize, thumbSize: Library.defaultThumbSize)
    let g0 = try await lib.geocodeLimit()
    try await lib.setGeocodeLimit(250)
    let g1 = try await lib.geocodeLimit()
    try await lib.setGeocodeLimit(nil)
    let g2 = try await lib.geocodeLimit()
    check(g0 == nil && g1 == 250 && g2 == nil, "geocode limit saved (\(String(describing: g0)), \(String(describing: g1)), \(String(describing: g2)))")
    check(Library.excludePattern(" Backups ") == "Backups" && Library.excludePattern("/a/b/../c/") == "/a/c", "exclude patterns normalized")
    check(Pipeline.ExportFormat(argument: "ini") == .picasa && Pipeline.ExportFormat(argument: "xmp") == .xmp && Pipeline.ExportFormat(argument: "x") == nil,
          "export format arguments")
    let dryAll = try await Pipeline.export(lib, format: .all, dryRun: true)
    check(dryAll.ini?.dryRun == true && dryAll.xmp?.dryRun == true && dryAll.ini?.written == 0 && dryAll.xmp?.written == 0, "export dry run writes nothing: \(dryAll)")

    // Accented name stored NFD on disk, NFC in .picasa.ini.
    let nfd = "e\u{301}te\u{301}.jpg"
    try FileManager.default.copyItem(at: media.appendingPathComponent("IMG_0001.JPG"), to: media.appendingPathComponent(nfd))
    try "[\u{E9}t\u{E9}.jpg]\ncaption=Accent\n[IMG_0001.JPG]\nstar=yes\nfaces=rect64(3f845bcb59418507),d5a3ba4f3c09a5c1\n"
        .write(to: media.appendingPathComponent(".picasa.ini"), atomically: false, encoding: .utf8)
    _ = try await Scanner(library: lib).scan(root: tmp.appendingPathComponent("media"))
    _ = try await Indexer(library: lib).extractMetadata(); _ = try await Indexer(library: lib).generateThumbnails()
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

// MARK: Folder exclusions and small images
do {
    let root = tmp.appendingPathComponent("excl")
    func jpeg(_ rel: String, _ w: Int, _ h: Int, camera: String? = nil) throws {
        let url = root.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        c.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let d = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil)!
        let props: [CFString: Any] = camera.map { [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFModel: $0]] } ?? [:]
        CGImageDestinationAddImage(d, c.makeImage()!, props as CFDictionary); CGImageDestinationFinalize(d)
    }
    try jpeg("2004/photo_big.jpg", 2000, 1500)                    // kept
    try jpeg("2004/old_phone.jpg", 320, 240, camera: "Nokia 6600") // small but has camera EXIF → kept
    try jpeg("2004/tiny.jpg", 150, 100, camera: "Nokia 6600")      // below min size → ignored
    try jpeg("2004/app_thumb.jpg", 400, 300)                      // small, no EXIF → ignored
    try jpeg("2004/thumbs/t1.jpg", 2000, 1500)                    // default-excluded folder
    try jpeg("LightCraft Library/a/b.jpg", 2000, 1500)            // excluded later by the user

    let lib = try Library(root: tmp.appendingPathComponent("libexcl"))
    let r1 = try await Scanner(library: lib).scan(root: root)
    check(r1.added == 5, "thumbs/ skipped by default: \(r1)")
    try await lib.addExclude("lightcraft library")
    let r2 = try await Scanner(library: lib).scan(root: root)
    check(r2.removed == 1, "user exclusion prunes what was indexed under it: \(r2)")
    _ = try await Indexer(library: lib).extractMetadata()
    let ignored = try await lib.items(ids: try await lib.mediaIds(.ignored)).map(\.name).sorted()
    check(ignored == ["app_thumb.jpg", "tiny.jpg"], "small images without camera EXIF ignored: \(ignored)")
    let unindexed = try await lib.mediaIds(.all)
    check(unindexed.isEmpty, "not shown before they have a thumbnail: \(unindexed)")
    let indexed = try await Indexer(library: lib).run()
    let thumbs = indexed.thumbnails
    check(thumbs == 2, "no thumbnails for ignored images (\(indexed))")
    let visible = try await lib.items(ids: try await lib.mediaIds(.all)).map(\.name).sorted()
    check(visible == ["old_phone.jpg", "photo_big.jpg"], "ignored images hidden from All: \(visible)")
    let estimated = try await lib.items(ids: try await lib.mediaIds(.estimatedDates))
    check(!estimated.isEmpty && estimated.allSatisfy { $0.dateSource == .folder || $0.dateSource == .fileDate }, "photos without a date are estimated and listed: \(estimated.map { ($0.name, $0.dateSource as Any) })")
    let relaxed = try await lib.classifySmall(minSize: 0, thumbSize: 0)
    check(relaxed == 0, "thresholds re-evaluated without rescanning")
    let bogus = (try? await Scanner(library: lib).scan(root: URL(fileURLWithPath: "/no/such/folder"))) == nil
    let knownRoots = try await lib.roots().map(\.path)
    check(bogus && !knownRoots.contains("/no/such/folder"), "a missing folder is not remembered as a root")
    // The disk goes away mid-run: the indexer stops instead of marking everything unreadable.
    try jpeg("2005/late.jpg", 2000, 1500, camera: "Canon")
    _ = try await Scanner(library: lib).scan(root: root)
    let moved = root.deletingLastPathComponent().appendingPathComponent("unplugged")
    try FileManager.default.moveItem(at: root, to: moved)
    var stopped = false
    do { _ = try await Indexer(library: lib).run() } catch is VolumeUnavailable { stopped = true }
    let unmarked = try await lib.withDB { try $0.scalar("SELECT count(*) FROM media WHERE name = 'late.jpg' AND meta_state = 0") }
    check(stopped && unmarked == 1, "indexing stops when the disk vanishes and leaves items pending (\(stopped), \(unmarked ?? -1))")
    try FileManager.default.moveItem(at: moved, to: root)
    let dropped = try await lib.removeRoot(root.path)
    let left = try await lib.stats().images
    check(dropped == 5 && left == 0, "remove-root drops its index (\(dropped), \(left) left)")
} catch { check(false, "exclusions threw \(error)") }

// Date estimates from file and folder names.
do {
    let cal = Calendar.current
    func ymd(_ d: Date?) -> String { d.map { let c = cal.dateComponents([.year, .month, .day, .hour, .minute], from: $0); return "\(c.year!)-\(c.month!)-\(c.day!) \(c.hour!):\(c.minute!)" } ?? "nil" }
    let file = cal.date(from: DateComponents(year: 2023, month: 3, day: 2))!
    let a = DateGuess.guess(name: "IMG_20160910_162536.jpg", folderPath: "/Volumes/photos/2023", fileDate: file)
    check(ymd(a?.0) == "2016-9-10 16:25" && a?.1 == .fileName, "date from IMG_ yyyyMMdd_HHmmss: \(ymd(a?.0))")
    let b = DateGuess.guess(name: "WhatsApp Image 2020-03-01 at 12.05.07.jpeg", folderPath: "/x", fileDate: file)
    check(ymd(b?.0) == "2020-3-1 12:5" && b?.1 == .fileName, "WhatsApp style name: \(ymd(b?.0))")
    let c = DateGuess.guess(name: "12345678_10150000000000001_1234567_n.jpg", folderPath: "/Volumes/photos/2019/2019-06-24 vacances", fileDate: file)
    check(ymd(c?.0) == "2019-6-24 12:0" && c?.1 == .folder, "ids ignored, dated by the folder: \(ymd(c?.0))")
    let d = DateGuess.guess(name: "scan.jpg", folderPath: "/p/2017-09 rentrée", fileDate: file)
    check(ymd(d?.0) == "2017-9-1 0:0" && d?.1 == .folder, "year-month folder: \(ymd(d?.0))")
    let e = DateGuess.guess(name: "scan.jpg", folderPath: "/p/2023", fileDate: file)
    check(e?.0 == file && e?.1 == .folder, "year folder keeps the file date inside that year")
    let f = DateGuess.guess(name: "image_05.bmp", folderPath: "/p/_a_trier/z_recuva", fileDate: file)
    check(f?.0 == file && f?.1 == .fileDate, "nothing in the names: file date")
    let g = DateGuess.guess(name: "IMG_20230231.jpg", folderPath: "/p", fileDate: file)
    check(g?.1 == .fileDate, "impossible dates rejected (31 Feb)")
}

// Map clustering stays linear: 60 000 photos in one place must not freeze the map.
do {
    let pts = (0..<60_000).map { GeoPoint(id: Int64($0), lat: 45 + Double($0 % 7) * 1e-5, lon: 6 + Double($0 % 11) * 1e-5, score: 0) }
    let t0 = Date()
    let c = GeoCluster.cluster(pts, latRange: 44...46, lonRange: 5...7)
    let dt = Date().timeIntervalSince(t0)
    check(c.count == 1 && c[0].count == 60_000 && dt < 1, "clustering 60k photos in one cell: \(String(format: "%.2f", dt)) s")
}

// Per-root counts for the Folders cards (rootStats), through the covering index only.
do {
    let dir = tmp.appendingPathComponent("pn-roots-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let lib = try Library(root: dir)
    try await lib.withDB { db in
        let a = try db.run("INSERT INTO roots(path, added_at) VALUES('/Photos/A', 0)")
        let b = try db.run("INSERT INTO roots(path, added_at) VALUES('/Volumes/NAS/B', 0)")
        _ = try db.run("INSERT INTO roots(path, added_at) VALUES('/Volumes/Empty', 0)")
        let a1 = try db.run("INSERT INTO folders(root_id, path, scanned_at) VALUES(?, '/Photos/A', 100)", a)
        let a2 = try db.run("INSERT INTO folders(root_id, path, scanned_at) VALUES(?, '/Photos/A/2020', 250)", a)
        let b1 = try db.run("INSERT INTO folders(root_id, path, scanned_at) VALUES(?, '/Volumes/NAS/B', 0)", b)
        // name, folder, kind, size, meta, thumb, analysis, face, ignored, dup_of
        let rows: [(String, Int64, Int, Int, Int, Int, Int, Int, Int)] = [
            ("p1.jpg", a1, 0, 10, 1, 1, 1, 1, 0), // photo, done
            ("p2.cr2", a2, 2, 20, 1, 1, 0, 0, 0), // raw counts as a photo; analysis + faces to do
            ("v1.mov", a2, 1, 30, 1, 0, 3, 3, 0), // video, thumbnail to do
            ("t.jpg", a2, 0, 1, 1, 0, 0, 0, 1),   // ignored small image: only its metadata counts
            ("n1.jpg", b1, 0, 5, 0, 0, 0, 0, 0),  // not indexed yet
        ]
        var first: Int64 = 0
        for r in rows {
            let id = try db.run("""
                INSERT INTO media(folder_id, name, kind, size, mtime, meta_state, thumb_state, analysis_state, face_state, ignored)
                VALUES(?, ?, ?, ?, 0, ?, ?, ?, ?, ?)
                """, r.1, r.0, r.2, r.3, r.4, r.5, r.6, r.7, r.8)
            if first == 0 { first = id }
        }
        // A hidden copy of p1 (identical file): not counted as a photo.
        _ = try db.run("INSERT INTO media(folder_id, name, kind, size, mtime, meta_state, thumb_state, analysis_state, face_state, dup_of) VALUES(?, 'p1 copy.jpg', 0, 10, 0, 1, 1, 1, 1, ?)", a2, first)
    }
    let s = try await lib.rootStats()
    check(s.map(\.path) == ["/Photos/A", "/Volumes/Empty", "/Volumes/NAS/B"], "one card per root, by path: \(s.map(\.path))")
    let a = s[0], empty = s[1], b = s[2]
    check(a.folders == 2 && a.photos == 2 && a.videos == 1 && a.copies == 1 && a.ignored == 1 && a.bytes == 71,
          "root A counts (copy and ignored excepted): \(a)")
    check(a.pendingMeta == 0 && a.pendingThumbs == 1 && a.pendingAnalysis == 1 && a.pendingFaces == 1, "root A work left: \(a)")
    check(a.lastScan == Date(timeIntervalSince1970: 250), "last scan of A is its latest folder: \(String(describing: a.lastScan))")
    check(b.photos == 1 && b.pendingMeta == 1 && b.pendingThumbs == 1 && b.lastScan == nil, "root B never fully scanned: \(b)")
    check(empty.folders == 0 && empty.photos == 0 && empty.pending == 0 && empty.lastScan == nil, "empty root: \(empty)")
    let plan = try await lib.withDB { db in
        try db.all("EXPLAIN QUERY PLAN SELECT f.root_id, sum(m.size), sum(m.face_state = 0) FROM media m INDEXED BY media_root_stats JOIN folders f ON f.id = m.folder_id GROUP BY f.root_id") { $0.text(3) }
    }
    check(plan.contains { $0.contains("COVERING INDEX media_root_stats") }, "media read through the covering index: \(plan)")
} catch { check(false, "root stats threw \(error)") }

// Throughput plans and tuning.
do {
    let host = HostInfo(performanceCores: 8, efficiencyCores: 4, memoryGB: 32)
    let ssd = ThroughputPlan.make(profile: .auto, volume: .internalSSD, stage: .thumbnails, host: host)
    check(ssd.concurrency == 8 && ssd.maxConcurrency == 12 && ssd.adaptive && !ssd.sortByPath, "internal SSD plan \(ssd)")
    let hdd = ThroughputPlan.make(profile: .auto, volume: .hdd, stage: .metadata, host: host)
    check(hdd.concurrency == 2 && hdd.maxConcurrency == 2 && hdd.sortByPath, "hard disk plan \(hdd)")
    let nasAnalysis = ThroughputPlan.make(profile: .auto, volume: .internalSSD, stage: .analysis, host: host)
    check(nasAnalysis.concurrency == 4 && nasAnalysis.maxConcurrency == 8, "analysis capped by performance cores \(nasAnalysis)")
    let forced = ThroughputPlan.make(profile: .nas, volume: .internalSSD, stage: .metadata, host: host)
    check(forced.concurrency == 4 && forced.maxConcurrency == 8, "nas profile forces network values \(forced)")
    let eco = ThroughputPlan.make(profile: .eco, volume: .internalSSD, stage: .analysis, host: host)
    check(eco.concurrency == 1 && !eco.adaptive, "eco plan \(eco)")
    let small = ThroughputPlan.make(profile: .auto, volume: .internalSSD, stage: .analysis, host: HostInfo(performanceCores: 4, efficiencyCores: 0, memoryGB: 0.5))
    check(small.maxConcurrency == 1 && small.concurrency == 1, "analysis capped by memory \(small)")

    // Throughput grows with concurrency up to 6, flat after: the tuner climbs, then stays around 6.
    var t = AdaptiveTuner(plan: ThroughputPlan(concurrency: 2, minConcurrency: 1, maxConcurrency: 12, batch: 8, adaptive: true, sortByPath: false))
    for _ in 0..<60 {
        let rate = Double(min(t.concurrency, 6)) * 2 // photos/s
        t.record(items: t.batch, seconds: Double(t.batch) / rate)
    }
    check((5...7).contains(t.concurrency), "tuner settles near the knee: \(t.concurrency)")
    check((14...22).contains(t.batch), "batch aims at ~1.5 s: \(t.batch) at \(min(t.concurrency, 6) * 2)/s")
    let resumed = AdaptiveTuner(plan: ssd, saved: (concurrency: 40, batch: 500))
    check(resumed.concurrency == ssd.maxConcurrency && resumed.batch == AdaptiveTuner.maxBatch, "saved values clamped to the plan")
}

// MARK: auto-scan (targeted scan, folder watcher, catch-up after a restart)
/// Waits for the first watcher batch matching `pred` (nil after `timeout` seconds).
func nextBatch(_ w: (@escaping @Sendable (FolderWatcher.Batch) -> Void) -> FolderWatcher, timeout: Double = 15,
               where pred: @escaping @Sendable (FolderWatcher.Batch) -> Bool) async -> (FolderWatcher, FolderWatcher.Batch?) {
    final class Box: @unchecked Sendable { var batch: FolderWatcher.Batch?; let lock = NSLock() }
    let box = Box()
    let watcher = w { b in box.lock.withLock { if box.batch == nil, pred(b) { box.batch = b } } }
    check(watcher.start(), "watcher starts")
    let end = Date().addingTimeInterval(timeout)
    while Date() < end, box.lock.withLock({ box.batch == nil }) { try? await Task.sleep(for: .milliseconds(100)) }
    return (watcher, box.lock.withLock { box.batch })
}
do {
    let fm = FileManager.default
    let root = tmp.appendingPathComponent("watched")
    @Sendable func touch(_ rel: String) throws {
        let u = root.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: u)
    }
    try touch("a/x.jpg"); try touch("d/old.jpg"); try touch("d/sub/old2.jpg"); try touch(".hidden/h.jpg")
    let lib = try Library(root: tmp.appendingPathComponent("lib-watch"))
    let scanner = Scanner(library: lib)
    let full = try await scanner.scan(root: root)
    check(full.added == 3, "watched root: full scan \(full)")
    let a = root.appendingPathComponent("a").path

    // Created, renamed, a new folder of folders, a deleted folder (reported through its parent).
    try touch("a/y.jpg"); try touch("a/b/c/z.jpg")
    try fm.moveItem(at: root.appendingPathComponent("a/x.jpg"), to: root.appendingPathComponent("a/x2.jpg"))
    try fm.removeItem(at: root.appendingPathComponent("d"))
    let r1 = try await scanner.scan(folders: [a, root.path])
    check(r1.added == 3 && r1.removed == 3, "targeted scan: +y +x2 +z, −x −old −old2: \(r1)")
    let names = try await lib.withDB { db in try db.all("SELECT name FROM media ORDER BY name") { $0.text(0) } }
    check(names == ["x2.jpg", "y.jpg", "z.jpg"], "library after the targeted scan: \(names)")
    let r2 = try await scanner.scan(folders: [a])
    check(r2.added == 0 && r2.removed == 0 && r2.updated == 0, "targeted rescan is a no-op: \(r2)")
    let hidden = try await scanner.scan(folders: [root.appendingPathComponent(".hidden").path])
    check(hidden.folders == 0 && hidden.added == 0, "hidden folders stay skipped: \(hidden)")
    let outside = try await scanner.scan(folders: [tmp.appendingPathComponent("elsewhere").path])
    check(outside.folders == 0, "folders outside the roots are ignored")
    // Gone folder reported directly (no parent event).
    try fm.removeItem(at: root.appendingPathComponent("a/b"))
    let r3 = try await scanner.scan(folders: [root.appendingPathComponent("a/b/c").path])
    check(r3.removed == 1, "a deleted folder reported itself is pruned: \(r3)")
    let r3b = try await scanner.scan(folders: [a])
    check(r3b.removed == 0, "…and its parent no longer lists it: \(r3b)")

    // FSEvents needs fseventsd: unreachable from some sandboxes, where these checks are skipped.
    let fsevents = FolderWatcher.currentEventId() > 0 && FolderWatcher.journalUUID(for: root.path) != nil
    if fsevents {
        // Live watcher: a copied photo is reported once the folder is quiet.
        let (w2, live2) = await nextBatch({ handler in
            let w = FolderWatcher(roots: [root.path], sinceWhen: FolderWatcher.currentEventId(), latency: 0.2, quiet: 0.5, handler: handler)
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { try? touch("a/live.jpg") }
            return w
        // A batch still carrying the changes made just before (renames, deletions) can come first.
        }, where: { $0.folders.contains(a) && FileManager.default.fileExists(atPath: a + "/live.jpg") })
        check(live2 != nil, "live watcher reports the changed folder: \(String(describing: live2))")
        w2.stop()
        let r4 = try await scanner.scan(folders: live2?.folders ?? [])
        check(r4.added == 1, "the watcher's folders bring the new photo in: \(r4)")

        // Restart: the checkpoint is saved, files arrive while "the app is closed", then the journal is replayed.
        let uuid = FolderWatcher.journalUUID(for: root.path)
        check(uuid != nil, "the temporary volume has an FSEvents journal")
        try await lib.saveWatchCheckpoint(eventId: FolderWatcher.currentEventId(), volumes: [root.path: uuid ?? "?"])
        try await Task.sleep(for: .milliseconds(300))
        try touch("a/while-closed.jpg"); try touch("new/n.jpg")
        try await Task.sleep(for: .seconds(1)) // let fseventsd record them
        let plan = try await lib.watchPlan(catchUp: true)
        check(plan.watched == [root.path] && plan.fullRescan.isEmpty && plan.sinceWhen != nil, "restart replays the journal: \(plan)")
        let (w3, replay) = await nextBatch({ FolderWatcher(roots: plan.watched, sinceWhen: plan.sinceWhen, latency: 0.2, quiet: 0.5, handler: $0) },
                                           where: { $0.historyDone })
        w3.stop()
        check(replay?.folders.contains(a) == true || replay?.recursive.isEmpty == false, "replay reports what changed while closed: \(String(describing: replay))")
        let r5 = try await scanner.scan(folders: replay?.folders ?? [], recursive: replay?.recursive ?? [])
        check(r5.added == 2, "catch-up brings both photos in: \(r5)")

        // Fallbacks to a full rescan.
        try await lib.saveWatchCheckpoint(eventId: FolderWatcher.currentEventId(), volumes: [root.path: "another-volume"])
        let other = try await lib.watchPlan(catchUp: true)
        check(other.fullRescan == [root.path], "another journal → full rescan")
        try await lib.saveWatchCheckpoint(eventId: FolderWatcher.currentEventId() + 1_000_000, volumes: [root.path: uuid ?? "?"])
        let future = try await lib.watchPlan(catchUp: true)
        check(future.fullRescan == [root.path] && future.sinceWhen == nil, "invalid event ID → full rescan")
        let noCatchUp = try await lib.watchPlan(catchUp: false)
        check(noCatchUp.fullRescan.isEmpty, "no catch-up asked → no rescan")
    } else {
        print("SKIP auto-scan FSEvents checks: fseventsd not reachable here (event ID \(FolderWatcher.currentEventId()))")
        let plan = try await lib.watchPlan(catchUp: true)
        check(plan.watched.isEmpty && plan.fullRescan == [root.path] && plan.periodic == [root.path],
              "no journal → full rescan at launch, then periodic: \(plan)")
    }
    let fresh = try Library(root: tmp.appendingPathComponent("lib-watch2"))
    _ = try await Scanner(library: fresh).scan(root: root)
    let first = try await fresh.watchPlan(catchUp: true)
    check(first.fullRescan == [root.path], "first launch → full rescan")
    let onByDefault = try await fresh.watchEnabled()
    check(onByDefault, "watching is on by default")
    try await fresh.setWatchEnabled(false)
    let off = try await fresh.watchEnabled()
    check(!off, "watching can be turned off")

    // Unmounted volume: the root disappears, nothing is pruned.
    let before = try await lib.withDB { db in try db.scalar("SELECT count(*) FROM media") }
    let moved = tmp.appendingPathComponent("watched-unplugged")
    try fm.moveItem(at: root, to: moved)
    let r6 = try await scanner.scan(folders: [a, root.path])
    let left = try await lib.withDB { db in try db.scalar("SELECT count(*) FROM media") }
    check(r6.removed == 0 && left == before, "a missing root is left untouched: \(r6), \(String(describing: left)) media")
} catch { check(false, "auto-scan threw \(error)") }

print("\(passed) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
