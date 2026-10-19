import Foundation
import Testing
import AVFoundation
import ImmichAPI
@testable import DarkRoomCore

/// Video and Live Photo versions and Make Still. Everything is reverted / undone; created versions are
/// permanently removed afterwards (test fixtures only).
@Suite("Live Photo and video editing", .enabled(if: TestServer.isAvailable), .serialized)
struct LiveVideoIntegrationTests {
    let work = FileManager.default.temporaryDirectory.appending(path: "darkroom-live-\(UUID().uuidString)")

    func setUp() async throws -> (ImmichClient, VersionManager) {
        RenderEngine.exiftoolURL = RewriteIntegrationTests.exiftool
        let client = try await TestServer.client()
        return (client, VersionManager(client: client, registry: VersionRegistry(file: work.appending(path: "r.json"))))
    }

    func size(_ url: URL) async throws -> CGSize {
        let track = try #require(try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first)
        let natural = try await track.load(.naturalSize)
        let t = try await track.load(.preferredTransform)
        let r = CGRect(origin: .zero, size: natural).applying(t)
        return CGSize(width: abs(r.width), height: abs(r.height))
    }

    @Test func losslessRotateAndTrimmedAdjustedVideo() async throws {
        let (client, manager) = try await setUp()
        let id = try #require(TestServer.seeded["video-mp4"]?.first)
        var context = try await manager.context(for: id)
        let file = try await client.downloadOriginal(assetID: id, to: work.appending(path: context.original.originalFileName))
        let before = try await size(file)

        var rotate = EditRecipe(); rotate.geometry.quarterTurns = 1
        #expect(VideoRenderer.plan(rotate) == .passthrough(quarterTurns: 1))
        guard case .version(let rotated) = try await manager.save(rotate, context: context, originalFile: file) else { Issue.record("no version"); return }
        let rotatedFile = try await client.downloadOriginal(assetID: rotated, to: work.appending(path: "rotated.mp4"))
        let after = try await size(rotatedFile)
        #expect(after.width == before.height && after.height == before.width, "Rotated \(before) → \(after)")

        context = try await manager.context(for: rotated)
        var trim = EditRecipe(); trim.trimStart = 1; trim.trimEnd = 3; trim.exposure = 0.3
        #expect(VideoRenderer.plan(trim) == .reencode)
        guard case .version(let trimmed) = try await manager.save(trim, context: context, originalFile: file) else { Issue.record("no version"); return }
        let trimmedFile = try await client.downloadOriginal(assetID: trimmed, to: work.appending(path: "trimmed.mp4"))
        let duration = try await AVURLAsset(url: trimmedFile).load(.duration).seconds
        #expect(abs(duration - 2) < 0.3, "Trimmed to ~2 s (\(duration))")

        try await manager.revert(try await manager.context(for: trimmed))
        #expect(try await client.getAssetInfo(id: id).visibility == .timeline)
        try? await client.deleteAssets(body: AssetBulkDeleteDto(force: true, ids: [rotated, trimmed]))
    }

    @Test func livePhotoVersionKeepsMotion() async throws {
        let (client, manager) = try await setUp()
        let id = try #require(TestServer.seeded["live-heic-landscape"]?.first)
        let context = try await manager.context(for: id)
        let originalMotion = try #require(context.original.livePhotoVideoId)
        let file = try await client.downloadOriginal(assetID: id, to: work.appending(path: context.original.originalFileName))
        var recipe = EditRecipe(); recipe.exposure = 0.4; recipe.vibrance = 20
        guard case .version(let versionID) = try await manager.save(recipe, context: context, originalFile: file, isLivePhoto: true) else {
            Issue.record("no version"); return
        }
        let version = try await client.getAssetInfo(id: versionID)
        let newMotion = try #require(version.livePhotoVideoId, "Version is a Live Photo")
        #expect(newMotion != originalMotion)
        #expect(try await client.getAssetInfo(id: newMotion).visibility == .hidden)
        #expect(try await client.getAssetInfo(id: id).livePhotoVideoId == originalMotion, "Original keeps its own motion")
        try await manager.revert(try await manager.context(for: versionID))
        #expect(try await client.getAssetInfo(id: id).visibility == .timeline)
        #expect(try await client.getAssetInfo(id: id).livePhotoVideoId == originalMotion)
        try? await client.deleteAssets(body: AssetBulkDeleteDto(force: true, ids: [versionID, newMotion]))
    }

    @Test func makeStillAndUndo() async throws {
        let (client, _) = try await setUp()
        let id = try #require(TestServer.seeded["live-jpg"]?.first)
        let motion = try #require(try await client.getAssetInfo(id: id).livePhotoVideoId)
        let undo = try await AssetActions(client: client).makeStill(id)
        #expect(try await client.getAssetInfo(id: id).livePhotoVideoId == nil)
        #expect(try await client.getAssetInfo(id: motion).isTrashed)
        try await undo.run()
        #expect(try await client.getAssetInfo(id: id).livePhotoVideoId == motion)
        #expect(!(try await client.getAssetInfo(id: motion).isTrashed))
    }
}
