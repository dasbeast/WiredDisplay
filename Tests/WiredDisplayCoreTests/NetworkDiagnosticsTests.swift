import XCTest
@testable import WiredDisplayCore

final class NetworkDiagnosticsTests: XCTestCase {
    func testLocalInterfaceKindLabelsMatchExpectedUserFacingNames() {
        XCTAssertEqual(LocalInterfaceKind.thunderboltBridge.discoveryLabel, "Thunderbolt")
        XCTAssertEqual(LocalInterfaceKind.wiredEthernet.discoveryLabel, "Ethernet")
        XCTAssertEqual(LocalInterfaceKind.wifi.discoveryLabel, "Wi-Fi")
    }

    func testWiredKindsArePreferredAndRankAheadOfWifi() {
        XCTAssertTrue(LocalInterfaceKind.thunderboltBridge.isWiredPreferred)
        XCTAssertTrue(LocalInterfaceKind.wiredEthernet.isWiredPreferred)
        XCTAssertFalse(LocalInterfaceKind.wifi.isWiredPreferred)
        XCTAssertLessThan(LocalInterfaceKind.thunderboltBridge.priorityScore, LocalInterfaceKind.wifi.priorityScore)
        XCTAssertLessThan(LocalInterfaceKind.wiredEthernet.priorityScore, LocalInterfaceKind.wifi.priorityScore)
    }

    func testSerializeAndParseDiscoveryPathOptionsRoundTrip() {
        let options = [
            DiscoveryPathOption(host: "169.254.10.20", kind: .thunderboltBridge),
            DiscoveryPathOption(host: "10.0.0.8", kind: .wiredEthernet),
            DiscoveryPathOption(host: "192.168.1.12", kind: .wifi),
        ]

        let payload = NetworkDiagnostics.serializeDiscoveryPathOptions(options)
        let decoded = NetworkDiagnostics.parseDiscoveryPathOptions(payload)

        XCTAssertEqual(decoded, options)
    }

    func testOrderedUniqueDiscoveryPathOptionsMovesPreferredHostFirstAndDeduplicates() {
        let ordered = NetworkDiagnostics.orderedUniqueDiscoveryPathOptions(
            [
                DiscoveryPathOption(host: "192.168.1.12", kind: .wifi),
                DiscoveryPathOption(host: "169.254.10.20", kind: .thunderboltBridge),
                DiscoveryPathOption(host: "10.0.0.8", kind: .wiredEthernet),
                DiscoveryPathOption(host: "169.254.10.20", kind: .thunderboltBridge),
            ],
            preferredHost: "10.0.0.8"
        )

        XCTAssertEqual(
            ordered,
            [
                DiscoveryPathOption(host: "10.0.0.8", kind: .wiredEthernet),
                DiscoveryPathOption(host: "169.254.10.20", kind: .thunderboltBridge),
                DiscoveryPathOption(host: "192.168.1.12", kind: .wifi),
            ]
        )
    }

    func testParseDiscoveryPathOptionsSkipsMalformedEntries() {
        let decoded = NetworkDiagnostics.parseDiscoveryPathOptions(
            "thunderboltBridge=169.254.1.2,garbage,wifi=192.168.0.4,unknown=10.0.0.5,other="
        )

        XCTAssertEqual(
            decoded,
            [
                DiscoveryPathOption(host: "169.254.1.2", kind: .thunderboltBridge),
                DiscoveryPathOption(host: "192.168.0.4", kind: .wifi),
            ]
        )
    }

    func testLooksLikeWiredPreferredHostOnlyForLinkLocalAddresses() {
        XCTAssertTrue(NetworkDiagnostics.looksLikeWiredPreferredHost("169.254.44.22"))
        XCTAssertFalse(NetworkDiagnostics.looksLikeWiredPreferredHost("192.168.1.10"))
        XCTAssertFalse(NetworkDiagnostics.looksLikeWiredPreferredHost("10.0.0.5"))
    }

    func testResolvePreferredDiscoveryHostHonorsAdvertisedHostAndWiredFlag() {
        let resolved = NetworkDiagnostics.resolvePreferredDiscoveryHost(
            advertisedHost: " 10.0.0.8 ",
            advertisedHostIsWired: true,
            resolvedHosts: ["169.254.20.30"],
            fallbackHostName: "receiver.local."
        )

        XCTAssertEqual(
            resolved,
            ResolvedDiscoveryHost(host: "10.0.0.8", prefersWiredPath: true)
        )
    }

    func testResolvePreferredDiscoveryHostFallsBackToBestResolvedAddress() {
        let resolved = NetworkDiagnostics.resolvePreferredDiscoveryHost(
            advertisedHost: nil,
            resolvedHosts: ["203.0.113.4", "fe80::1", "169.254.20.30", "10.0.0.8"],
            fallbackHostName: "receiver.local."
        )

        XCTAssertEqual(
            resolved,
            ResolvedDiscoveryHost(host: "169.254.20.30", prefersWiredPath: true)
        )
    }

    func testResolvePreferredDiscoveryHostFallsBackToHostNameWhenNoResolvedAddresses() {
        let resolved = NetworkDiagnostics.resolvePreferredDiscoveryHost(
            advertisedHost: nil,
            resolvedHosts: [],
            fallbackHostName: " receiver.local. "
        )

        XCTAssertEqual(
            resolved,
            ResolvedDiscoveryHost(host: "receiver.local", prefersWiredPath: false)
        )
    }
}
