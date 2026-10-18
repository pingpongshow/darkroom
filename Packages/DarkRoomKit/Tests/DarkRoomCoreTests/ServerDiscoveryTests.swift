// check-secrets: allow-example-ips (generic RFC 1918 examples for subnet tests)
import Foundation
import Testing
@testable import DarkRoomCore

@Suite struct ServerDiscoveryTests {
    @Test func subnetHostsCoverTheLocal24() throws {
        let subnet = try #require(IPv4Subnet(interface: "en0", address: "192.168.1.37", netmask: "255.255.255.0"))
        #expect(subnet.isScannablePrivateLAN)
        let hosts = subnet.scanHosts
        #expect(hosts.count == 253) // .1 ... .254 without the Mac itself
        #expect(hosts.first == "192.168.1.1")
        #expect(hosts.last == "192.168.1.254")
        #expect(!hosts.contains("192.168.1.37"))
    }

    @Test func largeSubnetsAreLimitedToTheirOwn24() throws {
        let subnet = try #require(IPv4Subnet(interface: "en0", address: "10.20.30.40", netmask: "255.255.0.0"))
        #expect(subnet.scanHosts.count == 253)
        #expect(subnet.scanHosts.allSatisfy { $0.hasPrefix("10.20.30.") })
    }

    @Test func nonLANRangesAreSkipped() throws {
        #expect(!(try #require(IPv4Subnet(interface: "utun4", address: "100.101.102.103", netmask: "255.192.0.0"))).isScannablePrivateLAN)
        #expect(!(try #require(IPv4Subnet(interface: "en5", address: "169.254.3.4", netmask: "255.255.0.0"))).isScannablePrivateLAN)
        #expect((try #require(IPv4Subnet(interface: "en0", address: "172.20.1.2", netmask: "255.255.255.0"))).isScannablePrivateLAN)
        #expect(!(try #require(IPv4Subnet(interface: "en0", address: "172.32.1.2", netmask: "255.255.255.0"))).isScannablePrivateLAN)
    }

    @Test func candidatesPutKnownServersAndDefaultPortFirst() throws {
        let known = URL(string: "http://photos.example.test:9999")!
        let discovery = ServerDiscovery(knownServers: [known])
        let subnet = try #require(IPv4Subnet(interface: "en0", address: "192.168.50.10", netmask: "255.255.255.0"))
        let list = discovery.candidates(localSubnets: [subnet])
        #expect(list.first == known)
        let firstSubnetCandidate = try #require(list.first { $0.host()?.hasPrefix("192.168.50.") == true })
        #expect(firstSubnetCandidate.port == 2283)
        #expect(Set(list.map(\.absoluteString)).count == list.count)
    }

    @Test func probeRejectsNonImmichServices() async {
        // Nothing listens on this port; the probe must simply return nil.
        let session = URLSession(configuration: .ephemeral)
        #expect(await ServerDiscovery.probe(URL(string: "http://127.0.0.1:9")!, session: session) == nil)
    }
}
