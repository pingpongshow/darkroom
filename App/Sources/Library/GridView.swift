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
        collection.setDraggingSourceOperationMask([.copy, .link], forLocal: true)
        collection.setDraggingSourceOperationMask([.copy], forLocal: false)
        context.coordinator.attach(collection)

        let scroll = NSScrollView()
        scroll.documentView = collection
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = NSColor(Theme.gridBackground)
        scroll.automaticallyAdjustsContentInsets = false
        context.coordinator.scrollView = scroll
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.scrolled(_:)),
                                               name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.library = library
        coordinator.apply(store: ObjectIdentifier(timeline), sections: timeline.sections, revision: timeline.revision,
                          cellSize: library.gridCellSize)
        coordinator.syncSelection(library.selection)
        coordinator.applyRAW(library.rawAssetIDs)
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
        private var rawIDs: Set<String> = []

        init(library: LibraryModel) { self.library = library }

        func attach(_ collection: GridCollectionView) {
            self.collection = collection
            collection.dataSource = self
            collection.delegate = self
            collection.onOpen = { [weak self] in self?.openSelected() }
            collection.onModifiedClick = { [weak self] path, modifiers in self?.modifiedClick(at: path, modifiers) ?? false }
            collection.menuProvider = { [weak self] point in
                guard let self, let collection = self.collection else { return nil }
                if let path = collection.indexPathForItem(at: point), !collection.selectionIndexPaths.contains(path) {
                    collection.selectionIndexPaths = [path]
                    self.selectionChanged()
                }
                guard !self.library.selection.isEmpty else { return nil }
                return MenuEntry.nsMenu(self.library.assetMenu(includeOpen: true))
            }
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
            // A month finished loading or an asset changed: update just those cells, not the whole grid
            // (a full reload redraws every visible thumbnail and makes the grid flicker).
            if !storeChanged, !sizeChanged, let collection, updateInPlace(old: self.sections, new: sections, in: collection) {
                self.revision = revision
                syncSelection(library.selection, force: true)
                return
            }
            self.sections = sections
            self.revision = revision
            self.cellSize = cellSize
            if let layout = collection?.collectionViewLayout as? NSCollectionViewFlowLayout {
                layout.itemSize = NSSize(width: cellSize, height: cellSize)
                if sizeChanged { layout.invalidateLayout() }
            }
            let selected = library.selection
            if storeChanged { restoring = true }   // don't record the reload's own scroll as the saved position
            collection?.reloadData()
            if storeChanged { restoreScroll(store: store) }
            syncSelection(selected, force: true)
        }

        /// Applies changes without reloadData when the month structure is the same. Returns false when a full reload is needed.
        private func updateInPlace(old: [TimelineSection], new: [TimelineSection], in collection: NSCollectionView) -> Bool {
            guard old.count == new.count else { return false }
            var resized = IndexSet()
            var changed: [Int] = []
            for i in new.indices {
                guard old[i].bucket == new[i].bucket else { return false }
                let oldCount = old[i].assets?.count ?? old[i].count
                let newCount = new[i].assets?.count ?? new[i].count
                if oldCount != newCount { resized.insert(i) }
                else if old[i].assets != new[i].assets { changed.append(i) }
            }
            sections = new
            if !resized.isEmpty {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0
                    collection.reloadSections(resized)
                }
            }
            // Same number of cells: refresh the visible ones in place (unchanged photos keep their image).
            for path in collection.indexPathsForVisibleItems() where changed.contains(path.section) {
                guard let item = collection.item(at: path) as? ThumbnailItem else { continue }
                if let asset = new[path.section].assets?[safe: path.item] {
                    item.configure(asset: asset, isRAW: rawIDs.contains(asset.id), pipeline: library.pipeline, cellSize: cellSize)
                }
            }
            return true
        }

        /// Back from a photo: show that same photo in the grid (centred and selected); otherwise the last scroll position.
        private func restoreScroll(store: ObjectIdentifier) {
            guard let collection else { restoring = false; return }
            if let id = library.focusedAssetID {
                collection.scroll(NSPoint(x: 0, y: library.gridScroll?.store == store ? library.gridScroll!.y : 0))
                reveal(id, attempts: 6)
                return
            }
            guard let saved = library.gridScroll, saved.store == store else {
                collection.scroll(.zero); restoring = false; scrolled(nil); return
            }
            collection.layoutSubtreeIfNeeded()
            collection.scroll(NSPoint(x: 0, y: saved.y))
            restoring = false
            scrolled(nil)
        }

        /// Centres a photo once the grid has its size (retrying while the window lays out or its month loads).
        func reveal(_ id: String, attempts: Int) {
            DispatchQueue.main.asyncAfter(deadline: .now() + (attempts == 6 ? 0 : 0.12)) { [weak self] in
                guard let self, let collection = self.collection else { return }
                collection.layoutSubtreeIfNeeded()
                if collection.bounds.width > 0, let path = self.indexPath(of: id) {
                    collection.scrollToItems(at: [path], scrollPosition: .centeredVertically)
                    self.restoring = false
                    self.scrolled(nil)
                } else if attempts > 0 {
                    self.reveal(id, attempts: attempts - 1)
                } else {
                    self.restoring = false
                }
            }
        }

        private var restoring = false

        @objc func scrolled(_ note: Notification?) {
            guard !restoring, let store, let clip = scrollView?.contentView else { return }
            library.gridScroll = (store, clip.bounds.origin.y)
        }

        /// The RAW list arrived or grew: badge the visible cells (the image itself is kept).
        func applyRAW(_ ids: Set<String>) {
            guard ids != rawIDs else { return }
            rawIDs = ids
            guard let collection else { return }
            for path in collection.indexPathsForVisibleItems() {
                guard let item = collection.item(at: path) as? ThumbnailItem, let asset = asset(at: path) else { continue }
                item.configure(asset: asset, isRAW: ids.contains(asset.id), pipeline: library.pipeline, cellSize: cellSize)
            }
        }

        func indexPath(of id: String) -> IndexPath? {
            for (s, section) in sections.enumerated() {
                if let i = section.assets?.firstIndex(where: { $0.id == id }) { return IndexPath(item: i, section: s) }
            }
            return nil
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
            collection.layoutSubtreeIfNeeded()
            // Pinned headers report their pinned position, so place the month's first row just below its header.
            let headerHeight = (collection.collectionViewLayout as? NSCollectionViewFlowLayout)?.headerReferenceSize.height ?? 34
            let y: CGFloat?
            if collection.numberOfItems(inSection: index) > 0,
               let item = collection.layoutAttributesForItem(at: IndexPath(item: 0, section: index)) {
                y = item.frame.minY - headerHeight - 4
            } else {
                y = collection.layoutAttributesForSupplementaryElement(ofKind: NSCollectionView.elementKindSectionHeader,
                                                                       at: IndexPath(item: 0, section: index))?.frame.minY
            }
            if let y { collection.scroll(NSPoint(x: 0, y: max(0, y))) }
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
                item.configure(asset: asset, isRAW: rawIDs.contains(asset.id), pipeline: library.pipeline, cellSize: cellSize)
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

        // MARK: Drag (to sidebar albums, album cards)

        func collectionView(_ collectionView: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>, with event: NSEvent) -> Bool {
            !indexPaths.isEmpty
        }

        func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
            guard let asset = asset(at: indexPath) else { return nil }
            // The first dragged item carries every selected id; the rest are placeholders.
            let ids = library.selection.contains(asset.id) ? library.targetIDs : [asset.id]
            let item = NSPasteboardItem()
            if ids.first == asset.id || !library.selection.contains(asset.id) {
                item.setString(GridDrag.prefix + ids.joined(separator: ","), forType: .string)
            } else {
                item.setString("", forType: .string)
            }
            return item
        }

        // MARK: Selection

        func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) { selectionChanged() }
        func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) { selectionChanged() }

        /// Where a Shift-click range starts: the last photo clicked or picked on its own.
        private var anchorID: String?

        /// ⌘-click adds or removes one photo; ⇧-click selects every photo from the anchor to the clicked one.
        /// Returns false for a plain click (normal selection).
        func modifiedClick(at path: IndexPath, _ modifiers: NSEvent.ModifierFlags) -> Bool {
            guard let collection else { return false }
            if modifiers.contains(.shift), let anchorID, let anchor = indexPath(of: anchorID) {
                let range = paths(from: anchor, to: path)
                collection.selectionIndexPaths = modifiers.contains(.command) ? collection.selectionIndexPaths.union(range) : range
                selectionChanged(keepAnchor: true)
                return true
            }
            if modifiers.contains(.command) || modifiers.contains(.shift) {
                var paths = collection.selectionIndexPaths
                if paths.contains(path) { paths.remove(path) } else { paths.insert(path) }
                collection.selectionIndexPaths = paths
                anchorID = asset(at: path)?.id
                selectionChanged(keepAnchor: true)
                return true
            }
            anchorID = asset(at: path)?.id
            return false
        }

        /// Every cell between two cells (inclusive), across months, in grid order.
        private func paths(from a: IndexPath, to b: IndexPath) -> Set<IndexPath> {
            let (start, end) = a <= b ? (a, b) : (b, a)
            var result = Set<IndexPath>()
            for s in start.section...end.section where sections.indices.contains(s) {
                let count = sections[s].assets?.count ?? sections[s].count
                guard count > 0 else { continue }
                let first = s == start.section ? start.item : 0
                let last = s == end.section ? min(end.item, count - 1) : count - 1
                guard first <= last else { continue }
                for i in first...last { result.insert(IndexPath(item: i, section: s)) }
            }
            return result
        }

        func selectionChanged(keepAnchor: Bool = false) {
            guard !updatingSelection, let collection else { return }
            let ids = Set(collection.selectionIndexPaths.compactMap { asset(at: $0)?.id })
            // A single photo picked another way (arrow keys, plain click) becomes the new anchor.
            if !keepAnchor, ids.count == 1 { anchorID = ids.first }
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
    /// Click with ⌘ or ⇧ on a cell: returns true when handled (the click is then not passed on).
    var onModifiedClick: ((IndexPath, NSEvent.ModifierFlags) -> Bool)?
    var onDoubleClick: ((NSPoint) -> Void)?
    var menuProvider: ((NSPoint) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        menuProvider?(convert(event.locationInWindow, from: nil))
    }

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
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.clickCount == 1, let path = indexPathForItem(at: convert(event.locationInWindow, from: nil)),
           onModifiedClick?(path, modifiers) == true {
            window?.makeFirstResponder(self)
            return
        }
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
    /// The rendition currently shown (so re-configuring the same photo doesn't flash its placeholder).
    private var shownKey: ImagePipeline.Key?

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
        shownKey = nil
        imageLayer.contents = nil
        badge.stringValue = ""
        icons.stringValue = ""
        view.setAccessibilityIdentifier(nil)
    }

    func configure(asset: TimelineAsset, isRAW: Bool, pipeline: ImagePipeline, cellSize: Double) {
        task?.cancel()
        assetID = asset.id
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.image)
        view.setAccessibilityIdentifier("asset-\(asset.id)")
        view.setAccessibilityLabel(asset.isVideo ? "Video" : asset.isLivePhoto ? "Live Photo" : "Photo")
        var flags: [String] = []
        if asset.isFavorite { flags.append("♥") }
        if asset.isLivePhoto { flags.append("LIVE") }
        if isRAW { flags.append("RAW") }
        if asset.isPanorama { flags.append("360°") }
        if let count = asset.stackCount { flags.append("◫ \(count)") }
        icons.stringValue = flags.joined(separator: "  ")
        badge.stringValue = asset.isVideo ? (asset.duration.map(Self.format) ?? "") : ""

        let scale = view.window?.backingScaleFactor ?? 2
        let wanted = Int(cellSize * scale)
        let size: AssetMediaSize = wanted > 300 ? .preview : .thumbnail
        let key = ImagePipeline.Key(assetID: asset.id, size: size, cacheKey: asset.cacheKey)
        let maxPixel = max(wanted, 256)
        // Already showing this rendition: nothing to redraw.
        if shownKey == key { return }
        // In memory: draw immediately, without the blurred placeholder or a fade.
        if let cached = pipeline.cachedImage(key, maxPixel: maxPixel) {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            imageLayer.contents = cached
            CATransaction.commit()
            shownKey = key
            return
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        imageLayer.contents = asset.thumbhash.flatMap { ThumbHash.cgImage(base64: $0) }
        CATransaction.commit()
        shownKey = nil
        let id = asset.id
        task = Task { [weak self] in
            guard let image = try? await pipeline.image(key, maxPixel: maxPixel) else { return }
            guard let self, self.assetID == id, !Task.isCancelled else { return }
            CATransaction.begin(); CATransaction.setAnimationDuration(0.12)
            self.imageLayer.contents = image
            CATransaction.commit()
            self.shownKey = key
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
