import Foundation
import CoreGraphics

// MARK: - Input

/// One machine as the topology sees it: this Mac or an external machine, the
/// engines running on it and the WireGuard interfaces found on it.
struct TopologyMachine: Sendable, Hashable {
    let key: MachineFilter
    let name: String
    var engines: [ContainerEngine] = []
    /// Container networks per engine (names only).
    var networkNames: [ContainerEngine: [String]] = [:]
    var interfaces: [WireGuardInterface] = []
    /// IP literals the machine is reached at (an external machine's host).
    var reachAddresses: [String] = []
    /// Everything the drill-down shows, from every engine on the machine
    /// (container networks only; WireGuard interfaces are in `interfaces`).
    var containers: [ContainerInfo] = []
    var networks: [NetworkEntry] = []
    var volumes: [VolumeEntry] = []
    /// The machine's own LAN addresses, when known (this Mac's `en*` interfaces).
    var lanAddresses: [String] = []

    var id: String { Self.nodeID(for: key) }

    static func nodeID(for key: MachineFilter) -> String {
        switch key {
        case .local: "machine:local"
        case .machine(let label): "machine:\(label)"
        }
    }

    /// Bare IPs of the WireGuard interfaces.
    var overlayAddresses: [String] {
        interfaces.flatMap { $0.addresses.compactMap { $0.split(separator: "/").first.map(String.init) } }
    }

    /// A dump answered, so the peer list is authoritative.
    var hasPeerData: Bool { interfaces.contains { $0.source == .dump } }

    var runningCount: Int { containers.filter(\.isRunning).count }

    /// Whether there is anything to drill into.
    var hasDetail: Bool { !containers.isEmpty || !networks.isEmpty || !volumes.isEmpty }

    /// Where the machine can be reached on a plain network: its LAN addresses
    /// and the host an external machine is reached at, without duplicates.
    var networkAddresses: [String] {
        var seen = Set<String>()
        return (lanAddresses + reachAddresses).filter { seen.insert($0).inserted }
    }
}

// MARK: - Output

struct TopologyNode: Identifiable, Sendable, Hashable {
    enum Kind: Sendable, Hashable {
        case machine
        /// An engine (Apple, Docker, Colima) attached to its machine.
        case runtime
        /// A WireGuard peer that matches no known machine.
        case unknownPeer
        /// Drill-down: a container of an expanded machine.
        case container
        /// Drill-down: a Docker/Apple network of an expanded machine.
        case network
        /// Drill-down: a volume or bind mount (only with "Show volumes").
        case volume
        /// Drill-down: the "+K more" / "show fewer" node of an engine.
        case more
    }

    enum MoreCategory: String, Sendable, Hashable {
        case containers, networks, volumes
    }

    let id: String
    let kind: Kind
    var title: String
    var subtitle: String?
    /// The machine a `.runtime` node belongs to; the machine itself for `.machine`.
    var machineID: String?
    var engine: ContainerEngine?
    var machine: TopologyMachine?
    /// For `.unknownPeer`.
    var peer: WireGuardPeer?
    /// What the node would be called without the user's label (the machine's own
    /// name, or "unknown peer"). `title` is the label when there is one.
    var autoTitle: String?
    /// The user's label for a machine or unknown peer; it is already in `title`.
    var label: String?
    var note: String?
    /// Public keys that identify this node: its own interfaces' keys and the keys
    /// other machines list for it. Each can be labelled.
    var peerKeys: [String] = []
    /// The icon's device type: the user's choice, else (machines only) one read
    /// off the machine's name, else this Mac a laptop and an external machine a
    /// server. `nil` for an unknown peer on Auto, which is drawn as "?".
    var deviceType: PeerDeviceType?
    /// The type the user chose (`nil` is "Auto").
    var userDeviceType: PeerDeviceType?
    /// The keys a type chosen for this node is stored under: its public keys, or
    /// (a machine with none) the node id.
    var deviceTypeKeys: [String] = []
    /// What the node hangs off (engine → machine, container/network/volume/more
    /// → engine). Layout and the expand/collapse animation follow it.
    var parentID: String?
    var container: ContainerInfo?
    var network: NetworkEntry?
    var volume: VolumeEntry?
    /// For `.more`: what it stands for, how many are hidden (or, when expanded,
    /// how many sit beyond the limit) and whether it is currently open.
    var moreCategory: MoreCategory?
    var hiddenCount: Int = 0
    var isMoreExpanded: Bool = false
}

/// One side's view of a WireGuard link: the interface and the peer it lists.
struct TopologyLink: Sendable, Hashable {
    let reporterID: String
    let interfaceName: String
    let peer: WireGuardPeer
    /// The user's label and note for `peer`'s public key.
    var label: String?
    var note: String?
}

struct TopologyEdge: Identifiable, Sendable, Hashable {
    enum Kind: Sendable, Hashable {
        case wireGuard
        /// A machine and an engine on it.
        case hosts
        /// Drill-down: an engine and a container/network/volume of it.
        case contains
        /// Drill-down: a container and a network it is attached to.
        case attached
        /// Drill-down: a container and a volume or bind mount it uses.
        case mount
    }

    enum Verification: Sendable, Hashable {
        /// A `wg` dump on at least one end lists the peer.
        case verified
        /// Both ends sit in the same overlay network but no dump could confirm it.
        case unverified
    }

    let id: String
    /// Sorted pair of node ids.
    let a: String
    let b: String
    let kind: Kind
    var verification: Verification = .verified
    var links: [TopologyLink] = []
    /// Overlay network both ends belong to (unverified edges).
    var overlay: String?
    /// For `.attached`: the container's address on that network.
    var detail: String?

    var latestHandshake: Date? { links.compactMap(\.peer.latestHandshake).max() }
    var rxBytes: Int64 { links.map(\.peer.rxBytes).max() ?? 0 }
    var txBytes: Int64 { links.map(\.peer.txBytes).max() ?? 0 }
    var endpoints: [String] { links.compactMap(\.peer.endpoint) }
    var keepalive: Int? { links.compactMap(\.peer.keepalive).first }
    /// The distinct labels the user gave the peers on this edge.
    var labels: [String] {
        var seen = Set<String>()
        return links.compactMap(\.label).filter { seen.insert($0).inserted }
    }

    func isStale(now: Date = Date()) -> Bool {
        guard kind == .wireGuard, verification == .verified else { return false }
        guard let handshake = latestHandshake else { return true }
        return now.timeIntervalSince(handshake) > WireGuardPeerPresenter.staleAfter
    }
}

struct NetworkTopology: Sendable, Equatable {
    var nodes: [TopologyNode] = []
    var edges: [TopologyEdge] = []
    /// The machine most WireGuard links meet at, when there is one.
    var hubID: String?

    static func == (lhs: NetworkTopology, rhs: NetworkTopology) -> Bool {
        lhs.nodes.map(\.id) == rhs.nodes.map(\.id) && lhs.edges == rhs.edges && lhs.hubID == rhs.hubID
    }

    func node(_ id: String) -> TopologyNode? { nodes.first { $0.id == id } }
    var machines: [TopologyNode] { nodes.filter { $0.kind == .machine } }
    func children(of id: String) -> [TopologyNode] { nodes.filter { $0.parentID == id } }
    /// Containers, networks, volumes and "more" nodes: what an expansion adds.
    func drillDownNodes(of machineID: String) -> [TopologyNode] {
        nodes.filter { $0.machineID == machineID && [.container, .network, .volume, .more].contains($0.kind) }
    }
}

// MARK: - Builder

enum TopologyBuilder {
    /// Machines from the Networks list: this Mac and every external machine that
    /// has an entry, plus `knownMachines` (external labels with no entry yet, so
    /// an unreachable machine still has a node).
    ///
    /// `containers` and `volumes` (from every runtime and machine) feed the
    /// drill-down; `lanAddresses` are the machines' own network addresses.
    static func machines(
        from entries: [NetworkEntry],
        knownMachines: [(label: String, host: String)] = [],
        containers: [ContainerInfo] = [],
        volumes: [VolumeEntry] = [],
        lanAddresses: [MachineFilter: [String]] = [:]
    ) -> [TopologyMachine] {
        var order: [MachineFilter] = [.local]
        var result: [MachineFilter: TopologyMachine] = [
            .local: TopologyMachine(key: .local, name: String(localized: "Ten Mac"))
        ]
        for known in knownMachines {
            let key = MachineFilter.machine(known.label)
            if result[key] == nil { order.append(key) }
            var machine = result[key] ?? TopologyMachine(key: key, name: known.label)
            if WireGuardPeerPresenter.isIPLiteral(known.host) { machine.reachAddresses.append(known.host) }
            result[key] = machine
        }
        for entry in entries {
            let key = entry.machineFilterValue
            if result[key] == nil {
                order.append(key)
                result[key] = TopologyMachine(key: key, name: entry.machineLabel ?? "")
            }
            if entry.kind == .wireguard {
                if let interface = entry.wireGuard { result[key]?.interfaces.append(interface) }
            } else {
                let engine = entry.engine
                if result[key]?.engines.contains(engine) == false { result[key]?.engines.append(engine) }
                result[key]?.networkNames[engine, default: []].append(entry.name)
                result[key]?.networks.append(entry)
            }
        }
        func ensure(_ key: MachineFilter, label: String?, engine: ContainerEngine) {
            if result[key] == nil {
                order.append(key)
                result[key] = TopologyMachine(key: key, name: label ?? "")
            }
            if result[key]?.engines.contains(engine) == false { result[key]?.engines.append(engine) }
        }
        for container in containers {
            ensure(container.machineFilterValue, label: container.machineLabel, engine: container.engine)
            result[container.machineFilterValue]?.containers.append(container)
        }
        for volume in volumes {
            ensure(volume.machineFilterValue, label: volume.machineLabel, engine: volume.engine)
            result[volume.machineFilterValue]?.volumes.append(volume)
        }
        for (key, addresses) in lanAddresses { result[key]?.lanAddresses = addresses }
        return order.compactMap { result[$0] }.map { machine in
            var machine = machine
            machine.engines.sort { (ContainerEngine.allCases.firstIndex(of: $0) ?? 0) < (ContainerEngine.allCases.firstIndex(of: $1) ?? 0) }
            return machine
        }
    }

    /// `aliases` are the user's peer labels (public key → label) and `notes` their
    /// notes. A label wins over the auto-matched machine name and over "unknown
    /// peer", on the node and in every tooltip and panel that uses its title.
    ///
    /// `expanded` holds the ids of the machines drilled into: those get their
    /// containers, networks and (with `showVolumes`) volumes as extra nodes.
    /// `expandedMore` holds the ids of the "+K more" nodes that are open. The
    /// defaults give the plain diagram.
    static func build(
        machines: [TopologyMachine], aliases: [String: String] = [:], notes: [String: String] = [:],
        deviceTypes: [String: PeerDeviceType] = [:], now: Date = Date(),
        expanded: Set<String> = [], expandedMore: Set<String> = [], showVolumes: Bool = false,
        containerLimit: Int = TopologyBuilder.containerLimit
    ) -> NetworkTopology {
        var nodes: [TopologyNode] = []
        var edges: [String: TopologyEdge] = [:]
        var edgeOrder: [String] = []

        func addEdge(_ a: String, _ b: String, kind: TopologyEdge.Kind, link: TopologyLink? = nil,
                     verification: TopologyEdge.Verification = .verified, overlay: String? = nil) {
            let (x, y) = a < b ? (a, b) : (b, a)
            let id = "\(kind == .wireGuard ? "wg" : "host"):\(x)|\(y)"
            if edges[id] == nil {
                edges[id] = TopologyEdge(id: id, a: x, b: y, kind: kind, verification: verification, overlay: overlay)
                edgeOrder.append(id)
            }
            if let link { edges[id]?.links.append(link) }
            if verification == .verified { edges[id]?.verification = .verified }
        }

        // Machine and engine nodes, then (when expanded) what runs on them.
        var drillDownEdges: [TopologyEdge] = []
        for machine in machines {
            nodes.append(TopologyNode(
                id: machine.id, kind: .machine, title: machine.name, subtitle: nil,
                machineID: machine.id, machine: machine
            ))
            for engine in machine.engines {
                let id = "runtime:\(machine.id):\(engine.rawValue)"
                nodes.append(TopologyNode(
                    id: id, kind: .runtime, title: engine.title,
                    subtitle: nil, machineID: machine.id, engine: engine, parentID: machine.id
                ))
                addEdge(machine.id, id, kind: .hosts)
            }
            if expanded.contains(machine.id) {
                let drill = expansion(of: machine, expandedMore: expandedMore, showVolumes: showVolumes, containerLimit: containerLimit)
                for (engine, subtitle) in drill.engineSubtitles {
                    if let index = nodes.firstIndex(where: { $0.id == "runtime:\(machine.id):\(engine.rawValue)" }) {
                        nodes[index].subtitle = subtitle
                    }
                }
                nodes.append(contentsOf: drill.nodes)
                drillDownEdges.append(contentsOf: drill.edges)
            }
        }

        // Which machine owns which overlay address.
        var owners: [String: String] = [:]
        for machine in machines {
            for ip in machine.overlayAddresses + machine.reachAddresses where owners[ip] == nil { owners[ip] = machine.id }
        }
        let hubCandidates = Set(machines.filter { machine in
            machine.interfaces.contains { $0.source == .dump && $0.peers.count >= 2 }
        }.map(\.id))

        // Verified links, from every dump.
        var unknownNodes: [String: TopologyNode] = [:]
        var keysByMachine: [String: [String]] = [:]
        for machine in machines {
            for interface in machine.interfaces where interface.source == .dump {
                for peer in interface.peers {
                    let link = TopologyLink(
                        reporterID: machine.id, interfaceName: interface.name, peer: peer,
                        label: aliases[peer.publicKey], note: notes[peer.publicKey].flatMap { $0.isEmpty ? nil : $0 }
                    )
                    if let target = owner(of: peer, observer: machine.id, owners: owners, hubCandidates: hubCandidates) {
                        addEdge(machine.id, target, kind: .wireGuard, link: link)
                        keysByMachine[target, default: []].append(peer.publicKey)
                    } else {
                        let id = "peer:\(peer.publicKey)"
                        if unknownNodes[id] == nil {
                            let alias = aliases[peer.publicKey]
                            unknownNodes[id] = TopologyNode(
                                id: id, kind: .unknownPeer,
                                title: alias ?? String(localized: "Nieznany peer"),
                                subtitle: WireGuardFormat.shortKey(peer.publicKey), peer: peer,
                                autoTitle: String(localized: "Nieznany peer"), label: alias,
                                note: notes[peer.publicKey].flatMap { $0.isEmpty ? nil : $0 },
                                peerKeys: [peer.publicKey],
                                deviceType: deviceTypes[peer.publicKey],
                                userDeviceType: deviceTypes[peer.publicKey],
                                deviceTypeKeys: [peer.publicKey]
                            )
                        }
                        addEdge(machine.id, id, kind: .wireGuard, link: link)
                    }
                }
            }
        }
        nodes.append(contentsOf: unknownNodes.values.sorted { $0.id < $1.id })

        // A label on a key that identifies a machine (its own interface key or
        // the key a peer list holds for it) renames the machine node.
        for index in nodes.indices where nodes[index].kind == .machine {
            guard let machine = nodes[index].machine else { continue }
            var seen = Set<String>()
            let keys = (machine.interfaces.compactMap(\.publicKey) + (keysByMachine[machine.id] ?? [])).filter { seen.insert($0).inserted }
            nodes[index].autoTitle = machine.name
            nodes[index].peerKeys = keys
            let typeKeys = keys.isEmpty ? [nodes[index].id] : keys
            let chosen = (keys + [nodes[index].id]).lazy.compactMap { deviceTypes[$0] }.first
            nodes[index].deviceTypeKeys = typeKeys
            nodes[index].userDeviceType = chosen
            nodes[index].deviceType = PeerDeviceType.resolved(
                user: chosen, inferred: PeerDeviceType.inferred(fromName: machine.name),
                builtIn: machine.key == .local ? .laptop : .server
            )
            if let key = keys.first(where: { aliases[$0] != nil }), let label = aliases[key] {
                nodes[index].label = label
                nodes[index].title = label
                nodes[index].note = notes[key].flatMap { $0.isEmpty ? nil : $0 }
            }
        }

        // Unverified overlay membership.
        let subnets = overlaySubnets(machines)
        for subnet in subnets {
            let members = machines.filter { machine in
                machine.overlayAddresses.contains { CIDR.contains(subnet, $0) }
            }
            guard members.count >= 2 else { continue }
            let withData = members.filter(\.hasPeerData)
            if withData.isEmpty {
                for i in 0..<members.count {
                    for j in (i + 1)..<members.count {
                        addEdge(members[i].id, members[j].id, kind: .wireGuard, verification: .unverified, overlay: subnet)
                    }
                }
            } else {
                // A dump is authoritative for its own peers; a member that no
                // dump lists and that cannot report itself hangs off the hub
                // (or off the dump holder) as unverified.
                let hub = withData.max { $0.interfaces.flatMap(\.peers).count < $1.interfaces.flatMap(\.peers).count } ?? withData[0]
                for member in members where !member.hasPeerData && member.id != hub.id {
                    let linked = edgeOrder.contains { id in
                        guard let edge = edges[id], edge.kind == .wireGuard else { return false }
                        return edge.a == member.id || edge.b == member.id
                    }
                    if !linked { addEdge(hub.id, member.id, kind: .wireGuard, verification: .unverified, overlay: subnet) }
                }
            }
        }

        let ordered = edgeOrder.compactMap { edges[$0] } + drillDownEdges
        return NetworkTopology(nodes: nodes, edges: ordered, hubID: hub(machines: machines, edges: ordered))
    }

    /// Most verified WireGuard links, at least two. Ties go to the machine whose dump
    /// lists more peers, then to the first.
    static func hub(machines: [TopologyMachine], edges: [TopologyEdge]) -> String? {
        var degree: [String: Int] = [:]
        for edge in edges where edge.kind == .wireGuard && edge.verification == .verified {
            degree[edge.a, default: 0] += 1
            degree[edge.b, default: 0] += 1
        }
        let candidates = machines.filter { (degree[$0.id] ?? 0) >= 2 }
        let best = candidates.max { lhs, rhs in
            let l = (degree[lhs.id] ?? 0, lhs.interfaces.flatMap(\.peers).count)
            let r = (degree[rhs.id] ?? 0, rhs.interfaces.flatMap(\.peers).count)
            return l < r
        }
        return best?.id
    }

    /// Whose address a peer is: an allowed `/32`, then the endpoint host, then —
    /// for a wider allowed range — the one machine inside it (or the one hub).
    static func owner(of peer: WireGuardPeer, observer: String, owners: [String: String], hubCandidates: Set<String>) -> String? {
        for allowed in peer.allowedIPs {
            if let ip = WireGuardPeerPresenter.hostAddress(of: allowed), let id = owners[ip], id != observer { return id }
        }
        if let host = WireGuardPeerPresenter.endpointHost(peer.endpoint), let id = owners[host], id != observer { return id }
        var inside = Set<String>()
        for allowed in peer.allowedIPs where WireGuardPeerPresenter.hostAddress(of: allowed) == nil {
            guard !allowed.hasSuffix("/0") else { continue }
            for (ip, id) in owners where id != observer && CIDR.contains(allowed, ip) { inside.insert(id) }
        }
        if inside.count == 1 { return inside.first }
        let hubs = inside.intersection(hubCandidates)
        return hubs.count == 1 ? hubs.first : nil
    }

    /// Networks wide enough to be an overlay (not a `/32` client address).
    static func overlaySubnets(_ machines: [TopologyMachine]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for machine in machines {
            for subnet in machine.interfaces.flatMap(\.subnets) {
                guard let prefix = subnet.split(separator: "/").last.flatMap({ Int($0) }), prefix <= 30 else { continue }
                if seen.insert(subnet).inserted { result.append(subnet) }
            }
        }
        return result
    }
}

/// IPv4 CIDR containment; IPv6 and malformed input only match exactly.
enum CIDR {
    static func contains(_ cidr: String, _ ip: String) -> Bool {
        let parts = cidr.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let prefix = Int(parts[1]), (0...32).contains(prefix),
              let network = value(String(parts[0])), let address = value(ip) else { return String(parts.first ?? "") == ip }
        let mask: UInt32 = prefix == 0 ? 0 : UInt32.max << UInt32(32 - prefix)
        return (network & mask) == (address & mask)
    }

    private static func value(_ ip: String) -> UInt32? {
        let parts = ip.split(separator: ".").compactMap { UInt32($0) }
        guard parts.count == 4, parts.allSatisfy({ $0 < 256 }) else { return nil }
        return parts.reduce(UInt32(0)) { ($0 << 8) | $1 }
    }
}

// MARK: - Layout and hit-testing

enum TopologyLayout {
    /// Sector an expanded machine on the circle fans out over: the outer side only,
    /// so the tunnels on the inner side stay readable.
    static let spokeSpan = 3.7

    /// Positions in a virtual plane centred on (0, 0). Hub-and-spoke when a hub
    /// exists, otherwise a circle; engines orbit their machine pointing away
    /// from the centre; unknown peers sit beyond whoever reports them.
    ///
    /// An expanded machine claims a footprint (its engines, containers, networks
    /// and volumes in concentric rings, see `TopologyClusterLayout`); the circle
    /// grows until neighbouring footprints do not touch. `pinned` holds machines
    /// the user dragged: they stay where they were put and their cluster follows
    /// rigidly. Nothing here depends on earlier positions, so the same topology
    /// always lands in the same place.
    static func positions(for topology: NetworkTopology, pinned: [String: CGPoint] = [:]) -> [String: CGPoint] {
        var result: [String: CGPoint] = [:]
        let machines = topology.machines
        let spokes = machines.filter { $0.id != topology.hubID }

        // How far each expanded machine reaches.
        func fullCircle(_ id: String) -> Bool { id == topology.hubID || machines.count == 1 }
        // Which way each machine faces: away from the middle of the circle.
        var facing: [String: Double] = [:]
        let onCircle = topology.hubID != nil ? spokes : machines
        for (index, machine) in onCircle.enumerated() where machines.count > 1 {
            facing[machine.id] = -Double.pi / 2 + 2 * .pi * Double(index) / Double(onCircle.count)
        }
        var clusters: [String: TopologyClusterLayout.Result] = [:]
        for machine in machines {
            let full = fullCircle(machine.id)
            if let cluster = TopologyClusterLayout.compute(
                machineID: machine.id, in: topology, span: full ? 2 * Double.pi : spokeSpan,
                orientation: full ? Double.pi / 2 : (facing[machine.id] ?? Double.pi / 2)
            ) { clusters[machine.id] = cluster }
        }
        func footprint(_ id: String) -> Double { clusters[id]?.radius ?? 0 }

        // Machines: on the circle, wide enough for the footprints.
        func ringRadius(base: Double, ids: [String], centre: String?) -> Double {
            var radius = base
            for id in ids {
                if let centre, footprint(centre) > 0 || footprint(id) > 0 { radius = max(radius, footprint(centre) + footprint(id) + 100) }
            }
            if ids.count >= 2 {
                for index in ids.indices {
                    let a = footprint(ids[index]), b = footprint(ids[(index + 1) % ids.count])
                    guard a > 0 || b > 0, ids.count > 2 || index == 0 else { continue }
                    radius = max(radius, (a + b + 100) / (2 * sin(Double.pi / Double(ids.count))))
                }
            }
            return radius
        }
        var slots: [String: CGPoint] = [:]
        var circleRadius = 0.0
        if let hub = topology.hubID {
            slots[hub] = .zero
            circleRadius = ringRadius(base: 300, ids: spokes.map(\.id), centre: hub)
            place(spokes.map(\.id), radius: circleRadius, into: &slots, startAngle: -Double.pi / 2)
        } else if machines.count == 1 {
            slots[machines[0].id] = .zero
        } else {
            circleRadius = ringRadius(base: 260, ids: machines.map(\.id), centre: nil)
            place(machines.map(\.id), radius: circleRadius, into: &slots, startAngle: -Double.pi / 2)
        }
        for (id, point) in slots { result[id] = pinned[id] ?? point }

        // Unknown peers: outwards of the observer (or on an outer ring around a hub).
        let unknown = topology.nodes.filter { $0.kind == .unknownPeer }
        let widest = spokes.map { footprint($0.id) }.max() ?? 0
        for (index, node) in unknown.enumerated() {
            let observerIDs = topology.edges.filter { $0.a == node.id || $0.b == node.id }
                .map { $0.a == node.id ? $0.b : $0.a }
            let observerID = observerIDs.first
            let observer = observerID.flatMap { result[$0] } ?? .zero
            let spread = Double(index) - Double(unknown.count - 1) / 2
            if observer == .zero {
                let outer = max(470, circleRadius + widest + 130, footprint(observerID ?? "") + 160)
                let angle = -Double.pi / 2 + 2 * Double.pi * (Double(index) + 0.5) / Double(max(unknown.count, 1))
                result[node.id] = CGPoint(x: cos(angle) * outer, y: sin(angle) * outer)
            } else {
                let length = hypot(observer.x, observer.y)
                let direction = CGPoint(x: observer.x / length, y: observer.y / length)
                let normal = CGPoint(x: -direction.y, y: direction.x)
                let distance = 200 + footprint(observerID ?? "")
                result[node.id] = CGPoint(
                    x: observer.x + direction.x * distance + normal.x * spread * 90,
                    y: observer.y + direction.y * distance + normal.y * spread * 90
                )
            }
        }

        // Engines around their machine; an expanded machine also carries its
        // containers, networks and volumes.
        for machine in machines {
            guard let centre = result[machine.id], let slot = slots[machine.id] else { continue }
            let outward = (slot == .zero) ? Double.pi / 2 : atan2(slot.y, slot.x)
            if let cluster = clusters[machine.id] {
                for (id, offset) in cluster.offsets {
                    result[id] = CGPoint(x: centre.x + offset.x, y: centre.y + offset.y)
                }
                continue
            }
            let runtimes = topology.nodes.filter { $0.kind == .runtime && $0.machineID == machine.id }
            guard !runtimes.isEmpty else { continue }
            for (index, runtime) in runtimes.enumerated() {
                let offset = (Double(index) - Double(runtimes.count - 1) / 2) * 0.62
                let angle = outward + offset
                result[runtime.id] = CGPoint(x: centre.x + cos(angle) * 95, y: centre.y + sin(angle) * 95)
            }
        }
        return result
    }

    /// Rough on-screen size of a node (points at zoom 1), for spacing and for
    /// checking that a layout does not overlap.
    static func nodeSize(_ node: TopologyNode) -> CGSize {
        switch node.kind {
        case .machine: CGSize(width: 190, height: 56)
        case .runtime: CGSize(width: 96, height: node.subtitle == nil ? 26 : 40)
        case .unknownPeer: CGSize(width: 90, height: 66)
        case .container: CGSize(width: 150, height: 44)
        case .network: CGSize(width: 140, height: 42)
        case .volume: CGSize(width: 130, height: 30)
        case .more: CGSize(width: 100, height: 30)
        }
    }

    private static func place(_ ids: [String], radius: Double, into result: inout [String: CGPoint], startAngle: Double) {
        guard !ids.isEmpty else { return }
        for (index, id) in ids.enumerated() {
            let angle = startAngle + 2 * .pi * Double(index) / Double(ids.count)
            result[id] = CGPoint(x: cos(angle) * radius, y: sin(angle) * radius)
        }
    }

    /// Distance from `point` to the segment `a`–`b`.
    static func distance(from point: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(point.x - a.x, point.y - a.y) }
        let t = max(0, min(1, ((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared))
        return hypot(point.x - (a.x + t * dx), point.y - (a.y + t * dy))
    }

    /// The WireGuard edge closest to `point` within `threshold`.
    static func nearestEdge(
        to point: CGPoint, in topology: NetworkTopology, positions: [String: CGPoint], threshold: Double
    ) -> TopologyEdge? {
        var best: (TopologyEdge, Double)?
        for edge in topology.edges where edge.kind == .wireGuard {
            guard let a = positions[edge.a], let b = positions[edge.b] else { continue }
            let d = distance(from: point, toSegment: a, b)
            if d <= threshold, d < (best?.1 ?? .infinity) { best = (edge, d) }
        }
        return best?.0
    }
}
