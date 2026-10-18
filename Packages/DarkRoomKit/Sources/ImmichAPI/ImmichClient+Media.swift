import Foundation
import CryptoKit

/// Hand-written endpoints with binary, multipart or streaming bodies.
public extension ImmichClient {

    // MARK: URLs (for loaders and AVPlayer, which add `authHeaders` themselves)

    /// `GET /assets/{id}/thumbnail?size=…&edited=…`
    func thumbnailURL(assetID: String, size: AssetMediaSize = .thumbnail, edited: Bool = true, cacheKey: String? = nil) -> URL {
        var items = [URLQueryItem(name: "size", value: size.rawValue), URLQueryItem(name: "edited", value: edited ? "true" : "false")]
        if let cacheKey { items.append(URLQueryItem(name: "c", value: cacheKey)) }
        return makeRequest("GET", "/assets/\(assetID.pathEscaped)/thumbnail", query: items).url!
    }

    /// `GET /assets/{id}/original`
    func originalURL(assetID: String, edited: Bool = false) -> URL {
        makeRequest("GET", "/assets/\(assetID.pathEscaped)/original",
                    query: [URLQueryItem(name: "edited", value: edited ? "true" : "false")]).url!
    }

    /// `GET /assets/{id}/video/playback` (the server's playback copy, or the original if none).
    func playbackURL(assetID: String) -> URL {
        makeRequest("GET", "/assets/\(assetID.pathEscaped)/video/playback").url!
    }

    func personThumbnailURL(personID: String) -> URL {
        makeRequest("GET", "/people/\(personID.pathEscaped)/thumbnail").url!
    }

    func profileImageURL(userID: String) -> URL {
        makeRequest("GET", "/users/\(userID.pathEscaped)/profile-image").url!
    }

    // MARK: Data

    /// Downloads an image rendition into memory.
    func thumbnail(assetID: String, size: AssetMediaSize = .thumbnail, edited: Bool = true) async throws -> Data {
        let url = thumbnailURL(assetID: assetID, size: size, edited: edited)
        return try await perform(authorized(url), path: "/assets/{id}/thumbnail")
    }

    func personThumbnail(personID: String) async throws -> Data {
        try await perform(authorized(personThumbnailURL(personID: personID)), path: "/people/{id}/thumbnail")
    }

    func profileImage(userID: String) async throws -> Data {
        try await perform(authorized(profileImageURL(userID: userID)), path: "/users/{id}/profile-image")
    }

    /// Downloads an asset's original to `destination` (streamed to disk), returning the file URL.
    @discardableResult
    func downloadOriginal(assetID: String, to destination: URL, edited: Bool = false,
                          progress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        let request = authorized(originalURL(assetID: assetID, edited: edited))
        let delegate = progress.map(DownloadProgressDelegate.init)
        let (temp, response): (URL, URLResponse)
        do {
            (temp, response) = try await session.download(for: request, delegate: delegate)
        } catch {
            throw ImmichError.transport(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let data = (try? Data(contentsOf: temp)) ?? Data()
            try Self.check(response, data: data, path: "/assets/{id}/original")
        }
        let fm = FileManager.default
        try? fm.removeItem(at: destination)
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: temp, to: destination)
        return destination
    }

    /// `POST /download/archive` - zip of the given assets, saved to `destination`.
    @discardableResult
    func downloadArchive(assetIDs: [String], to destination: URL) async throws -> URL {
        var request = makeRequest("POST", "/download/archive")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder.immich.encode(AssetIdsDto(assetIds: assetIDs))
        let (temp, response) = try await session.download(for: request)
        try Self.check(response, data: Data(), path: "/download/archive")
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temp, to: destination)
        return destination
    }

    // MARK: Upload

    struct UploadOptions: Sendable {
        public var filename: String?
        public var fileCreatedAt: Date
        public var fileModifiedAt: Date
        public var livePhotoVideoID: String?
        public var visibility: AssetVisibility?
        public var isFavorite: Bool?
        public var duration: String?
        public var sidecar: URL?
        public init(filename: String? = nil, fileCreatedAt: Date, fileModifiedAt: Date, livePhotoVideoID: String? = nil,
                    visibility: AssetVisibility? = nil, isFavorite: Bool? = nil, duration: String? = nil, sidecar: URL? = nil) {
            self.filename = filename
            self.fileCreatedAt = fileCreatedAt
            self.fileModifiedAt = fileModifiedAt
            self.livePhotoVideoID = livePhotoVideoID
            self.visibility = visibility
            self.isFavorite = isFavorite
            self.duration = duration
            self.sidecar = sidecar
        }
    }

    /// `POST /assets` - uploads a file (streamed from disk). Returns the new (or duplicate) asset id.
    func upload(file: URL, options: UploadOptions,
                progress: (@Sendable (Double) -> Void)? = nil) async throws -> AssetMediaResponseDto {
        let boundary = "DarkRoom-\(UUID().uuidString)"
        let body = try MultipartFile.build(file: file, boundary: boundary, options: options)
        defer { try? FileManager.default.removeItem(at: body) }
        var request = makeRequest("POST", "/assets")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if let checksum = try? Self.sha1(of: file) {
            request.setValue(checksum, forHTTPHeaderField: "x-immich-checksum")
        }
        let delegate = progress.map(UploadProgressDelegate.init)
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.upload(for: request, fromFile: body, delegate: delegate)
        } catch {
            throw ImmichError.transport(error.localizedDescription)
        }
        try Self.check(response, data: data, path: "/assets")
        do {
            return try JSONDecoder.immich.decode(AssetMediaResponseDto.self, from: data)
        } catch {
            throw ImmichError.decoding(String(describing: error), path: "/assets")
        }
    }

    /// SHA-1 hex of a file, as Immich uses for duplicate detection (`/assets/bulk-upload-check`).
    static func sha1(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = Insecure.SHA1()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Base64 SHA-1, the form Immich stores and returns as `checksum`.
    static func sha1Base64(of file: URL) throws -> String {
        let hex = try sha1(of: file)
        var bytes = [UInt8]()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return Data(bytes).base64EncodedString()
    }

    func authorized(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        for (key, value) in Self.deviceHeaders { request.setValue(value, forHTTPHeaderField: key) }
        applyAuth(&request)
        return request
    }
}

/// Builds a multipart body on disk so large videos are never loaded into memory.
enum MultipartFile {
    static func build(file: URL, boundary: String, options: ImmichClient.UploadOptions) throws -> URL {
        let out = FileManager.default.temporaryDirectory.appending(path: "darkroom-upload-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: out.path, contents: nil)
        let handle = try FileHandle(forWritingTo: out)
        defer { try? handle.close() }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let filename = options.filename ?? file.lastPathComponent
        var fields: [(String, String)] = [
            ("fileCreatedAt", iso.string(from: options.fileCreatedAt)),
            ("fileModifiedAt", iso.string(from: options.fileModifiedAt)),
            ("filename", filename),
        ]
        if let v = options.livePhotoVideoID { fields.append(("livePhotoVideoId", v)) }
        if let v = options.visibility { fields.append(("visibility", v.rawValue)) }
        if let v = options.isFavorite { fields.append(("isFavorite", v ? "true" : "false")) }
        if let v = options.duration { fields.append(("duration", v)) }
        func write(_ s: String) throws { try handle.write(contentsOf: Data(s.utf8)) }
        for (name, value) in fields {
            try write("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        func appendFile(field: String, url: URL, name: String) throws {
            try write("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(field)\"; filename=\"\(name)\"\r\n"
                      + "Content-Type: application/octet-stream\r\n\r\n")
            let input = try FileHandle(forReadingFrom: url)
            defer { try? input.close() }
            while let chunk = try input.read(upToCount: 4 << 20), !chunk.isEmpty {
                try handle.write(contentsOf: chunk)
            }
            try write("\r\n")
        }
        try appendFile(field: "assetData", url: file, name: filename)
        if let sidecar = options.sidecar {
            try appendFile(field: "sidecarData", url: sidecar, name: sidecar.lastPathComponent)
        }
        try write("--\(boundary)--\r\n")
        return out
    }
}

final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    let report: @Sendable (Double) -> Void
    init(_ report: @escaping @Sendable (Double) -> Void) { self.report = report }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        report(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
    }
}

final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, Sendable {
    let report: @Sendable (Double) -> Void
    init(_ report: @escaping @Sendable (Double) -> Void) { self.report = report }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        report(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}
