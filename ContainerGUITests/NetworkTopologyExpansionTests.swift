import XCTest

/// The drill-down of the topology: what expanding a machine adds, the "+K more"
/// limit, volumes on request, collapsing, the layout of an expanded cluster and
/// the in-between frames of the animation. Synthetic data only.
final class NetworkTopologyExpansionTests: XCTestCase {
    // MARK: Builders

    private func container(
        _ name: String, running: Bool = true, engine: ContainerEngine = .docker, machine: String? = nil,
        ip: String? = nil, networks: [String] = [], ports: [(Int, Int)] = [], mounts: [(String, String, String?)] = []
    ) -> ContainerInfo {
        let configuration = ContainerInfo.Configuration(
            id: name, image: .init(reference: "img/\(name):1", descriptor: nil),
            creationDate: nil, labels: nil, resources: nil, platform: nil, initProcess: nil,
            publishedPorts: ports.map { .init(hostAddress: nil, hostPort: $0.0, containerPort: $0.1, proto: "tcp") },
            mounts: mounts.map { .init(source: $0.0, destination: $0.1, type: $0.2.map { .init(volume: .init(name: $0)) }) },
            rosetta: nil, runtimeHandler: nil, readOnly: nil, ssh: nil, virtualization: nil,
            networks: networks.map { .init(network: $0) }, readonlyPaths: nil, maskedPaths: nil
        )
        let status = ContainerInfo.Status(
            state: running ? "running" : "exited", startedDate: nil,
            networks: networks.enumerated().map { index, name in
                .init(hostname: name, ipv4Address: index == 0 ? ip.map { "\($0)/24" } : nil, network: name)
            }
        )
        let base = ContainerInfo(id: name, configuration: configuration, status: status, runtime: engine == .apple ? .apple : .docker)
        if let machine { return base.with(runtimeID: "machine:\(machine)", machineLabel: machine, engine: engine) }
        return engine == .colima ? base.with(engine: .colima) : base
    }

    private func network(_ name: String, engine: ContainerEngine = .docker, subnet: String? = nil, builtIn: Bool = false,
                         machine: String? = nil, attached: [String] = []) -> NetworkEntry {
        let kind: NetworkEntry.Kind = engine == .apple ? .apple : .docker
        var entry = NetworkEntry(
            id: name, reference: name, name: name, kind: kind, ipv4Subnet: subnet, isBuiltIn: builtIn,
            attached: attached.map { .init(name: $0, ipv4Address: nil) }
        )
        if let machine { entry = entry.with(runtimeID: "machine:\(machine)", machineLabel: machine, engine: engine) }
        else if engine == .colima { entry = entry.with(engine: .colima) }
        return entry
    }

    private func volume(_ name: String, engine: ContainerEngine = .docker, bind: Bool = false, path: String? = nil,
                        machine: String? = nil, usedBy: [String] = []) -> VolumeEntry {
        var entry = VolumeEntry(id: name, reference: name, name: name, kind: engine == .apple ? .apple : .docker,
                                storage: bind ? .bind : .volume, path: path, usedBy: usedBy)
        if let machine { entry = entry.with(runtimeID: "machine:\(machine)", machineLabel: machine, engine: engine) }
        return entry
    }

    private let studioID = "machine:Mac Studio"

    /// This Mac with Apple and Docker; "Mac Studio" with Colima, a web stack and a database.
    private func scenario(extraContainers: [ContainerInfo] = []) -> [TopologyMachine] {
        let containers = [
            container("web", engine: .colima, machine: "Mac Studio", ip: "172.18.0.2", networks: ["appnet", "bridge"], ports: [(8080, 80), (8443, 443)],
                      mounts: [("/srv/site", "/usr/share/nginx", nil)]),
            container("db", engine: .colima, machine: "Mac Studio", ip: "172.18.0.3", networks: ["appnet"],
                      mounts: [("/var/lib/docker/volumes/pgdata/_data", "/var/lib/postgresql", "pgdata")]),
            container("old", running: false, engine: .colima, machine: "Mac Studio", ip: nil, networks: ["bridge"]),
            container("buildkit", engine: .apple, ip: "192.168.64.5", networks: ["default"]),
            container("redis", engine: .docker, ip: "172.17.0.2", networks: ["bridge"]),
        ] + extraContainers
        let networks = [
            network("appnet", engine: .colima, subnet: "172.18.0.0/16", machine: "Mac Studio"),
            network("bridge", engine: .colima, subnet: "172.17.0.0/16", builtIn: true, machine: "Mac Studio"),
            network("unused", engine: .colima, subnet: "172.30.0.0/16", machine: "Mac Studio"),
            network("default", engine: .apple, subnet: "192.168.64.0/24", builtIn: true),
            network("bridge", engine: .docker, subnet: "172.17.0.0/16", builtIn: true),
        ]
        let volumes = [
            volume("pgdata", engine: .colima, path: "/var/lib/docker/volumes/pgdata/_data", machine: "Mac Studio", usedBy: ["db"]),
            volume("/srv/site", engine: .colima, bind: true, path: "/srv/site", machine: "Mac Studio", usedBy: ["web"]),
            volume("cache", engine: .colima, machine: "Mac Studio"),
        ]
        let studio = MachineFilter.machine("Mac Studio")
        return TopologyBuilder.machines(
            from: networks, knownMachines: [(label: "Mac Studio", host: "192.168.68.65")],
            containers: containers, volumes: volumes,
            lanAddresses: [.local: ["192.168.68.20"], studio: ["192.168.68.65"]]
        )
    }

    private func ids(_ topology: NetworkTopology, _ kind: TopologyNode.Kind) -> Set<String> {
        Set(topology.nodes.filter { $0.kind == kind }.map(\.id))
    }

    private func edges(_ topology: NetworkTopology, _ kind: TopologyEdge.Kind) -> [TopologyEdge] { topology.edges.filter { $0.kind == kind } }

    // MARK: Machines from the stores' data

    func testMachinesCarryContainersNetworksVolumesAndAddresses() {
        let machines = scenario()
        let studio = try! XCTUnwrap(machines.first { $0.id == studioID })
        XCTAssertEqual(studio.containers.map(\.id).sorted(), ["db", "old", "web"])
        XCTAssertEqual(studio.networks.map(\.name).sorted(), ["appnet", "bridge", "unused"])
        XCTAssertEqual(studio.volumes.count, 3)
        XCTAssertEqual(studio.engines, [.colima])
        XCTAssertEqual(studio.networkAddresses, ["192.168.68.65"], "LAN address and the reach address are one")
        let local = try! XCTUnwrap(machines.first { $0.key == .local })
        XCTAssertEqual(local.containers.map(\.id).sorted(), ["buildkit", "redis"])
        XCTAssertEqual(local.lanAddresses, ["192.168.68.20"])
        XCTAssertEqual(local.engines, [.apple, .docker])
    }

    func testAMachineKnownOnlyFromItsContainersStillGetsANode() {
        let machines = TopologyBuilder.machines(from: [], containers: [container("x", machine: "ghost")])
        XCTAssertEqual(machines.map(\.id), ["machine:local", "machine:ghost"])
        XCTAssertEqual(machines[1].engines, [.docker])
    }

    // MARK: Default view unchanged

    func testNothingExpandedIsThePlainDiagram() {
        let plain = TopologyBuilder.build(machines: scenario())
        XCTAssertEqual(Set(plain.nodes.map(\.kind)), [.machine, .runtime])
        XCTAssertTrue(edges(plain, .contains).isEmpty && edges(plain, .attached).isEmpty && edges(plain, .mount).isEmpty)
        XCTAssertEqual(plain.nodes.count, 3 + 2, "this Mac and its two engines; the studio and its engine")
    }

    // MARK: Expansion

    func testExpandingAMachineAddsItsContainersNetworksAndTheirEdges() {
        let t = TopologyBuilder.build(machines: scenario(), expanded: [studioID])
        XCTAssertEqual(ids(t, .container), ["ctr:\(studioID):web", "ctr:\(studioID):db", "ctr:\(studioID):old"])
        XCTAssertEqual(ids(t, .network), ["net:\(studioID):colima:appnet", "net:\(studioID):colima:bridge", "net:\(studioID):colima:unused"],
                       "the idle non-built-in network is shown too")
        // This Mac stays as it was.
        XCTAssertFalse(t.nodes.contains { $0.id.contains("buildkit") })

        let engine = "runtime:\(studioID):colima"
        XCTAssertEqual(Set(edges(t, .contains).map { Set([$0.a, $0.b]) }), [
            [engine, "ctr:\(studioID):web"], [engine, "ctr:\(studioID):db"], [engine, "ctr:\(studioID):old"],
            [engine, "net:\(studioID):colima:unused"],
        ], "containers hang off the engine; an idle network off the engine too")
        let attached = Set(edges(t, .attached).map { Set([$0.a, $0.b]) })
        XCTAssertEqual(attached, [
            ["ctr:\(studioID):web", "net:\(studioID):colima:appnet"], ["ctr:\(studioID):web", "net:\(studioID):colima:bridge"],
            ["ctr:\(studioID):db", "net:\(studioID):colima:appnet"], ["ctr:\(studioID):old", "net:\(studioID):colima:bridge"],
        ])
        let ip = edges(t, .attached).first { $0.a.hasSuffix(":web") || $0.b.hasSuffix(":web") }
        XCTAssertNotNil(ip)
    }

    func testContainerNodeCarriesAddressPortsAndStatus() {
        let t = TopologyBuilder.build(machines: scenario(), expanded: [studioID])
        let web = try! XCTUnwrap(t.node("ctr:\(studioID):web"))
        XCTAssertEqual(web.subtitle, "172.18.0.2 · 8080→80, 8443→443")
        XCTAssertEqual(web.container?.topologyState, .running)
        XCTAssertEqual(t.node("ctr:\(studioID):old")?.container?.topologyState, .stopped)
        XCTAssertEqual(TopologyContainerState(state: "paused"), .other)
        XCTAssertEqual(web.parentID, "runtime:\(studioID):colima")
        XCTAssertEqual(web.machineID, studioID)
        let appnet = try! XCTUnwrap(t.node("net:\(studioID):colima:appnet"))
        XCTAssertEqual(appnet.subtitle, "172.18.0.0/16")
        // The edge knows the address on that network.
        let edge = try! XCTUnwrap(edges(t, .attached).first { Set([$0.a, $0.b]) == ["ctr:\(studioID):web", appnet.id] })
        XCTAssertEqual(edge.detail, "172.18.0.2")
    }

    func testEngineSubtitleCountsRunningContainersOnlyWhenExpanded() {
        let plain = TopologyBuilder.build(machines: scenario())
        XCTAssertNil(plain.node("runtime:\(studioID):colima")?.subtitle)
        let open = TopologyBuilder.build(machines: scenario(), expanded: [studioID])
        XCTAssertEqual(open.node("runtime:\(studioID):colima")?.subtitle, String(format: String(localized: "%lld/%lld działa"), 2, 3))
    }

    func testRunningBeforeStoppedThenByName() {
        let sorted = TopologyBuilder.sortedForTopology([
            container("b", running: false), container("z"), container("a", running: false), container("m"),
        ])
        XCTAssertEqual(sorted.map(\.id), ["m", "z", "a", "b"])
    }

    func testCollapsingRemovesEverythingTheExpansionAdded() {
        let machines = scenario()
        let open = TopologyBuilder.build(machines: machines, expanded: [studioID, "machine:local"], showVolumes: true)
        let closed = TopologyBuilder.build(machines: machines, expanded: [])
        XCTAssertGreaterThan(open.nodes.count, closed.nodes.count)
        XCTAssertEqual(closed, TopologyBuilder.build(machines: machines))
        let half = TopologyBuilder.build(machines: machines, expanded: ["machine:local"])
        XCTAssertTrue(half.nodes.contains { $0.id.hasPrefix("ctr:machine:local:") })
        XCTAssertFalse(half.nodes.contains { $0.id.hasPrefix("ctr:\(studioID)") }, "other machines stay collapsed")
    }

    // MARK: +K more

    private func crowd(_ count: Int, stopped: Int = 0) -> [ContainerInfo] {
        (0..<count).map { container(String(format: "svc%02d", $0), running: $0 >= stopped, engine: .colima, machine: "Mac Studio", networks: ["appnet"]) }
    }

    func testAnEngineShowsAtMostEightContainersThenAMoreNode() {
        let t = TopologyBuilder.build(machines: scenario(extraContainers: crowd(14)), expanded: [studioID])
        // 14 extra + web, db, old = 17 on Colima.
        XCTAssertEqual(ids(t, .container).count, 8)
        let more = try! XCTUnwrap(t.nodes.first { $0.kind == .more && $0.moreCategory == .containers })
        XCTAssertEqual(more.hiddenCount, 9)
        XCTAssertEqual(more.parentID, "runtime:\(studioID):colima")
        XCTAssertFalse(more.isMoreExpanded)
        XCTAssertEqual(more.id, TopologyBuilder.moreNodeID("runtime:\(studioID):colima", .containers))
        XCTAssertTrue(edges(t, .contains).contains { Set([$0.a, $0.b]) == [more.parentID!, more.id] })
    }

    func testRunningContainersFillTheLimitBeforeStoppedOnes() {
        let t = TopologyBuilder.build(machines: scenario(extraContainers: crowd(14, stopped: 6)), expanded: [studioID])
        let shown = t.nodes.filter { $0.kind == .container }.compactMap(\.container)
        XCTAssertEqual(shown.count, 8)
        XCTAssertTrue(shown.allSatisfy(\.isRunning), "17 containers, 7 stopped (10 running): all 8 shown are running")
    }

    func testOpeningTheMoreNodeShowsEverythingAndKeepsAWayBack() {
        let machines = scenario(extraContainers: crowd(14))
        let moreID = TopologyBuilder.moreNodeID("runtime:\(studioID):colima", .containers)
        let t = TopologyBuilder.build(machines: machines, expanded: [studioID], expandedMore: [moreID])
        XCTAssertEqual(ids(t, .container).count, 17)
        let more = try! XCTUnwrap(t.node(moreID))
        XCTAssertTrue(more.isMoreExpanded)
        XCTAssertEqual(more.title, String(localized: "Pokaż mniej"))
        // The limit is a parameter.
        let two = TopologyBuilder.build(machines: machines, expanded: [studioID], containerLimit: 2)
        XCTAssertEqual(ids(two, .container).count, 2)
        XCTAssertEqual(two.node(moreID)?.hiddenCount, 15)
        // Exactly at the limit there is no more node.
        let exact = TopologyBuilder.build(machines: scenario(extraContainers: crowd(5)), expanded: [studioID])
        XCTAssertEqual(ids(exact, .container).count, 8)
        XCTAssertNil(exact.nodes.first { $0.kind == .more })
    }

    // MARK: Volumes

    func testVolumesOnlyAppearWhenAsked() {
        let off = TopologyBuilder.build(machines: scenario(), expanded: [studioID])
        XCTAssertTrue(ids(off, .volume).isEmpty)
        XCTAssertTrue(edges(off, .mount).isEmpty)

        let on = TopologyBuilder.build(machines: scenario(), expanded: [studioID], showVolumes: true)
        XCTAssertEqual(ids(on, .volume), ["vol:\(studioID):colima:pgdata", "vol:\(studioID):colima:/srv/site", "vol:\(studioID):colima:cache"])
        XCTAssertEqual(Set(edges(on, .mount).map { Set([$0.a, $0.b]) }), [
            ["ctr:\(studioID):db", "vol:\(studioID):colima:pgdata"],
            ["ctr:\(studioID):web", "vol:\(studioID):colima:/srv/site"],
        ], "named volume by name, bind mount by source; the unused one hangs off its engine")
        XCTAssertTrue(edges(on, .contains).contains { Set([$0.a, $0.b]) == ["runtime:\(studioID):colima", "vol:\(studioID):colima:cache"] })
        XCTAssertEqual(on.node("vol:\(studioID):colima:/srv/site")?.subtitle, String(localized: "bind"))
        // Turning it off again takes them away.
        XCTAssertEqual(ids(TopologyBuilder.build(machines: scenario(), expanded: [studioID], showVolumes: false), .volume), [])
    }

    func testIdleNetworksAndVolumesAreLimitedWithTheirOwnMoreNode() {
        var machines = scenario()
        let index = machines.firstIndex { $0.id == studioID }!
        machines[index].networks += (0..<9).map { network("idle\($0)", engine: .colima, machine: "Mac Studio") }
        machines[index].volumes += (0..<9).map { volume("vol\($0)", engine: .colima, machine: "Mac Studio") }
        let t = TopologyBuilder.build(machines: machines, expanded: [studioID], showVolumes: true)
        let engine = "runtime:\(studioID):colima"
        XCTAssertEqual(t.node(TopologyBuilder.moreNodeID(engine, .networks))?.hiddenCount, 10 - TopologyBuilder.orphanLimit)
        XCTAssertEqual(t.node(TopologyBuilder.moreNodeID(engine, .volumes))?.hiddenCount, 10 - TopologyBuilder.orphanLimit)
        let opened = TopologyBuilder.build(
            machines: machines, expanded: [studioID], expandedMore: [TopologyBuilder.moreNodeID(engine, .networks)], showVolumes: true)
        XCTAssertEqual(ids(opened, .network).count, 2 + 10, "appnet, bridge connected; every idle network (unused + 9) now shown")
    }

    // MARK: Layout

    private func rect(_ node: TopologyNode, at point: CGPoint) -> CGRect {
        let size = TopologyLayout.nodeSize(node)
        return CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height)
    }

    private func overlaps(_ topology: NetworkTopology, _ positions: [String: CGPoint]) -> [String] {
        var found: [String] = []
        let nodes = topology.nodes
        for i in nodes.indices {
            for j in nodes.indices where j > i {
                guard let a = positions[nodes[i].id], let b = positions[nodes[j].id] else { continue }
                if rect(nodes[i], at: a).insetBy(dx: 2, dy: 2).intersects(rect(nodes[j], at: b).insetBy(dx: 2, dy: 2)) {
                    found.append("\(nodes[i].id) × \(nodes[j].id)")
                }
            }
        }
        return found
    }

    /// Three machines on a hub-and-spoke layout, each with plenty to show.
    private func busy() -> [TopologyMachine] {
        var machines: [TopologyMachine] = []
        for name in ["hub", "alpha", "beta"] {
            var machine = TopologyMachine(key: .machine(name), name: name, engines: [.docker, .colima, .apple])
            for engine in machine.engines {
                for n in 0..<12 {
                    machine.containers.append(container("\(name)-\(engine.rawValue)-\(n)", running: n % 3 != 0, engine: engine, machine: name,
                                                         networks: ["net\(n % 4)"]))
                }
                for n in 0..<4 {
                    machine.networks.append(network("net\(n)", engine: engine, subnet: "10.\(n).0.0/24", machine: name))
                }
                machine.volumes += (0..<5).map { volume("v\(engine.rawValue)\($0)", engine: engine, machine: name) }
            }
            machines.append(machine)
        }
        // Make "hub" the hub: it lists both others.
        let peers = ["10.10.0.1", "10.10.0.2"].enumerated().map { index, ip in
            WireGuardPeer(publicKey: "K\(index)=", endpoint: nil, allowedIPs: ["\(ip)/32"], latestHandshake: nil, rxBytes: 0, txBytes: 0, keepalive: nil)
        }
        machines[0].interfaces = [WireGuardInterface(name: "wg0", listenPort: 1, publicKey: "H=", addresses: ["10.10.0.254/24"], subnets: ["10.10.0.0/24"],
                                                     peers: peers, source: .dump, peerDetailsNeedRoot: false)]
        machines[1].reachAddresses = ["10.10.0.1"]
        machines[2].reachAddresses = ["10.10.0.2"]
        return machines
    }

    func testAnExpandedClusterKeepsEveryNodeApart() {
        let all = Set(busy().map(\.id))
        for volumes in [false, true] {
            let t = TopologyBuilder.build(machines: busy(), expanded: all, showVolumes: volumes)
            XCTAssertEqual(t.hubID, "machine:hub")
            let positions = TopologyLayout.positions(for: t)
            XCTAssertEqual(Set(positions.keys), Set(t.nodes.map(\.id)), "every node, children included, gets a position")
            XCTAssertEqual(overlaps(t, positions), [], "no two nodes overlap (volumes: \(volumes))")
        }
    }

    func testExpandedMachinesDoNotCollideWithEachOther() {
        let t = TopologyBuilder.build(machines: busy(), expanded: Set(busy().map(\.id)), showVolumes: true)
        let positions = TopologyLayout.positions(for: t)
        // Every node of one machine's cluster is farther from any node of another machine's than the node sizes need.
        let byMachine = Dictionary(grouping: t.nodes) { $0.machineID ?? $0.id }
        let keys = byMachine.keys.sorted()
        for (i, a) in keys.enumerated() {
            for b in keys[(i + 1)...] {
                for x in byMachine[a]! { for y in byMachine[b]! {
                    guard let p = positions[x.id], let q = positions[y.id] else { continue }
                    XCTAssertFalse(rect(x, at: p).intersects(rect(y, at: q)), "\(x.id) × \(y.id)")
                } }
            }
        }
    }

    func testLayoutIsDeterministicAndGrowsOnlyWhenNeeded() {
        let machines = busy()
        let plain = TopologyBuilder.build(machines: machines)
        XCTAssertEqual(hypot(TopologyLayout.positions(for: plain)["machine:alpha"]!.x, TopologyLayout.positions(for: plain)["machine:alpha"]!.y), 300, accuracy: 0.001)
        let open = TopologyBuilder.build(machines: machines, expanded: ["machine:alpha"], showVolumes: true)
        let p1 = TopologyLayout.positions(for: open), p2 = TopologyLayout.positions(for: open)
        XCTAssertEqual(p1, p2)
        XCTAssertGreaterThan(hypot(p1["machine:alpha"]!.x, p1["machine:alpha"]!.y), 300, "room made for the cluster")
        XCTAssertEqual(p1["machine:hub"], .zero)
    }

    func testChildrenFanOutwardsFromASpokeAndNetworksSitBeyondTheirContainers() {
        let t = TopologyBuilder.build(machines: busy(), expanded: ["machine:alpha"])
        let p = TopologyLayout.positions(for: t)
        let centre = p["machine:alpha"]!
        let outward = atan2(centre.y, centre.x)
        for node in t.nodes where node.machineID == "machine:alpha" && [.container, .runtime].contains(node.kind) {
            let point = p[node.id]!
            var difference = atan2(point.y - centre.y, point.x - centre.x) - outward
            while difference > .pi { difference -= 2 * .pi }
            while difference < -.pi { difference += 2 * .pi }
            XCTAssertLessThanOrEqual(abs(difference), TopologyLayout.spokeSpan / 2 + 0.3, "\(node.id) fans out on the outer side of its machine")
        }
        let maxContainer = t.nodes.filter { $0.kind == .container }.map { hypot(p[$0.id]!.x - centre.x, p[$0.id]!.y - centre.y) }.max()!
        let minNetwork = t.nodes.filter { $0.kind == .network }.map { hypot(p[$0.id]!.x - centre.x, p[$0.id]!.y - centre.y) }.min()!
        XCTAssertGreaterThan(minNetwork, maxContainer)
    }

    func testADraggedMachineStaysPutAndItsClusterFollowsRigidly() {
        let t = TopologyBuilder.build(machines: busy(), expanded: ["machine:alpha"])
        let base = TopologyLayout.positions(for: t)
        let target = CGPoint(x: 1234, y: -321)
        let moved = TopologyLayout.positions(for: t, pinned: ["machine:alpha": target])
        XCTAssertEqual(moved["machine:alpha"], target)
        let dx = target.x - base["machine:alpha"]!.x, dy = target.y - base["machine:alpha"]!.y
        for node in t.nodes where node.machineID == "machine:alpha" && node.kind != .machine {
            XCTAssertEqual(moved[node.id]!.x, base[node.id]!.x + dx, accuracy: 0.001)
            XCTAssertEqual(moved[node.id]!.y, base[node.id]!.y + dy, accuracy: 0.001)
        }
        XCTAssertEqual(moved["machine:beta"], base["machine:beta"], "others do not move")
    }

    func testTierCountsAndSpread() {
        XCTAssertEqual(TopologyClusterLayout.tierCounts(for: 0, span: 3.7), [])
        for count in [1, 5, 9, 27, 40] {
            let tiers = TopologyClusterLayout.tierCounts(for: count, span: 3.7)
            XCTAssertEqual(tiers.reduce(0, +), count)
        }
        let spread = TopologyClusterLayout.spread([0, 0.01, 0.02, 2], minGap: 0.5)
        XCTAssertEqual(spread.count, 4)
        for (a, b) in zip(spread.sorted(), spread.sorted().dropFirst()) { XCTAssertGreaterThanOrEqual(b - a, 0.5 - 1e-6) }
    }

    // MARK: Animation

    func testTransitionGlidesNewNodesOutOfTheirParentAndBack() {
        let machines = scenario()
        let closed = TopologyBuilder.build(machines: machines)
        let open = TopologyBuilder.build(machines: machines, expanded: [studioID])
        let closedPositions = TopologyLayout.positions(for: closed), openPositions = TopologyLayout.positions(for: open)
        let transition = TopologyTransition(from: closed, fromPositions: closedPositions, to: open, toPositions: openPositions)

        let start = transition.frame(at: 0), end = transition.frame(at: 1)
        let web = "ctr:\(studioID):web"
        let engine = "runtime:\(studioID):colima"
        XCTAssertEqual(start.positions[web]!.x, start.positions[engine]!.x, accuracy: 0.001, "new nodes start on their parent")
        XCTAssertEqual(start.nodes.first { $0.node.id == web }?.opacity ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(end.positions[web]!.x, openPositions[web]!.x, accuracy: 0.001)
        XCTAssertEqual(end.nodes.first { $0.node.id == web }?.opacity ?? -1, 1, accuracy: 0.001)
        let middle = transition.frame(at: 0.5)
        XCTAssertEqual(middle.nodes.first { $0.node.id == web }?.opacity ?? -1, 0.5, accuracy: 0.001)
        XCTAssertEqual(end.nodes.count, open.nodes.count)
        XCTAssertEqual(end.edges.count, open.edges.count)
        XCTAssertEqual(start.nodes.count, open.nodes.count, "new nodes are drawn (invisibly) from the first frame")

        // Collapsing is the same film backwards: the leaving nodes shrink into the engine.
        let back = TopologyTransition(from: open, fromPositions: openPositions, to: closed, toPositions: closedPositions)
        XCTAssertEqual(back.frame(at: 0).nodes.first { $0.node.id == web }?.opacity ?? -1, 1, accuracy: 0.001)
        XCTAssertEqual(back.frame(at: 1).nodes.first { $0.node.id == web }?.opacity ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(back.frame(at: 1).positions[web]!.y, back.frame(at: 1).positions[engine]!.y, accuracy: 0.001)
        // Edges to vanishing nodes fade with them.
        let fading = back.frame(at: 0.5).edges.first { $0.edge.kind == .attached }
        XCTAssertEqual(fading?.opacity ?? -1, 0.5, accuracy: 0.001)
    }

    func testMachinesThatStayMoveSmoothly() {
        let machines = busy()
        let closed = TopologyBuilder.build(machines: machines)
        let open = TopologyBuilder.build(machines: machines, expanded: ["machine:alpha"])
        let a = TopologyLayout.positions(for: closed)["machine:alpha"]!, b = TopologyLayout.positions(for: open)["machine:alpha"]!
        let frame = TopologyTransition(from: closed, fromPositions: TopologyLayout.positions(for: closed),
                                       to: open, toPositions: TopologyLayout.positions(for: open)).frame(at: 0.5)
        XCTAssertEqual(frame.positions["machine:alpha"]!.x, (a.x + b.x) / 2, accuracy: 0.001)
    }

    // MARK: Helpers on containers, volumes and networks

    func testNetworkAttachmentFromTheNetworksOwnList() {
        let c = container("api", networks: [])
        XCTAssertTrue(network("n", attached: ["api"]).isAttached(c), "the network lists it")
        XCTAssertFalse(network("n", attached: ["other"]).isAttached(c))
        XCTAssertTrue(network("n").isAttached(container("api", networks: ["n"])), "the container says so")
    }

    func testVolumeUsageByNameByMountAndByBindSource() {
        let named = volume("pgdata", path: "/data/pg", usedBy: ["db"])
        XCTAssertTrue(named.isUsed(by: container("db")))
        XCTAssertTrue(named.isUsed(by: container("other", mounts: [("/data/pg", "/x", nil)])))
        XCTAssertTrue(named.isUsed(by: container("other", mounts: [("anything", "/x", "pgdata")])))
        XCTAssertFalse(named.isUsed(by: container("other")))
        let bind = volume("/srv/a", bind: true, path: "/srv/a")
        XCTAssertTrue(bind.isUsed(by: container("c", mounts: [("/srv/a", "/a", nil)])))
        XCTAssertFalse(bind.isUsed(by: container("c", mounts: [("/srv/b", "/a", nil)])))
    }

    func testContainerSubtitleAndAddresses() {
        let c = container("web", ip: "10.0.0.5", networks: ["a", "b"], ports: [(1, 2), (3, 4), (5, 6)])
        XCTAssertEqual(c.topologySubtitle, "10.0.0.5 · 1→2, 3→4 +1")
        XCTAssertEqual(c.networkAddresses.map(\.address), ["10.0.0.5"])
        XCTAssertEqual(c.attachedNetworkNames, ["a", "b"])
        XCTAssertNil(container("quiet").topologySubtitle)
    }

    func testLANAddressesAreEthernetAndWiFiOnly() {
        XCTAssertTrue(HostAddresses.isLAN(interface: "en0", address: "192.168.68.20"))
        XCTAssertFalse(HostAddresses.isLAN(interface: "utun3", address: "10.10.0.3"), "a tunnel is the WireGuard address")
        XCTAssertFalse(HostAddresses.isLAN(interface: "bridge100", address: "192.168.64.1"))
        XCTAssertFalse(HostAddresses.isLAN(interface: "en1", address: "169.254.3.4"))
        XCTAssertFalse(HostAddresses.isLAN(interface: "lo0", address: "127.0.0.1"))
        _ = HostAddresses.localIPv4() // must not crash
    }
}
