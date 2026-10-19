import Foundation
import AVFoundation
import CoreImage

/// Video and Live Photo motion editing: the Develop recipe applied to every frame, trim, and lossless
/// rotation (only the rotation flag changes) or lossless trim (passthrough) when that's all that changed.
public struct VideoRenderer: Sendable {
    public let engine: RenderEngine

    public init(engine: RenderEngine = .shared) { self.engine = engine }

    /// What changed, deciding between passthrough and re-encode.
    public enum Plan: Equatable, Sendable {
        case unchanged
        /// Rotation flag and/or trim only (no re-encode).
        case passthrough(quarterTurns: Int)
        case reencode
    }

    public static func plan(_ recipe: EditRecipe) -> Plan {
        var adjustments = recipe
        adjustments.geometry.quarterTurns = 0
        adjustments.trimStart = nil
        adjustments.trimEnd = nil
        adjustments.snapshots = []
        let turns = ((recipe.geometry.quarterTurns % 4) + 4) % 4
        if adjustments == EditRecipe() {
            return turns == 0 && recipe.trimStart == nil && recipe.trimEnd == nil ? .unchanged : .passthrough(quarterTurns: turns)
        }
        return .reencode
    }

    /// The video's frame (for the Develop preview) at `time`, with the recipe applied.
    public func frame(_ url: URL, at time: Double, recipe: EditRecipe, maxPixel: CGFloat) async throws -> CGImage {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 30)
        let (cg, _) = try await generator.image(at: CMTime(seconds: max(0, time), preferredTimescale: 600))
        let image = engine.render(CIImage(cgImage: cg), recipe: recipe, isRAW: false, maxPixel: maxPixel)
        guard let out = engine.cgImage(image) else { throw RenderEngine.RenderError.renderFailed }
        return out
    }

    /// Writes the edited video. Output keeps the container type of the source (.mov / .mp4).
    public func export(_ source: URL, recipe: EditRecipe, to destination: URL,
                       progress: (@Sendable (Double) -> Void)? = nil) async throws {
        let asset = AVURLAsset(url: source)
        let duration = try await asset.load(.duration).seconds
        let start = max(0, recipe.trimStart ?? 0), end = min(duration, recipe.trimEnd ?? duration)
        let range = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), end: CMTime(seconds: end, preferredTimescale: 600))
        let fileType: AVFileType = source.pathExtension.lowercased() == "mp4" ? .mp4 : .mov
        try? FileManager.default.removeItem(at: destination)

        switch Self.plan(recipe) {
        case .unchanged:
            try FileManager.default.copyItem(at: source, to: destination)
        case .passthrough(let turns):
            // Copy every track as-is into a composition; only the video's rotation flag changes.
            let composition = AVMutableComposition()
            for track in try await asset.load(.tracks) {
                guard let copy = composition.addMutableTrack(withMediaType: track.mediaType, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
                try copy.insertTimeRange(range, of: track, at: .zero)
                if track.mediaType == .video {
                    let natural = try await track.load(.naturalSize)
                    copy.preferredTransform = try await track.load(.preferredTransform)
                        .concatenating(Self.quarterTurnTransform(turns, size: natural, existing: try await track.load(.preferredTransform)))
                }
            }
            try await run(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough), to: destination,
                          type: fileType, progress: progress)
        case .reencode:
            let videoTrack = try await asset.loadTracks(withMediaType: .video).first
            let isHEVC = try await videoTrack?.load(.formatDescriptions).contains {
                CMFormatDescriptionGetMediaSubType($0) == kCMVideoCodecType_HEVC
            } ?? false
            let engine = self.engine
            let composition = try await AVMutableVideoComposition.videoComposition(with: asset) { request in
                // Frames arrive upright (track transform applied); apply the full recipe.
                let edited = engine.render(request.sourceImage, recipe: recipe, isRAW: false)
                request.finish(with: edited.transformed(by: CGAffineTransform(translationX: -edited.extent.minX, y: -edited.extent.minY)), context: nil)
            }
            // Output size follows the edited geometry (crop / rotation).
            let probe = engine.applyGeometry(CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: composition.renderSize)), recipe.geometry)
            composition.renderSize = CGSize(width: max(2, (probe.extent.width / 2).rounded() * 2), height: max(2, (probe.extent.height / 2).rounded() * 2))
            let preset = isHEVC ? AVAssetExportPresetHEVCHighestQuality : AVAssetExportPresetHighestQuality
            guard let session = AVAssetExportSession(asset: asset, presetName: preset) else { throw VideoError.exportUnavailable }
            session.videoComposition = composition
            session.timeRange = range
            try await run(session, to: destination, type: fileType, progress: progress)
        }
    }

    private func run(_ session: AVAssetExportSession?, to destination: URL, type: AVFileType,
                     progress: (@Sendable (Double) -> Void)?) async throws {
        guard let session else { throw VideoError.exportUnavailable }
        let box = SessionBox(session: session)
        let watcher = progress.map { report in
            Task {
                while !Task.isCancelled {
                    report(Double(box.session.progress))
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
        }
        defer { watcher?.cancel() }
        try await session.export(to: destination, as: type)
    }

    /// Rotation by quarter turns clockwise, keeping the frame at the origin.
    static func quarterTurnTransform(_ turns: Int, size: CGSize, existing: CGAffineTransform) -> CGAffineTransform {
        // Displayed size after the existing transform.
        let shown = CGRect(origin: .zero, size: size).applying(existing).size
        let w = abs(shown.width), h = abs(shown.height)
        switch turns {
        case 1: return CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0)
        case 2: return CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)
        case 3: return CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w)
        default: return .identity
        }
    }

    /// Progress is only read from the session (thread-safe property).
    private final class SessionBox: @unchecked Sendable {
        let session: AVAssetExportSession
        init(session: AVAssetExportSession) { self.session = session }
    }

    public enum VideoError: LocalizedError {
        case exportUnavailable
        public var errorDescription: String? { "This video can’t be exported on this Mac." }
    }
}
