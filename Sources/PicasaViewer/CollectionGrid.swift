import AppKit
import SwiftUI

/// A titled run of consecutive items (a year) in a grid.
struct GridSection: Hashable {
    var title: String
    var start: Int
    var count: Int

    /// Consecutive runs of the same year (items are sorted newest first); 0 = undated.
    static func byYear(_ years: [Int]) -> [GridSection] {
        var out: [GridSection] = []
        for (i, y) in years.enumerated() {
            let title = y == 0 ? "No date" : String(y)
            if out.last?.title == title { out[out.count - 1].count += 1 } else { out.append(GridSection(title: title, start: i, count: 1)) }
        }
        return out
    }
}

/// A frame drawn over a thumbnail (a face or an animal), normalized coordinates, origin top-left.
struct GridFrame: Sendable {
    var x, y, w, h: Double
    var color: NSColor
    /// Not confirmed by a person yet (suggestion, unnamed): dashed.
    var dashed: Bool
    var width: CGFloat = 2
}

/// What frames a grid draws on its thumbnails; `id` identifies the rule (a change redraws).
struct GridFrames: @unchecked Sendable, Equatable {
    let id: String
    let load: @Sendable (Int64) async -> [GridFrame]
    static func == (a: GridFrames, b: GridFrames) -> Bool { a.id == b.id }
}

/// Lets a SwiftUI control (the year rail) scroll the grid.
@MainActor
final class GridController {
    fileprivate weak var view: NSCollectionView?

    func scrollTo(section: Int) {
        guard let cv = view, section < cv.numberOfSections, let clip = cv.enclosingScrollView?.contentView else { return }
        let ip = IndexPath(item: 0, section: section)
        let y = cv.layoutAttributesForSupplementaryElement(ofKind: NSCollectionView.elementKindSectionHeader, at: ip)?.frame.minY
            ?? cv.layoutAttributesForItem(at: ip)?.frame.minY ?? 0
        clip.scroll(to: NSPoint(x: 0, y: max(0, y)))
        cv.enclosingScrollView?.reflectScrolledClipView(clip)
    }

    func scrollToTop() {
        guard let clip = view?.enclosingScrollView?.contentView else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            clip.animator().setBoundsOrigin(.zero)
        }
        view?.enclosingScrollView?.reflectScrolledClipView(clip)
    }
}

/// Virtualized thumbnail grid on NSCollectionView: only visible cells exist, so it stays smooth
/// with hundreds of thousands of items (a SwiftUI LazyVGrid lays out every row on large sets).
/// Optional sections (years) get pinned headers. Indexes given to callers are always flat.
struct CollectionGrid: NSViewRepresentable {
    let ids: [Int64]
    let cellSize: CGFloat
    let thumbs: ThumbnailCache
    /// What is being shown (the filter): a new value scrolls back to the top. When only the ids change
    /// (a scan adding photos), the scroll position and the selection are kept.
    var resetKey: AnyHashable = 0
    /// Library revision: cells still waiting for a thumbnail retry when it moves (thumbnails are
    /// generated after a scan has already listed the photos).
    var revision = 0
    var sections: [GridSection] = []
    var controller: GridController? = nil
    /// Face / animal frames over the thumbnails (nil: none).
    var frames: GridFrames? = nil
    /// Grouped views: cover id → photos in its group (badge), members of open groups (tinted), and the
    /// action when a badge is clicked (or a closed cover double-clicked).
    var badges: [Int64: Int] = [:]
    var expanded: Set<Int64> = []
    var members: Set<Int64> = []
    var onBadge: ((Int64) -> Void)? = nil
    var onOpen: (Int) -> Void
    /// Selected item indexes (click, ⌘/⇧-click, arrows), reported after each change.
    var onSelect: (([Int]) -> Void)? = nil
    /// Scrolled away from the top, and how many items arrived above since (live lists).
    var onTopState: ((_ atTop: Bool, _ newAbove: Int) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let layout = NSCollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 4
        layout.minimumLineSpacing = 4
        layout.sectionInset = NSEdgeInsets(top: 6, left: 6, bottom: 10, right: 6)
        layout.sectionHeadersPinToVisibleBounds = true
        let cv = DoubleClickCollectionView()
        cv.collectionViewLayout = layout
        cv.isSelectable = true
        cv.allowsMultipleSelection = true
        cv.backgroundColors = [.clear]
        cv.register(ThumbItem.self, forItemWithIdentifier: ThumbItem.id)
        cv.register(SectionHeader.self, forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader, withIdentifier: SectionHeader.id)
        cv.dataSource = context.coordinator
        cv.delegate = context.coordinator
        cv.prefetchDataSource = context.coordinator
        cv.onDoubleClick = { [weak coordinator = context.coordinator] ip in
            guard let c = coordinator else { return }
            let f = c.flat(ip)
            // A closed group opens on double-click; anything else opens in the viewer.
            if f < c.shownIds.count, let onBadge = c.parent.onBadge, c.parent.badges[c.shownIds[f]] != nil, !c.parent.expanded.contains(c.shownIds[f]) {
                onBadge(c.shownIds[f]); return
            }
            guard let i = c.parentIndex(f) else { return }
            c.parent.onOpen(i)
        }
        cv.onBadgeClick = { [weak coordinator = context.coordinator] ip in
            guard let c = coordinator else { return }
            let f = c.flat(ip)
            if f < c.shownIds.count { c.parent.onBadge?(c.shownIds[f]) }
        }
        let scroll = NSScrollView()
        scroll.documentView = cv
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.scrolled),
                                               name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        context.coordinator.view = cv
        context.coordinator.shownIds = ids
        context.coordinator.shownSections = sections
        controller?.view = cv
        context.coordinator.apply(size: cellSize)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        let old = c.parent
        c.parent = self
        guard let cv = c.view else { return }
        controller?.view = cv
        if old.resetKey != resetKey {
            c.shownIds = ids; c.shownSections = sections
            cv.reloadData(); cv.scroll(.zero)
            if let onSelect { DispatchQueue.main.async { onSelect([]) } }
        } else if c.shownIds != ids || c.shownSections != sections {
            c.update()
        } else if old.expanded != expanded || old.badges != badges {
            for case let item as ThumbItem in cv.visibleItems() { c.decorate(item) }
        }
        if old.revision != revision {
            for case let item as ThumbItem in cv.visibleItems() { item.retryIfEmpty(cache: thumbs) }
        }
        if old.frames != frames || (frames != nil && old.revision != revision) {
            for case let item as ThumbItem in cv.visibleItems() { item.loadFrames(frames) }
        }
        c.apply(size: cellSize)
    }

    @MainActor
    final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegateFlowLayout, NSCollectionViewPrefetching {
        var parent: CollectionGrid
        weak var view: NSCollectionView?
        /// What the grid displays. It follows `parent.ids`, except on a live list while the user is
        /// scrolled down: new items arriving at the front are held back (the photos under the user's
        /// eyes must not move) and shown when they come back to the top — scrolling up or the button.
        var shownIds: [Int64] = []
        var shownSections: [GridSection] = []
        private var size: CGFloat = 0
        private var atTop = true
        private var newAbove = 0
        private var held = false

        var offsetY: CGFloat { view?.enclosingScrollView?.contentView.bounds.origin.y ?? 0 }

        @objc func scrolled() {
            let top = offsetY < 8
            if top != atTop || top {
                atTop = top
                if top && held { held = false; update() } // back at the top: show what arrived meanwhile
                if top { newAbove = 0 }
                publishTop()
            }
        }

        func decorate(_ item: ThumbItem) {
            guard let id = item.currentId else { return }
            item.setGroup(count: parent.badges[id], open: parent.expanded.contains(id), member: parent.members.contains(id))
        }

        /// Index in the caller's list (parent.ids) of a displayed item, for open / selection callbacks.
        func parentIndex(_ shown: Int) -> Int? {
            guard shown < shownIds.count else { return nil }
            let id = shownIds[shown]
            return shownIds.count == parent.ids.count && parent.ids[shown] == id ? shown : parent.ids.firstIndex(of: id)
        }

        private func publishTop() {
            let (t, n) = (atTop, newAbove)
            DispatchQueue.main.async { [parent] in parent.onTopState?(t, n) }
        }

        init(_ p: CollectionGrid) { parent = p }

        func apply(size: CGFloat) {
            guard size != self.size, let layout = view?.collectionViewLayout as? NSCollectionViewFlowLayout else { return }
            self.size = size
            layout.itemSize = NSSize(width: size, height: size)
            layout.invalidateLayout()
        }

        func flat(_ ip: IndexPath) -> Int { Self.flat(ip, shownSections) }

        static func flat(_ ip: IndexPath, _ sections: [GridSection]) -> Int {
            sections.isEmpty ? ip.item : (ip.section < sections.count ? sections[ip.section].start + ip.item : 0)
        }

        static func path(_ i: Int, _ sections: [GridSection]) -> IndexPath {
            guard !sections.isEmpty else { return IndexPath(item: i, section: 0) }
            var lo = 0, hi = sections.count - 1
            while lo < hi { // last section starting at or before i
                let mid = (lo + hi + 1) / 2
                if sections[mid].start <= i { lo = mid } else { hi = mid - 1 }
            }
            return IndexPath(item: i - sections[lo].start, section: lo)
        }

        /// Live update without losing the user's place: items arriving at the front animate in when at
        /// the top and are held back otherwise; appended items are inserted; anything else reloads in
        /// place. Selected photos stay selected wherever they moved.
        func update() {
            guard let cv = view else { return }
            let (oldIds, oldSections) = (shownIds, shownSections)
            let (newIds, newSections) = (parent.ids, parent.sections)
            let selectedIds = Set(cv.selectionIndexPaths.map { Self.flat($0, oldSections) }.compactMap { $0 < oldIds.count ? oldIds[$0] : nil })
            let offset = cv.enclosingScrollView?.contentView.bounds.origin
            let flat = oldSections.isEmpty && newSections.isEmpty
            // Live list (Last indexed): k new items at the front, the oldest dropped at the end (limit).
            let k = oldIds.first.flatMap { newIds.firstIndex(of: $0) } ?? 0
            let kept = newIds.count - k
            if flat, k > 0, kept > 0, kept <= oldIds.count, newIds[k...].elementsEqual(oldIds.prefix(kept)) {
                guard offsetY < 8 else {
                    held = true
                    newAbove = k
                    publishTop()
                    return
                }
                shownIds = newIds; shownSections = newSections
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.35
                    cv.animator().performBatchUpdates({
                        if oldIds.count > kept {
                            cv.deleteItems(at: Set((kept..<oldIds.count).map { IndexPath(item: $0, section: 0) }))
                        }
                        cv.insertItems(at: Set((0..<k).map { IndexPath(item: $0, section: 0) }))
                    })
                }
            } else if flat, newIds.count > oldIds.count, newIds.starts(with: oldIds) {
                shownIds = newIds; shownSections = newSections
                cv.insertItems(at: Set((oldIds.count..<newIds.count).map { IndexPath(item: $0, section: 0) }))
            } else {
                held = false
                shownIds = newIds; shownSections = newSections
                cv.reloadData()
                if let offset, let clip = cv.enclosingScrollView?.contentView {
                    cv.layoutSubtreeIfNeeded()
                    clip.scroll(to: offset)
                    cv.enclosingScrollView?.reflectScrolledClipView(clip)
                }
            }
            guard !selectedIds.isEmpty else { return }
            cv.selectionIndexPaths = Set(newIds.enumerated().filter { selectedIds.contains($0.element) }.map { Self.path($0.offset, newSections) })
            report(cv)
        }

        func numberOfSections(in cv: NSCollectionView) -> Int { max(1, shownSections.count) }

        func collectionView(_ cv: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
            shownSections.isEmpty ? shownIds.count : (section < shownSections.count ? shownSections[section].count : 0)
        }

        func collectionView(_ cv: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            let item = cv.makeItem(withIdentifier: ThumbItem.id, for: indexPath) as! ThumbItem
            let i = flat(indexPath)
            if i < shownIds.count { item.show(id: shownIds[i], cache: parent.thumbs); item.loadFrames(parent.frames); decorate(item) }
            return item
        }

        func collectionView(_ cv: NSCollectionView, viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind,
                            at indexPath: IndexPath) -> NSView {
            let h = cv.makeSupplementaryView(ofKind: kind, withIdentifier: SectionHeader.id, for: indexPath) as! SectionHeader
            if indexPath.section < shownSections.count {
                let s = shownSections[indexPath.section]
                h.set(title: s.title, count: s.count)
            }
            return h
        }

        func collectionView(_ cv: NSCollectionView, layout: NSCollectionViewLayout, referenceSizeForHeaderInSection section: Int) -> NSSize {
            shownSections.isEmpty ? .zero : NSSize(width: cv.bounds.width, height: 30)
        }

        func collectionView(_ cv: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) { report(cv) }
        func collectionView(_ cv: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) { report(cv) }
        func report(_ cv: NSCollectionView) {
            let sel = cv.selectionIndexPaths.map(flat).compactMap(parentIndex).sorted()
            DispatchQueue.main.async { [parent] in parent.onSelect?(sel) }
        }

        func collectionView(_ cv: NSCollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
            let ids = indexPaths.map(flat).compactMap { $0 < shownIds.count ? shownIds[$0] : nil }
            let cache = parent.thumbs
            Task { for id in ids where cache.cached(id) == nil { _ = await cache.load(id) } }
        }
    }
}

/// Year rail on the right of a sectioned grid: click a year to jump to it.
struct YearRail: View {
    let sections: [GridSection]
    let controller: GridController

    var body: some View {
        if sections.count > 1 {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .trailing, spacing: 2) {
                    ForEach(Array(sections.enumerated()), id: \.offset) { i, s in
                        Button { controller.scrollTo(section: i) } label: {
                            Text(s.title).font(.caption2.monospacedDigit()).padding(.horizontal, 6).padding(.vertical, 1)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("\(s.count) item\(s.count > 1 ? "s" : "")")
                    }
                }
                .padding(.vertical, 6)
            }
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 2)
            .overlay(alignment: .leading) { Divider() }
        }
    }
}

/// A grid with year sections and the year rail: the standard photo grid of every view.
struct YearGrid: View {
    @EnvironmentObject private var model: AppModel
    let ids: [Int64]
    let sections: [GridSection]
    var cellSize: CGFloat = 150
    var resetKey: AnyHashable = 0
    var onSelect: (([Int]) -> Void)? = nil
    var frames: GridFrames? = nil
    var badges: [Int64: Int] = [:]
    var expanded: Set<Int64> = []
    var members: Set<Int64> = []
    var onBadge: ((Int64) -> Void)? = nil
    @State private var controller = GridController()
    @State private var atTop = true
    @State private var newAbove = 0

    var body: some View {
        // The rail sits beside the grid (not over it) so it never covers the scroll bar.
        HStack(spacing: 0) {
            CollectionGrid(ids: ids, cellSize: cellSize, thumbs: model.thumbs, resetKey: resetKey, revision: model.revision,
                           sections: sections, controller: controller, frames: frames,
                           badges: badges, expanded: expanded, members: members, onBadge: onBadge,
                           onOpen: { model.open(ids, at: $0) }, onSelect: onSelect,
                           onTopState: { top, n in atTop = top; newAbove = n })
                .overlay(alignment: .top) {
                    if !atTop {
                        Button { controller.scrollToTop() } label: {
                            Label(newAbove > 0 ? "\(newAbove) new" : "Top", systemImage: "arrow.up")
                                .font(.callout.weight(.medium)).padding(.horizontal, 12).padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                        .background(.regularMaterial, in: Capsule())
                        .overlay(Capsule().stroke(.quaternary))
                        .shadow(radius: 3, y: 1)
                        .padding(.top, sections.isEmpty ? 10 : 40)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .help("Back to the top")
                    }
                }
                .animation(.easeOut(duration: 0.2), value: atTop)
            YearRail(sections: sections, controller: controller)
        }
    }
}

final class SectionHeader: NSView, NSCollectionViewElement {
    static let id = NSUserInterfaceItemIdentifier("year")
    private let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        let blur = NSVisualEffectView(frame: bounds)
        blur.material = .headerView
        blur.blendingMode = .withinWindow
        blur.autoresizingMask = [.width, .height]
        addSubview(blur)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.frame = NSRect(x: 10, y: 6, width: 400, height: 18)
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(title: String, count: Int) {
        let attr = NSMutableAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)])
        attr.append(NSAttributedString(string: "  \(count) item\(count > 1 ? "s" : "")",
                                       attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
        label.attributedStringValue = attr
    }
}

final class DoubleClickCollectionView: NSCollectionView {
    var onDoubleClick: ((IndexPath) -> Void)?
    var onBadgeClick: ((IndexPath) -> Void)?
    override func mouseDown(with event: NSEvent) {
        let p0 = convert(event.locationInWindow, from: nil)
        // A click on a group's badge opens / closes the group (and does not select).
        if event.clickCount == 1, let ip = indexPathForItem(at: p0), let item = item(at: ip) as? ThumbItem,
           item.badgeHit(convert(p0, to: item.view)) {
            onBadgeClick?(ip); return
        }
        super.mouseDown(with: event)
        guard event.clickCount == 2 else { return }
        let p = convert(event.locationInWindow, from: nil)
        if let ip = indexPathForItem(at: p) { onDoubleClick?(ip) }
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 49, let ip = selectionIndexPaths.min() { // return / space
            onDoubleClick?(ip)
        } else { super.keyDown(with: event) }
    }
}

final class ThumbItem: NSCollectionViewItem {
    static let id = NSUserInterfaceItemIdentifier("thumb")
    private var current: Int64?
    private let image = NSImageView()

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        view.layer?.cornerRadius = 2
        image.imageScaling = .scaleProportionallyUpOrDown
        image.frame = view.bounds
        image.autoresizingMask = [.width, .height]
        view.addSubview(image)
        overlay.frame = view.bounds
        overlay.autoresizingMask = [.width, .height]
        view.addSubview(overlay, positioned: .above, relativeTo: image)
    }

    override var isSelected: Bool {
        didSet {
            view.layer?.borderWidth = isSelected ? 3 : 0
            view.layer?.borderColor = NSColor.controlAccentColor.cgColor
        }
    }

    var currentId: Int64? { current }

    // MARK: Groups (badge "×N" on a cover; tint on the members of an open group)

    private let badge = NSTextField(labelWithString: "")
    private var hasBadge = false

    func setGroup(count: Int?, open: Bool, member: Bool) {
        if badge.superview == nil {
            badge.font = .systemFont(ofSize: 11, weight: .bold)
            badge.textColor = .white
            badge.alignment = .center
            badge.wantsLayer = true
            badge.layer?.cornerRadius = 9
            badge.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.7).cgColor
            view.addSubview(badge)
        }
        hasBadge = count != nil
        badge.isHidden = !hasBadge
        if let n = count {
            badge.stringValue = open ? "×\(n) ▴" : "×\(n) ▾"
            badge.sizeToFit()
            let w = badge.frame.width + 12
            badge.frame = NSRect(x: view.bounds.width - w - 5, y: view.bounds.height - 23, width: w, height: 18)
            badge.autoresizingMask = [.minXMargin, .minYMargin]
            badge.layer?.backgroundColor = (open ? NSColor.controlAccentColor : NSColor.black.withAlphaComponent(0.7)).cgColor
        }
        // Closed group: a second card peeking behind the cover; open group's members: accent tint.
        view.layer?.shadowOpacity = count != nil && !open ? 0.9 : 0
        view.layer?.shadowColor = NSColor.white.withAlphaComponent(0.5).cgColor
        view.layer?.shadowOffset = CGSize(width: 4, height: -4)
        view.layer?.shadowRadius = 0
        view.layer?.backgroundColor = (member ? NSColor.controlAccentColor.withAlphaComponent(0.35) : NSColor.quaternaryLabelColor).cgColor
    }

    func badgeHit(_ p: NSPoint) -> Bool { hasBadge && !badge.isHidden && badge.frame.insetBy(dx: -4, dy: -4).contains(p) }

    func show(id: Int64, cache: ThumbnailCache) {
        current = id
        if let img = cache.cached(id) { image.image = img; drawFrames(); return }
        image.image = nil
        Task { @MainActor in
            let img = await cache.load(id)
            if self.current == id { self.image.image = img; self.drawFrames() }
        }
    }

    func retryIfEmpty(cache: ThumbnailCache) {
        if image.image == nil, let id = current { show(id: id, cache: cache) }
    }

    // MARK: Frames

    private let overlay = FramesOverlay()

    func loadFrames(_ spec: GridFrames?) {
        guard let spec, let id = current else { setFrames([]); return }
        Task { @MainActor in
            let f = await spec.load(id)
            if self.current == id { self.setFrames(f) }
        }
    }

    private func setFrames(_ f: [GridFrame]) {
        overlay.frames = f
        drawFrames()
    }

    /// Frames follow the picture as drawn (aspect fit inside the square cell).
    private func drawFrames() {
        if overlay.superview == nil {
            overlay.frame = view.bounds
            overlay.autoresizingMask = [.width, .height]
            view.addSubview(overlay, positioned: .above, relativeTo: image)
        }
        overlay.imageSize = image.image?.size ?? .zero
        overlay.needsDisplay = true
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        image.image = nil
        current = nil
        setFrames([])
        setGroup(count: nil, open: false, member: false)
    }
}

/// Draws face / animal frames over a thumbnail (top-left coordinates, aspect-fit picture).
final class FramesOverlay: NSView {
    var frames: [GridFrame] = []
    var imageSize: CGSize = .zero
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil } // clicks go to the cell

    override func draw(_ dirtyRect: NSRect) {
        guard !frames.isEmpty, imageSize.width > 0, imageSize.height > 0 else { return }
        let b = bounds
        let s = min(b.width / imageSize.width, b.height / imageSize.height)
        let pic = CGRect(x: (b.width - imageSize.width * s) / 2, y: (b.height - imageSize.height * s) / 2,
                         width: imageSize.width * s, height: imageSize.height * s)
        let shadow = NSShadow()
        shadow.shadowColor = .black.withAlphaComponent(0.7); shadow.shadowBlurRadius = 2; shadow.shadowOffset = .zero
        shadow.set()
        for f in frames {
            let r = CGRect(x: pic.minX + f.x * pic.width, y: pic.minY + f.y * pic.height, width: f.w * pic.width, height: f.h * pic.height)
            let path = NSBezierPath(rect: r.insetBy(dx: f.width / 2, dy: f.width / 2))
            path.lineWidth = f.width
            if f.dashed { path.setLineDash([4, 3], count: 2, phase: 0) }
            f.color.setStroke()
            path.stroke()
        }
    }
}
