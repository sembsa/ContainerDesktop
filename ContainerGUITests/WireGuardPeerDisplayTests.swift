import XCTest

/// The peer detail section: ordering, stale dimming, friendly names, aliases —
/// and the sudo rule the probe depends on.
final class WireGuardPeerDisplayTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func peer(
        _ key: String, ips: [String] = [], endpoint: String? = nil, ago: TimeInterval? = nil, keepalive: Int? = nil
    ) -> WireGuardPeer {
        WireGuardPeer(
            publicKey: key, endpoint: endpoint, allowedIPs: ips,
            latestHandshake: ago.map { now.addingTimeInterval(-$0) },
            rxBytes: 1024, txBytes: 2048, keepalive: keepalive
        )
    }

    private func interface(_ peers: [WireGuardPeer], addresses: [String] = ["10.10.0.254/24"]) -> WireGuardInterface {
        WireGuardInterface(name: "wg0", listenPort: 51820, publicKey: "HUBKEY=", addresses: addresses,
                           subnets: ["10.10.0.0/24"], peers: peers, source: .dump, peerDetailsNeedRoot: false)
    }

    func testMostRecentHandshakeFirstNeverLast() {
        let iface = interface([
            peer("never"), peer("old", ago: 3600), peer("fresh", ago: 20), peer("mid", ago: 100),
        ])
        let rows = WireGuardPeerPresenter.rows(for: iface, now: now)
        XCTAssertEqual(rows.map(\.peer.publicKey), ["fresh", "mid", "old", "never"])
    }

    func testStaleAfterThreeMinutesOrNever() {
        let iface = interface([peer("a", ago: 179), peer("b", ago: 181), peer("c")])
        let rows = Dictionary(uniqueKeysWithValues: WireGuardPeerPresenter.rows(for: iface, now: now).map { ($0.peer.publicKey, $0.isStale) })
        XCTAssertEqual(rows, ["a": false, "b": true, "c": true])
    }

    func testFriendlyNameFromAllowedIPMatchingAKnownMachine() {
        let hosts = [
            WireGuardKnownHost(name: "Mac Studio", addresses: ["10.10.0.1"]),
            WireGuardKnownHost(name: "This Mac", addresses: ["10.10.0.3"]),
        ]
        let iface = interface([peer("studio", ips: ["10.10.0.1/32"]), peer("mac", ips: ["10.10.0.3/32"]), peer("phone", ips: ["10.10.0.9/32"])])
        let rows = WireGuardPeerPresenter.rows(for: iface, knownHosts: hosts, now: now)
        let names = Dictionary(uniqueKeysWithValues: rows.map { ($0.peer.publicKey, $0.name) })
        XCTAssertEqual(names["studio"] ?? nil, "Mac Studio")
        XCTAssertEqual(names["mac"] ?? nil, "This Mac")
        XCTAssertNil(names["phone"] ?? nil, "no guess for an unknown peer")
        XCTAssertEqual(rows.first { $0.peer.publicKey == "studio" }?.nameSource, .machine)
    }

    func testWideAllowedRangesNeverMatchAHost() {
        let hosts = [WireGuardKnownHost(name: "Hub", addresses: ["10.10.0.254"])]
        let iface = interface([peer("gw", ips: ["0.0.0.0/0"]), peer("net", ips: ["10.10.0.0/24"])])
        XCTAssertTrue(WireGuardPeerPresenter.rows(for: iface, knownHosts: hosts, now: now).allSatisfy { $0.name == nil })
    }

    func testEndpointHostMatchesWhenAllowedIPsDoNot() {
        let hosts = [WireGuardKnownHost(name: "cloudlab", addresses: ["203.0.113.7"])]
        let iface = interface([peer("hub", ips: ["10.10.0.0/24"], endpoint: "203.0.113.7:51820")])
        XCTAssertEqual(WireGuardPeerPresenter.rows(for: iface, knownHosts: hosts, now: now)[0].name, "cloudlab")
        XCTAssertEqual(WireGuardPeerPresenter.endpointHost("[2001:db8::1]:51820"), "2001:db8::1")
        XCTAssertEqual(WireGuardPeerPresenter.endpointHost("203.0.113.7:51820"), "203.0.113.7")
        XCTAssertNil(WireGuardPeerPresenter.endpointHost(nil))
    }

    func testAliasWinsOverMachineMatch() {
        let hosts = [WireGuardKnownHost(name: "Mac Studio", addresses: ["10.10.0.1"])]
        let iface = interface([peer("studio", ips: ["10.10.0.1/32"])])
        let rows = WireGuardPeerPresenter.rows(for: iface, aliases: ["studio": "Rick's studio"], knownHosts: hosts, now: now)
        XCTAssertEqual(rows[0].name, "Rick's studio")
        XCTAssertEqual(rows[0].nameSource, .alias)
    }

    func testKnownHostsFromInterfacesAndIPLiteralEndpointsOnly() {
        let studio = interface([], addresses: ["10.10.0.1/24"])
        let hosts = WireGuardPeerPresenter.knownHosts(
            interfaces: [("Mac Studio", studio)],
            endpoints: [(label: "Mac Studio", host: "192.168.68.65"), (label: "Cloudlab", host: "cloudlab-two")]
        )
        XCTAssertEqual(hosts.map(\.name), ["Mac Studio"], "a DNS name or ssh alias identifies no address")
        XCTAssertEqual(Set(hosts[0].addresses), ["10.10.0.1", "192.168.68.65"])
        XCTAssertTrue(WireGuardPeerPresenter.isIPLiteral("10.0.0.1"))
        XCTAssertFalse(WireGuardPeerPresenter.isIPLiteral("studio"))
    }

    func testAliasStorageRoundTripsAndBlankRemoves() {
        var stored = ""
        stored = WireGuardAliases.setting("  Phone ", for: "KEY1=", in: stored)
        stored = WireGuardAliases.setting("Laptop", for: "KEY2=", in: stored)
        XCTAssertEqual(WireGuardAliases.decode(stored), ["KEY1=": "Phone", "KEY2=": "Laptop"])
        stored = WireGuardAliases.setting("   ", for: "KEY1=", in: stored)
        XCTAssertEqual(WireGuardAliases.decode(stored), ["KEY2=": "Laptop"])
        XCTAssertTrue(WireGuardAliases.decode("not json").isEmpty)
    }

    func testRowsCarryKeepaliveAndNoSecrets() {
        let iface = interface([peer("k", ips: ["10.10.0.2/32"], endpoint: "1.2.3.4:51820", ago: 5, keepalive: 25)])
        let row = WireGuardPeerPresenter.rows(for: iface, now: now)[0]
        XCTAssertEqual(row.peer.keepalive, 25)
        // The model has no preshared/private key field at all; the dump parser
        // blanks the columns (covered in WireGuardProbeTests).
        let mirror = Mirror(reflecting: row.peer).children.compactMap(\.label)
        XCTAssertFalse(mirror.contains { $0.lowercased().contains("preshared") || $0.lowercased().contains("private") })
    }

    // MARK: - The sudo rule

    func testSudoUsesTheAbsoluteWgPathsAndExactArguments() {
        XCTAssertEqual(WireGuardProbe.wgCandidates, ["/opt/homebrew/bin/wg", "/usr/local/bin/wg", "/usr/bin/wg"])
        let script = WireGuardProbe.script(trySudo: true)
        // `$WG` is only ever set from one of those absolute candidates (or an
        // absolute `command -v` result), so the rule
        // `NOPASSWD: /opt/homebrew/bin/wg show all dump` matches exactly.
        XCTAssertTrue(script.contains(#"sudo -n "$WG" show all dump"#))
        for candidate in WireGuardProbe.wgCandidates { XCTAssertTrue(script.contains("\"\(candidate)\"")) }
        XCTAssertTrue(script.contains(#"case "$c" in /*)"#), "a bare command name is never handed to sudo")
        XCTAssertTrue(WireGuardProbe.script(trySudo: false).contains("TRY_SUDO=0"))
    }
}
