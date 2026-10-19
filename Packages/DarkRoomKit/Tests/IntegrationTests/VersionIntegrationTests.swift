import Foundation
import Testing
import ImmichAPI
@testable import DarkRoomCore

/// Versions against the real server. Every test reverts, then permanently removes the versions it created
/// (test fixtures only; seeded originals are restored to their previous state).
@Suite("Edit versions", .enabled(if: TestServer.isAvailable), .serialized)
struct VersionIntegrationTests {
    let work = FileManager.default.temporaryDirectory.appending(path: "darkroom-versions-\(UUID().uuidString)")

    func setUp() async throws -> (ImmichClient, VersionManager) {
        let client = try await TestServer.client()
        let registry = VersionRegistry(file: work.appending(path: "registry.json"))
        return (client, VersionManager(client: client, registry: registry))
    }

    func download(_ client: ImmichClient, _ asset: AssetResponseDto) async throws -> URL {
        try await client.downloadOriginal(assetID: asset.id, to: work.appending(path: asset.originalFileName))
    }

    func purge(_ client: ImmichClient, _ ids: [String]) async {
        try? await client.deleteAssets(body: AssetBulkDeleteDto(force: true, ids: ids))
    }

    @Test func geometryOnlyUsesImmichBuiltInEdit() async throws {
        let (client, manager) = try await setUp()
        let id = try #require(TestServer.seeded["jpg"]?.first)
        var context = try await manager.context(for: id)
        var recipe = EditRecipe()
        recipe.geometry.quarterTurns = 1
        recipe.geometry.crop = .init(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        let file = try await download(client, context.original)
        #expect(try await manager.save(recipe, context: context, originalFile: file) == .builtInEdit)
        let edits = try await client.getAssetEdits(id: id).edits
        #expect(edits.map(\.action) == [.crop, .rotate])
        context = try await manager.context(for: id)
        #expect(context.recipe.geometry.quarterTurns == 1)
        #expect(abs((context.recipe.geometry.crop?.width ?? 0) - 0.8) < 0.01, "Built-in crop reads back")
        #expect(try await manager.save(EditRecipe(), context: context, originalFile: file) == .reverted)
        #expect(try await client.getAssetEdits(id: id).edits.isEmpty)
    }

    @Test func adjustmentsMakeAStackedVersionAndHideTheOriginal() async throws {
        let (client, manager) = try await setUp()
        let id = try #require(TestServer.seeded["heic"]?.first)
        let (album, deleteAlbum) = try await AssetActions(client: client).createAlbum(name: "DarkRoom Version Test", assetIDs: [id])
        var created: [String] = []

        var context = try await manager.context(for: id)
        let file = try await download(client, context.original)
        var recipe = EditRecipe(); recipe.exposure = 0.4; recipe.vibrance = 20
        guard case .version(let versionID) = try await manager.save(recipe, context: context, originalFile: file) else {
            Issue.record("Expected a version"); return
        }
        created.append(versionID)
        let version = try await client.getAssetInfo(id: versionID)
        #expect(version.originalFileName.hasSuffix("-edit.heic"))
        #expect(version.fileCreatedAt == context.original.fileCreatedAt)
        #expect(try await client.getAssetInfo(id: id).visibility == .hidden)
        let stackID = try #require(await manager.stackID(primary: versionID))
        #expect(try await client.getStack(id: stackID).primaryAssetId == versionID)
        #expect(version.stack == nil, "Hidden originals don't show as stack members in Immich")
        #expect(try await client.getAllAlbums(assetId: versionID).contains { $0.id == album.id }, "Album carried to the version")

        // Opening either asset gives the same recipe; re-saving replaces the version.
        context = try await manager.context(for: versionID)
        #expect(context.recipe.exposure == 0.4)
        #expect(try await manager.context(for: id).version?.id == versionID)
        recipe.exposure = -0.3
        guard case .version(let second) = try await manager.save(recipe, context: context, originalFile: file) else {
            Issue.record("Expected a second version"); return
        }
        created.append(second)
        #expect(try await client.getAssetInfo(id: versionID).isTrashed, "Old version goes to the trash")
        let newStack = try #require(await manager.stackID(primary: second))
        let visible = try await client.getStack(id: newStack).assets.map(\.id)
        #expect(visible == [second], "Immich lists only the version; the hidden original stays in the stack")

        // Revert.
        context = try await manager.context(for: second)
        try await manager.revert(context)
        #expect(try await client.getAssetInfo(id: id).visibility == .timeline)
        #expect(try await client.getAssetInfo(id: id).stack == nil)
        #expect(try await client.getAssetInfo(id: second).isTrashed)
        await purge(client, created)
        try? await deleteAlbum.run()
    }

    @Test func rawPairVersionAndReconciler() async throws {
        let (client, manager) = try await setUp()
        let pair = try #require(TestServer.seeded["raw-jpeg-pair"])
        let infos = try await AssetActions(client: client).details(pair)
        let raw = try #require(infos.first { RenderEngine.isRAW(URL(fileURLWithPath: $0.originalFileName)) })
        let seededStack = try #require(raw.stack)
        let seededPrimary = try await client.getStack(id: seededStack.id).primaryAssetId
        let context = try await manager.context(for: raw.id)
        let file = try await download(client, context.original)
        var recipe = EditRecipe(); recipe.contrast = 20; recipe.whiteBalance = .daylight
        guard case .version(let versionID) = try await manager.save(recipe, context: context, originalFile: file) else {
            Issue.record("Expected a version"); return
        }
        let version = try await client.getAssetInfo(id: versionID)
        #expect(version.originalFileName.hasSuffix("-edit.tif"))
        let stack = try await client.getStack(id: try #require(await manager.stackID(primary: versionID)))
        #expect(stack.primaryAssetId == versionID, "Version is the cover of the RAW+JPEG stack")
        for id in pair { #expect(try await client.getAssetInfo(id: id).visibility == .hidden) }

        // Version trashed in Immich web → the reconciler un-hides the originals.
        try await client.deleteAssets(body: AssetBulkDeleteDto(force: false, ids: [versionID]))
        let actions = await Reconciler(client: client, registry: manager.registry).run()
        #expect(actions.count == pair.count)
        for id in pair { #expect(try await client.getAssetInfo(id: id).visibility == .timeline) }

        // Put the camera pair back exactly as seeded (stacked).
        if let s = try await client.getAssetInfo(id: pair[0]).stack { try? await client.deleteStack(id: s.id) }
        _ = try await client.createStack(body: StackCreateDto(assetIds: [seededPrimary] + pair.filter { $0 != seededPrimary }))
        try? await client.deleteAssetMetadata(id: raw.id, key: VersionManager.versionKey)
        await purge(client, [versionID])
    }
}
