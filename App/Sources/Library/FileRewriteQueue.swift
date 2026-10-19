import Foundation
import SwiftUI
import ImmichAPI
import DarkRoomCore

/// Background queue that writes metadata changes into the original files (and Mac versions), per the plan.
/// Changes wait a few seconds so a quick ⌘Z never touches a file; later undos swap the old file back.
@MainActor
final class FileRewriteQueue: ObservableObject {
    @AppStorage("writeMetadataToFiles", store: .darkRoom) var enabled = true
    @Published private(set) var pending: Set<String> = []
    @Published private(set) var running: String?

    private weak var library: LibraryModel?
    private let rewriter: MetadataRewriter?
    private var scheduled: [String: Task<Void, Never>] = [:]
    /// Finished rewrites: old id → (new id, undo), so an undo of the metadata change can swap back first.
    private var finished: [String: (newID: String, undo: UndoAction)] = [:]

    init(library: LibraryModel) {
        self.library = library
        if let exiftool = Bundle.main.url(forResource: "exiftool", withExtension: nil, subdirectory: "exiftool") {
            let develop = library.develop
            rewriter = MetadataRewriter(client: library.client, versions: develop.versions,
                                        writer: MetadataWriter(exiftool: exiftool), originals: develop.originals)
        } else {
            rewriter = nil
        }
    }

    var isAvailable: Bool { rewriter != nil }

    /// Schedules the files behind `ids` to be rewritten after a short delay.
    func schedule(_ ids: [String], delay: Duration = .seconds(6)) {
        guard enabled, rewriter != nil else { return }
        for id in ids {
            scheduled[id]?.cancel()
            pending.insert(id)
            scheduled[id] = Task { [weak self] in
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                await self?.run(id)
            }
        }
    }

    /// Called by an undo: cancels a pending rewrite, or swaps back a finished one. Returns the id to undo against.
    func revert(_ id: String) async -> String {
        if let task = scheduled[id] {
            task.cancel()
            scheduled[id] = nil
            pending.remove(id)
            return id
        }
        if let done = finished.removeValue(forKey: id) {
            try? await done.undo.run()
            return id
        }
        return id
    }

    private func run(_ id: String) async {
        guard let rewriter, let library else { return }
        // One at a time (files can be large).
        while running != nil { try? await Task.sleep(for: .milliseconds(300)) }
        running = id
        defer {
            running = nil
            pending.remove(id)
            scheduled[id] = nil
        }
        do {
            let result = try await rewriter.rewrite(id) { message in
                Task { @MainActor in library.statusMessage = message }
            }
            for (old, new) in result.replaced { finished[old] = (new, result.undo) }
            library.flash("Saved changes into \(result.replaced.count == 1 ? "the file" : "\(result.replaced.count) files")")
            if let new = result.replaced[id] {
                if library.focusedAssetID == id { library.focusedAssetID = new }
                if library.selection.contains(id) { library.selection.remove(id); library.selection.insert(new) }
            }
            await library.timeline.reload()
            library.detailsRevision += 1
        } catch MetadataWriter.RewriteError.notOwner {
            // Partner/shared items: Immich keeps the change; files belong to their owner.
        } catch {
            library.flash("Couldn’t write metadata into the file: \(error.localizedDescription)", isError: true)
        }
    }
}
