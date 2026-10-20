import AppKit
import SwiftUI

/// Virtualized thumbnail grid on NSCollectionView: only visible cells exist, so it stays smooth
/// with hundreds of thousands of items (a SwiftUI LazyVGrid lays out every row on large sets).
struct CollectionGrid: NSViewRepresentable {
    let ids: [Int64]
    let cellSize: CGFloat
    let thumbs: ThumbnailCache
    var onOpen: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let layout = NSCollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 4
        layout.minimumLineSpacing = 4
        layout.sectionInset = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        let cv = DoubleClickCollectionView()
        cv.collectionViewLayout = layout
        cv.isSelectable = true
        cv.allowsMultipleSelection = true
        cv.backgroundColors = [.clear]
        cv.register(ThumbItem.self, forItemWithIdentifier: ThumbItem.id)
        cv.dataSource = context.coordinator
        cv.delegate = context.coordinator
        cv.prefetchDataSource = context.coordinator
        cv.onDoubleClick = { [weak coordinator = context.coordinator] index in coordinator?.parent.onOpen(index) }
        let scroll = NSScrollView()
        scroll.documentView = cv
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        context.coordinator.view = cv
        context.coordinator.apply(size: cellSize)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        let idsChanged = c.parent.ids != ids
        c.parent = self
        if idsChanged { c.view?.reloadData(); c.view?.scroll(.zero) }
        c.apply(size: cellSize)
    }

    @MainActor
    final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegateFlowLayout, NSCollectionViewPrefetching {
        var parent: CollectionGrid
        weak var view: NSCollectionView?
        private var size: CGFloat = 0

        init(_ p: CollectionGrid) { parent = p }

        func apply(size: CGFloat) {
            guard size != self.size, let layout = view?.collectionViewLayout as? NSCollectionViewFlowLayout else { return }
            self.size = size
            layout.itemSize = NSSize(width: size, height: size)
            layout.invalidateLayout()
        }

        func collectionView(_ cv: NSCollectionView, numberOfItemsInSection section: Int) -> Int { parent.ids.count }

        func collectionView(_ cv: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            let item = cv.makeItem(withIdentifier: ThumbItem.id, for: indexPath) as! ThumbItem
            let id = parent.ids[indexPath.item]
            item.show(id: id, cache: parent.thumbs)
            return item
        }

        func collectionView(_ cv: NSCollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
            let ids = indexPaths.compactMap { $0.item < parent.ids.count ? parent.ids[$0.item] : nil }
            let cache = parent.thumbs
            Task { for id in ids where cache.cached(id) == nil { _ = await cache.load(id) } }
        }
    }
}

final class DoubleClickCollectionView: NSCollectionView {
    var onDoubleClick: ((Int) -> Void)?
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        guard event.clickCount == 2 else { return }
        let p = convert(event.locationInWindow, from: nil)
        if let ip = indexPathForItem(at: p) { onDoubleClick?(ip.item) }
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 49, let ip = selectionIndexPaths.first { // return / space
            onDoubleClick?(ip.item)
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
    }

    override var isSelected: Bool {
        didSet {
            view.layer?.borderWidth = isSelected ? 3 : 0
            view.layer?.borderColor = NSColor.controlAccentColor.cgColor
        }
    }

    func show(id: Int64, cache: ThumbnailCache) {
        current = id
        if let img = cache.cached(id) { image.image = img; return }
        image.image = nil
        Task { @MainActor in
            let img = await cache.load(id)
            if self.current == id { self.image.image = img }
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        image.image = nil
        current = nil
    }
}
