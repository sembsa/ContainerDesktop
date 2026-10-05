import XCTest

/// The pure part of the topology diagram: nodes and edges from machine lists and
/// (synthetic) `wg` data, the hub, the layout and the hit-testing.
final class NetworkTopologyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func peer(_ key: String, ips: [String], endpoint: String? = nil, ago: TimeInterval? = 30,
                      rx: Int64 = 100, tx: Int64 = 200, keepalive: Int? = 25) -> WireGuardPeer {
        WireGuardPeer(publicKey: key, endpoint: endpoint, allowedIPs: ips,
                      latestHandshake: ago.map { now.addingTimeInterval(-$0) }, rxBytes: rx, txBytes: tx, keepalive: keepalive)
    }

    private func dumpInterface(_ name: String, address: String, subnet: String = "10.10.0.0/24", peers: [WireGuardPeer]) -> WireGuardInterface {
        WireGuardInterface(name: name, listenPort: 51820, publicKey: "PUB-\(name)=", addresses: [address],
                           subnets: [subnet], peers: peers, source: .dump, peerDetailsNeedRoot: false)
    }

    private func blindInterface(_ name: String, address: String, subnet: String = "10.10.0.0/24") -> WireGuardInterface {
        WireGuardInterface(name: name, listenPort: nil, publicKey: nil, addresses: [address], subnets: [subnet],
                           peers: [], source: .addressOnly, peerDetailsNeedRoot: true, inferred: true)
    }

    private func machine(_ name: String?, engines: [ContainerEngine] = [], interfaces: [WireGuardInterface] = [],
                         reach: [String] = []) -> TopologyMachine {
        TopologyMachine(key: name.map(MachineFilter.machine) ?? .local, name: name ?? "This Mac",
                        engines: engines, interfaces: interfaces, reachAddresses: reach)
    }

    private func wgEdges(_ t: NetworkTopology) -> [TopologyEdge] { t.edges.filter { $0.kind == .wireGuard } }

    // MARK: - The real shape: hub with four peers, spokes unreadable

    private var hubWithFourPeers: [TopologyMachine] {
        let hub = machine("cloudlab-two", engines: [.docker], interfaces: [dumpInterface("wg0", address: "10.10.0.254/24", peers: [
            peer("STUDIO=", ips: ["10.10.0.1/32"], endpoint: "192.168.68.65:51820", ago: 20),
            peer("MAC=", ips: ["10.10.0.3/32"], endpoint: "84.1.2.3:51820", ago: 40),
            peer("PHONE=", ips: ["10.10.0.5/32"], endpoint: "5.6.7.8:1111", ago: 900),
            peer("LAPTOP=", ips: ["10.10.0.6/32"], ago: nil),
        ])])
        let studio = machine("Mac Studio", engines: [.apple, .colima], interfaces: [blindInterface("utun12", address: "10.10.0.1/32")])
        let mac = machine(nil, engines: [.apple, .docker], interfaces: [blindInterface("utun0", address: "10.10.0.3/32")])
        return [mac, studio, hub]
    }

    func testHubAndSpokesFromTheHubsDumpAlone() {
        let t = TopologyBuilder.build(machines: hubWithFourPeers, now: now)
        XCTAssertEqual(t.hubID, "machine:cloudlab-two")
        let wg = wgEdges(t)
        XCTAssertEqual(wg.count, 4, "hub-Mac, hub-Studio and two unknown peers; nothing guessed between the spokes")
        XCTAssertTrue(wg.allSatisfy { $0.verification == .verified })
        XCTAssertTrue(wg.contains { Set([$0.a, $0.b]) == ["machine:cloudlab-two", "machine:local"] })
        XCTAssertTrue(wg.contains { Set([$0.a, $0.b]) == ["machine:cloudlab-two", "machine:Mac Studio"] })
        let unknown = t.nodes.filter { $0.kind == .unknownPeer }
        XCTAssertEqual(Set(unknown.map(\.id)), ["peer:PHONE=", "peer:LAPTOP="])
    }

    func testEngineNodesHangOffTheirMachine() {
        let t = TopologyBuilder.build(machines: hubWithFourPeers, now: now)
        let runtimes = t.nodes.filter { $0.kind == .runtime }
        XCTAssertEqual(runtimes.count, 5)
        XCTAssertEqual(Set(runtimes.filter { $0.machineID == "machine:Mac Studio" }.map(\.title)), ["Apple", "Colima"])
        XCTAssertEqual(t.edges.filter { $0.kind == .hosts }.count, 5)
    }

    func testStaleAndNeverHandshakesAreFlagged() {
        let t = TopologyBuilder.build(machines: hubWithFourPeers, now: now)
        func edge(_ other: String) -> TopologyEdge { wgEdges(t).first { $0.a == other || $0.b == other }! }
        XCTAssertFalse(edge("machine:Mac Studio").isStale(now: now))
        XCTAssertTrue(edge("peer:PHONE=").isStale(now: now))
        XCTAssertTrue(edge("peer:LAPTOP=").isStale(now: now), "never connected counts as stale")
        XCTAssertEqual(edge("machine:Mac Studio").keepalive, 25)
        XCTAssertEqual(edge("machine:Mac Studio").endpoints, ["192.168.68.65:51820"])
    }

    // MARK: - Nothing readable: dashed, unverified

    func testWithoutAnyDumpOverlayMembersAreJoinedByDashedEdges() {
        let machines = [
            machine(nil, interfaces: [blindInterface("utun0", address: "10.10.0.3/32", subnet: "10.10.0.3/32")]),
            machine("Mac Studio", interfaces: [blindInterface("utun12", address: "10.10.0.1/24")]),
            machine("cloudlab-two", interfaces: [blindInterface("wg0", address: "10.10.0.254/24")]),
        ]
        let t = TopologyBuilder.build(machines: machines, now: now)
        let wg = wgEdges(t)
        XCTAssertEqual(wg.count, 3, "three members of 10.10.0.0/24, a /32 client address included")
        XCTAssertTrue(wg.allSatisfy { $0.verification == .unverified && $0.overlay == "10.10.0.0/24" })
        XCTAssertTrue(wg.allSatisfy { !$0.isStale(now: now) }, "unverified edges are never 'stale', they are unknown")
        XCTAssertNil(t.hubID, "no verified link, no hub")
    }

    func testUnlistedUnreadableMemberHangsOffTheDumpHolderAsUnverified() {
        let hub = machine("hub", interfaces: [dumpInterface("wg0", address: "10.10.0.254/24", peers: [
            peer("A=", ips: ["10.10.0.1/32"]), peer("B=", ips: ["10.10.0.9/32"]),
        ])])
        let stranger = machine("Mac Studio", interfaces: [blindInterface("utun12", address: "10.10.0.77/32")])
        let t = TopologyBuilder.build(machines: [hub, stranger], now: now)
        let toStudio = wgEdges(t).filter { $0.a == "machine:Mac Studio" || $0.b == "machine:Mac Studio" }
        XCTAssertEqual(toStudio.map(\.verification), [.unverified])
        XCTAssertEqual(wgEdges(t).filter { $0.verification == .verified }.count, 2, "both peers show as unknown nodes")
    }

    // MARK: - Resolution rules

    func testWideAllowedRangeResolvesToTheHubOnly() {
        let hub = machine("hub", interfaces: [dumpInterface("wg0", address: "10.10.0.254/24", peers: [
            peer("S1=", ips: ["10.10.0.1/32"]), peer("S2=", ips: ["10.10.0.3/32"]),
        ])])
        let spoke = machine("spoke", interfaces: [dumpInterface("wg0", address: "10.10.0.1/32", subnet: "10.10.0.1/32", peers: [
            peer("HUB=", ips: ["10.10.0.0/24"]),
        ])])
        let other = machine(nil, interfaces: [blindInterface("utun0", address: "10.10.0.3/32")])
        let t = TopologyBuilder.build(machines: [other, spoke, hub], now: now)
        let spokeEdges = wgEdges(t).filter { $0.a == "machine:spoke" || $0.b == "machine:spoke" }
        XCTAssertEqual(spokeEdges.count, 1)
        XCTAssertTrue(spokeEdges[0].a == "machine:hub" || spokeEdges[0].b == "machine:hub", "10.10.0.0/24 covers several machines; only the hub qualifies")
        XCTAssertEqual(spokeEdges[0].links.count, 2, "both ends report the same tunnel: one edge, two observations")
    }

    func testDefaultRouteIsNotAMachine() {
        let spoke = machine("spoke", interfaces: [dumpInterface("wg0", address: "10.10.0.1/24", peers: [peer("GW=", ips: ["0.0.0.0/0"])])])
        let other = machine("other", interfaces: [blindInterface("wg0", address: "10.10.0.2/24")])
        let t = TopologyBuilder.build(machines: [spoke, other], now: now)
        XCTAssertTrue(t.nodes.contains { $0.id == "peer:GW=" })
    }

    func testEndpointMatchesAMachineByItsReachAddress() {
        let mac = machine(nil, interfaces: [dumpInterface("utun0", address: "10.10.0.3/32", subnet: "10.10.0.3/32", peers: [
            peer("HUB=", ips: ["192.168.50.0/24"], endpoint: "167.233.101.159:51820"),
        ])])
        let cloud = machine("cloudlab-two", reach: ["167.233.101.159"])
        let t = TopologyBuilder.build(machines: [mac, cloud], now: now)
        XCTAssertEqual(wgEdges(t).map { Set([$0.a, $0.b]) }, [["machine:local", "machine:cloudlab-two"]])
        XCTAssertTrue(t.nodes.allSatisfy { $0.kind != .unknownPeer })
    }

    func testUnknownPeerSeenByTwoMachinesIsOneNodeWithAliasAsTitle() {
        let a = machine("a", interfaces: [dumpInterface("wg0", address: "10.10.0.1/24", peers: [peer("PHONE=", ips: ["10.10.0.50/32"])])])
        let b = machine("b", interfaces: [dumpInterface("wg0", address: "10.10.0.2/24", peers: [peer("PHONE=", ips: ["10.10.0.50/32"])])])
        let t = TopologyBuilder.build(machines: [a, b], aliases: ["PHONE=": "Rick's phone"], now: now)
        let unknown = t.nodes.filter { $0.kind == .unknownPeer }
        XCTAssertEqual(unknown.map(\.title), ["Rick's phone"])
        XCTAssertEqual(wgEdges(t).count, 2)
    }

    func testMutualDumpsMergeIntoOneVerifiedEdgeWithTheFreshestHandshake() {
        let a = machine("a", interfaces: [dumpInterface("wg0", address: "10.10.0.1/24", peers: [peer("B=", ips: ["10.10.0.2/32"], ago: 500, rx: 10, tx: 20)])])
        let b = machine("b", interfaces: [dumpInterface("wg0", address: "10.10.0.2/24", peers: [peer("A=", ips: ["10.10.0.1/32"], ago: 15, rx: 30, tx: 40)])])
        let t = TopologyBuilder.build(machines: [a, b], now: now)
        let edge = try! XCTUnwrap(wgEdges(t).first)
        XCTAssertEqual(wgEdges(t).count, 1)
        XCTAssertEqual(edge.latestHandshake, now.addingTimeInterval(-15))
        XCTAssertFalse(edge.isStale(now: now))
        XCTAssertEqual(edge.rxBytes, 30)
    }

    func testNoWireGuardAtAllIsJustMachinesAndEngines() {
        let t = TopologyBuilder.build(machines: [machine(nil, engines: [.apple, .docker]), machine("studio", engines: [.colima])], now: now)
        XCTAssertTrue(wgEdges(t).isEmpty)
        XCTAssertNil(t.hubID)
        XCTAssertEqual(t.machines.count, 2)
    }

    // MARK: - From the Networks list

    func testMachinesFromEntriesKeepThisMacFirstAndCollectEngines() {
        let entries = [
            NetworkEntry(id: "1", reference: "default", name: "default", kind: .apple),
            NetworkEntry(id: "2", reference: "bridge", name: "bridge", kind: .docker)
                .with(runtimeID: "machine:1", machineLabel: "studio", engine: .colima),
            NetworkEntry(id: "3", reference: "bridge", name: "bridge", kind: .docker),
            NetworkEntry(wireGuard: dumpInterface("wg0", address: "10.10.0.254/24", peers: [])),
        ]
        let machines = TopologyBuilder.machines(from: entries, knownMachines: [("cloudlab", "167.233.101.159"), ("studio", "studio")])
        XCTAssertEqual(machines.map(\.name), [String(localized: "Ten Mac"), "cloudlab", "studio"])
        XCTAssertEqual(machines[0].engines, [.apple, .docker])
        XCTAssertEqual(machines[0].interfaces.map(\.name), ["wg0"])
        XCTAssertEqual(machines[1].reachAddresses, ["167.233.101.159"])
        XCTAssertEqual(machines[2].reachAddresses, [], "an ssh alias is not an address")
        XCTAssertEqual(machines[2].engines, [.colima])
        XCTAssertEqual(machines[0].networkNames[.docker], ["bridge"])
    }

    // MARK: - Layout and hit-testing

    func testHubSitsInTheMiddleAndSpokesOnACircle() {
        let t = TopologyBuilder.build(machines: hubWithFourPeers, now: now)
        let p = TopologyLayout.positions(for: t)
        XCTAssertEqual(p["machine:cloudlab-two"], .zero)
        for id in ["machine:local", "machine:Mac Studio"] {
            let point = try! XCTUnwrap(p[id])
            XCTAssertEqual(hypot(point.x, point.y), 300, accuracy: 0.001)
        }
        XCTAssertEqual(Set(p.keys), Set(t.nodes.map(\.id)), "every node gets a position")
        let runtime = try! XCTUnwrap(p["runtime:machine:Mac Studio:colima"]), studio = p["machine:Mac Studio"]!
        XCTAssertEqual(hypot(runtime.x - studio.x, runtime.y - studio.y), 95, accuracy: 0.001)
    }

    func testWithoutAHubMachinesShareACircleAndASingleMachineSitsAtTheCentre() {
        let two = TopologyBuilder.build(machines: [machine(nil), machine("studio")], now: now)
        let p = TopologyLayout.positions(for: two)
        XCTAssertEqual(hypot(p["machine:local"]!.x, p["machine:local"]!.y), 260, accuracy: 0.001)
        XCTAssertNotEqual(p["machine:local"], p["machine:studio"])
        let one = TopologyBuilder.build(machines: [machine(nil)], now: now)
        XCTAssertEqual(TopologyLayout.positions(for: one)["machine:local"], .zero)
        XCTAssertEqual(TopologyLayout.positions(for: two), TopologyLayout.positions(for: two), "deterministic")
    }

    func testNearestEdgeHitTesting() {
        let t = TopologyBuilder.build(machines: hubWithFourPeers, now: now)
        let p = TopologyLayout.positions(for: t)
        let hub = p["machine:cloudlab-two"]!, studio = p["machine:Mac Studio"]!
        let middle = CGPoint(x: (hub.x + studio.x) / 2, y: (hub.y + studio.y) / 2)
        XCTAssertEqual(TopologyLayout.nearestEdge(to: middle, in: t, positions: p, threshold: 6)?.id, "wg:machine:Mac Studio|machine:cloudlab-two")
        XCTAssertNil(TopologyLayout.nearestEdge(to: CGPoint(x: 5000, y: 5000), in: t, positions: p, threshold: 6))
        XCTAssertEqual(TopologyLayout.distance(from: CGPoint(x: 5, y: 5), toSegment: .zero, CGPoint(x: 10, y: 0)), 5, accuracy: 0.0001)
        XCTAssertEqual(TopologyLayout.distance(from: CGPoint(x: 20, y: 0), toSegment: .zero, CGPoint(x: 10, y: 0)), 10, accuracy: 0.0001)
    }

    func testCIDRContainment() {
        XCTAssertTrue(CIDR.contains("10.10.0.0/24", "10.10.0.254"))
        XCTAssertFalse(CIDR.contains("10.10.0.0/24", "10.10.1.1"))
        XCTAssertTrue(CIDR.contains("10.10.0.3/32", "10.10.0.3"))
        XCTAssertTrue(CIDR.contains("0.0.0.0/0", "8.8.8.8"))
        XCTAssertFalse(CIDR.contains("garbage", "10.0.0.1"))
    }
}
