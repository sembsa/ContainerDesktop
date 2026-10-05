import Foundation

/// What the UI may do to a network. Gated per engine so the views never branch
/// on "is this Apple's".
struct NetworkActions: OptionSet, Sendable, Hashable {
    let rawValue: Int
    static let create = NetworkActions(rawValue: 1 << 0)
    static let remove = NetworkActions(rawValue: 1 << 1)
    /// `container network prune`.
    static let prune = NetworkActions(rawValue: 1 << 2)

    static let apple: NetworkActions = [.create, .remove, .prune]
    /// A local Docker engine. Prune is left out on purpose: `docker network
    /// prune` also takes networks that other tools set up for later.
    static let docker: NetworkActions = [.create, .remove]
    static let none: NetworkActions = []
}

/// A network from any engine, normalised: Apple's `container network`, Docker's
/// (local or on an external machine), or a WireGuard interface.
///
/// `reference` is the engine-local identifier to hand back to that engine;
/// `id` is the UI identity and is unique across machines.
struct NetworkEntry: Identifiable, Sendable, Hashable {
    enum Kind: String, Sendable, Hashable, CaseIterable {
        case apple
        case docker
        case wireguard
    }

    struct Attachment: Sendable, Hashable, Identifiable {
        let name: String
        let ipv4Address: String?
        var id: String { name }
    }

    var id: String
    var reference: String
    var name: String
    var kind: Kind
    /// `nat`, `bridge`, `overlay`, … — Apple calls it the mode.
    var driver: String?
    /// Docker's `local` / `swarm`.
    var scope: String?
    var ipv4Subnet: String?
    var ipv4Gateway: String?
    var ipv6Subnet: String?
    var isInternal: Bool = false
    /// The engine's own networks (`default`, `bridge`, `host`, `none`): never removable.
    var isBuiltIn: Bool = false
    var createdAt: Date? = nil
    var attached: [Attachment] = []
    var wireGuard: WireGuardInterface? = nil

    /// Same owner fields as `ContainerInfo`, so the three tags read identically.
    var runtimeID: String? = nil
    var machineLabel: String? = nil
    var location: ContainerLocation = .local
    var engineOverride: ContainerEngine? = nil

    /// Key matching `ContainerRuntime.id`.
    var runtimeKey: String { runtimeID ?? (kind == .apple ? RuntimeKind.apple.rawValue : RuntimeKind.docker.rawValue) }

    /// The engine behind it. WireGuard has none; it reports `.docker` here only
    /// to keep the type total — use `runtimeFilterValue` / `sourceTags`.
    var engine: ContainerEngine { engineOverride ?? (kind == .apple ? .apple : .docker) }

    /// Text of the third tag: the engine, or "WireGuard".
    var runtimeTitle: String { kind == .wireguard ? NetworkEntry.wireGuardTitle : engine.title }

    static let wireGuardTitle = "WireGuard"

    /// The same three tags as a container row: location, machine (external
    /// only), runtime — the runtime being "WireGuard" for a tunnel.
    var sourceTags: [SourceTag] {
        var tags = [SourceTag(kind: .location, text: location.title)]
        if location == .external, let machineLabel { tags.append(SourceTag(kind: .machine, text: machineLabel)) }
        tags.append(SourceTag(kind: .runtime, text: runtimeTitle))
        return tags
    }

    var machineFilterValue: MachineFilter {
        location == .external ? .machine(machineLabel ?? "") : .local
    }

    var runtimeFilterValue: NetworkRuntimeFilter {
        kind == .wireguard ? .wireGuard : .engine(engine)
    }

    /// What may be done to it. Anything reached through an external machine,
    /// and every WireGuard interface, is read-only.
    var actions: NetworkActions {
        if kind == .wireguard || runtimeID != nil { return .none }
        return kind == .apple ? .apple : .docker
    }

    var canRemove: Bool { actions.contains(.remove) && !isBuiltIn }

    func matchesSearch(_ needle: String) -> Bool {
        guard !needle.isEmpty else { return true }
        let fields = [name, driver ?? "", ipv4Subnet ?? "", ipv4Gateway ?? ""]
            + attached.map(\.name)
            + sourceTags.map(\.text)
        return fields.contains { $0.lowercased().contains(needle) }
    }

    /// Suffix that tells two same-named networks apart ("studio · Colima").
    var disambiguator: String {
        ([machineLabel].compactMap { $0 } + [runtimeTitle]).joined(separator: " · ")
    }

    /// The same network under another owner. Passing a `machineLabel` makes it
    /// external; `reference` is preserved unless replaced.
    func with(
        id newID: String? = nil,
        reference newReference: String? = nil,
        runtimeID: String? = nil,
        machineLabel: String? = nil,
        engine: ContainerEngine? = nil
    ) -> NetworkEntry {
        var copy = self
        if let newID { copy.id = newID }
        if let newReference { copy.reference = newReference }
        if let runtimeID { copy.runtimeID = runtimeID }
        if let machineLabel {
            copy.machineLabel = machineLabel
            copy.location = .external
        }
        if let engine { copy.engineOverride = engine }
        return copy
    }

    // MARK: - Mapping from Apple's JSON

    init(
        id: String, reference: String, name: String, kind: Kind,
        driver: String? = nil, scope: String? = nil,
        ipv4Subnet: String? = nil, ipv4Gateway: String? = nil, ipv6Subnet: String? = nil,
        isInternal: Bool = false, isBuiltIn: Bool = false, createdAt: Date? = nil,
        attached: [Attachment] = [], wireGuard: WireGuardInterface? = nil,
        runtimeID: String? = nil, machineLabel: String? = nil,
        location: ContainerLocation = .local, engineOverride: ContainerEngine? = nil
    ) {
        self.id = id; self.reference = reference; self.name = name; self.kind = kind
        self.driver = driver; self.scope = scope
        self.ipv4Subnet = ipv4Subnet; self.ipv4Gateway = ipv4Gateway; self.ipv6Subnet = ipv6Subnet
        self.isInternal = isInternal; self.isBuiltIn = isBuiltIn; self.createdAt = createdAt
        self.attached = attached; self.wireGuard = wireGuard
        self.runtimeID = runtimeID; self.machineLabel = machineLabel
        self.location = location; self.engineOverride = engineOverride
    }

    /// `container network ls --format json` entry -> neutral model.
    init(apple info: NetworkInfo) {
        self.init(
            id: info.id,
            reference: info.name,
            name: info.name,
            kind: .apple,
            driver: info.configuration.mode,
            ipv4Subnet: info.status?.ipv4Subnet,
            ipv4Gateway: info.status?.ipv4Gateway,
            ipv6Subnet: info.status?.ipv6Subnet,
            isInternal: info.configuration.mode?.lowercased() == "hostonly",
            isBuiltIn: info.configuration.labels?["com.apple.container.resource.role"] == "builtin" || info.name == "default",
            createdAt: info.configuration.creationDate
        )
    }

    /// A WireGuard interface as a network row.
    init(wireGuard interface: WireGuardInterface) {
        let ipv4 = interface.subnets.first { !$0.contains(":") }
        let ipv6 = interface.subnets.first { $0.contains(":") }
        self.init(
            id: "wg:" + interface.name,
            reference: interface.name,
            name: interface.name,
            kind: .wireguard,
            driver: NetworkEntry.wireGuardTitle,
            ipv4Subnet: ipv4,
            ipv6Subnet: ipv6,
            wireGuard: interface
        )
    }
}

/// The runtime half of the Networks toolbar filter. WireGuard sits beside the
/// engines because it is the third tag on its rows.
enum NetworkRuntimeFilter: Hashable, Identifiable, Sendable {
    case engine(ContainerEngine)
    case wireGuard

    var id: String {
        switch self {
        case .engine(let engine): engine.rawValue
        case .wireGuard: "wireguard"
        }
    }

    var title: String {
        switch self {
        case .engine(let engine): engine.title
        case .wireGuard: NetworkEntry.wireGuardTitle
        }
    }

    /// Display order of the menu.
    static let order: [NetworkRuntimeFilter] =
        ContainerEngine.allCases.map { .engine($0) } + [.wireGuard]
}

/// Pure list logic behind the Networks toolbar, testable without the app.
enum NetworkSourceFilter {
    static func apply(
        machine: MachineFilter?, runtime: NetworkRuntimeFilter?, search: String = "", to list: [NetworkEntry]
    ) -> [NetworkEntry] {
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        return list.filter { entry in
            (machine == nil || entry.machineFilterValue == machine)
                && (runtime == nil || entry.runtimeFilterValue == runtime)
                && entry.matchesSearch(needle)
        }
    }

    /// Two engines both have a `bridge`. The UI identity of the later one gets
    /// the owner appended; commands still go out under `reference`.
    static func makeIdentitiesUnique(_ list: [NetworkEntry]) -> [NetworkEntry] {
        var seen = Set<String>()
        return list.map { entry in
            var candidate = entry.id
            if seen.contains(candidate) { candidate = "\(entry.id)@\(entry.disambiguator)" }
            var counter = 2
            while seen.contains(candidate) {
                candidate = "\(entry.id)@\(entry.disambiguator)-\(counter)"
                counter += 1
            }
            seen.insert(candidate)
            return candidate == entry.id ? entry : entry.with(id: candidate)
        }
    }
}
