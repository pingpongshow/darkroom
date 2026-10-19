import Foundation
import Synchronization

/// Errors surfaced by the Immich API layer.
public enum ImmichError: Error, LocalizedError, Sendable, Equatable {
    case invalidServerURL(String)
    case transport(String)
    case http(status: Int, message: String, path: String)
    case unauthorized
    case decoding(String, path: String)
    case unsupportedServerVersion(String)
    /// The account is in read-only mode: DarkRoom doesn't change anything in Immich.
    case readOnly

    public var errorDescription: String? {
        switch self {
        case .invalidServerURL(let url): "“\(url)” is not a valid server address."
        case .transport(let message): "Couldn’t reach the server: \(message)"
        case .http(let status, let message, _): "The server returned an error (\(status)): \(message)"
        case .unauthorized: "Your session has expired. Please sign in again."
        case .decoding(let message, let path): "Unexpected response from \(path): \(message)"
        case .unsupportedServerVersion(let version): "Immich \(version) isn’t supported by this version of DarkRoom."
        case .readOnly: "Read-only mode is on, so nothing was changed in Immich (Preferences ▸ Accounts)."
        }
    }
}

/// Read-only mode: when on, the client refuses every request that could change the library
/// (all non-GET requests except searches, duplicate checks, downloads and session handling).
public final class WritePolicy: Sendable {
    private let state = Mutex(false)
    public init(readOnly: Bool = false) { state.withLock { $0 = readOnly } }
    public var isReadOnly: Bool {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }

    /// POST endpoints that only read.
    static let readingPOSTs = ["/search/", "/assets/bulk-upload-check", "/download/", "/auth/login", "/auth/logout",
                               "/auth/validateToken", "/auth/session/"]

    public func check(method: String, path: String) throws {
        guard isReadOnly else { return }
        let method = method.uppercased()
        if method == "GET" || method == "HEAD" { return }
        let path = path.hasPrefix("/") ? path : "/" + path
        if method == "POST", Self.readingPOSTs.contains(where: { path.hasPrefix($0) }) { return }
        throw ImmichError.readOnly
    }
}

/// How requests authenticate.
public enum ImmichCredential: Sendable, Equatable {
    case none
    /// Session token from `/auth/login` (sent as a bearer token).
    case session(String)
    case apiKey(String)
}

/// Thin, typed client for one Immich server and one signed-in user.
///
/// Generated operations live in `Generated/Operations.swift`; media/multipart endpoints in
/// `ImmichClient+Media.swift`. The client is an actor-free, immutable value holder; the
/// credential can be swapped by creating a new client.
public final class ImmichClient: Sendable {
    public let serverURL: URL
    public let credential: ImmichCredential
    let session: URLSession
    /// Shared by clients derived with `with(credential:)`.
    public let writes: WritePolicy
    /// Identifies DarkRoom in Immich's "Authorized devices" list.
    public static let deviceHeaders = ["devicemodel": "DarkRoom", "devicetype": "macOS"]
    public static var userAgent: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        return "DarkRoom/\(version)"
    }

    /// - Parameter serverURL: the server root, e.g. `http://localhost:2283` (with or without `/api`).
    public init(serverURL: URL, credential: ImmichCredential = .none, session: URLSession = .darkRoomDefault,
                writes: WritePolicy = WritePolicy()) {
        var url = serverURL
        if url.lastPathComponent == "api" { url.deleteLastPathComponent() }
        self.serverURL = url
        self.credential = credential
        self.session = session
        self.writes = writes
    }

    public convenience init(server: String, credential: ImmichCredential = .none, session: URLSession = .darkRoomDefault) throws {
        var text = server.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") { text = "http://" + text }
        guard let url = URL(string: text), url.host() != nil else { throw ImmichError.invalidServerURL(server) }
        self.init(serverURL: url, credential: credential, session: session)
    }

    public func with(credential: ImmichCredential) -> ImmichClient {
        ImmichClient(serverURL: serverURL, credential: credential, session: session, writes: writes)
    }

    public var apiURL: URL { serverURL.appending(path: "api") }

    // MARK: Request building

    public func makeRequest(_ method: String, _ path: String, query: [URLQueryItem] = []) -> URLRequest {
        var components = URLComponents(url: apiURL.appending(path: path.hasPrefix("/") ? String(path.dropFirst()) : path),
                                       resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        for (key, value) in Self.deviceHeaders { request.setValue(value, forHTTPHeaderField: key) }
        applyAuth(&request)
        return request
    }

    public func applyAuth(_ request: inout URLRequest) {
        switch credential {
        case .none: break
        case .session(let token): request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        case .apiKey(let key): request.setValue(key, forHTTPHeaderField: "x-api-key")
        }
    }

    /// Headers needed to fetch protected media directly (e.g. AVPlayer, image loaders).
    public var authHeaders: [String: String] {
        var request = URLRequest(url: serverURL)
        applyAuth(&request)
        return request.allHTTPHeaderFields ?? [:]
    }

    // MARK: Sending

    func send<Body: Encodable, Response: Decodable>(_ method: String, _ path: String, query: [URLQueryItem],
                                                     body: Body?) async throws -> Response {
        let data = try await raw(method, path, query: query, body: body)
        do {
            return try JSONDecoder.immich.decode(Response.self, from: data.isEmpty ? Data("null".utf8) : data)
        } catch {
            throw ImmichError.decoding(String(describing: error), path: path)
        }
    }

    func sendVoid<Body: Encodable>(_ method: String, _ path: String, query: [URLQueryItem], body: Body?) async throws {
        _ = try await raw(method, path, query: query, body: body)
    }

    @discardableResult
    public func raw<Body: Encodable>(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Body?) async throws -> Data {
        var request = makeRequest(method, path, query: query)
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder.immich.encode(body)
        }
        return try await perform(request, path: path)
    }

    public func perform(_ request: URLRequest, path: String) async throws -> Data {
        try writes.check(method: request.httpMethod ?? "GET", path: path)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ImmichError.transport(error.localizedDescription)
        }
        try Self.check(response, data: data, path: path)
        return data
    }

    static func check(_ response: URLResponse, data: Data, path: String) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 { throw ImmichError.unauthorized }
            let message = (try? JSONDecoder().decode(ServerMessage.self, from: data))?.text
                ?? String(data: data, encoding: .utf8)?.prefix(300).description ?? ""
            throw ImmichError.http(status: http.statusCode, message: message, path: path)
        }
    }
}

/// Immich error bodies: `{ "message": "..." | ["...", ...], "error": "...", "statusCode": 400 }`.
struct ServerMessage: Decodable {
    let text: String
    enum CodingKeys: String, CodingKey { case message, error, errors }
    struct FieldError: Decodable { let path: [JSONValue]?; let message: String }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var text: String
        if let single = try? c.decode(String.self, forKey: .message) {
            text = single
        } else if let many = try? c.decode([String].self, forKey: .message) {
            text = many.joined(separator: "; ")
        } else {
            text = (try? c.decode(String.self, forKey: .error)) ?? "Unknown error"
        }
        // Validation details: {"errors":[{"path":["field"],"message":"..."}]}
        if let fields = try? c.decode([FieldError].self, forKey: .errors), !fields.isEmpty {
            text += ": " + fields.map { field in
                let path = (field.path ?? []).compactMap { if case .string(let s) = $0 { s } else { nil } }.joined(separator: ".")
                return path.isEmpty ? field.message : "\(path): \(field.message)"
            }.joined(separator: "; ")
        }
        self.text = text
    }
}

/// Placeholder body type for requests without a body.
public struct Empty: Codable, Sendable {}

public extension URLSession {
    /// Shared session with sensible timeouts and a URL cache sized for thumbnails.
    static let darkRoomDefault: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 60 * 60 * 6
        config.httpMaximumConnectionsPerHost = 8
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()
}

public extension JSONDecoder {
    static let immich: JSONDecoder = JSONDecoder()
}

public extension JSONEncoder {
    static let immich: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
}

extension String {
    var pathEscaped: String {
        addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? self
    }
}

/// Encodes query values the way Immich's API expects.
public enum QueryValue {
    public static func items(_ name: String, _ value: String) -> [URLQueryItem] { [URLQueryItem(name: name, value: value)] }
    public static func items(_ name: String, _ value: Int) -> [URLQueryItem] { [URLQueryItem(name: name, value: String(value))] }
    public static func items(_ name: String, _ value: Double) -> [URLQueryItem] { [URLQueryItem(name: name, value: String(value))] }
    public static func items(_ name: String, _ value: Bool) -> [URLQueryItem] { [URLQueryItem(name: name, value: value ? "true" : "false")] }
    public static func items(_ name: String, _ values: [String]) -> [URLQueryItem] { values.map { URLQueryItem(name: name, value: $0) } }
    public static func items<T: RawRepresentable>(_ name: String, _ value: T) -> [URLQueryItem] where T.RawValue == String {
        [URLQueryItem(name: name, value: value.rawValue)]
    }
    public static func items<T: RawRepresentable>(_ name: String, _ values: [T]) -> [URLQueryItem] where T.RawValue == String {
        values.map { URLQueryItem(name: name, value: $0.rawValue) }
    }
    public static func items(_ name: String, _ value: JSONValue) -> [URLQueryItem] {
        [URLQueryItem(name: name, value: value.queryString)]
    }
}
