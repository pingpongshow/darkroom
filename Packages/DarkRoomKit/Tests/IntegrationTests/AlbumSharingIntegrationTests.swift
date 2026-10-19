import Foundation
import Testing
import ImmichAPI
@testable import DarkRoomCore

@Suite("Albums, sharing, activity, links and partners", .enabled(if: TestServer.isAvailable), .serialized)
struct AlbumSharingIntegrationTests {

    @Test func sharedAlbumRolesActivityAndLinks() async throws {
        let admin = try await TestServer.client()
        let viewer = try await TestServer.client(as: \.user)
        let viewerID = try await viewer.getMyUser().id
        let photos = try #require(TestServer.seeded["heic"])
        let albums = AlbumActions(client: admin)

        let (album, deleteAlbum) = try await AssetActions(client: admin).createAlbum(name: "DarkRoom Shared Test", assetIDs: photos)

        // Rename + cover with undo.
        let (renamed, undoRename) = try await albums.update(album, name: "DarkRoom Shared Test 2", coverAssetID: photos[1])
        #expect(renamed.albumName == "DarkRoom Shared Test 2")
        #expect(renamed.albumThumbnailAssetId == photos[1])
        try await undoRename.run()
        let restored = try await admin.getAlbumInfo(id: album.id)
        #expect(restored.albumName == "DarkRoom Shared Test")

        // Share with the viewer as viewer, then promote to editor.
        let shared = try await albums.share(album.id, with: [viewerID], role: .viewer)
        #expect(shared.albumUsers.contains { $0.user.id == viewerID && $0.role == .viewer })
        try await albums.setRole(album.id, userID: viewerID, role: .editor)
        #expect(try await admin.getAlbumInfo(id: album.id).albumUsers.contains { $0.user.id == viewerID && $0.role == .editor })
        #expect(try await viewer.getAllAlbums(isShared: true).contains { $0.id == album.id })

        // Activity from the viewer.
        let viewerAlbums = AlbumActions(client: viewer)
        _ = try await viewerAlbums.comment(album.id, text: "Lovely")
        try await viewerAlbums.toggleLike(album.id, existing: nil)
        var feed = try await albums.activity(album.id)
        #expect(feed.contains { $0.type == .comment && $0.comment == "Lovely" })
        let like = try #require(feed.first { $0.type == .like })
        try await viewerAlbums.toggleLike(album.id, existing: like)
        feed = try await albums.activity(album.id)
        #expect(!feed.contains { $0.type == .like })

        // Viewer leaves.
        try await viewerAlbums.removeUser(album.id, userID: "me")
        #expect(try await viewer.getAllAlbums(isShared: true).allSatisfy { $0.id != album.id })

        // Shared links: album and individual, with expiry and password.
        var options = AlbumActions.LinkOptions()
        options.expiresIn = 86_400
        options.password = "secret-pass"
        let albumLink = try await albums.createLink(albumID: album.id, options: options)
        #expect(albumLink.type == .album)
        #expect(albumLink.expiresAt != nil)
        let url = await albums.url(for: albumLink)
        #expect(url.absoluteString.contains("/share/"))
        let photoLink = try await albums.createLink(assetIDs: [photos[0]], options: AlbumActions.LinkOptions())
        #expect(photoLink.type == .individual)
        #expect(try await admin.getAllSharedLinks().contains { $0.id == photoLink.id })
        try await admin.removeSharedLink(id: albumLink.id)
        try await admin.removeSharedLink(id: photoLink.id)
        #expect(try await admin.getAllSharedLinks().allSatisfy { $0.id != albumLink.id && $0.id != photoLink.id })

        try await deleteAlbum.run()
    }

    @Test func partnerSharing() async throws {
        let admin = try await TestServer.client()
        let viewer = try await TestServer.client(as: \.user)
        let viewerID = try await viewer.getMyUser().id
        _ = try await admin.createPartner(body: PartnerCreateDto(sharedWithId: viewerID))
        let fromViewer = try await AlbumActions(client: viewer).partners()
        let partner = try #require(fromViewer.sharedWithMe.first)
        #expect(try await AlbumActions(client: admin).partners().sharedByMe.contains { $0.id == viewerID })
        let updated = try await viewer.updatePartner(id: partner.id, body: PartnerUpdateDto(inTimeline: true))
        #expect(updated.inTimeline == true)
        // The viewer can browse the partner's timeline.
        let store = await TimelineStore(client: viewer, query: .partner(partner.id))
        await store.reload()
        #expect(await store.totalCount > 0)
        try await admin.removePartner(id: viewerID)
        #expect(try await AlbumActions(client: viewer).partners().sharedWithMe.isEmpty)
    }
}
