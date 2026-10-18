import SwiftUI
import ImmichAPI
import DarkRoomCore

/// Library window (replaced by the full Lightroom-style shell in M1).
struct LibraryRootView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var session: UserSession
    @State private var stats: AssetStatsResponseDto?
    @State private var version: String = ""

    var body: some View {
        VStack(spacing: 18) {
            AvatarView(account: session.account, size: 64)
            Text(session.account.name).font(.title2.weight(.light))
            if let stats {
                Text("\(stats.images) photos · \(stats.videos) videos").foregroundStyle(Theme.textSecondary)
                    .accessibilityIdentifier("library-stats")
            } else {
                ProgressView().controlSize(.small)
            }
            Text(version).font(.caption).foregroundStyle(Theme.textTertiary)
            HStack {
                Button("Switch User") { state.lock() }
                Button("Sign Out") { Task { await state.signOutCurrent() } }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            stats = try? await session.client.getAssetStatistics()
            if let v = try? await session.client.getServerVersion() { version = "Immich v\(v.major).\(v.minor).\(v.patch)" }
        }
    }
}
