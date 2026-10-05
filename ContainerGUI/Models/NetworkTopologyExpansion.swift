import Foundation

// MARK: - What a container says about itself

/// How a container node is coloured.
enum TopologyContainerState: Sendable, Hashable {
    case running
    case stopped
    /// Paused, restarting, dead, … — anything that is neither up nor plainly down.
    case other

    init(state: String) {
        switch state.lowercased() {
        case "running": self = .running
        case "stopped", "exited", "created", "": self = .stopped
        default: self = .other
        }
    }
}

extension ContainerInfo {
    var topologyState: TopologyContainerState { TopologyContainerState(state: state) }

    /// Network name → the container's IPv4 on it (no CIDR suffix), in the CLI's order.
    var networkAddresses: [(network: String, address: String)] {
        (status?.networks ?? []).compactMap { entry in
            guard let address = entry.ipv4Address, !address.isEmpty else { return nil }
            let bare = String(address.split(separator: "/").first ?? "")
            return (entry.network ?? "", bare)
        }
    }

    /// Every network the container is attached to: the configured ones plus the
    /// ones it has an address on, without duplicates.
    var attachedNetworkNames: [String] {
        var seen = Set<String>()
        let configured = (configuration.networks ?? []).compactMap(\.network)
        let live = (status?.networks ?? []).compactMap(\.network)
        return (configured + live).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Names other records use for this container (a network lists its attached
    /// containers by name, a volume lists the containers that mount it).
    var topologyAliases: Set<String> {
        var names: Set<String> = [id, reference, configuration.id]
        for entry in status?.networks ?? [] {
            if let hostname = entry.hostname, !hostname.isEmpty { names.insert(hostname) }
        }
        return names
    }

    /// "8080→80, 8443→443 +1": what the container publishes, short.
    func publishedPortSummary(limit: Int = 2) -> String? {
        let ports = (configuration.publishedPorts ?? []).compactMap { port -> String? in
            guard let host = port.hostPort, let inner = port.containerPort else { return nil }
            return "\(host)→\(inner)"
        }
        guard !ports.isEmpty else { return nil }
        let shown = ports.prefix(limit).joined(separator: ", ")
        return ports.count > limit ? "\(shown) +\(ports.count - limit)" : shown
    }

    /// The second line of a container node: its address and published ports.
    var topologySubtitle: String? {
        let parts = [primaryIPv4Address, publishedPortSummary()].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

extension VolumeEntry {
    /// Whether `container` uses this volume or bind mount: the volume lists it,
    /// or one of the container's mounts points here.
    func isUsed(by container: ContainerInfo) -> Bool {
        if !usedBy.isEmpty, !container.topologyAliases.isDisjoint(with: usedBy) { return true }
        for mount in container.configuration.mounts ?? [] {
            if isBind {
                if let source = mount.source, source == path || source == name { return true }
            } else if mount.type?.volume?.name == name || (path != nil && mount.source == path) {
                return true
            }
        }
        return false
    }
}

extension NetworkEntry {
    /// Whether `container` is attached to this network: it says so, or the
    /// network lists it.
    func isAttached(_ container: ContainerInfo) -> Bool {
        if container.attachedNetworkNames.contains(name) { return true }
        let aliases = container.topologyAliases
        return attached.contains { aliases.contains($0.name) }
    }
}

// MARK: - Expansion of one machine

extension TopologyBuilder {
    /// Containers shown per engine before the rest hides behind "+K more".
    static let containerLimit = 8
    /// Networks and volumes no visible container uses, shown per engine.
    static let orphanLimit = 4

    static func containerNodeID(_ machineID: String, _ container: ContainerInfo) -> String { "ctr:\(machineID):\(container.id)" }
    static func networkNodeID(_ machineID: String, _ engine: ContainerEngine, _ network: NetworkEntry) -> String {
        "net:\(machineID):\(engine.rawValue):\(network.name)"
    }
    static func volumeNodeID(_ machineID: String, _ engine: ContainerEngine, _ volume: VolumeEntry) -> String {
        "vol:\(machineID):\(engine.rawValue):\(volume.id)"
    }
    static func engineNodeID(_ machineID: String, _ engine: ContainerEngine) -> String { "runtime:\(machineID):\(engine.rawValue)" }
    static func moreNodeID(_ engineNodeID: String, _ category: TopologyNode.MoreCategory) -> String {
        "more:\(engineNodeID):\(category.rawValue)"
    }

    /// Running before stopped, then by name.
    static func sortedForTopology(_ containers: [ContainerInfo]) -> [ContainerInfo] {
        containers.sorted { lhs, rhs in
            if lhs.isRunning != rhs.isRunning { return lhs.isRunning }
            let order = lhs.id.localizedStandardCompare(rhs.id)
            return order == .orderedSame ? lhs.reference < rhs.reference : order == .orderedAscending
        }
    }

    struct Expansion {
        var nodes: [TopologyNode] = []
        var edges: [TopologyEdge] = []
        /// "2/5 running" for the engine pills of an expanded machine.
        var engineSubtitles: [ContainerEngine: String] = [:]
    }

    /// The nodes and edges an expanded machine adds: per engine its containers
    /// (running first, at most `containerLimit`, then a "+K more" node), the
    /// networks they are attached to, and with `showVolumes` the volumes they
    /// mount. Networks and volumes no visible container uses are kept to
    /// `orphanLimit` with their own "+K more".
    static func expansion(
        of machine: TopologyMachine, expandedMore: Set<String>, showVolumes: Bool, containerLimit: Int
    ) -> Expansion {
        var result = Expansion()
        var edgeIDs = Set<String>()

        func addEdge(_ a: String, _ b: String, kind: TopologyEdge.Kind, detail: String? = nil) {
            let (x, y) = a < b ? (a, b) : (b, a)
            let prefix: String
            switch kind {
            case .contains: prefix = "contains"
            case .attached: prefix = "attach"
            case .mount: prefix = "mount"
            case .hosts: prefix = "host"
            case .wireGuard: prefix = "wg"
            }
            let id = "\(prefix):\(x)|\(y)"
            guard edgeIDs.insert(id).inserted else { return }
            result.edges.append(TopologyEdge(id: id, a: x, b: y, kind: kind, detail: detail))
        }

        func moreNode(
            engine: ContainerEngine, engineID: String, category: TopologyNode.MoreCategory, total: Int, limit: Int, title: (Int) -> String
        ) {
            guard total > limit else { return }
            let id = moreNodeID(engineID, category)
            let open = expandedMore.contains(id)
            result.nodes.append(TopologyNode(
                id: id, kind: .more, title: open ? String(localized: "Pokaż mniej") : title(total - limit),
                machineID: machine.id, engine: engine, parentID: engineID,
                moreCategory: category, hiddenCount: total - limit, isMoreExpanded: open
            ))
            addEdge(engineID, id, kind: .contains)
        }

        for engine in machine.engines {
            let engineID = engineNodeID(machine.id, engine)
            let engineContainers = sortedForTopology(machine.containers.filter { $0.engine == engine })
            let running = engineContainers.filter(\.isRunning).count
            if !engineContainers.isEmpty {
                result.engineSubtitles[engine] = String(format: String(localized: "%lld/%lld działa"), Int64(running), Int64(engineContainers.count))
            }

            // Containers.
            let containerMoreID = moreNodeID(engineID, .containers)
            let visible = expandedMore.contains(containerMoreID) ? engineContainers : Array(engineContainers.prefix(max(containerLimit, 0)))
            var visibleIDs: [String: ContainerInfo] = [:]
            for container in visible {
                let id = containerNodeID(machine.id, container)
                visibleIDs[id] = container
                result.nodes.append(TopologyNode(
                    id: id, kind: .container, title: container.id, subtitle: container.topologySubtitle,
                    machineID: machine.id, engine: engine, parentID: engineID, container: container
                ))
                addEdge(engineID, id, kind: .contains)
            }
            moreNode(engine: engine, engineID: engineID, category: .containers, total: engineContainers.count, limit: max(containerLimit, 0)) {
                String(format: String(localized: "+%lld więcej"), Int64($0))
            }

            // Networks: every one a visible container is on, plus a few idle ones.
            var connectedNetworks: [NetworkEntry] = []
            var idleNetworks: [NetworkEntry] = []
            for network in machine.networks.filter({ $0.engine == engine }) {
                let users = visible.filter { network.isAttached($0) }
                if users.isEmpty {
                    if !network.isBuiltIn { idleNetworks.append(network) }
                } else {
                    connectedNetworks.append(network)
                    let networkID = networkNodeID(machine.id, engine, network)
                    for container in users {
                        let address = container.networkAddresses.first { $0.network == network.name }?.address
                            ?? network.attached.first { container.topologyAliases.contains($0.name) }?.ipv4Address
                                .map { String($0.split(separator: "/").first ?? "") }
                        addEdge(containerNodeID(machine.id, container), networkID, kind: .attached, detail: address)
                    }
                }
            }
            let networkMoreID = moreNodeID(engineID, .networks)
            let shownIdleNetworks = expandedMore.contains(networkMoreID) ? idleNetworks : Array(idleNetworks.prefix(orphanLimit))
            for network in connectedNetworks + shownIdleNetworks {
                let id = networkNodeID(machine.id, engine, network)
                result.nodes.append(TopologyNode(
                    id: id, kind: .network, title: network.name, subtitle: network.ipv4Subnet,
                    machineID: machine.id, engine: engine, parentID: engineID, network: network
                ))
                if shownIdleNetworks.contains(network) { addEdge(engineID, id, kind: .contains) }
            }
            moreNode(engine: engine, engineID: engineID, category: .networks, total: idleNetworks.count, limit: orphanLimit) {
                String(format: String(localized: "+%lld sieci"), Int64($0))
            }

            // Volumes and bind mounts, on request.
            guard showVolumes else { continue }
            var connectedVolumes: [VolumeEntry] = []
            var idleVolumes: [VolumeEntry] = []
            for volume in machine.volumes.filter({ $0.engine == engine }) {
                let users = visible.filter { volume.isUsed(by: $0) }
                if users.isEmpty {
                    idleVolumes.append(volume)
                } else {
                    connectedVolumes.append(volume)
                    let volumeID = volumeNodeID(machine.id, engine, volume)
                    for container in users { addEdge(containerNodeID(machine.id, container), volumeID, kind: .mount) }
                }
            }
            let volumeMoreID = moreNodeID(engineID, .volumes)
            let shownIdleVolumes = expandedMore.contains(volumeMoreID) ? idleVolumes : Array(idleVolumes.prefix(orphanLimit))
            for volume in connectedVolumes + shownIdleVolumes {
                let id = volumeNodeID(machine.id, engine, volume)
                result.nodes.append(TopologyNode(
                    id: id, kind: .volume, title: volume.isBind ? (volume.path ?? volume.name) : volume.name,
                    subtitle: volume.isBind ? String(localized: "bind") : nil,
                    machineID: machine.id, engine: engine, parentID: engineID, volume: volume
                ))
                if shownIdleVolumes.contains(volume) { addEdge(engineID, id, kind: .contains) }
            }
            moreNode(engine: engine, engineID: engineID, category: .volumes, total: idleVolumes.count, limit: orphanLimit) {
                String(format: String(localized: "+%lld wolumenów"), Int64($0))
            }
        }
        return result
    }
}
