import Foundation

/// Writes XMP sidecars (`IMG_0001.xmp` next to `IMG_0001.JPG`) with the library's edits, in the
/// standard schemas other tools read: rating, caption, keywords, people/pets as named face regions
/// (Metadata Working Group) and as hierarchical keywords (People|Name, Pets|Name, Albums|Name).
/// Sidecars written by another program are never touched; ours are marked xmp:CreatorTool="PicasaNext".
public struct XmpExportReport: Sendable, CustomStringConvertible {
    public var sidecars = 0, changed = 0, written = 0, removed = 0, foreign = 0
    public var failed: [(path: String, error: String)] = []
    public var dryRun = false
    public var description: String {
        "export-xmp: \(sidecars) sidecars · \(changed) to write" + (dryRun ? " (dry run, nothing written)" : " · \(written) written")
            + (removed > 0 ? " · \(removed) obsolete removed" : "")
            + (foreign > 0 ? " · \(foreign) skipped (sidecar from another program)" : "")
            + (failed.isEmpty ? "" : " · \(failed.count) failed")
    }
}

extension Library {
    static let xmpMarker = "xmp:CreatorTool=\"PicasaNext\""

    struct XmpData {
        var star = false
        var caption: String?
        var width: Int?, height: Int?
        var keywords: [String] = []
        var regions: [(name: String, type: String, x: Double, y: Double, w: Double, h: Double)] = []
        var albums: [String] = []
        var isEmpty: Bool { !star && caption == nil && keywords.isEmpty && regions.isEmpty && albums.isEmpty }
    }

    public func exportXmp(dryRun: Bool = false, only: String? = nil, progress: ProgressHandler? = nil) throws -> XmpExportReport {
        var rep = XmpExportReport()
        rep.dryRun = dryRun
        let fm = FileManager.default
        func under(_ path: String) -> Bool {
            guard let only else { return true }
            return path == only || path.hasPrefix(only.hasSuffix("/") ? only : only + "/")
        }
        // Everything with data, plus files that may still have one of our sidecars (data removed since).
        var data: [Int64: XmpData] = [:]
        var paths: [Int64: (folder: String, name: String)] = [:]
        try db.query("""
            SELECT m.id, f.path, m.name, m.star, m.caption, m.width, m.height FROM media m JOIN folders f ON f.id = m.folder_id
            WHERE m.ignored = 0
            """) { r in
            let folder = r.text(1)
            guard under(folder) else { return }
            paths[r.int(0)] = (folder, r.text(2))
            data[r.int(0)] = XmpData(star: r.int(3) != 0, caption: r.optText(4), width: r.optInt(5).map(Int.init), height: r.optInt(6).map(Int.init))
        }
        try db.query("SELECT media_id, tag FROM tags ORDER BY tag") { r in data[r.int(0)]?.keywords.append(r.text(1)) }
        try db.query("""
            SELECT fa.media_id, p.name, fa.x, fa.y, fa.w, fa.h FROM faces fa JOIN persons p ON p.id = fa.person_id
            WHERE fa.ignored = 0 ORDER BY fa.x
            """) { r in data[r.int(0)]?.regions.append((r.text(1), "Face", r.double(2), r.double(3), r.double(4), r.double(5))) }
        try db.query("""
            SELECT a.media_id, p.name, a.x, a.y, a.w, a.h FROM animals a JOIN pets p ON p.id = a.pet_id
            WHERE a.ignored = 0 ORDER BY a.x
            """) { r in data[r.int(0)]?.regions.append((r.text(1), "Pet", r.double(2), r.double(3), r.double(4), r.double(5))) }
        try db.query("SELECT ai.media_id, a.name FROM album_items ai JOIN albums a ON a.id = ai.album_id ORDER BY a.name") { r in
            data[r.int(0)]?.albums.append(r.text(1))
        }

        // RAW+JPEG pairs share one sidecar (IMG_1.CR2 + IMG_1.JPG → IMG_1.xmp): merge their data.
        var bySidecar: [String: XmpData] = [:]
        for (id, p) in paths {
            let base = (p.name as NSString).deletingPathExtension
            let key = p.folder + "/" + base + ".xmp"
            guard let d = data[id] else { continue }
            if var m = bySidecar[key] {
                m.star = m.star || d.star
                m.caption = m.caption ?? d.caption
                m.width = m.width ?? d.width; m.height = m.height ?? d.height
                m.keywords = Array(Set(m.keywords + d.keywords)).sorted()
                if m.regions.isEmpty { m.regions = d.regions }
                m.albums = Array(Set(m.albums + d.albums)).sorted()
                bySidecar[key] = m
            } else {
                bySidecar[key] = d
            }
        }

        let keys = bySidecar.keys.sorted()
        for (i, path) in keys.enumerated() {
            if i % 200 == 0 { progress?(LibraryProgress(stage: "export-xmp", done: i, total: keys.count, current: path)) }
            let d = bySidecar[path]!
            let url = URL(fileURLWithPath: path)
            guard fm.fileExists(atPath: url.deletingLastPathComponent().path) else { continue } // disk not mounted
            let existing = fm.fileExists(atPath: path) ? try? String(contentsOf: url, encoding: .utf8) : nil
            let ours = existing?.contains(Self.xmpMarker) ?? false
            if d.isEmpty {
                // Nothing to say any more: remove a sidecar we wrote earlier, leave anything else.
                guard ours else { continue }
                rep.removed += 1
                if !dryRun { try? fm.removeItem(at: url) }
                continue
            }
            rep.sidecars += 1
            if existing != nil && !ours { rep.foreign += 1; continue }
            let xml = Self.xmp(d)
            if existing == xml { continue }
            rep.changed += 1
            if dryRun { continue }
            do { try Self.replace(url, with: Data(xml.utf8)); rep.written += 1 }
            catch { rep.failed.append((path, error.localizedDescription)) }
        }
        return rep
    }

    static func xmp(_ d: XmpData) -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        func num(_ v: Double) -> String { String(format: "%.6f", v) }
        func bag(_ items: [String]) -> String {
            "<rdf:Bag>" + items.map { "\n     <rdf:li>\(esc($0))</rdf:li>" }.joined() + "\n    </rdf:Bag>"
        }
        let people = d.regions.filter { $0.type == "Face" }.map(\.name)
        let pets = d.regions.filter { $0.type == "Pet" }.map(\.name)
        let subjects = Array(Set(d.keywords + people + pets)).sorted()
        let hierarchy = (Set(people).sorted().map { "People|\($0)" } + Set(pets).sorted().map { "Pets|\($0)" }
                         + d.albums.map { "Albums|\($0)" } + d.keywords)
        var x = """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="PicasaNext">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""
            xmlns:xmp="http://ns.adobe.com/xap/1.0/"
            xmlns:dc="http://purl.org/dc/elements/1.1/"
            xmlns:lr="http://ns.adobe.com/lightroom/1.0/"
            xmlns:mwg-rs="http://www.metadataworkinggroup.com/schemas/regions/"
            xmlns:stArea="http://ns.adobe.com/xmp/sType/Area#"
            xmlns:stDim="http://ns.adobe.com/xap/1.0/sType/Dimensions#"
            \(xmpMarker)\(d.star ? " xmp:Rating=\"5\"" : "")>

        """
        if let c = d.caption {
            x += "   <dc:description>\n    <rdf:Alt>\n     <rdf:li xml:lang=\"x-default\">\(esc(c))</rdf:li>\n    </rdf:Alt>\n   </dc:description>\n"
        }
        if !subjects.isEmpty { x += "   <dc:subject>\n    \(bag(subjects))\n   </dc:subject>\n" }
        if !hierarchy.isEmpty { x += "   <lr:hierarchicalSubject>\n    \(bag(hierarchy))\n   </lr:hierarchicalSubject>\n" }
        if !d.regions.isEmpty {
            x += "   <mwg-rs:Regions rdf:parseType=\"Resource\">\n"
            if let w = d.width, let h = d.height {
                x += "    <mwg-rs:AppliedToDimensions stDim:w=\"\(w)\" stDim:h=\"\(h)\" stDim:unit=\"pixel\"/>\n"
            }
            x += "    <mwg-rs:RegionList>\n     <rdf:Bag>\n"
            for r in d.regions {
                // MWG areas are centred: x, y are the centre of the box.
                x += """
                      <rdf:li rdf:parseType="Resource">
                       <mwg-rs:Name>\(esc(r.name))</mwg-rs:Name>
                       <mwg-rs:Type>\(r.type)</mwg-rs:Type>
                       <mwg-rs:Area stArea:x="\(num(r.x + r.w / 2))" stArea:y="\(num(r.y + r.h / 2))" stArea:w="\(num(r.w))" stArea:h="\(num(r.h))" stArea:unit="normalized"/>
                      </rdf:li>

                """
            }
            x += "     </rdf:Bag>\n    </mwg-rs:RegionList>\n   </mwg-rs:Regions>\n"
        }
        x += "  </rdf:Description>\n </rdf:RDF>\n</x:xmpmeta>\n<?xpacket end=\"w\"?>\n"
        return x
    }
}
