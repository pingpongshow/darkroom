import Foundation
import ImmichAPI

/// Album management, sharing with users, activity, shared links and partners.
public struct AlbumActions: Sendable {
    public let client: ImmichClient

    public init(client: ImmichClient) { self.client = client }

    // MARK: Albums

    public func update(_ album: AlbumResponseDto, name: String? = nil, description: String? = nil,
                       coverAssetID: String? = nil, activityEnabled: Bool? = nil, order: AssetOrder? = nil) async throws -> (AlbumResponseDto, UndoAction) {
        let updated = try await client.updateAlbumInfo(id: album.id, body: UpdateAlbumDto(
            albumName: name, albumThumbnailAssetId: coverAssetID, description: description,
            isActivityEnabled: activityEnabled, order: order))
        let undo = UndoAction(name: coverAssetID != nil ? "Set Album Cover" : "Edit Album") { [client] in
            _ = try await client.updateAlbumInfo(id: album.id, body: UpdateAlbumDto(
                albumName: name == nil ? nil : album.albumName,
                albumThumbnailAssetId: coverAssetID == nil ? nil : album.albumThumbnailAssetId,
                description: description == nil ? nil : album.description,
                isActivityEnabled: activityEnabled == nil ? nil : album.isActivityEnabled,
                order: order == nil ? nil : album.order))
        }
        return (updated, undo)
    }

    /// Deletes the album only; its photos stay in the library. Not undoable (callers confirm).
    public func delete(_ albumID: String) async throws {
        try await client.deleteAlbum(id: albumID)
    }

    // MARK: Sharing with users

    public func share(_ albumID: String, with userIDs: [String], role: AlbumUserRole) async throws -> AlbumResponseDto {
        try await client.addUsersToAlbum(id: albumID, body: AddUsersDto(albumUsers: userIDs.map { AlbumUserAddDto(role: role, userId: $0) }))
    }

    public func setRole(_ albumID: String, userID: String, role: AlbumUserRole) async throws {
        try await client.updateAlbumUser(id: albumID, userId: userID, body: UpdateAlbumUserDto(role: role))
    }

    /// Removes a user from the album (owners); pass "me" to leave an album shared with you.
    public func removeUser(_ albumID: String, userID: String) async throws {
        try await client.removeUserFromAlbum(id: albumID, userId: userID)
    }

    // MARK: Activity

    public func activity(_ albumID: String, assetID: String? = nil) async throws -> [ActivityResponseDto] {
        try await client.getActivities(albumId: albumID, assetId: assetID)
            .sorted { $0.createdAt < $1.createdAt }
    }

    public func comment(_ albumID: String, assetID: String? = nil, text: String) async throws -> ActivityResponseDto {
        try await client.createActivity(body: ActivityCreateDto(albumId: albumID, assetId: assetID, comment: text, type: .comment))
    }

    /// Likes (or, if `existing` is passed, un-likes).
    public func toggleLike(_ albumID: String, assetID: String? = nil, existing: ActivityResponseDto?) async throws {
        if let existing { try await client.deleteActivity(id: existing.id) }
        else { _ = try await client.createActivity(body: ActivityCreateDto(albumId: albumID, assetId: assetID, type: .like)) }
    }

    // MARK: Shared links

    public struct LinkOptions: Sendable, Equatable {
        public var description = ""
        public var expiresIn: TimeInterval?
        public var password = ""
        public var allowDownload = true
        public var allowUpload = false
        public var showMetadata = true
        public init() {}
    }

    public func createLink(albumID: String? = nil, assetIDs: [String] = [], options: LinkOptions) async throws -> SharedLinkResponseDto {
        try await client.createSharedLink(body: SharedLinkCreateDto(
            albumId: albumID, allowDownload: options.allowDownload, allowUpload: options.allowUpload,
            assetIds: albumID == nil ? assetIDs : nil,
            description: options.description.isEmpty ? nil : options.description,
            expiresAt: options.expiresIn.map { ImmichDate.format(Date().addingTimeInterval($0)) },
            password: options.password.isEmpty ? nil : options.password,
            showMetadata: options.showMetadata,
            type: albumID == nil ? .individual : .album))
    }

    /// The public URL: the server's external domain if one is set in Immich, else the server URL.
    public func url(for link: SharedLinkResponseDto) async -> URL {
        var base = client.serverURL.absoluteString
        if let config = try? await client.getServerConfig(), !config.externalDomain.isEmpty { base = config.externalDomain }
        while base.hasSuffix("/") { base.removeLast() }
        return URL(string: "\(base)/share/\(link.slug ?? link.key)")!
    }

    // MARK: Partners

    public func partners() async throws -> (sharedWithMe: [PartnerResponseDto], sharedByMe: [PartnerResponseDto]) {
        async let with = client.getPartners(direction: .sharedWith)
        async let by = client.getPartners(direction: .sharedBy)
        return try await (with, by)
    }
}
