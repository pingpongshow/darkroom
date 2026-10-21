import SwiftUI
import AppKit
import Network

/// macOS Local Network privacy: without it DarkRoom can't reach an Immich server on the home network (every
/// request fails as "offline"). macOS has no API to read the setting, so a test connection to the server tells:
/// when the setting blocks it, the connection's path says so. A first attempt also makes macOS ask the user.
enum LocalNetworkAccess {
    enum Status { case allowed, denied, unknown }

    static func check(_ server: URL) async -> Status {
        guard let host = server.host(), !host.isEmpty else { return .unknown }
        let port = server.port ?? (server.scheme == "https" ? 443 : 80)
        guard let endpointPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return .unknown }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: .tcp)
        let result = Result()
        return await withCheckedContinuation { continuation in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    result.finish(.allowed, connection, continuation)
                case .waiting, .failed:
                    if connection.currentPath?.unsatisfiedReason == .localNetworkDenied {
                        result.finish(.denied, connection, continuation)
                    } else if case .failed = state {
                        result.finish(.unknown, connection, continuation)
                    }
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .utility))
            // Server down or unreachable for another reason: not a permission problem.
            DispatchQueue.global().asyncAfter(deadline: .now() + 6) { result.finish(.unknown, connection, continuation) }
        }
    }

    /// Resumes the check once (state changes and the timeout race).
    private final class Result: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func finish(_ status: Status, _ connection: NWConnection, _ continuation: CheckedContinuation<Status, Never>) {
            let first = lock.withLock { () -> Bool in
                defer { done = true }
                return !done
            }
            guard first else { return }
            connection.stateUpdateHandler = nil
            connection.cancel()
            continuation.resume(returning: status)
        }
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Some macOS versions only apply a changed setting to a freshly started app.
    @MainActor static func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", path]
        try? task.run()
        NSApp.terminate(nil)
    }
}

/// Shown when the Local Network setting blocks the Immich server; closes by itself once access works.
struct LocalNetworkSheet: View {
    @EnvironmentObject var state: AppState
    let server: URL
    @State private var checking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "network.slash").font(.system(size: 28)).foregroundStyle(Theme.danger)
                VStack(alignment: .leading, spacing: 2) {
                    Text("DarkRoom needs Local Network access").font(.headline)
                    Text("macOS is blocking the connection to your Immich server at \(server.host() ?? server.absoluteString).")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("1. Click Open Privacy Settings.")
                Text("2. Under Local Network, turn on DarkRoom. If it’s already on, turn it off and on again: after an update")
                Text("    macOS can keep showing the old setting without applying it to the new version.")
                Text("3. Come back here. If it still can’t connect, click Quit & Reopen.")
            }
            .font(.callout)
            HStack {
                Button("Not Now") { state.localNetworkBlocked = nil }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if checking { ProgressView().controlSize(.small) }
                Button("Check Again") {
                    checking = true
                    Task { await state.checkLocalNetwork([server]); checking = false }
                }
                .disabled(checking)
                Button("Quit & Reopen") { LocalNetworkAccess.relaunch() }
                Button("Open Privacy Settings") { LocalNetworkAccess.openSettings() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
        .accessibilityIdentifier("local-network-sheet")
    }
}
