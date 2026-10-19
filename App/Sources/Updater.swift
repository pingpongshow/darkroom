import SwiftUI
import Sparkle

/// Sparkle updates from the public releases-only repo. Disabled until a public EdDSA key is
/// configured (SPARKLE_PUBLIC_KEY build setting) and in development/test runs.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()
    private let controller: SPUStandardUpdaterController?
    @Published private(set) var canCheck = false

    private init() {
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        guard !key.isEmpty else { controller = nil; return }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        controller.updater.publisher(for: \.canCheckForUpdates).receive(on: RunLoop.main).assign(to: &$canCheck)
    }

    var isAvailable: Bool { controller != nil }
    func checkForUpdates() { controller?.checkForUpdates(nil) }
    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }
}

struct UpdateCommands: View {
    @ObservedObject private var updater = Updater.shared
    var body: some View {
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!updater.isAvailable || !updater.canCheck)
    }
}
