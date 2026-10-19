import SwiftUI
import AppKit
import AVKit
import ImmichAPI
import DarkRoomCore

/// Single-photo view (E): zoomable image, Live Photo motion, video playback, filmstrip.
struct LoupeView: View {
    @EnvironmentObject var library: LibraryModel
    @State private var image: CGImage?
        @State private var loadError: String?

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Theme.gridBackground
                if let asset = library.focusedAsset {
                    if asset.isVideo {
                        VideoPlayerView(url: library.client.playbackURL(assetID: asset.id), headers: library.client.authHeaders)
                            .id(asset.id)
                            .accessibilityIdentifier("video-player")
                    } else if library.playingLive, let motionID = asset.livePhotoVideoID {
                        VideoPlayerView(url: library.client.playbackURL(assetID: motionID), headers: library.client.authHeaders,
                                        autoplay: true, showsControls: false, onEnd: { library.playingLive = false })
                            .id(motionID)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("Live Photo motion")
                            .accessibilityIdentifier("video-player")
                    } else {
                        ZoomableImageView(image: image, onZoomBeyondFit: { loadFullSize(asset) })
                            .id(asset.id)
                        liveButton(asset)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .zIndex(1)
                    }
                    if library.showInfoOverlay, let image {
                        InfoOverlay(asset: asset, image: image).padding(14)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    }
                } else {
                    Text("No photo selected").foregroundStyle(Theme.textTertiary)
                }
                if let loadError { Text(loadError).foregroundStyle(Theme.danger).padding().background(.black.opacity(0.6)) }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("loupe")
            if let asset = library.focusedAsset, asset.stackID != nil { StackStrip(asset: asset) }
            PresetBar()
            if library.showFilmstrip { FilmstripView().frame(height: 86) }
        }
        .task(id: library.focusedAssetID) { await loadPreview() }
    }

    @ViewBuilder private func liveButton(_ asset: TimelineAsset) -> some View {
        if asset.isLivePhoto {
            Button { library.playingLive = true } label: {
                Label("LIVE", systemImage: "livephoto").font(.caption.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.black.opacity(0.45), in: Capsule()).foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .padding(12)
            .help("Play Live Photo (Space)")
            .accessibilityIdentifier("play-live")
        }
    }

    private func loadPreview() async {
        library.playingLive = false
        loadError = nil
        guard let asset = library.focusedAsset, asset.isImage else { image = nil; return }
        let key = ImagePipeline.Key(assetID: asset.id, size: .thumbnail, cacheKey: asset.cacheKey)
        if let quick = await library.pipeline.cachedImage(key, maxPixel: 256) { image = quick } else {
            image = asset.thumbhash.flatMap { ThumbHash.cgImage(base64: $0) }
        }
        do {
            image = try await library.pipeline.image(.init(assetID: asset.id, size: .preview, cacheKey: asset.cacheKey))
        } catch is CancellationError {
        } catch {
            loadError = "Couldn’t load this photo: \(error.localizedDescription)"
        }
        if let index = library.orderedAssets.firstIndex(where: { $0.id == asset.id }) { library.prefetchAround(index) }
    }

    private func loadFullSize(_ asset: TimelineAsset) {
        Task {
            if let full = try? await library.pipeline.image(.init(assetID: asset.id, size: .fullsize, cacheKey: asset.cacheKey)),
               library.focusedAssetID == asset.id {
                image = full
            }
        }
    }
}

/// NSScrollView-based zooming: fit by default, pinch / ⌘+ / ⌘− / double-click to 100%.
struct ZoomableImageView: NSViewRepresentable {
    var image: CGImage?
    var onZoomBeyondFit: () -> Void

    func makeNSView(context: Context) -> ZoomScrollView {
        let scroll = ZoomScrollView()
        scroll.onZoomBeyondFit = onZoomBeyondFit
        return scroll
    }

    func updateNSView(_ scroll: ZoomScrollView, context: Context) {
        scroll.onZoomBeyondFit = onZoomBeyondFit
        scroll.setImage(image)
    }
}

final class ZoomScrollView: NSScrollView {
    private let imageView = NSImageView()
    private var currentImage: CGImage?
    private var naturalSize = NSSize.zero
    var onZoomBeyondFit: (() -> Void)?
    private var requestedFull = false
    private var needsFit = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        allowsMagnification = true
        minMagnification = 0.02
        maxMagnification = 8
        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers = true
        drawsBackground = false
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        documentView = imageView
        contentView = CenteringClipView()
        documentView = imageView
        NotificationCenter.default.addObserver(self, selector: #selector(magnified), name: NSScrollView.didEndLiveMagnifyNotification, object: self)
    }

    required init?(coder: NSCoder) { fatalError() }

    func setImage(_ image: CGImage?) {
        guard image !== currentImage else { return }
        let previous = currentImage
        currentImage = image
        guard let image else { imageView.image = nil; return }
        let size = NSSize(width: image.width, height: image.height)
        // Keep the visible region when a sharper rendition replaces a smaller one.
        let wasZoomed = previous != nil && magnification > fitMagnification(for: naturalSize) * 1.01
        let relativeCenter = wasZoomed ? relativeVisibleCenter() : nil
        naturalSize = size
        imageView.image = NSImage(cgImage: image, size: size)
        imageView.frame = NSRect(origin: .zero, size: size)
        if let relativeCenter, let prev = previous {
            let factor = Double(prev.width) / Double(image.width)
            magnification *= factor
            restore(relativeCenter)
        } else {
            fit()
        }
    }

    override func layout() {
        super.layout()
        if currentImage != nil, needsFit || magnification <= fitMagnification(for: naturalSize) * 1.01 { fit() }
    }

    func fit() {
        guard naturalSize.width > 0 else { return }
        // Until the view has a size the fit can't be computed; retry on the next layout.
        needsFit = bounds.width <= 0 || bounds.height <= 0
        magnification = fitMagnification(for: naturalSize)
    }

    private func fitMagnification(for size: NSSize) -> CGFloat {
        guard size.width > 0, size.height > 0, bounds.width > 0 else { return 1 }
        return min(bounds.width / size.width, bounds.height / size.height, 1)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            let point = imageView.convert(event.locationInWindow, from: nil)
            if magnification > fitMagnification(for: naturalSize) * 1.01 { animator().magnification = fitMagnification(for: naturalSize) }
            else { setMagnification(1, centeredAt: point); magnified() }
        } else {
            super.mouseDown(with: event)
        }
    }

    @objc private func magnified() {
        if !requestedFull && magnification > fitMagnification(for: naturalSize) * 1.05 {
            requestedFull = true
            onZoomBeyondFit?()
        }
    }

    func zoom(by factor: CGFloat) {
        magnification = max(minMagnification, min(maxMagnification, magnification * factor))
        magnified()
    }

    private func relativeVisibleCenter() -> CGPoint {
        let visible = documentVisibleRect
        return CGPoint(x: visible.midX / max(imageView.frame.width, 1), y: visible.midY / max(imageView.frame.height, 1))
    }

    private func restore(_ relative: CGPoint) {
        let visible = documentVisibleRect
        let point = CGPoint(x: relative.x * imageView.frame.width - visible.width / 2,
                            y: relative.y * imageView.frame.height - visible.height / 2)
        contentView.scroll(to: point)
        reflectScrolledClipView(contentView)
    }
}

/// Keeps the image centred when it's smaller than the view.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let document = documentView else { return rect }
        if rect.width > document.frame.width { rect.origin.x = (document.frame.width - rect.width) / 2 }
        if rect.height > document.frame.height { rect.origin.y = (document.frame.height - rect.height) / 2 }
        return rect
    }
}

/// AVPlayer for Immich video (auth headers passed to the asset).
struct VideoPlayerView: NSViewRepresentable {
    var url: URL
    var headers: [String: String]
    var autoplay = true
    var showsControls = true
    var onEnd: (() -> Void)?

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = showsControls ? .floating : .none
        view.videoGravity = .resizeAspect
        let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        view.player = player
        context.coordinator.observe(player, onEnd: onEnd)
        if autoplay { player.play() }
        view.setAccessibilityIdentifier("video-player")
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {}

    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: Coordinator) {
        nsView.player?.pause()
        nsView.player = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        private var token: NSObjectProtocol?
        func observe(_ player: AVPlayer, onEnd: (() -> Void)?) {
            guard let onEnd else { return }
            token = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
                                                           object: player.currentItem, queue: .main) { _ in onEnd() }
        }
        deinit { if let token { NotificationCenter.default.removeObserver(token) } }
    }
}

/// Thumbnail strip under the loupe for quick navigation.
struct FilmstripView: View {
    @EnvironmentObject var library: LibraryModel

    var body: some View {
        let assets = library.orderedAssets
        let current = library.focusedAssetID.flatMap { id in assets.firstIndex { $0.id == id } } ?? 0
        let window = assets.isEmpty ? [] : Array(assets[max(0, current - 40)...min(assets.count - 1, current + 40)])
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 4) {
                    ForEach(window) { asset in
                        PipelineImage(asset: asset, size: .thumbnail, maxPixel: 160)
                            .frame(width: 72, height: 72)
                            .clipped()
                            .overlay(RoundedRectangle(cornerRadius: 2).stroke(asset.id == library.focusedAssetID ? Theme.highlight : .clear, lineWidth: 2))
                            .onTapGesture { library.focusedAssetID = asset.id; library.selection = [asset.id] }
                            .id(asset.id)
                    }
                }
                .padding(.horizontal, 8)
            }
            .background(Theme.panel)
            .onChange(of: library.focusedAssetID) { _, id in
                if let id { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .center) } }
            }
            .onAppear { if let id = library.focusedAssetID { proxy.scrollTo(id, anchor: .center) } }
        }
    }
}

/// SwiftUI image backed by the shared pipeline (ThumbHash placeholder first).
struct PipelineImage: View {
    @EnvironmentObject var library: LibraryModel
    let asset: TimelineAsset
    var size: AssetMediaSize = .thumbnail
    var maxPixel: Int? = 256
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            Theme.panelRaised
            if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFill()
            }
        }
        .task(id: asset.cacheKey) {
            image = asset.thumbhash.flatMap { ThumbHash.cgImage(base64: $0) }
            if let loaded = try? await library.pipeline.image(.init(assetID: asset.id, size: size, cacheKey: asset.cacheKey), maxPixel: maxPixel) {
                image = loaded
            }
        }
    }
}

/// Favourite presets under the loupe for one-click looks (⌃1…⌃9 shown).
struct PresetBar: View {
    @EnvironmentObject var library: LibraryModel

    var body: some View {
        let store = library.develop.presets
        let state = store.snapshot
        let favorites = state.favorites.compactMap { store.preset($0) }
        if !favorites.isEmpty, library.focusedAsset != nil {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    Image(systemName: "camera.filters").foregroundStyle(Theme.textTertiary)
                    ForEach(favorites) { preset in
                        let number = state.shortcuts.first { $0.value == preset.id }?.key
                        Button { library.applyPreset(preset, to: library.targetIDs) } label: {
                            Text(number.map { "\(preset.name) ⌃\($0)" } ?? preset.name)
                                .font(.caption).padding(.horizontal, 8).padding(.vertical, 4)
                                .background(Capsule().fill(Theme.panelRaised))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
            }
            .background(Theme.panel)
            .accessibilityIdentifier("preset-bar")
        }
    }
}
