import Foundation
import Testing
@testable import DarkRoomCore

@Suite("Server discovery", .enabled(if: TestServer.isAvailable))
struct DiscoveryIntegrationTests {
    @Test func findsTheTestServerAmongCandidates() async {
        // The test server is reachable on localhost:2283 through the tunnel; mix it with dead candidates.
        let discovery = ServerDiscovery(timeout: 0.5)
        let candidates = [URL(string: "http://127.0.0.1:9")!, URL(string: "http://localhost:2283")!,
                          URL(string: "http://127.0.0.1:1")!]
        var found: [DiscoveredServer] = []
        for await server in discovery.scan(candidates: candidates) { found.append(server) }
        #expect(found.map(\.url.absoluteString) == ["http://localhost:2283"])
        #expect(found.first?.version == "v3.3.3")
    }
}
