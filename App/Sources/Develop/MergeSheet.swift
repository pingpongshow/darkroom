import SwiftUI
import CoreImage
import ImmichAPI
import DarkRoomCore

extension LibraryModel {
    /// HDR / panorama from the selected photos (⌃H / ⌃M).
    func startMerge(_ kind: Merge.Kind) {
        let ids = targetIDs
        guard ids.count >= 2 else { flash("Select two or more photos to merge", isError: true); return }
        mergeRequest = MergeRequest(kind: kind, ids: ids)
    }
}

struct MergeRequest: Identifiable {
    let id = UUID()
    var kind: Merge.Kind
    var ids: [String]
}

/// Downloads the originals, previews the merge, then uploads it stacked on top of the sources.
struct MergeSheet: View {
    @EnvironmentObject var library: LibraryModel
    let request: MergeRequest
    @State private var kind: Merge.Kind
    @State private var files: [URL] = []
    @State private var assets: [AssetResponseDto] = []
    @State private var preview: CGImage?
    @State private var status = "Downloading originals…"
    @State private var working = true
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    init(request: MergeRequest) {
        self.request = request
        _kind = State(initialValue: request.kind)
    }

    private var isPanorama: Bool { if case .panorama = kind { true } else { false } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isPanorama ? "Merge to Panorama" : "Merge to HDR").font(.headline)
            Text("\(request.ids.count) photos").font(.caption).foregroundStyle(.secondary)
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Theme.gridBackground)
                if let preview {
                    Image(preview, scale: 1, label: Text("Merge preview")).resizable().scaledToFit()
                        .accessibilityIdentifier("merge-preview")
                } else {
                    VStack { ProgressView(); Text(status).font(.caption).foregroundStyle(.secondary) }
                }
            }
            .frame(width: 640, height: 360)
            if isPanorama {
                Picker("Projection", selection: Binding<Merge.Projection>(
                    get: { if case .panorama(let p) = kind { return p } else { return Merge.Projection.perspective } },
                    set: { (p: Merge.Projection) in kind = .panorama(p); Task { await render() } })) {
                    ForEach(Merge.Projection.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).frame(width: 300)
            }
            if let error { Text(error).foregroundStyle(Theme.danger).font(.caption) }
            HStack {
                if working { ProgressView().controlSize(.small); Text(status).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Merge") { Task { await merge() } }.keyboardShortcut(.defaultAction)
                    .disabled(working || preview == nil)
                    .accessibilityIdentifier("merge-confirm")
            }
        }
        .padding(20)
        .task { await load() }
    }

    private func load() async {
        do {
            let develop = library.develop
            for id in request.ids {
                let asset = try await library.client.getAssetInfo(id: id)
                assets.append(asset)
                status = "Downloading \(assets.count) of \(request.ids.count)…"
                files.append(try await develop.originals.file(for: asset))
            }
            await render()
        } catch {
            self.error = error.localizedDescription
            working = false
        }
    }

    private func render() async {
        working = true
        status = isPanorama ? "Aligning and stitching…" : "Aligning and merging…"
        let files = self.files, kind = self.kind
        let result: Result<CGImage, Error> = await Task.detached(priority: .userInitiated) {
            do {
                let engine = RenderEngine.shared
                let merged = try Merge.merged(kind, files: files)
                let scale = min(1, 1280 / max(merged.extent.width, merged.extent.height))
                let small = merged.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                guard let cg = engine.cgImage(small) else { throw Merge.MergeError.failed("Couldn’t render the preview") }
                return .success(cg)
            } catch { return .failure(error) }
        }.value
        switch result {
        case .success(let cg): preview = cg; error = nil
        case .failure(let e): error = e.localizedDescription
        }
        working = false
    }

    private func merge() async {
        guard let first = assets.first, let firstFile = files.first else { return }
        working = true
        status = "Writing…"
        do {
            let work = FileManager.default.temporaryDirectory.appending(path: "darkroom-merge-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: work) }
            let files = self.files, kind = self.kind
            let output = try await Task.detached(priority: .userInitiated) {
                try Merge.write(try Merge.merged(kind, files: files), kind: kind, first: firstFile, to: work)
            }.value
            status = "Uploading…"
            let client = library.client
            let created = ImmichDate.parse(first.fileCreatedAt) ?? .now
            let upload = try await client.upload(file: output, options: .init(fileCreatedAt: created, fileModifiedAt: .now))
            try await client.copyAsset(body: AssetCopyDto(albums: true, favorite: true, sharedLinks: false, sidecar: false,
                                                          sourceId: first.id, stack: false, targetId: upload.id))
            // Merged photo on top of its sources.
            for asset in assets { if let stack = asset.stack { try? await client.deleteStack(id: stack.id) } }
            _ = try await client.createStack(body: StackCreateDto(assetIds: [upload.id] + assets.map(\.id)))
            library.flash("Merged \(assets.count) photos")
            await library.timeline.reload()
            dismiss()
        } catch {
            self.error = error.localizedDescription
            working = false
        }
    }
}
