import XCTest

/// Docker / Apple network output -> `NetworkEntry`, the three source tags, the
/// toolbar filters and the action gating. The docker fixtures are real output
/// from Docker Desktop (`docker network ls` / `inspect`).
final class NetworkRuntimeTests: XCTestCase {
    private func fixtureText(_ name: String, ext: String) throws -> String {
        let bundle = Bundle(for: type(of: self))
        let url = bundle.url(forResource: name, withExtension: ext, subdirectory: "Fixtures")
            ?? bundle.url(forResource: name, withExtension: ext)
        return try String(contentsOf: XCTUnwrap(url, "missing fixture \(name).\(ext)"), encoding: .utf8)
    }

    private let local = ContainerLocation.local.title
    private let external = ContainerLocation.external.title

    private func texts(_ entry: NetworkEntry) -> [String] { entry.sourceTags.map(\.text) }

    // MARK: - docker network ls

    func testDecodeLsRows() throws {
        let rows = try DockerNetworkRow.decodeLines(fixtureText("docker-network-ls", ext: "ndjson"))
        XCTAssertEqual(rows.map(\.Name), ["bridge", "host", "none"])
        XCTAssertEqual(rows.first?.Driver, "bridge")
        XCTAssertEqual(rows.first?.Scope, "local")
        XCTAssertEqual(rows.first?.Internal, "false")
    }

    func testLsRowMapsWithoutInspect() throws {
        let row = try XCTUnwrap(DockerNetworkRow.decodeLines(fixtureText("docker-network-ls", ext: "ndjson")).first)
        let entry = DockerNetworkMapper.map(row)
        XCTAssertEqual(entry.name, "bridge")
        XCTAssertEqual(entry.kind, .docker)
        XCTAssertEqual(entry.driver, "bridge")
        XCTAssertEqual(entry.scope, "local")
        XCTAssertNil(entry.ipv4Subnet)
        XCTAssertTrue(entry.isBuiltIn)
        XCTAssertFalse(entry.isInternal)
    }

    func testInternalFlagInLsRow() throws {
        let json = #"{"ID":"abc","Name":"backend","Driver":"bridge","Scope":"local","Internal":"true","IPv6":"false","Labels":""}"#
        let entry = DockerNetworkMapper.map(try XCTUnwrap(DockerNetworkRow.decodeLines(json).first))
        XCTAssertTrue(entry.isInternal)
        XCTAssertFalse(entry.isBuiltIn)
    }

    // MARK: - docker network inspect

    func testInspectMapsSubnetGatewayAndAttachedContainers() throws {
        let inspected = try DockerNetworkInspect.decodeArray(fixtureText("docker-network-inspect", ext: "json"))
        let bridge = try XCTUnwrap(inspected.first { $0.Name == "bridge" })
        let entry = DockerNetworkMapper.map(bridge)

        XCTAssertEqual(entry.kind, .docker)
        XCTAssertEqual(entry.driver, "bridge")
        XCTAssertEqual(entry.scope, "local")
        XCTAssertEqual(entry.ipv4Subnet, "172.17.0.0/16")
        XCTAssertEqual(entry.ipv4Gateway, "172.17.0.1")
        XCTAssertNil(entry.ipv6Subnet)
        XCTAssertFalse(entry.isInternal)
        XCTAssertTrue(entry.isBuiltIn)
        XCTAssertEqual(entry.attached.map(\.name), ["test-nginx"])
        XCTAssertEqual(entry.attached.first?.ipv4Address, "172.17.0.2/16")
        XCTAssertNotNil(entry.createdAt)
    }

    func testHostAndNoneHaveNoAddressing() throws {
        let inspected = try DockerNetworkInspect.decodeArray(fixtureText("docker-network-inspect", ext: "json"))
        for name in ["host", "none"] {
            let entry = DockerNetworkMapper.map(try XCTUnwrap(inspected.first { $0.Name == name }))
            XCTAssertNil(entry.ipv4Subnet, name)
            XCTAssertTrue(entry.attached.isEmpty, name)
            XCTAssertTrue(entry.isBuiltIn, name)
        }
    }

    func testNullIPAMContainersAndLabelsDecode() throws {
        // Docker emits null for an empty IPAM.Config / Containers / Labels.
        let json = """
        [{"Name":"x","Id":"1","Scope":"local","Driver":"macvlan","Internal":true,
          "IPAM":{"Driver":"default","Config":null},"Containers":null,"Labels":null}]
        """
        let entry = DockerNetworkMapper.map(try XCTUnwrap(DockerNetworkInspect.decodeArray(json).first))
        XCTAssertEqual(entry.driver, "macvlan")
        XCTAssertNil(entry.ipv4Subnet)
        XCTAssertTrue(entry.isInternal)
        XCTAssertTrue(entry.attached.isEmpty)
    }

    func testIPv4AndIPv6SubnetsAreSeparated() throws {
        let json = """
        [{"Name":"dual","Id":"2","Driver":"bridge","EnableIPv6":true,
          "IPAM":{"Config":[{"Subnet":"fd00:1::/64","Gateway":"fd00:1::1"},{"Subnet":"172.20.0.0/16","Gateway":"172.20.0.1"}]}}]
        """
        let entry = DockerNetworkMapper.map(try XCTUnwrap(DockerNetworkInspect.decodeArray(json).first))
        XCTAssertEqual(entry.ipv4Subnet, "172.20.0.0/16")
        XCTAssertEqual(entry.ipv4Gateway, "172.20.0.1")
        XCTAssertEqual(entry.ipv6Subnet, "fd00:1::/64")
    }

    func testMalformedInspectThrowsDecodingError() {
        XCTAssertThrowsError(try DockerNetworkInspect.decodeArray("{not json"))
    }

    // MARK: - Apple

    func testAppleNetworkNormalisation() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let bundle = Bundle(for: type(of: self))
        let url = try XCTUnwrap(bundle.url(forResource: "networks-list", withExtension: "json", subdirectory: "Fixtures")
                                ?? bundle.url(forResource: "networks-list", withExtension: "json"))
        let infos = try decoder.decode([NetworkInfo].self, from: Data(contentsOf: url))
        let entry = NetworkEntry(apple: try XCTUnwrap(infos.first))

        XCTAssertEqual(entry.kind, .apple)
        XCTAssertEqual(entry.name, "default")
        XCTAssertEqual(entry.driver, "nat")
        XCTAssertEqual(entry.ipv4Subnet, "192.168.64.0/24")
        XCTAssertEqual(entry.ipv4Gateway, "192.168.64.1")
        XCTAssertNotNil(entry.ipv6Subnet)
        XCTAssertTrue(entry.isBuiltIn)
        XCTAssertNotNil(entry.createdAt)
    }

    // MARK: - Tags

    private func docker(_ name: String = "bridge") -> NetworkEntry {
        NetworkEntry(id: name, reference: name, name: name, kind: .docker)
    }

    func testLocalAppleTags() {
        let entry = NetworkEntry(id: "default", reference: "default", name: "default", kind: .apple)
        XCTAssertEqual(texts(entry), [local, "Apple"])
        XCTAssertEqual(entry.sourceTags.map(\.kind), [.location, .runtime])
    }

    func testLocalDockerTags() {
        XCTAssertEqual(texts(docker()), [local, "Docker"])
    }

    func testExternalColimaTagsShowAllThree() {
        let entry = docker().with(runtimeID: "machine:1", machineLabel: "Mac Studio", engine: .colima)
        XCTAssertEqual(texts(entry), [external, "Mac Studio", "Colima"])
        XCTAssertEqual(entry.sourceTags.map(\.kind), [.location, .machine, .runtime])
        XCTAssertEqual(entry.location, .external)
    }

    func testExternalAppleTags() {
        let entry = NetworkEntry(id: "default", reference: "default", name: "default", kind: .apple)
            .with(runtimeID: "machine:1", machineLabel: "Mac Studio", engine: .apple)
        XCTAssertEqual(texts(entry), [external, "Mac Studio", "Apple"])
    }

    func testWireGuardTagsReplaceTheRuntimeChip() {
        let interface = WireGuardInterface(
            name: "wg0", listenPort: nil, publicKey: nil, addresses: ["10.10.0.3/32"], subnets: ["10.10.0.3/32"],
            peers: [], source: .addressOnly, peerDetailsNeedRoot: true
        )
        let mine = NetworkEntry(wireGuard: interface)
        XCTAssertEqual(texts(mine), [local, "WireGuard"])
        XCTAssertEqual(mine.kind, .wireguard)

        let hub = mine.with(runtimeID: "machine:2", machineLabel: "Cloudlab  Two")
        XCTAssertEqual(texts(hub), [external, "Cloudlab  Two", "WireGuard"])
        XCTAssertEqual(hub.sourceTags.map(\.kind), [.location, .machine, .runtime])
        XCTAssertEqual(hub.runtimeFilterValue, .wireGuard)
    }

    // MARK: - Actions (Apple-only actions stay gated)

    func testActionGating() {
        let apple = NetworkEntry(id: "n", reference: "n", name: "n", kind: .apple)
        XCTAssertEqual(apple.actions, .apple)
        XCTAssertTrue(apple.actions.contains(.prune))

        let localDocker = docker("backend")
        XCTAssertTrue(localDocker.actions.contains(.create))
        XCTAssertTrue(localDocker.canRemove)
        XCTAssertFalse(localDocker.actions.contains(.prune))

        XCTAssertFalse(DockerNetworkMapper.map(DockerNetworkRow.stub(name: "bridge")).canRemove)

        let remote = docker("backend").with(runtimeID: "machine:1", machineLabel: "studio")
        XCTAssertEqual(remote.actions, .none)
        XCTAssertFalse(remote.canRemove)

        let wg = NetworkEntry(wireGuard: WireGuardInterface(
            name: "wg0", listenPort: nil, publicKey: nil, addresses: [], subnets: [], peers: [],
            source: .addressOnly, peerDetailsNeedRoot: false
        ))
        XCTAssertEqual(wg.actions, .none)
    }

    // MARK: - Filters and identity

    func testMachineAndRuntimeFilters() {
        let a = NetworkEntry(id: "a", reference: "default", name: "default", kind: .apple)
        let d = docker()
        let c = docker().with(runtimeID: "machine:1", machineLabel: "studio", engine: .colima)
        let w = NetworkEntry(wireGuard: WireGuardInterface(
            name: "wg0", listenPort: nil, publicKey: nil, addresses: [], subnets: [], peers: [],
            source: .addressOnly, peerDetailsNeedRoot: false
        )).with(runtimeID: "machine:1", machineLabel: "studio")
        let all = [a, d, c, w]

        XCTAssertEqual(NetworkSourceFilter.apply(machine: nil, runtime: nil, to: all).count, 4)
        XCTAssertEqual(NetworkSourceFilter.apply(machine: .local, runtime: nil, to: all), [a, d])
        XCTAssertEqual(NetworkSourceFilter.apply(machine: .machine("studio"), runtime: nil, to: all), [c, w])
        XCTAssertEqual(NetworkSourceFilter.apply(machine: nil, runtime: .engine(.colima), to: all), [c])
        XCTAssertEqual(NetworkSourceFilter.apply(machine: nil, runtime: .wireGuard, to: all), [w])
        XCTAssertEqual(NetworkSourceFilter.apply(machine: .machine("studio"), runtime: .engine(.docker), to: all), [])
    }

    func testSearchMatchesTagsNamesAndSubnets() {
        var d = docker("backend").with(runtimeID: "machine:1", machineLabel: "Studio", engine: .colima)
        d.ipv4Subnet = "172.20.0.0/16"
        XCTAssertTrue(d.matchesSearch("studio"))
        XCTAssertTrue(d.matchesSearch("colima"))
        XCTAssertTrue(d.matchesSearch("172.20"))
        XCTAssertTrue(d.matchesSearch("back"))
        XCTAssertFalse(d.matchesSearch("wireguard"))
        XCTAssertTrue(d.matchesSearch(""))
    }

    func testSameNameOnTwoEnginesGetsDistinctIdentities() {
        let one = docker()
        let two = docker().with(runtimeID: "machine:1", machineLabel: "studio", engine: .colima)
        let unique = NetworkSourceFilter.makeIdentitiesUnique([one, two])
        XCTAssertEqual(Set(unique.map(\.id)).count, 2)
        XCTAssertEqual(unique[0].id, "bridge")
        XCTAssertTrue(unique[1].id.contains("studio"))
        XCTAssertEqual(unique[1].reference, "bridge", "commands still address the engine-local name")
    }

    func testSortPutsThisMacFirstThenEngineThenWireGuard() {
        let w = NetworkEntry(wireGuard: WireGuardInterface(
            name: "wg0", listenPort: nil, publicKey: nil, addresses: [], subnets: [], peers: [],
            source: .addressOnly, peerDetailsNeedRoot: false
        ))
        let remote = docker("alpha").with(runtimeID: "machine:1", machineLabel: "studio")
        let sorted = NetworkStore.sorted([remote, w, docker("zeta"), NetworkEntry(id: "d", reference: "default", name: "default", kind: .apple), docker("beta")])
        XCTAssertEqual(sorted.map(\.name), ["default", "beta", "zeta", "wg0", "alpha"])
    }
}

private extension DockerNetworkRow {
    static func stub(name: String) -> DockerNetworkRow {
        let json = #"{"ID":"x","Name":"\#(name)","Driver":"bridge","Scope":"local","Internal":"false"}"#
        return (try? DockerNetworkRow.decodeLines(json).first) ?? { fatalError("stub") }()
    }
}
