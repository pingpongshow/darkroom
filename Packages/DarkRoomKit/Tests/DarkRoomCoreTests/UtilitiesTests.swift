import Foundation
import Testing
@testable import DarkRoomCore

@Suite("Bursts and folders")
struct UtilitiesTests {
    func photo(_ id: String, _ t: TimeInterval, ratio: Double = 1.5) -> TimelineAsset {
        TimelineAsset(id: id, isImage: true, ratio: ratio, thumbhash: nil, fileCreatedAt: Date(timeIntervalSince1970: t), ownerID: "u")
    }

    @Test func detectsRapidSequences() {
        let assets = [photo("a", 0), photo("b", 0.3), photo("c", 0.6), photo("d", 0.9),   // burst of 4
                      photo("e", 10), photo("f", 10.5),                                    // too short
                      photo("g", 20), photo("h", 20.4, ratio: 0.75), photo("i", 20.8)]     // shape changes
        let bursts = LibraryUtilities.bursts(in: assets)
        #expect(bursts.count == 1)
        #expect(bursts.first?.map(\.id) == ["a", "b", "c", "d"])
    }

    @Test func buildsCollapsedFolderTree() {
        let tree = LibraryUtilities.folderTree(["/data/library/u1/2024/01", "/data/library/u1/2024/02", "/data/library/u1/2025/07"])
        #expect(tree.map(\.name) == ["2024", "2025"])
        #expect(tree.first?.children.map(\.name) == ["01", "02"])
        #expect(tree.first?.children.first?.path == "/data/library/u1/2024/01")
    }
}
