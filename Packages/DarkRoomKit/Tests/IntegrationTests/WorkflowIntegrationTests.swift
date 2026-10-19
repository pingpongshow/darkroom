import Foundation
import Testing
import CoreImage
import ImageIO
import ImmichAPI
@testable import DarkRoomCore

@Suite("Culling and export", .enabled(if: TestServer.isAvailable), .serialized)
struct WorkflowIntegrationTests {
    @Test func pickRejectUnflagAndUndo() async throws {
        let client = try await TestServer.client()
        let culling = Culling(client: client)
        let ids = try #require(TestServer.seeded["heic"])
        func flags(_ id: String) async throws -> Set<String> {
            Set((try await client.getAssetInfo(id: id).tags ?? []).map(\.value).filter { $0.hasPrefix("Culling/") })
        }
        let pick = try await culling.setFlag(.pick, on: ids)
        #expect(try await eventually { try await flags(ids[0]) == ["Culling/Pick"] })
        let reject = try await culling.setFlag(.reject, on: [ids[0]])
        #expect(try await eventually { try await flags(ids[0]) == ["Culling/Reject"] })
        #expect(try await culling.assets(flagged: .reject).map(\.id).contains(ids[0]))
        try await reject.run()
        #expect(try await eventually { try await flags(ids[0]) == ["Culling/Pick"] })
        let clear = try await culling.setFlag(nil, on: ids)
        #expect(try await eventually { try await flags(ids[0]).isEmpty })
        _ = clear
        try await pick.run()   // back to unflagged (the state before picking)
        #expect(try await eventually { try await flags(ids[1]).isEmpty })
        for t in try await client.getAllTags() where t.value == "Culling" { try await client.deleteTag(id: t.id) }
    }

    @Test func exportResizesWatermarksAndStripsLocation() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "darkroom-exp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let src = dir.appending(path: "IMG_9.jpg")
        let img = CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 1200, height: 800))
        let cg = RenderEngine.shared.cgImage(img)!
        let dest = CGImageDestinationCreateWithURL(src as CFURL, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, cg, [kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 10.0, kCGImagePropertyGPSLatitudeRef: "N"],
                                              kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2024:01:02 03:04:05"]] as CFDictionary)
        CGImageDestinationFinalize(dest)
        var s = ExportSettings()
        s.longEdge = 600; s.metadata = .noLocation; s.watermarkText = "© DarkRoom"; s.naming = "{date}-{seq}"; s.format = .png
        let out = try Exporter.export(src, settings: s, folder: dir, sequence: 3)
        #expect(out.lastPathComponent == "2024-01-02-0003.png")
        let props = RenderEngine.metadata(of: out)
        #expect(props[kCGImagePropertyPixelWidth] as? Int == 600)
        #expect(props[kCGImagePropertyGPSDictionary] == nil)
        // Watermark changed pixels in the bottom-right corner.
        let outImage = CIImage(contentsOf: out)!
        let corner = outImage.applyingFilter("CIAreaMaximum", parameters: [kCIInputExtentKey: CIVector(cgRect: CGRect(x: 420, y: 5, width: 175, height: 40))])
        var px = [UInt8](repeating: 0, count: 4)
        RenderEngine.shared.context.render(corner, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        #expect(px[0] > 170, "Watermark text (70% white) is brighter than the grey background")
    }
}
