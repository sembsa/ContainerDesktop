import XCTest

/// The peer labels: the value type (set / clear / normalisation), the
/// `UserDefaults`-backed store (persist round trip, legacy import) and the way a
/// label takes priority over an auto-matched name in the list and the topology.
@MainActor
final class WireGuardPeerLabelStoreTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func freshDefaults() -> UserDefaults {
        let name = "WireGuardPeerLabelStoreTests.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        return UserDefaults(suiteName: name)!
    }

    private func peer(_ key: String, ips: [String] = [], endpoint: String? = nil, ago: TimeInterval? = 30) -> WireGuardPeer {
        WireGuardPeer(publicKey: key, endpoint: endpoint, allowedIPs: ips,
                      latestHandshake: ago.map { now.addingTimeInterval(-$0) }, rxBytes: 1, txBytes: 2, keepalive: nil)
    }

    private func interface(_ name: String = "wg0", address: String, key: String? = nil, peers: [WireGuardPeer]) -> WireGuardInterface {
        WireGuardInterface(name: name, listenPort: 51820, publicKey: key, addresses: [address], subnets: ["10.10.0.0/24"],
                           peers: peers, source: .dump, peerDetailsNeedRoot: false)
    }

    // MARK: - Value type

    func testSetTrimsAndStoresLabelAndNote() {
        var labels = WireGuardPeerLabels()
        XCTAssertTrue(labels.set(label: "  Mac Studio  ", note: "\n in the office \n", for: "KEY1="))
        XCTAssertEqual(labels.label(for: "KEY1="), "Mac Studio")
        XCTAssertEqual(labels.note(for: "KEY1="), "in the office")
        XCTAssertEqual(labels.names, ["KEY1=": "Mac Studio"])
        XCTAssertEqual(labels.notes, ["KEY1=": "in the office"])
    }

    func testALabelIsRequiredToSave() {
        var labels = WireGuardPeerLabels()
        XCTAssertFalse(labels.set(label: "   \n", note: "orphan note", for: "KEY1="))
        XCTAssertFalse(labels.set(label: "Phone", for: ""), "no key, nothing to attach it to")
        XCTAssertTrue(labels.isEmpty)
        labels.set(label: "Phone", note: "mine", for: "KEY1=")
        XCTAssertFalse(labels.set(label: "", note: "changed", for: "KEY1="))
        XCTAssertEqual(labels.entry(for: "KEY1="), WireGuardPeerLabel(label: "Phone", note: "mine"), "a rejected save changes nothing")
    }

    func testNoteIsOptionalAndOverwritten() {
        var labels = WireGuardPeerLabels()
        labels.set(label: "Phone", for: "KEY1=")
        XCTAssertNil(labels.note(for: "KEY1="))
        labels.set(label: "Phone", note: "n1", for: "KEY1=")
        labels.set(label: "Phone 2", note: "", for: "KEY1=")
        XCTAssertEqual(labels.entry(for: "KEY1="), WireGuardPeerLabel(label: "Phone 2", note: ""))
        XCTAssertTrue(labels.notes.isEmpty)
    }

    func testLengthsAreCapped() {
        var labels = WireGuardPeerLabels()
        labels.set(label: String(repeating: "a", count: 200), note: String(repeating: "n", count: 2000), for: "KEY1=")
        XCTAssertEqual(labels.label(for: "KEY1=")?.count, WireGuardPeerLabels.maxLabelLength)
        XCTAssertEqual(labels.entry(for: "KEY1=")?.note.count, WireGuardPeerLabels.maxNoteLength)
    }

    func testClearRemovesLabelAndNoteOfThatKeyOnly() {
        var labels = WireGuardPeerLabels()
        labels.set(label: "A", note: "na", for: "KEY1=")
        labels.set(label: "B", for: "KEY2=")
        labels.clear(for: "KEY1=")
        XCTAssertNil(labels.entry(for: "KEY1="))
        XCTAssertNil(labels.note(for: "KEY1="))
        XCTAssertEqual(labels.names, ["KEY2=": "B"])
        labels.clear(for: "unknown")
        XCTAssertEqual(labels.names, ["KEY2=": "B"])
    }

    // MARK: - Priority

    private let hosts = [WireGuardKnownHost(name: "Mac Studio", addresses: ["10.10.0.1"])]

    func testLabelWinsOverMachineMatchAndClearingFallsBackToTheMachineThenTheKey() {
        let iface = interface(address: "10.10.0.254/24", peers: [
            peer("STUDIO=", ips: ["10.10.0.1/32"]), peer("OTHER=", ips: ["10.10.0.9/32"]),
        ])
        var labels = WireGuardPeerLabels()
        labels.set(label: "Studio (office)", note: "wired", for: "STUDIO=")
        labels.set(label: "Spare", for: "OTHER=")

        func rows() -> [String: WireGuardPeerRow] {
            Dictionary(uniqueKeysWithValues: WireGuardPeerPresenter.rows(
                for: iface, aliases: labels.names, notes: labels.notes, knownHosts: hosts, now: now
            ).map { ($0.peer.publicKey, $0) })
        }
        XCTAssertEqual(rows()["STUDIO="]?.name, "Studio (office)")
        XCTAssertEqual(rows()["STUDIO="]?.nameSource, .alias)
        XCTAssertEqual(rows()["STUDIO="]?.autoName, "Mac Studio", "the form can say what clearing reverts to")
        XCTAssertEqual(rows()["STUDIO="]?.note, "wired")
        XCTAssertEqual(rows()["OTHER="]?.name, "Spare")
        XCTAssertNil(rows()["OTHER="]?.autoName)

        labels.clear(for: "STUDIO=")
        XCTAssertEqual(rows()["STUDIO="]?.name, "Mac Studio")
        XCTAssertEqual(rows()["STUDIO="]?.nameSource, .machine)
        XCTAssertNil(rows()["STUDIO="]?.note)

        labels.clear(for: "OTHER=")
        XCTAssertNil(rows()["OTHER="]?.name, "no label, no match: the list shows the shortened key")
        XCTAssertNil(rows()["OTHER="]?.nameSource)
    }

    func testHeaderSummaryNamesTheFirstFewPeers() {
        let iface = interface(address: "10.10.0.254/24", peers: (1...5).map { peer("K\($0)=", ips: ["10.10.0.\($0)/32"], ago: Double($0)) })
        let labels = ["K1=": "One", "K2=": "Two", "K3=": "Three", "K4=": "Four"]
        let rows = WireGuardPeerPresenter.rows(for: iface, aliases: labels, now: now)
        XCTAssertEqual(WireGuardPeerPresenter.summary(of: rows), "One, Two, Three +1")
        XCTAssertEqual(WireGuardPeerPresenter.peerNames(rows).count, 5)
        XCTAssertEqual(WireGuardPeerPresenter.peerNames(rows).last, WireGuardFormat.shortKey("K5="))
        XCTAssertNil(WireGuardPeerPresenter.summary(of: WireGuardPeerPresenter.rows(for: iface, now: now)))
    }

    func testLabelRenamesAMachineNodeAndShowsOnItsEdges() {
        let hub = TopologyMachine(key: .machine("hub"), name: "hub", interfaces: [
            interface(address: "10.10.0.254/24", key: "HUB=", peers: [
                peer("STUDIO=", ips: ["10.10.0.1/32"]), peer("MAC=", ips: ["10.10.0.3/32"]), peer("PHONE=", ips: ["10.10.0.5/32"]),
            ]),
        ])
        let studio = TopologyMachine(key: .machine("Mac Studio"), name: "Mac Studio", interfaces: [
            WireGuardInterface(name: "utun1", listenPort: nil, publicKey: nil, addresses: ["10.10.0.1/32"], subnets: ["10.10.0.1/32"],
                               peers: [], source: .addressOnly, peerDetailsNeedRoot: true, inferred: true),
        ])
        let mac = TopologyMachine(key: .local, name: "Ten Mac", interfaces: [
            WireGuardInterface(name: "utun0", listenPort: nil, publicKey: nil, addresses: ["10.10.0.3/32"], subnets: ["10.10.0.3/32"],
                               peers: [], source: .addressOnly, peerDetailsNeedRoot: true, inferred: true),
        ])
        let plain = TopologyBuilder.build(machines: [mac, studio, hub], now: now)
        XCTAssertEqual(plain.node("machine:Mac Studio")?.title, "Mac Studio")
        XCTAssertEqual(plain.node("peer:PHONE=")?.title, String(localized: "Nieznany peer"))

        let labelled = TopologyBuilder.build(
            machines: [mac, studio, hub],
            aliases: ["STUDIO=": "Studio (office)", "MAC=": "This laptop", "PHONE=": "Rick's phone", "HUB=": "Cloud hub"],
            notes: ["PHONE=": "iPhone 17"], now: now
        )
        let studioNode = labelled.node("machine:Mac Studio")
        XCTAssertEqual(studioNode?.title, "Studio (office)", "a label beats the auto-matched machine name")
        XCTAssertEqual(studioNode?.autoTitle, "Mac Studio")
        XCTAssertEqual(studioNode?.peerKeys, ["STUDIO="])
        XCTAssertEqual(labelled.node("machine:local")?.title, "This laptop")
        XCTAssertEqual(labelled.node("machine:hub")?.title, "Cloud hub", "a machine's own interface key labels it too")
        XCTAssertEqual(labelled.node("machine:hub")?.autoTitle, "hub")
        let phone = labelled.node("peer:PHONE=")
        XCTAssertEqual(phone?.title, "Rick's phone")
        XCTAssertEqual(phone?.note, "iPhone 17")
        let edge = labelled.edges.first { $0.kind == .wireGuard && $0.links.first?.peer.publicKey == "STUDIO=" }
        XCTAssertEqual(edge?.labels, ["Studio (office)"])
        XCTAssertEqual(edge?.links.first?.label, "Studio (office)")

        // Clearing reverts every one of them.
        let cleared = TopologyBuilder.build(machines: [mac, studio, hub], aliases: [:], now: now)
        XCTAssertEqual(cleared.node("machine:Mac Studio")?.title, "Mac Studio")
        XCTAssertEqual(cleared.node("machine:local")?.title, "Ten Mac")
        XCTAssertNil(cleared.node("machine:local")?.label)
    }

    // MARK: - Store and persistence

    func testStorePersistsAndReloads() {
        let defaults = freshDefaults()
        let store = WireGuardPeerLabelStore(defaults: defaults)
        XCTAssertTrue(store.labels.isEmpty)
        XCTAssertTrue(store.set(label: " Mac Studio ", note: "office", for: "KEY1="))
        XCTAssertTrue(store.set(label: "Phone", for: "KEY2="))
        XCTAssertFalse(store.set(label: "  ", for: "KEY3="))

        let reloaded = WireGuardPeerLabelStore(defaults: defaults)
        XCTAssertEqual(reloaded.names, ["KEY1=": "Mac Studio", "KEY2=": "Phone"])
        XCTAssertEqual(reloaded.note(for: "KEY1="), "office")
        XCTAssertNil(reloaded.note(for: "KEY2="))

        reloaded.clear(for: "KEY1=")
        let again = WireGuardPeerLabelStore(defaults: defaults)
        XCTAssertEqual(again.names, ["KEY2=": "Phone"])
        XCTAssertNil(again.entry(for: "KEY1="))
    }

    func testStoresOnDifferentDefaultsDoNotShareLabels() {
        let a = WireGuardPeerLabelStore(defaults: freshDefaults())
        let b = WireGuardPeerLabelStore(defaults: freshDefaults())
        a.set(label: "Only in A", for: "KEY1=")
        XCTAssertTrue(b.labels.isEmpty)
    }

    func testPersistedDataHoldsOnlyKeyLabelAndNote() throws {
        let defaults = freshDefaults()
        let store = WireGuardPeerLabelStore(defaults: defaults)
        store.set(label: "Phone", note: "mine", for: "PUBKEY=")
        let data = try XCTUnwrap(defaults.data(forKey: WireGuardPeerLabelStore.defaultsKey))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let entries = try XCTUnwrap(json["entries"] as? [String: [String: String]])
        XCTAssertEqual(entries, ["PUBKEY=": ["label": "Phone", "note": "mine"]])
        XCTAssertEqual(json.keys.sorted(), ["entries"])
    }

    func testCorruptDataStartsEmptyInsteadOfCrashing() {
        let defaults = freshDefaults()
        defaults.set(Data("not json".utf8), forKey: WireGuardPeerLabelStore.defaultsKey)
        XCTAssertTrue(WireGuardPeerLabelStore(defaults: defaults).labels.isEmpty)
    }

    func testEarlierAliasesAreImportedOnceAndLeftInPlace() {
        let defaults = freshDefaults()
        let legacy = WireGuardAliases.setting("Laptop", for: "KEY2=", in: WireGuardAliases.setting("Phone", for: "KEY1=", in: ""))
        defaults.set(legacy, forKey: WireGuardAliases.defaultsKey)

        let store = WireGuardPeerLabelStore(defaults: defaults)
        XCTAssertEqual(store.names, ["KEY1=": "Phone", "KEY2=": "Laptop"])
        XCTAssertEqual(defaults.string(forKey: WireGuardAliases.defaultsKey), legacy)

        // After the import the new key is the source of truth.
        store.clear(for: "KEY1=")
        XCTAssertEqual(WireGuardPeerLabelStore(defaults: defaults).names, ["KEY2=": "Laptop"])
    }
}
