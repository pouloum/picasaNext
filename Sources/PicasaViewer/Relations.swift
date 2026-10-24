import AppKit
import PicasaCore
import SwiftUI

/// Force-directed layout (d3-force style): springs on links, repulsion between all nodes,
/// collisions, and a weak pull to the centre. A few hundred nodes: plain O(n²) is fast enough.
struct ForceLayout: Sendable {
    struct Node: Sendable { var p: CGPoint; var v: CGVector = .zero; var r: CGFloat; var charge: CGFloat }
    struct Link: Sendable { var a: Int; var b: Int; var distance: CGFloat; var strength: CGFloat }

    var nodes: [Node]
    var links: [Link]
    var alpha: CGFloat = 1
    private var bias: [CGFloat] // d3: links move the less connected end more

    init(nodes: [Node], links: [Link]) {
        self.nodes = nodes
        self.links = links
        var degree = [CGFloat](repeating: 0, count: nodes.count)
        for l in links { degree[l.a] += 1; degree[l.b] += 1 }
        bias = links.map { degree[$0.a] / max(1, degree[$0.a] + degree[$0.b]) }
    }

    var settled: Bool { alpha < 0.004 }

    mutating func tick() {
        let n = nodes.count
        for (i, l) in links.enumerated() {
            let a = nodes[l.a].p, b = nodes[l.b].p
            var dx = b.x + nodes[l.b].v.dx - a.x - nodes[l.a].v.dx, dy = b.y + nodes[l.b].v.dy - a.y - nodes[l.a].v.dy
            if dx == 0 && dy == 0 { dx = 0.01; dy = 0.01 }
            let len = (dx * dx + dy * dy).squareRoot()
            let k = (len - l.distance) / len * alpha * l.strength
            dx *= k; dy *= k
            nodes[l.b].v.dx -= dx * bias[i]; nodes[l.b].v.dy -= dy * bias[i]
            nodes[l.a].v.dx += dx * (1 - bias[i]); nodes[l.a].v.dy += dy * (1 - bias[i])
        }
        for i in 0..<n {
            for j in (i + 1)..<n {
                var dx = nodes[j].p.x - nodes[i].p.x, dy = nodes[j].p.y - nodes[i].p.y
                if dx == 0 && dy == 0 { dx = CGFloat.random(in: -0.5...0.5); dy = CGFloat.random(in: -0.5...0.5) }
                let d2 = max(dx * dx + dy * dy, 1)
                // Repulsion (many-body), limited in range like d3's distanceMax.
                if d2 < 600 * 600 {
                    let f = alpha / d2
                    nodes[i].v.dx += dx * nodes[j].charge * f; nodes[i].v.dy += dy * nodes[j].charge * f
                    nodes[j].v.dx -= dx * nodes[i].charge * f; nodes[j].v.dy -= dy * nodes[i].charge * f
                }
                // Collision.
                let rr = nodes[i].r + nodes[j].r + 3
                if d2 < rr * rr {
                    let d = d2.squareRoot(), push = (rr - d) / d * 0.5
                    nodes[i].p.x -= dx * push; nodes[i].p.y -= dy * push
                    nodes[j].p.x += dx * push; nodes[j].p.y += dy * push
                }
            }
        }
        for i in 0..<n {
            nodes[i].v.dx -= nodes[i].p.x * 0.03 * alpha
            nodes[i].v.dy -= nodes[i].p.y * 0.03 * alpha
            nodes[i].v.dx *= 0.6; nodes[i].v.dy *= 0.6
            nodes[i].p.x += nodes[i].v.dx; nodes[i].p.y += nodes[i].v.dy
        }
        alpha += (0 - alpha) * 0.0228 // d3's default decay (300 ticks)
    }
}

/// Relations. By default only people: circles (face, size = photos, ring colour = circle of family /
/// friends, with a soft halo per circle) linked directly when photographed together — thickness =
/// photos together, links under a threshold hidden. "Moments" adds the squares (photos of the same
/// group) between them. Click: a person's links and photos · double-click: centred view ·
/// ⌘-click two people: the chain between them · years slider with play.
struct RelationsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var graph: RelationsGraph?
    @State private var positions: [Int: CGPoint] = [:]
    @State private var settling = false
    @State private var images: [Int: NSImage] = [:]
    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @GestureState private var pinch: CGFloat = 1
    @State private var hover: Int?
    @State private var focus: Int?
    @State private var panel: Panel?
    @State private var size: CGSize = .zero
    @State private var scrollMonitor: Any?
    @State private var loading = true
    @State private var mouseInside = false
    @State private var signature = ""
    @AppStorage("relations.moments") private var showMoments = false
    @AppStorage("relations.minTogether") private var minTogether = 3
    // Years: nil = all; otherwise that year only, or up to it (cumulative). Play walks the years.
    @State private var year: Int?
    @State private var cumulative = false
    @State private var playing = false
    @State private var ego: Int?
    @State private var egoPos: [Int: CGPoint] = [:]
    @State private var pathStart: Int?
    @State private var path: [Int]?
    @State private var layoutTask: Task<Void, Never>?
    /// Node being dragged (-1: the background, i.e. panning).
    @State private var dragging: Int?
    @State private var panDrag: CGSize = .zero

    struct Panel: Equatable { var title: String; var subtitle: String; var mediaIds: [Int64]; var node: Int }
    /// People photographed together within the years shown: weight = photos, and which photos.
    struct Edge { var a: Int; var b: Int; var photos: Int; var moments: [Int] }

    static let palette: [NSColor] = [.systemRed, .systemBlue, .systemGreen, .systemYellow, .systemPurple, .systemOrange,
                                     .systemTeal, .systemPink, .systemMint, .systemIndigo, .systemBrown, .systemCyan]

    var peopleCount: Int { graph?.people.count ?? 0 }
    func isPerson(_ i: Int) -> Bool { i < peopleCount }
    var zoom: CGFloat { scale * pinch }

    var personIndex: [Int64: Int] { Dictionary(uniqueKeysWithValues: (graph?.people ?? []).enumerated().map { ($1.id, $0) }) }

    func momentCount(_ mi: Int) -> Int {
        guard let g = graph else { return 0 }
        let m = g.moments[mi]
        guard let y = year else { return m.mediaIds.count }
        return m.years.reduce(0) { $0 + (($1 != 0 && (cumulative ? $1 <= y : $1 == y)) ? 1 : 0) }
    }

    /// Person–person links in the years shown (all, before the threshold).
    var allEdges: [Edge] {
        guard let g = graph else { return [] }
        let index = personIndex
        var acc: [[Int]: Edge] = [:]
        for (mi, m) in g.moments.enumerated() {
            let n = momentCount(mi)
            guard n > 0 else { continue }
            let ps = m.people.compactMap { index[$0] }.sorted()
            for x in 0..<ps.count { for y in (x + 1)..<ps.count {
                let k = [ps[x], ps[y]]
                acc[k, default: Edge(a: ps[x], b: ps[y], photos: 0, moments: [])].photos += n
                acc[k]!.moments.append(mi)
            } }
        }
        return Array(acc.values)
    }

    var edges: [Edge] { allEdges.filter { $0.photos >= minTogether } }

    var maxWeight: Int { max(1, allEdges.map(\.photos).max() ?? 1) }

    func radius(_ i: Int) -> CGFloat {
        guard let g = graph else { return 10 }
        if isPerson(i) { return 10 + 5 * log2(CGFloat(g.people[i].photos) + 1) }
        return (12 + 7 * log2(CGFloat(max(1, momentCount(i - peopleCount))) + 1)) / 2
    }

    var yearRange: ClosedRange<Int>? {
        let ys = graph?.moments.flatMap(\.years).filter { $0 > 0 } ?? []
        guard let a = ys.min(), let b = ys.max(), a < b else { return nil }
        return a...b
    }

    /// What is on screen: people with at least one link over the threshold (people mode) or with a
    /// visible moment (moments mode), restricted to the ego view if any.
    var visibleNodes: Set<Int> {
        guard let g = graph else { return [] }
        var out: Set<Int> = []
        if showMoments {
            let index = personIndex
            for mi in g.moments.indices where momentCount(mi) > 0 {
                out.insert(peopleCount + mi)
                for p in g.moments[mi].people { if let i = index[p] { out.insert(i) } }
            }
        } else {
            for e in edges { out.insert(e.a); out.insert(e.b) }
        }
        if ego != nil { out = out.filter { egoPos[$0] != nil } }
        if let e = ego { out.insert(e) }
        return out
    }

    func pos(_ i: Int) -> CGPoint? { ego != nil ? egoPos[i] : positions[i] }

    var body: some View {
        HStack(spacing: 0) {
            if !loading, let g = graph, !g.moments.isEmpty {
                sidePanel
                Divider()
            }
            ZStack(alignment: .topLeading) {
                if loading {
                    ProgressView("Building the graph…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let g = graph, g.moments.isEmpty {
                    ContentUnavailableView("No relations yet", systemImage: "point.3.connected.trianglepath.dotted",
                                           description: Text("Name people in People: photos where several named people appear together build the graph."))
                } else {
                    canvas
                        .gesture(panGesture)
                        .simultaneousGesture(MagnifyGesture().updating($pinch) { v, s, _ in s = v.magnification }
                            .onEnded { v in scale = min(6, max(0.1, scale * v.magnification)) })
                        .onTapGesture(coordinateSpace: .local) { p in tap(at: p) }
                        .onContinuousHover { phase in
                            if case let .active(p) = phase { hover = hit(p); mouseInside = true } else { hover = nil; mouseInside = false }
                        }
                    statusBanner.padding(10)
                    VStack { Spacer(); HStack { Spacer(); controls } }.padding(10)
                    if let h = hover { tooltip(h) }
                }
            }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
            .background(Color(white: 0.11))
            if let p = panel {
                Divider()
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.title).font(.headline).lineLimit(3)
                            Text(p.subtitle).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { panel = nil; focus = nil; path = nil } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless)
                    }
                    .padding(10)
                    CollectionGrid(ids: p.mediaIds, cellSize: 100, thumbs: model.thumbs, resetKey: [p.node, p.mediaIds.count]) { model.open(p.mediaIds, at: $0) }
                }
                .frame(width: 340)
            }
        }
        .task(id: model.revision) { await load() }
        .task(id: playing) { await play() }
        .onChange(of: showMoments) { relayout() }
        .onChange(of: minTogether) { relayout() }
        .onAppear(perform: installScroll)
        .onDisappear { if let m = scrollMonitor { NSEvent.removeMonitor(m); scrollMonitor = nil }; layoutTask?.cancel() }
        .onExitCommand { if ego != nil { exitEgo() } else { focus = nil; panel = nil; path = nil; pathStart = nil } }
    }

    // MARK: Drawing

    func toView(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x * zoom + size.width / 2 + offset.width + panDrag.width, y: p.y * zoom + size.height / 2 + offset.height + panDrag.height)
    }

    func toGraph(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - size.width / 2 - offset.width) / zoom, y: (p.y - size.height / 2 - offset.height) / zoom)
    }

    /// Highlighted nodes: the path, or the focused person and those they are photographed with.
    var related: Set<Int>? {
        if let p = path { return Set(p) }
        guard let f = focus, isPerson(f) else { return nil }
        var s: Set<Int> = [f]
        for e in edges where e.a == f || e.b == f { s.insert(e.a); s.insert(e.b); if showMoments { s.formUnion(e.moments.map { peopleCount + $0 }) } }
        return s
    }

    var canvas: some View {
        Canvas { ctx, _ in
            guard let g = graph else { return }
            let vis = visibleNodes, rel = related, es = edges, maxW = CGFloat(maxWeight)
            // Halos: one soft disc per circle of people (≥ 3 on screen), behind everything.
            if rel == nil && ego == nil {
                var groups: [Int: [CGPoint]] = [:]
                for i in vis where isPerson(i) { if let p = pos(i) { groups[g.people[i].community, default: []].append(p) } }
                for (c, pts) in groups where pts.count >= 3 {
                    let cx = pts.map(\.x).reduce(0, +) / CGFloat(pts.count), cy = pts.map(\.y).reduce(0, +) / CGFloat(pts.count)
                    let r = (pts.map { hypot($0.x - cx, $0.y - cy) }.sorted()[Int(Double(pts.count - 1) * 0.85)] + 50) * zoom
                    let ctr = toView(CGPoint(x: cx, y: cy))
                    let col = Color(nsColor: Self.palette[c % Self.palette.count])
                    ctx.fill(Path(ellipseIn: CGRect(x: ctr.x - r, y: ctr.y - r, width: 2 * r, height: 2 * r)),
                             with: .radialGradient(Gradient(colors: [col.opacity(0.16), col.opacity(0.0)]), center: ctr, startRadius: 0, endRadius: r))
                }
            }
            // Links.
            let pathPairs: Set<[Int]> = Set((path ?? []).indices.dropLast().map { [path![$0], path![$0 + 1]].sorted() })
            if showMoments {
                let index = personIndex
                var faint = Path(), hot = Path(), chain = Path()
                for (mi, m) in g.moments.enumerated() where vis.contains(peopleCount + mi) {
                    guard let bp = pos(peopleCount + mi) else { continue }
                    for pid in m.people {
                        guard let a = index[pid], vis.contains(a), let ap = pos(a) else { continue }
                        let line = { (p: inout Path) in p.move(to: toView(ap)); p.addLine(to: toView(bp)) }
                        if pathPairs.contains([a, peopleCount + mi]) { line(&chain) }
                        else if rel.map({ $0.contains(a) && $0.contains(peopleCount + mi) }) ?? false { line(&hot) } else { line(&faint) }
                    }
                }
                ctx.stroke(faint, with: .color(.white.opacity(rel == nil ? 0.10 : 0.03)), lineWidth: 1)
                ctx.stroke(hot, with: .color(.white.opacity(0.6)), lineWidth: 1.5)
                ctx.stroke(chain, with: .color(.accentColor), lineWidth: 4)
            } else {
                for e in es where vis.contains(e.a) && vis.contains(e.b) {
                    guard let a = pos(e.a), let b = pos(e.b) else { continue }
                    var p = Path(); p.move(to: toView(a)); p.addLine(to: toView(b))
                    let t = log(CGFloat(e.photos) + 1) / log(maxW + 1) // 0…1
                    let on = pathPairs.contains([e.a, e.b])
                    let hot = rel.map { $0.contains(e.a) && $0.contains(e.b) && (focus == nil || e.a == focus || e.b == focus || path != nil) } ?? false
                    let alpha = on ? 1 : rel == nil ? 0.12 + 0.5 * t : (hot ? 0.75 : 0.03)
                    ctx.stroke(p, with: .color(on ? .accentColor : .white.opacity(alpha)), lineWidth: on ? 5 : max(1, (0.8 + 5 * t) * min(1.6, zoom)))
                }
            }
            if showMoments {
                for i in peopleCount..<(peopleCount + g.moments.count) where vis.contains(i) { drawNode(i, ctx: &ctx, dim: rel.map { !$0.contains(i) } ?? false, g: g) }
            }
            // People, biggest last (on top), then their names.
            let people = vis.filter(isPerson).sorted { g.people[$0].photos < g.people[$1].photos }
            for i in people { drawNode(i, ctx: &ctx, dim: rel.map { !$0.contains(i) } ?? false, g: g) }
            let named = Set(people.suffix(zoom >= 0.7 ? people.count : 25))
            for i in people where named.contains(i) || hover == i || focus == i || (rel?.contains(i) ?? false) {
                drawName(i, ctx: &ctx, dim: rel.map { !$0.contains(i) } ?? false, g: g)
            }
        }
    }

    func drawNode(_ i: Int, ctx: inout GraphicsContext, dim: Bool, g: RelationsGraph) {
        guard let gp = pos(i) else { return }
        let c = toView(gp), r = radius(i) * zoom
        guard c.x > -r - 60, c.y > -r - 60, c.x < size.width + r + 60, c.y < size.height + r + 60 else { return }
        var ctx = ctx
        if dim { ctx.opacity = 0.15 }
        let rect = CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
        if isPerson(i) {
            let p = g.people[i]
            let marked = pathStart == i || ego == i || focus == i
            let ring = marked ? Color.accentColor : Color(nsColor: Self.palette[p.community % Self.palette.count])
            let w = max(2, r * (marked ? 0.22 : 0.12))
            ctx.fill(Path(ellipseIn: rect.insetBy(dx: -w, dy: -w)), with: .color(ring))
            ctx.fill(Path(ellipseIn: rect), with: .color(Color(white: 0.2)))
            if let img = images[i] {
                var c2 = ctx
                c2.clip(to: Path(ellipseIn: rect))
                c2.draw(Image(nsImage: img), in: rect)
            } else {
                ctx.draw(Text(String(p.name.prefix(2)).uppercased()).font(.system(size: max(8, r * 0.7), weight: .semibold)).foregroundStyle(.white), at: c)
            }
        } else {
            ctx.fill(RoundedRectangle(cornerRadius: max(2, r * 0.15)).path(in: rect.insetBy(dx: -2, dy: -2)),
                     with: .color(hover == i || panel?.node == i ? .accentColor : .white))
            if let img = images[i], r > 5 {
                var c2 = ctx
                c2.clip(to: RoundedRectangle(cornerRadius: max(1, r * 0.12)).path(in: rect))
                c2.draw(Image(nsImage: img), in: rect)
            } else {
                ctx.fill(Path(rect), with: .color(.gray))
            }
            let count = momentCount(i - peopleCount)
            if count > 1 && r > 9 {
                ctx.draw(Text("\(count)").font(.system(size: 10, weight: .bold)).foregroundStyle(.white),
                         at: CGPoint(x: rect.maxX - 3, y: rect.minY + 3), anchor: .topTrailing)
            }
        }
    }

    /// Name under a person, on a dark pill so it stays readable over links and halos.
    func drawName(_ i: Int, ctx: inout GraphicsContext, dim: Bool, g: RelationsGraph) {
        guard let gp = pos(i) else { return }
        let c = toView(gp), r = radius(i) * zoom
        let big = g.people[i].photos > 50
        let text = ctx.resolve(Text(g.people[i].name).font(.system(size: big ? 12 : 11, weight: big ? .semibold : .regular)).foregroundStyle(.white))
        let sz = text.measure(in: CGSize(width: 220, height: 40))
        let at = CGPoint(x: c.x, y: c.y + r + 6 + sz.height / 2)
        var ctx = ctx
        if dim { ctx.opacity = 0.2 }
        ctx.fill(Capsule().path(in: CGRect(x: at.x - sz.width / 2 - 6, y: at.y - sz.height / 2 - 2, width: sz.width + 12, height: sz.height + 4)),
                 with: .color(.black.opacity(0.62)))
        ctx.draw(text, at: at)
    }

    func tooltip(_ i: Int) -> some View {
        let (title, sub) = describe(i)
        return VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.callout.bold()).lineLimit(3)
            Text(sub).font(.caption).foregroundStyle(.secondary)
        }
        .padding(8).frame(maxWidth: 300, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .offset(x: min(size.width - 310, toView(pos(i) ?? .zero).x + 16), y: toView(pos(i) ?? .zero).y + 12)
        .allowsHitTesting(false)
    }

    func describe(_ i: Int) -> (String, String) {
        guard let g = graph else { return ("", "") }
        if isPerson(i) {
            let links = edges.filter { $0.a == i || $0.b == i }.sorted { $0.photos > $1.photos }
            let top = links.prefix(3).map { "\(g.people[$0.a == i ? $0.b : $0.a].name) (\($0.photos))" }.joined(separator: ", ")
            return (g.people[i].name, "\(g.people[i].photos) photos" + (top.isEmpty ? "" : " · most with \(top)"))
        }
        let m = g.moments[i - peopleCount]
        let names = Dictionary(uniqueKeysWithValues: g.people.map { ($0.id, $0.name) })
        let years = m.firstYear.map { f in m.lastYear.map { $0 == f ? "\(f)" : "\(f)–\($0)" } ?? "\(f)" } ?? ""
        let n = momentCount(i - peopleCount)
        return (m.people.compactMap { names[$0] }.joined(separator: ", "), "\(n) photo\(n > 1 ? "s" : "") together" + (years.isEmpty ? "" : " · \(years)"))
    }

    /// Controls in a vertical panel on the left (like the filters of the other views), so the graph
    /// keeps the whole height and width.
    var sidePanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Relations").font(.headline)
                    let vis = visibleNodes
                    Text("\(vis.filter(isPerson).count) people · \(showMoments ? "\(vis.count - vis.filter(isPerson).count) moments" : "\(edges.count) links")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Links").font(.subheadline.bold())
                    Stepper(value: $minTogether, in: 1...50) { Text("At least \(minTogether) photo\(minTogether > 1 ? "s" : "") together").font(.callout) }
                        .help("Hide links between people photographed together fewer times")
                    Toggle("Show moments", isOn: $showMoments).toggleStyle(.checkbox)
                        .help("Also show the photos each group of people shares (squares)")
                }
                if let range = yearRange {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Years").font(.subheadline.bold())
                        HStack {
                            Button { if !playing && (year ?? range.upperBound) >= range.upperBound { year = range.lowerBound }; playing.toggle() } label: {
                                Image(systemName: playing ? "pause.fill" : "play.fill")
                            }
                            .help("Play the years")
                            Text(year.map { cumulative ? "≤ \($0)" : "\($0)" } ?? "All years").monospacedDigit()
                            Spacer()
                            if year != nil { Button("All") { playing = false; year = nil; refreshAfterYear() } }
                        }
                        Slider(value: Binding(get: { Double(year ?? range.upperBound) }, set: { year = Int($0.rounded()); refreshAfterYear() }),
                               in: Double(range.lowerBound)...Double(range.upperBound), step: 1)
                        Toggle("Up to that year", isOn: $cumulative).toggleStyle(.checkbox)
                            .help("Everything up to the chosen year (otherwise that year only)")
                            .onChange(of: cumulative) { refreshAfterYear() }
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("How to").font(.subheadline.bold())
                    Group {
                        Text("Click a person: their links and photos")
                        Text("Double-click: centred view")
                        Text("⌘-click two people: the chain between them")
                        Text("Drag a person to move them; drag the background to pan; pinch or ⌘-scroll to zoom")
                    }
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let g = graph {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Circles").font(.subheadline.bold())
                        let groups = Dictionary(grouping: visibleNodes.filter(isPerson), by: { g.people[$0].community })
                            .sorted { $0.value.count > $1.value.count }.prefix(8)
                        ForEach(Array(groups), id: \.key) { c, members in
                            HStack(spacing: 6) {
                                Circle().fill(Color(nsColor: Self.palette[c % Self.palette.count])).frame(width: 10, height: 10)
                                let lead = members.max { g.people[$0].photos < g.people[$1].photos }.map { g.people[$0].name } ?? ""
                                Text("\(lead) + \(members.count - 1)").font(.caption).lineLimit(1)
                            }
                        }
                    }
                }
            }
            .padding(12)
        }
        .frame(width: 230)
        .background(.regularMaterial)
    }

    /// Ego view / path being chosen: a reminder at the top of the graph.
    @ViewBuilder var statusBanner: some View {
        if let e = ego, let g = graph {
            HStack(spacing: 8) {
                Text("Centred on \(g.people[e].name) — rings by photos together").font(.callout.bold())
                Button("Back to everyone") { exitEgo() }
            }
            .padding(.horizontal, 12).padding(.vertical, 6).background(.regularMaterial, in: Capsule())
        } else if let s = pathStart, let g = graph {
            Text("Path from \(g.people[s].name): ⌘-click another person").font(.callout)
                .padding(.horizontal, 12).padding(.vertical, 6).background(.regularMaterial, in: Capsule())
        }
    }

    var controls: some View {
        HStack(spacing: 6) {
            Button { withAnimation { scale = min(6, scale * 1.4) } } label: { Image(systemName: "plus.magnifyingglass") }
            Button { withAnimation { scale = max(0.1, scale / 1.4) } } label: { Image(systemName: "minus.magnifyingglass") }
            Button { withAnimation { fit() } } label: { Image(systemName: "arrow.up.left.and.down.right.magnifyingglass") }.help("Fit")
            if settling { ProgressView().controlSize(.small) }
        }
        .buttonStyle(.bordered)
    }

    // MARK: Interaction

    /// Dragging a person (or a moment) moves it; dragging the background pans.
    var panGesture: some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { v in
                if dragging == nil { dragging = hit(v.startLocation) ?? -1 }
                if let n = dragging, n >= 0 {
                    // A moved node stays where it is put: stop the layout still settling.
                    if settling { layoutTask?.cancel(); settling = false }
                    let p = toGraph(v.location)
                    if ego != nil { egoPos[n] = p } else { positions[n] = p }
                } else {
                    panDrag = v.translation
                }
            }
            .onEnded { v in
                if dragging == -1 { offset.width += v.translation.width; offset.height += v.translation.height }
                panDrag = .zero
                dragging = nil
            }
    }

    /// Two-finger scroll moves the graph, pinch or ⌘-scroll (or a mouse wheel) zooms.
    func installScroll() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { e in
            guard mouseInside, model.selection == .relations, model.viewing == nil else { return e }
            if e.modifierFlags.contains(.command) || !e.hasPreciseScrollingDeltas {
                scale = min(6, max(0.1, scale * (1 + e.scrollingDeltaY * 0.01)))
            } else {
                offset.width += e.scrollingDeltaX; offset.height += e.scrollingDeltaY
            }
            return nil
        }
    }

    func hit(_ p: CGPoint) -> Int? {
        let q = toGraph(p), vis = visibleNodes
        for i in vis where isPerson(i) {
            if let n = pos(i), hypot(n.x - q.x, n.y - q.y) <= radius(i) + 3 { return i }
        }
        for i in vis where !isPerson(i) {
            let r = radius(i) + 2
            if let n = pos(i), abs(n.x - q.x) <= r && abs(n.y - q.y) <= r { return i }
        }
        return nil
    }

    func tap(at p: CGPoint) {
        guard let g = graph else { return }
        let ev = NSApp.currentEvent
        let clicks = ev?.clickCount ?? 1, cmd = ev?.modifierFlags.contains(.command) ?? false
        guard let i = hit(p) else {
            if clicks >= 2, ego != nil { exitEgo() }
            focus = nil; panel = nil; path = nil; pathStart = nil
            return
        }
        if isPerson(i) && cmd {
            if let s = pathStart, s != i { showPath(from: s, to: i) } else { pathStart = i; path = nil; focus = nil }
            return
        }
        if isPerson(i) && clicks >= 2 { enterEgo(i); return }
        if isPerson(i) {
            focus = focus == i ? nil : i
            path = nil
            guard focus != nil else { panel = nil; return }
            let mine = edges.filter { $0.a == i || $0.b == i }
            let ids = photos(of: Set(mine.flatMap(\.moments)))
            panel = Panel(title: g.people[i].name, subtitle: "\(ids.count) photos with \(mine.count) people", mediaIds: ids, node: i)
        } else {
            let (title, sub) = describe(i)
            panel = Panel(title: title, subtitle: sub, mediaIds: momentPhotos(i - peopleCount), node: i)
        }
    }

    /// Photos of a moment within the years shown, newest first.
    func momentPhotos(_ mi: Int) -> [Int64] {
        guard let g = graph else { return [] }
        let m = g.moments[mi]
        guard let y = year else { return m.mediaIds }
        return zip(m.mediaIds, m.years).filter { $0.1 != 0 && (cumulative ? $0.1 <= y : $0.1 == y) }.map(\.0)
    }

    func photos(of moments: Set<Int>) -> [Int64] {
        var seen = Set<Int64>(), out: [Int64] = []
        for mi in moments.sorted() { for id in momentPhotos(mi) where seen.insert(id).inserted { out.append(id) } }
        return out
    }

    func fit() {
        let pts = visibleNodes.compactMap { pos($0) }
        guard !pts.isEmpty, size.width > 0 else { return }
        let xs = pts.map(\.x), ys = pts.map(\.y)
        let (x0, x1, y0, y1) = (xs.min()!, xs.max()!, ys.min()!, ys.max()!)
        scale = min(3, max(0.1, 0.96 * min(size.width / (x1 - x0 + 90), (size.height - 30) / (y1 - y0 + 90))))
        offset = CGSize(width: -(x0 + x1) / 2 * scale, height: -(y0 + y1) / 2 * scale)
    }

    // MARK: Ego, path, years

    /// Centred view: the person in the middle, the people photographed with them on rings (closest =
    /// most photos together); with moments, their shared moments in between.
    func enterEgo(_ c: Int) {
        guard let g = graph else { return }
        var weight: [Int: Int] = [:]
        for e in edges where e.a == c || e.b == c { weight[e.a == c ? e.b : e.a] = e.photos }
        var out: [Int: CGPoint] = [c: .zero]
        let ranked = weight.keys.sorted { (weight[$0]!, $0) > (weight[$1]!, $1) }
        var start = 0, ring = 0
        while start < ranked.count {
            let cap = 8 << ring, r = CGFloat(230 + ring * 180)
            let slice = ranked[start..<min(ranked.count, start + cap)]
            for (k, j) in slice.enumerated() {
                let a = CGFloat(k) / CGFloat(slice.count) * 2 * .pi + CGFloat(ring) * 0.4
                out[j] = CGPoint(x: cos(a) * r, y: sin(a) * r)
            }
            start += cap; ring += 1
        }
        if showMoments {
            let index = personIndex, pid = g.people[c].id
            for (k, mi) in g.moments.indices.filter({ g.moments[$0].people.contains(pid) && momentCount($0) > 0 }).enumerated() {
                let others = g.moments[mi].people.compactMap { index[$0] }.filter { $0 != c }.compactMap { out[$0] }
                guard !others.isEmpty else { continue }
                let mx = others.map(\.x).reduce(0, +) / CGFloat(others.count), my = others.map(\.y).reduce(0, +) / CGFloat(others.count)
                let jitter = CGFloat(k % 5 - 2) * 14
                out[peopleCount + mi] = CGPoint(x: mx * 0.55 + jitter, y: my * 0.55 - jitter)
            }
        }
        egoPos = out
        ego = c
        focus = nil; path = nil; pathStart = nil
        withAnimation(.easeInOut(duration: 0.4)) { fit() }
    }

    func exitEgo() {
        ego = nil; egoPos = [:]
        withAnimation(.easeInOut(duration: 0.4)) { fit() }
    }

    /// Shortest chain of people photographed together (over the links shown) between two people.
    func showPath(from a: Int, to b: Int) {
        guard let g = graph else { return }
        pathStart = nil; focus = nil
        var adj: [Int: [Int]] = [:]
        var byPair: [[Int]: Edge] = [:]
        for e in edges { adj[e.a, default: []].append(e.b); adj[e.b, default: []].append(e.a); byPair[[e.a, e.b]] = e }
        var prev: [Int: Int] = [a: a], queue = [a], head = 0
        while head < queue.count {
            let n = queue[head]; head += 1
            if n == b { break }
            for x in adj[n] ?? [] where prev[x] == nil { prev[x] = n; queue.append(x) }
        }
        guard prev[b] != nil else {
            path = nil
            panel = Panel(title: "\(g.people[a].name) and \(g.people[b].name)",
                          subtitle: "Not connected by the links shown (lower the threshold or the years filter)", mediaIds: [], node: b)
            return
        }
        var chain = [b]
        while chain.last! != a { chain.append(prev[chain.last!]!) }
        chain.reverse()
        path = chain
        let steps = chain.indices.dropLast().compactMap { byPair[[chain[$0], chain[$0 + 1]].sorted()] }
        panel = Panel(title: chain.map { g.people[$0].name }.joined(separator: " → "),
                      subtitle: "\(steps.count) step\(steps.count > 1 ? "s" : "") · " + steps.map { "\($0.photos)" }.joined(separator: " + ") + " photos",
                      mediaIds: photos(of: Set(steps.flatMap(\.moments))), node: b)
    }

    func refreshAfterYear() {
        if let e = ego { enterEgo(e) }
        if path != nil { path = nil; panel = nil }
    }

    func play() async {
        guard playing, let range = yearRange else { return }
        while playing && !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1.2))
            guard playing else { return }
            let next = (year ?? range.lowerBound) + 1
            if next > range.upperBound { playing = false; return }
            withAnimation(.easeInOut(duration: 0.3)) { year = next }
            refreshAfterYear()
        }
    }

    // MARK: Data and layout

    func load() async {
        guard let g = try? await model.library.relationsGraph() else { loading = false; return }
        // Live refreshes (a scan running) only redo the layout when the graph itself changed.
        let sig = g.people.map { "\($0.id)" }.joined(separator: ",") + "|" + g.moments.map { "\($0.id):\($0.mediaIds.count)" }.joined(separator: ",")
        guard sig != signature else { return }
        signature = sig
        let firstLoad = graph == nil
        if !firstLoad { images = [:]; panel = nil; focus = nil; ego = nil; egoPos = [:]; path = nil; pathStart = nil }
        graph = g
        loading = false
        relayout(fitAfter: true)
        Task { await loadImages(g) }
    }

    /// Lays out what is shown (people only, or people + moments), with links over the threshold.
    /// Positions of nodes already placed are kept as the starting point, so the picture does not jump.
    func relayout(fitAfter: Bool = false) {
        guard let g = graph else { return }
        layoutTask?.cancel()
        let all = Set(edges.flatMap { [$0.a, $0.b] })
        let nodesIdx: [Int] = showMoments ? Array(0..<(peopleCount + g.moments.count)) : all.sorted()
        let local = Dictionary(uniqueKeysWithValues: nodesIdx.enumerated().map { ($1, $0) })
        var nodes: [ForceLayout.Node] = []
        for (k, i) in nodesIdx.enumerated() {
            let a = CGFloat(k) * 2.4, d = 12 * CGFloat(k).squareRoot()
            let start = positions[i] ?? CGPoint(x: cos(a) * d, y: sin(a) * d)
            let person = isPerson(i)
            nodes.append(.init(p: start, r: radius(i) * (person ? 1 : 1.4) + (person ? 14 : 0), charge: person ? -420 : -60))
        }
        var links: [ForceLayout.Link] = []
        let maxW = CGFloat(maxWeight)
        if showMoments {
            let index = personIndex
            for (mi, m) in g.moments.enumerated() {
                for p in m.people {
                    if let a = index[p].flatMap({ local[$0] }), let b = local[peopleCount + mi] {
                        links.append(.init(a: a, b: b, distance: 40 + 60 / CGFloat(m.mediaIds.count).squareRoot(), strength: 0.5))
                    }
                }
            }
        } else {
            for e in edges {
                guard let a = local[e.a], let b = local[e.b] else { continue }
                let t = log(CGFloat(e.photos) + 1) / log(maxW + 1)
                links.append(.init(a: a, b: b, distance: 260 - 170 * t, strength: 0.15 + 0.6 * t))
            }
        }
        var sim = ForceLayout(nodes: nodes, links: links)
        if !positions.isEmpty && !fitAfter { sim.alpha = 0.6 }
        settling = true
        layoutTask = Task {
            var first = true
            while !sim.settled && !Task.isCancelled {
                sim = await Task.detached(priority: .userInitiated) { [sim] in
                    var s = sim
                    for _ in 0..<8 { s.tick() }
                    return s
                }.value
                guard !Task.isCancelled else { return }
                var out = positions
                for (k, i) in nodesIdx.enumerated() { out[i] = sim.nodes[k].p }
                positions = out
                if first && fitAfter { fit(); first = false }
            }
            settling = false
            if fitAfter { withAnimation(.easeInOut(duration: 0.5)) { fit() } }
        }
    }

    /// Face crops for people, square covers for moments (biggest moments first).
    func loadImages(_ g: RelationsGraph) async {
        for (i, p) in g.people.enumerated() {
            guard images[i] == nil, let fid = p.coverFaceId, let f = try? await model.library.face(id: fid),
                  let thumb = await model.thumbs.loadRaw(f.mediaId), let cg = thumb.cgImage(forProposedRect: nil, context: nil, hints: nil),
                  let c0 = RegionThumb.crop(cg, f, margin: 1.5) else { continue }
            let c = Turn.image(c0, model.thumbs.rotation(f.mediaId))
            images[i] = NSImage(cgImage: c, size: NSSize(width: c.width, height: c.height))
        }
        for (mi, m) in g.moments.enumerated().prefix(400) {
            let i = g.people.count + mi
            guard images[i] == nil, let t = await model.thumbs.load(m.coverMediaId),
                  let cg = t.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
            let side = min(cg.width, cg.height)
            if let sq = cg.cropping(to: CGRect(x: (cg.width - side) / 2, y: (cg.height - side) / 2, width: side, height: side)) {
                images[i] = NSImage(cgImage: sq, size: NSSize(width: side, height: side))
            }
        }
    }
}
