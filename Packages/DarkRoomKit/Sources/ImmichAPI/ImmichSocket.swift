import Foundation

/// Live events pushed by Immich over socket.io (`/api/socket.io`, websocket transport).
public enum ImmichEvent: Sendable, Equatable {
    case uploadSuccess(assetID: String)
    case assetUpdate(assetID: String)
    case assetDelete(assetID: String)
    case assetTrash(assetIDs: [String])
    case assetRestore(assetIDs: [String])
    case assetHidden(assetID: String)
    case stackUpdate(assetIDs: [String])
    case albumUpdate(albumID: String)
    case personThumbnail(personID: String)
    case sessionDelete(sessionID: String)
    case assetEditReady(assetID: String)
    case serverVersion
    case connected
    case disconnected
    case other(name: String)
}

/// Minimal Engine.IO v4 / Socket.IO v4 client (default namespace, websocket transport only),
/// enough to receive Immich's server-to-client events.
public final class ImmichSocket: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let client: ImmichClient
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private let lock = NSLock()
    private var continuation: AsyncStream<ImmichEvent>.Continuation?
    private var reconnectAttempt = 0
    private var stopped = false

    public init(client: ImmichClient) {
        self.client = client
    }

    /// Starts the connection (reconnecting automatically) and returns the event stream.
    public func events() -> AsyncStream<ImmichEvent> {
        AsyncStream { continuation in
            lock.withLock { self.continuation = continuation; self.stopped = false }
            continuation.onTermination = { [weak self] _ in self?.stop() }
            connect()
        }
    }

    public func stop() {
        lock.withLock { stopped = true }
        task?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
    }

    private func connect() {
        var components = URLComponents(url: client.serverURL.appending(path: "api/socket.io/"), resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        components.queryItems = [URLQueryItem(name: "EIO", value: "4"), URLQueryItem(name: "transport", value: "websocket")]
        var request = URLRequest(url: components.url!)
        client.applyAuth(&request)
        request.setValue(ImmichClient.userAgent, forHTTPHeaderField: "User-Agent")
        for (k, v) in ImmichClient.deviceHeaders { request.setValue(v, forHTTPHeaderField: k) }
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        let task = session.webSocketTask(with: request)
        lock.withLock { self.session = session; self.task = task }
        task.resume()
        receive(on: task)
    }

    private func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(.string(let text)):
                self.handle(text, task: task)
                self.receive(on: task)
            case .success:
                self.receive(on: task)
            case .failure:
                self.scheduleReconnect()
            }
        }
    }

    func handle(_ packet: String, task: URLSessionWebSocketTask) {
        guard let type = packet.first else { return }
        switch type {
        case "0": // engine.io open -> connect to default namespace
            task.send(.string("40")) { _ in }
        case "2": // ping -> pong
            task.send(.string("3")) { _ in }
        case "4":
            handleSocketIO(String(packet.dropFirst()))
        default:
            break
        }
    }

    private func handleSocketIO(_ payload: String) {
        guard let type = payload.first else { return }
        switch type {
        case "0":
            reconnectAttempt = 0
            emit(.connected)
        case "2":
            if let event = Self.parseEvent(String(payload.dropFirst())) { emit(event) }
        case "4":
            emit(.disconnected)
        default:
            break
        }
    }

    /// Parses `["event_name", arg1, ...]`.
    static func parseEvent(_ json: String) -> ImmichEvent? {
        let start = json.firstIndex(of: "[") ?? json.startIndex
        guard let data = json[start...].data(using: .utf8),
              let array = try? JSONDecoder().decode([JSONValue].self, from: data),
              let name = array.first?.stringValue else { return nil }
        let arg: JSONValue? = array.count > 1 ? array[1] : Optional<JSONValue>.none
        let id = arg?.stringValue ?? arg?["id"]?.stringValue ?? ""
        let ids = arg?.arrayValue?.compactMap(\.stringValue) ?? (id.isEmpty ? [] : [id])
        switch name {
        case "on_upload_success": return .uploadSuccess(assetID: id)
        case "on_asset_update": return .assetUpdate(assetID: id)
        case "on_asset_delete": return .assetDelete(assetID: id)
        case "on_asset_trash": return .assetTrash(assetIDs: ids)
        case "on_asset_restore": return .assetRestore(assetIDs: ids)
        case "on_asset_hidden": return .assetHidden(assetID: id)
        case "on_asset_stack_update": return .stackUpdate(assetIDs: Array(array.dropFirst()).compactMap(\.stringValue))
        case "on_album_update": return .albumUpdate(albumID: id)
        case "on_person_thumbnail": return .personThumbnail(personID: id)
        case "on_session_delete": return .sessionDelete(sessionID: id)
        case "on_server_version": return .serverVersion
        case "AssetEditReadyV1", "AssetEditReadyV2":
            return .assetEditReady(assetID: arg?["asset"]?["id"]?.stringValue ?? id)
        default: return .other(name: name)
        }
    }

    private func emit(_ event: ImmichEvent) {
        let continuation = lock.withLock { self.continuation }
        continuation?.yield(event)
    }

    private func scheduleReconnect() {
        let shouldStop = lock.withLock { stopped }
        guard !shouldStop else { return }
        emit(.disconnected)
        reconnectAttempt += 1
        let delay = min(30.0, pow(2.0, Double(min(reconnectAttempt, 5))))
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.lock.withLock({ self.stopped }) else { return }
            self.connect()
        }
    }

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                           didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        scheduleReconnect()
    }
}
