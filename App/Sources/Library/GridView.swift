import SwiftUI
import AppKit
import ImmichAPI
import DarkRoomCore

/// Lightroom-style grid of square cells, grouped by month, backed by NSCollectionView for speed.
struct GridView: NSViewRepresentable {
    @EnvironmentObject var library: LibraryModel
    @ObservedObject var timeline: TimelineStore

    func makeCoordinator() -> Coordinator { Coordinator(library: library) }

    func makeNSView(context: Context) -> NSScrollView {
        let layout = NSCollectionViewFlowLayout()
        layout.sectionInset = NSEdgeInsets(top: 4, left: 12, bottom: 18, right: 12)
        layout.minimumInteritemSpacing = 6
        layout.minimumLineSpacing = 6
        layout.headerReferenceSize = NSSize(width: 100, height: 34)
        layout.sectionHeadersPinToVisibleBounds = true

        let collection = GridCollectionView()
        collection.collectionViewLayout = layout
        collection.isSelectable = true
        collection.allowsMultipleSelection = true
        collection.backgroundColors = [NSColor(Theme.gridBackground)]
        collection.register(ThumbnailItem.self, forItemWithIdentifier: ThumbnailItem.identifier)
        collection.register(MonthHeaderView.self, forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
                            withIdentifier: MonthHeaderView.identifier)
        collection.setAccessibilityIdentifier("photo-grid")
        context.coordinator.attach(collection)

        let scroll = NSScrollView()
        scroll.documentView = collection
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = NSColor(Theme.gridBackground)
        scroll.automaticallyAdjustsContentInsets = false
        context.coordinator.scrollView = scroll
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.library = library
        coordinator.apply(store: ObjectIdentifier(timeline), sections: timeline.sections, revision: timeline.revision,
                          cellSize: library.gridCellSize)
        coordinator.syncSelection(library.selection)
        if let target = library.scrollRequest {
            coordinator.scroll(toSection: target)
            DispatchQueue.main.async { library.scrollRequest = nil }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate, NSCollectionViewDelegateFlowLayout {
        var library: LibraryModel
        weak var collection: GridCollectionView?
        weak var scrollView: NSScrollView?
        private var sections: [TimelineSection] = []
        private var revision = -1
        private var store: ObjectIdentifier?
        private var cellSize: Double = 0
        private var updatingSelection = false

        init(library: LibraryModel) { self.library = library }

        func attach(_ collection: GridCollectionView) {
            self.collection = collection
            collection.dataSource = self
            collection.delegate = self
            collection.onOpen = { [weak self] in self?.openSelected() }
            collection.onDoubleClick = { [weak self] point in
                guard let self, let collection = self.collection, let path = collection.indexPathForItem(at: point),
                      let asset = self.asset(at: path) else { return }
                self.library.open(asset.id)
            }
        }

        func apply(store: ObjectIdentifier, sections: [TimelineSection], revision: Int, cellSize: Double) {
            guard store != self.store || revision != self.revision || cellSize != self.cellSize
                    || sections.count != self.sections.count else { return }
            let storeChanged = store != self.store
            self.store = store
            let sizeChanged = cellSize != self.cellSize
            self.sections = sections
            self.revision = revision
            self.cellSize = cellSize
            if let layout = collection?.collectionViewLayout as? NSCollectionViewFlowLayout {
                layout.itemSize = NSSize(width: cellSize, height: cellSize)
                if sizeChanged { layout.invalidateLayout() }
            }
            let selected = library.selection
            collection?.reloadData()
            if storeChanged { collection?.scroll(.zero) }
            syncSelection(selected, force: true)
        }

        func syncSelection(_ ids: Set<String>, force: Bool = false) {
            guard let collection else { return }
            var paths = Set<IndexPath>()
            for (s, section) in sections.enumerated() {
                guard let assets = section.assets else { continue }
                for (i, asset) in assets.enumerated() where ids.contains(asset.id) { paths.insert(IndexPath(item: i, section: s)) }
            }
            guard force || paths != collection.selectionIndexPaths else { return }
            updatingSelection = true
            collection.selectionIndexPaths = paths
            updatingSelection = false
        }

        func scroll(toSection bucket: String) {
            guard let index = sections.firstIndex(where: { $0.bucket == bucket }), let collection else { return }
            Task { await library.timeline.loadSection(bucket) }
            if let attributes = collection.layoutAttributesForSupplementaryElement(ofKind: NSCollectionView.elementKindSectionHeader,
                                                                                   at: IndexPath(item: 0, section: index)) {
                collection.scroll(NSPoint(x: 0, y: attributes.frame.minY))
            }
        }

        func asset(at path: IndexPath) -> TimelineAsset? {
            sections[safe: path.section]?.assets?[safe: path.item]
        }

        private func openSelected() {
            if let id = library.selection.first ?? library.focusedAssetID { library.open(id) }
        }

        // MARK: Data source

        func numberOfSections(in collectionView: NSCollectionView) -> Int { sections.count }

        func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
            sections[section].assets?.count ?? sections[section].count
        }

        func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            let item = collectionView.makeItem(withIdentifier: ThumbnailItem.identifier, for: indexPath) as! ThumbnailItem
            let section = sections[indexPath.section]
            if let asset = section.assets?[safe: indexPath.item] {
                item.configure(asset: asset, pipeline: library.pipeline, cellSize: cellSize)
            } else {
                item.configurePlaceholder()
                let bucket = section.bucket
                Task { await library.timeline.loadSection(bucket) }
            }
            return item
        }

        func collectionView(_ collectionView: NSCollectionView, viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind,
                            at indexPath: IndexPath) -> NSView {
            let header = collectionView.makeSupplementaryView(ofKind: kind, withIdentifier: MonthHeaderView.identifier,
                                                              for: indexPath) as! MonthHeaderView
            let section = sections[indexPath.section]
            header.configure(title: section.title, count: section.count)
            return header
        }

        // MARK: Selection

        func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) { selectionChanged() }
        func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) { selectionChanged() }

        private func selectionChanged() {
            guard !updatingSelection, let collection else { return }
            let ids = Set(collection.selectionIndexPaths.compactMap { asset(at: $0)?.id })
            library.selection = ids
            if let last = collection.selectionIndexPaths.max(), let asset = asset(at: last) {
                library.focusedAssetID = asset.id
            }
        }
    }
}

/// Collection view that opens the loupe on Return/Space/double-click.
final class GridCollectionView: NSCollectionView {
    var onOpen: (() -> Void)?
    var onDoubleClick: ((NSPoint) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Take keyboard focus so shortcuts and arrow selection work straight away.
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self)
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76, 49: onOpen?() // Return, Enter, Space
        default: super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2 { onDoubleClick?(convert(event.locationInWindow, from: nil)) }
    }
}

/// One grid cell: thumbnail (ThumbHash placeholder first), badges, selection frame.
final class ThumbnailItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("ThumbnailItem")
    private let imageLayer = CALayer()
    private let badge = NSTextField(labelWithString: "")
    private let icons = NSTextField(labelWithString: "")
    private var task: Task<Void, Never>?
    private(set) var assetID: String?

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor(Theme.panel).cgColor
        view.layer?.cornerRadius = 3
        imageLayer.contentsGravity = .resizeAspect
        imageLayer.minificationFilter = .trilinear
        view.layer?.addSublayer(imageLayer)
        for label in [badge, icons] {
            label.font = .systemFont(ofSize: 10, weight: .semibold)
            label.textColor = .white
            label.wantsLayer = true
            label.shadow = { let s = NSShadow(); s.shadowBlurRadius = 2; s.shadowColor = .black; return s }()
            view.addSubview(label)
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let inset: CGFloat = 4
        CATransaction.begin(); CATransaction.setDisableActions(true)
        imageLayer.frame = view.bounds.insetBy(dx: inset, dy: inset)
        CATransaction.commit()
        badge.frame = NSRect(x: view.bounds.width - 70, y: 6, width: 64, height: 14)
        badge.alignment = .right
        icons.frame = NSRect(x: 8, y: 6, width: view.bounds.width - 80, height: 14)
    }

    override var isSelected: Bool {
        didSet {
            view.layer?.borderWidth = isSelected ? 2 : 0
            view.layer?.borderColor = NSColor(Theme.highlight).cgColor
            view.layer?.backgroundColor = (isSelected ? NSColor(Theme.panelRaised) : NSColor(Theme.panel)).cgColor
        }
    }

    func configurePlaceholder() {
        task?.cancel()
        assetID = nil
        imageLayer.contents = nil
        badge.stringValue = ""
        icons.stringValue = ""
        view.setAccessibilityIdentifier(nil)
    }

    func configure(asset: TimelineAsset, pipeline: ImagePipeline, cellSize: Double) {
        task?.cancel()
        assetID = asset.id
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.image)
        view.setAccessibilityIdentifier("asset-\(asset.id)")
        view.setAccessibilityLabel(asset.isVideo ? "Video" : asset.isLivePhoto ? "Live Photo" : "Photo")
        imageLayer.contents = asset.thumbhash.flatMap { ThumbHash.cgImage(base64: $0) }

        var flags: [String] = []
        if asset.isFavorite { flags.append("♥") }
        if asset.isLivePhoto { flags.append("LIVE") }
        if asset.isPanorama { flags.append("360°") }
        if let count = asset.stackCount { flags.append("◫ \(count)") }
        icons.stringValue = flags.joined(separator: "  ")
        badge.stringValue = asset.duration.map(Self.format) ?? ""

        let scale = view.window?.backingScaleFactor ?? 2
        let wanted = Int(cellSize * scale)
        let size: AssetMediaSize = wanted > 300 ? .preview : .thumbnail
        let key = ImagePipeline.Key(assetID: asset.id, size: size, cacheKey: asset.cacheKey)
        let id = asset.id
        task = Task { [weak self] in
            guard let image = try? await pipeline.image(key, maxPixel: max(wanted, 256)) else { return }
            guard let self, self.assetID == id, !Task.isCancelled else { return }
            CATransaction.begin(); CATransaction.setAnimationDuration(0.12)
            self.imageLayer.contents = image
            CATransaction.commit()
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        configurePlaceholder()
    }

    static func format(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

final class MonthHeaderView: NSView, NSCollectionViewElement {
    static let identifier = NSUserInterfaceItemIdentifier("MonthHeader")
    private let title = NSTextField(labelWithString: "")
    private let count = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(Theme.gridBackground).withAlphaComponent(0.94).cgColor
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = NSColor(Theme.text)
        count.font = .systemFont(ofSize: 11)
        count.textColor = NSColor(Theme.textTertiary)
        addSubview(title); addSubview(count)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        title.frame = NSRect(x: 14, y: 8, width: 260, height: 18)
        count.frame = NSRect(x: 280, y: 9, width: 200, height: 16)
    }

    func configure(title: String, count: Int) {
        self.title.stringValue = title
        self.count.stringValue = "\(count) item\(count == 1 ? "" : "s")"
    }
}
