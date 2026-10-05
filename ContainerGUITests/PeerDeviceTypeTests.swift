import XCTest
import AppKit

/// The device type of a peer: persistence next to the labels (round trip and
/// backwards-compatible decode), name hints, and which icon wins in the
/// topology and the peer list.
@MainActor
final class PeerDeviceTypeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func freshDefaults() -> UserDefaults {
        let name = "PeerDeviceTypeTests.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        return UserDefaults(suiteName: name)!
    }

    private func peer(_ key: String, ips: [String] = [], endpoint: String? = nil) -> WireGuardPeer {
        WireGuardPeer(publicKey: key, endpoint: endpoint, allowedIPs: ips,
                      latestHandshake: now.addingTimeInterval(-30), rxBytes: 1, txBytes: 2, keepalive: nil)
    }

    private func dump(_ name: String, address: String, key: String, peers: [WireGuardPeer]) -> WireGuardInterface {
        WireGuardInterface(name: name, listenPort: 51820, publicKey: key, addresses: [address], subnets: ["10.10.0.0/24"],
                           peers: peers, source: .dump, peerDetailsNeedRoot: false)
    }

    // MARK: - The enum

    func testAllElevenTypesHaveDistinctRealSymbolsAndTitles() {
        XCTAssertEqual(PeerDeviceType.allCases.count, 11)
        XCTAssertEqual(Set(PeerDeviceType.allCases.map(\.symbol)).count, 11)
        for type in PeerDeviceType.allCases {
            XCTAssertNotNil(NSImage(systemSymbolName: type.symbol, accessibilityDescription: nil), "\(type.symbol) is not an SF Symbol")
            XCTAssertFalse(type.title.isEmpty)
        }
        XCTAssertNotNil(NSImage(systemSymbolName: PeerDeviceType.autoSymbol, accessibilityDescription: nil))
    }

    func testNameHints() {
        XCTAssertEqual(PeerDeviceType.inferred(fromName: "Rick's iPhone"), .phone)
        XCTAssertEqual(PeerDeviceType.inferred(fromName: "pixel-8"), .phone)
        XCTAssertEqual(PeerDeviceType.inferred(fromName: "iPad Pro"), .tablet)
        XCTAssertEqual(PeerDeviceType.inferred(fromName: "garage-pi"), .singleBoard)
        XCTAssertEqual(PeerDeviceType.inferred(fromName: "Raspberry 4"), .singleBoard)
        XCTAssertEqual(PeerDeviceType.inferred(fromName: "edge-router"), .router)
        XCTAssertEqual(PeerDeviceType.inferred(fromName: "Living room TV"), .smartTV)
        XCTAssertEqual(PeerDeviceType.inferred(fromName: "hetzner-1"), .cloud)
        XCTAssertEqual(PeerDeviceType.inferred(fromName: "Rick's MacBook Pro"), .laptop)
    }

    func testNamesThatSayNothingCertainGiveNoHint() {
        for name in ["Mac Studio", "Ten Mac", "This Mac", "cloudlab-two", "pipeline", "tvorca", "", "studio"] {
            XCTAssertNil(PeerDeviceType.inferred(fromName: name), name)
        }
    }

    func testIconPriorityUserThenHintThenBuiltInThenNone() {
        XCTAssertEqual(PeerDeviceType.resolved(user: .tablet, inferred: .phone, builtIn: .server), .tablet)
        XCTAssertEqual(PeerDeviceType.resolved(user: nil, inferred: .phone, builtIn: .server), .phone)
        XCTAssertEqual(PeerDeviceType.resolved(user: nil, inferred: nil, builtIn: .server), .server)
        XCTAssertNil(PeerDeviceType.resolved(user: nil, inferred: nil, builtIn: nil))
    }

    // MARK: - Persistence

    func testStoreRoundTripWithDeviceTypes() {
        let defaults = freshDefaults()
        let store = WireGuardPeerLabelStore(defaults: defaults)
        XCTAssertTrue(store.set(label: "Pi", note: "garage", deviceType: .singleBoard, for: "PI="))
        XCTAssertTrue(store.set(label: "Plain", for: "PLAIN="))
        store.setDeviceType(.router, for: ["A=", "B="])

        let reloaded = WireGuardPeerLabelStore(defaults: defaults)
        XCTAssertEqual(reloaded.deviceType(for: "PI="), .singleBoard)
        XCTAssertEqual(reloaded.label(for: "PI="), "Pi")
        XCTAssertEqual(reloaded.note(for: "PI="), "garage")
        XCTAssertNil(reloaded.deviceType(for: "PLAIN="), "no choice is Auto")
        XCTAssertEqual(reloaded.deviceTypes, ["PI=": .singleBoard, "A=": .router, "B=": .router])
        XCTAssertNil(reloaded.label(for: "A="), "a type alone creates no label")
        XCTAssertEqual(reloaded.labels, store.labels)
    }

    func testResettingToAutoRemovesTheType() {
        let store = WireGuardPeerLabelStore(defaults: freshDefaults())
        store.set(label: "Pi", deviceType: .phone, for: "K=")
        store.set(label: "Pi", deviceType: nil, for: "K=")
        XCTAssertNil(store.deviceType(for: "K="))
        store.setDeviceType(.iot, for: ["K="])
        store.setDeviceType(nil, for: ["K="])
        XCTAssertTrue(store.deviceTypes.isEmpty)
    }

    func testClearingTheLabelClearsItsType() {
        let store = WireGuardPeerLabelStore(defaults: freshDefaults())
        store.set(label: "Phone", note: "n", deviceType: .phone, for: "K=")
        store.clear(for: "K=")
        XCTAssertNil(store.entry(for: "K="))
        XCTAssertNil(store.deviceType(for: "K="))
        XCTAssertTrue(store.labels.isEmpty)
        store.setDeviceType(.server, for: ["ONLY="])
        store.clear(for: "ONLY=")
        XCTAssertTrue(store.labels.isEmpty, "a type without a label is cleared too")
    }

    func testRejectedSaveKeepsTheOldType() {
        var labels = WireGuardPeerLabels()
        labels.set(label: "Phone", deviceType: .phone, for: "K=")
        XCTAssertFalse(labels.set(label: " ", deviceType: .server, for: "K="))
        XCTAssertEqual(labels.deviceType(for: "K="), .phone)
    }

    func testLabelsSavedByTheEarlierVersionStillDecode() throws {
        // Exactly what the previous build wrote: entries only, no deviceTypes.
        let old = Data(#"{"entries":{"KEY1=":{"label":"Mac Studio","note":"office"},"KEY2=":{"label":"Phone","note":""}}}"#.utf8)
        let labels = WireGuardPeerLabels.decoded(from: old)
        XCTAssertEqual(labels.label(for: "KEY1="), "Mac Studio")
        XCTAssertEqual(labels.note(for: "KEY1="), "office")
        XCTAssertEqual(labels.label(for: "KEY2="), "Phone")
        XCTAssertTrue(labels.deviceTypes.isEmpty)

        let defaults = freshDefaults()
        defaults.set(old, forKey: WireGuardPeerLabelStore.defaultsKey)
        let store = WireGuardPeerLabelStore(defaults: defaults)
        XCTAssertEqual(store.names, ["KEY1=": "Mac Studio", "KEY2=": "Phone"])
        XCTAssertNil(store.deviceType(for: "KEY1="))
    }

    func testFileWithoutTypesIsWrittenInTheOldShape() throws {
        var labels = WireGuardPeerLabels()
        labels.set(label: "Phone", for: "K=")
        let json = try XCTUnwrap(String(data: try XCTUnwrap(labels.encoded()), encoding: .utf8))
        XCTAssertFalse(json.contains("deviceTypes"), "an older build must still read what a labels-only user saved")
    }

    func testUnknownTypeFromANewerVersionIsSkippedNotFatal() {
        let data = Data(#"{"entries":{"K=":{"label":"X","note":""}},"deviceTypes":{"K=":"hologram","J=":"phone"}}"#.utf8)
        let labels = WireGuardPeerLabels.decoded(from: data)
        XCTAssertEqual(labels.label(for: "K="), "X", "the labels survive")
        XCTAssertNil(labels.deviceType(for: "K="))
        XCTAssertEqual(labels.deviceType(for: "J="), .phone)
    }

    // MARK: - Icon resolution in the topology

    private func machines() -> [TopologyMachine] {
        let hub = TopologyMachine(key: .machine("cloudlab-two"), name: "cloudlab-two", interfaces: [
            dump("wg0", address: "10.10.0.254/24", key: "HUB=", peers: [
                peer("STUDIO=", ips: ["10.10.0.1/32"]),
                peer("PHONE=", ips: ["10.10.0.5/32"]),
                peer("STRANGER=", ips: ["10.99.0.9/32"]),
            ])
        ], reachAddresses: ["203.0.113.9"])
        let studio = TopologyMachine(key: .machine("Mac Studio"), name: "Mac Studio", interfaces: [], reachAddresses: ["10.10.0.1"])
        let phone = TopologyMachine(key: .machine("Rick's iPhone"), name: "Rick's iPhone", interfaces: [], reachAddresses: ["10.10.0.5"])
        let local = TopologyMachine(key: .local, name: "This Mac")
        return [local, hub, studio, phone]
    }

    private func node(_ id: String, _ topology: NetworkTopology) throws -> TopologyNode {
        try XCTUnwrap(topology.node(id), id)
    }

    func testKnownMachinesKeepTheirBuiltInIconOnAuto() throws {
        let t = TopologyBuilder.build(machines: machines(), now: now)
        XCTAssertEqual(try node("machine:local", t).deviceType, .laptop)
        XCTAssertEqual(try node("machine:Mac Studio", t).deviceType, .server)
        XCTAssertNil(try node("machine:Mac Studio", t).userDeviceType)
    }

    func testNameHintOverridesTheBuiltInIcon() throws {
        let t = TopologyBuilder.build(machines: machines(), now: now)
        XCTAssertEqual(try node("machine:Rick's iPhone", t).deviceType, .phone)
    }

    func testUnknownPeerOnAutoStaysQuestionMark() throws {
        let t = TopologyBuilder.build(machines: machines(), aliases: ["STRANGER=": "Rick's iPhone"], now: now)
        let unknown = try node("peer:STRANGER=", t)
        XCTAssertEqual(unknown.kind, .unknownPeer)
        XCTAssertNil(unknown.deviceType, "a label that sounds like a phone does not change a peer on Auto")
    }

    func testUserTypeOverridesEverythingOnUnknownPeersAndMachines() throws {
        let t = TopologyBuilder.build(
            machines: machines(), aliases: [:],
            deviceTypes: ["STRANGER=": .iot, "STUDIO=": .desktop, "PHONE=": .tablet], now: now)
        XCTAssertEqual(try node("peer:STRANGER=", t).deviceType, .iot)
        let studio = try node("machine:Mac Studio", t)
        XCTAssertEqual(studio.deviceType, .desktop, "the user's choice beats the built-in server")
        XCTAssertEqual(studio.userDeviceType, .desktop)
        XCTAssertEqual(try node("machine:Rick's iPhone", t).deviceType, .tablet, "and beats a hint from the name")
    }

    func testMachineTypeIsStoredUnderItsKeysOrItsNodeId() throws {
        let t = TopologyBuilder.build(machines: machines(), now: now)
        XCTAssertEqual(try node("machine:Mac Studio", t).deviceTypeKeys, ["STUDIO="])
        XCTAssertEqual(try node("machine:local", t).deviceTypeKeys, ["machine:local"], "no keys: the node id")
        let withLocal = TopologyBuilder.build(machines: machines(), deviceTypes: ["machine:local": .desktop], now: now)
        XCTAssertEqual(try node("machine:local", withLocal).deviceType, .desktop)
    }

    // MARK: - Peer rows

    func testPeerRowIconPriority() throws {
        let iface = dump("wg0", address: "10.10.0.254/24", key: "HUB=", peers: [
            peer("STUDIO=", ips: ["10.10.0.1/32"]), peer("PHONE=", ips: ["10.10.0.5/32"]), peer("STRANGER=", ips: ["10.99.0.9/32"]),
        ])
        let hosts = [WireGuardKnownHost(name: "Mac Studio", addresses: ["10.10.0.1"]),
                     WireGuardKnownHost(name: "Rick's iPhone", addresses: ["10.10.0.5"])]
        func rows(_ types: [String: PeerDeviceType]) -> [String: WireGuardPeerRow] {
            Dictionary(uniqueKeysWithValues: WireGuardPeerPresenter.rows(for: iface, deviceTypes: types, knownHosts: hosts, now: now)
                .map { ($0.peer.publicKey, $0) })
        }
        let auto = rows([:])
        XCTAssertNil(auto["STUDIO="]?.deviceType, "a machine whose name says nothing: no row icon")
        XCTAssertEqual(auto["PHONE="]?.deviceType, .phone)
        XCTAssertEqual(auto["PHONE="]?.deviceTypeIsUserChosen, false)
        XCTAssertNil(auto["STRANGER="]?.deviceType)

        let chosen = rows(["PHONE=": .tablet, "STRANGER=": .router])
        XCTAssertEqual(chosen["PHONE="]?.deviceType, .tablet)
        XCTAssertEqual(chosen["PHONE="]?.deviceTypeIsUserChosen, true)
        XCTAssertEqual(chosen["STRANGER="]?.deviceType, .router)
    }
}
