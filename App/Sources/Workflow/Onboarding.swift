import SwiftUI
import TipKit

/// First-run tour (skippable, replay from Help ▸ Show Tour).
struct OnboardingTour: View {
    @AppStorage("tourSeen", store: .darkRoom) private var seen = false
    @Environment(\.dismiss) private var dismiss
    @State private var page = 0

    private let pages: [(symbol: String, title: String, text: String)] = [
        ("person.2.circle", "Welcome to DarkRoom",
         "Each person signs in to Immich once, then switches with their DarkRoom PIN or Touch ID. Lock with ⌃⌘L."),
        ("photo.on.rectangle", "Your Immich library",
         "Grid (G), loupe (E), search (⌘F), Explore, People, Places and the map. Changes made on phones or Immich web appear instantly."),
        ("flag", "Cull quickly",
         "Rate with 0–5, Pick with P, Reject with X, U to unflag. Filter the grid, compare (C) or survey (N), then trash all rejects."),
        ("slider.horizontal.3", "Develop and presets",
         "Press D to edit. Hover a preset to preview it, click to apply, then set its amount. Edits become a version on top of the untouched original."),
        ("arrow.up.forward.app", "Edit in your other apps",
         "⌘E opens the photo in your default editor (darktable, Photoshop, Pixelmator…). Save and close: DarkRoom uploads the result."),
        ("icloud.and.arrow.up", "Import",
         "⇧⌘I to choose files or folders from any disk, or drag them onto the window. Duplicates are skipped; Live Photos and RAW+JPEG stay paired."),
    ]

    var body: some View {
        VStack(spacing: 18) {
            let p = pages[page]
            Image(systemName: p.symbol).font(.system(size: 54, weight: .light)).foregroundStyle(Theme.highlight).frame(height: 70)
            Text(p.title).font(.title2.weight(.medium))
            Text(p.text).multilineTextAlignment(.center).foregroundStyle(.secondary).frame(width: 420, height: 70, alignment: .top)
            HStack(spacing: 6) {
                ForEach(pages.indices, id: \.self) { i in Circle().fill(i == page ? Theme.highlight : Color.secondary.opacity(0.3)).frame(width: 7, height: 7) }
            }
            HStack {
                Button("Skip Tour") { finish() }.accessibilityIdentifier("tour-skip")
                Spacer()
                if page > 0 { Button("Back") { page -= 1 } }
                Button(page == pages.count - 1 ? "Get Started" : "Next") {
                    if page == pages.count - 1 { finish() } else { page += 1 }
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("tour-next")
            }
        }
        .padding(28)
        .frame(width: 520)
        .accessibilityIdentifier("tour")
    }

    private func finish() { seen = true; dismiss() }
}

// MARK: Contextual tips (TipKit; off with Preferences ▸ Show tips)

struct DevelopTip: Tip {
    var title: Text { Text("Presets preview on hover") }
    var message: Text? { Text("Point at a preset to see it on the photo; click to apply, then adjust its Amount.") }
    var image: Image? { Image(systemName: "camera.filters") }
}

struct CullingTip: Tip {
    var title: Text { Text("Cull with the keyboard") }
    var message: Text? { Text("P picks, X rejects, 0–5 rates. Turn on Auto advance to move to the next photo automatically.") }
    var image: Image? { Image(systemName: "flag") }
}

struct ImportTip: Tip {
    var title: Text { Text("Upload from any disk") }
    var message: Text? { Text("Choose Import (⇧⌘I) or drop files and folders on the window.") }
    var image: Image? { Image(systemName: "icloud.and.arrow.up") }
}

enum TipsSetup {
    /// Tips are configured only when the "Show tips" preference is on (and never in UI tests).
    static func configure() {
        let show = UserDefaults.darkRoom.object(forKey: "showTips") as? Bool ?? true
        guard show, ProcessInfo.processInfo.environment["DARKROOM_DATA_DIR"] == nil else { return }
        try? Tips.configure([.displayFrequency(.daily)])
    }
}
