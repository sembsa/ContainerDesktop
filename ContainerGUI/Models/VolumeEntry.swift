import Foundation

/// What the UI may do to a volume. Gated per engine so the views never branch
/// on "is this Apple's".
struct VolumeActions: OptionSet, Sendable, Hashable {
    let rawValue: Int
    static let create = VolumeActions(rawValue: 1 << 0)
    static let remove = VolumeActions(rawValue: 1 << 1)
    /// `container volume prune`.
    static let prune = VolumeActions(rawValue: 1 << 2)
    /// Browse and copy files through a helper container.
    static let browse = VolumeActions(rawValue: 1 << 3)

    static let apple: VolumeActions = [.create, .remove, .prune, .browse]
    /// A local Docker engine. Prune is left out on purpose, like for networks.
    static let docker: VolumeActions = [.create, .remove]
    static let none: VolumeActions = []
}

/// A volume from any engine, normalised: Apple's `container volume`, or Docker's
/// (local, Colima, or on an external machine). Bind mounts that containers use
/// are listed as `.bind` rows so storage that is not a named volume is visible too.
///
/// `reference` is the engine-local identifier to hand back to that engine;
/// `id` is the UI identity and is unique across machines.
struct VolumeEntry: Identifiable, Sendable, Hashable {
    enum Kind: String, Sendable, Hashable, CaseIterable {
        case apple
        case docker
    }

    enum Storage: String, Sendable, Hashable {
        /// A named volume managed by the engine.
        case volume
        /// A host directory/file mounted into containers.
        case bind
    }

    var id: String
    var reference: String
    var name: String
    var kind: Kind
    var storage: Storage = .volume
    /// `local` for Docker; Apple's is `local` too.
    var driver: String?
    /// Apple's disk image format (`ext4`).
    var format: String?
    /// Docker's mountpoint, Apple's backing image, or the host path of a bind mount.
    var path: String?
    var scope: String?
    var sizeBytes: Int64?
    var createdAt: Date?
    var labels: [String: String] = [:]
    /// Names of the containers that mount it.
    var usedBy: [String] = []

    /// Same owner fields as `ContainerInfo`, so the three tags read identically.
    var runtimeID: String?
    var machineLabel: String?
    var location: ContainerLocation = .local
    var engineOverride: ContainerEngine?

    init(
        id: String, reference: String, name: String, kind: Kind, storage: Storage = .volume,
        driver: String? = nil, format: String? = nil, path: String? = nil, scope: String? = nil,
        sizeBytes: Int64? = nil, createdAt: Date? = nil, labels: [String: String] = [:], usedBy: [String] = [],
        runtimeID: String? = nil, machineLabel: String? = nil,
        location: ContainerLocation = .local, engineOverride: ContainerEngine? = nil
    ) {
        self.id = id; self.reference = reference; self.name = name; self.kind = kind; self.storage = storage
        self.driver = driver; self.format = format; self.path = path; self.scope = scope
        self.sizeBytes = sizeBytes; self.createdAt = createdAt; self.labels = labels; self.usedBy = usedBy
        self.runtimeID = runtimeID; self.machineLabel = machineLabel
        self.location = location; self.engineOverride = engineOverride
    }

    var isBind: Bool { storage == .bind }

    /// Key matching `ContainerRuntime.id`.
    var runtimeKey: String { runtimeID ?? (kind == .apple ? RuntimeKind.apple.rawValue : RuntimeKind.docker.rawValue) }

    var engine: ContainerEngine { engineOverride ?? (kind == .apple ? .apple : .docker) }

    /// The same three tags as a container row: location, machine (external
    /// only), runtime.
    var sourceTags: [SourceTag] {
        var tags = [SourceTag(kind: .location, text: location.title)]
        if location == .external, let machineLabel { tags.append(SourceTag(kind: .machine, text: machineLabel)) }
        tags.append(SourceTag(kind: .runtime, text: engine.title))
        return tags
    }

    var machineFilterValue: MachineFilter {
        location == .external ? .machine(machineLabel ?? "") : .local
    }

    /// What may be done to it. Anything reached through an external machine is
    /// read-only, and a bind mount is not an object of the engine.
    var actions: VolumeActions {
        if runtimeID != nil { return .none }
        return kind == .apple ? .apple : .docker
    }

    var canRemove: Bool { actions.contains(.remove) && !isBind }

    var composeProject: String? { labels["com.docker.compose.project"] ?? labels["compose.project"] }

    func matchesSearch(_ needle: String) -> Bool {
        guard !needle.isEmpty else { return true }
        let fields = [name, driver ?? "", format ?? "", path ?? "", composeProject ?? ""]
            + usedBy
            + labels.map { "\($0.key)=\($0.value)" }
            + sourceTags.map(\.text)
        return fields.contains { $0.lowercased().contains(needle) }
    }

    /// Suffix that tells two same-named volumes apart ("studio · Colima").
    var disambiguator: String {
        ([machineLabel].compactMap { $0 } + [engine.title]).joined(separator: " · ")
    }

    /// The same volume under another owner. Passing a `machineLabel` makes it
    /// external; `reference` is preserved unless replaced.
    func with(
        id newID: String? = nil,
        reference newReference: String? = nil,
        runtimeID: String? = nil,
        machineLabel: String? = nil,
        engine: ContainerEngine? = nil
    ) -> VolumeEntry {
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

    /// `container volume ls --format json` entry -> neutral model.
    init(apple info: VolumeInfo, usedBy: [String] = []) {
        self.init(
            id: info.id, reference: info.name, name: info.name, kind: .apple,
            driver: info.configuration.driver, format: info.configuration.format,
            path: info.configuration.source, scope: nil,
            sizeBytes: info.configuration.sizeInBytes, createdAt: info.configuration.creationDate,
            labels: (info.configuration.labels ?? [:]).filter { !$0.key.hasPrefix("com.apple.container.resource") },
            usedBy: usedBy
        )
    }
}

/// Pure list logic behind the Volumes toolbar, testable without the app.
enum VolumeSourceFilter {
    static func apply(
        machine: MachineFilter?, engine: ContainerEngine?, search: String = "",
        showBindMounts: Bool = true, to list: [VolumeEntry]
    ) -> [VolumeEntry] {
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        return list.filter { entry in
            (showBindMounts || !entry.isBind)
                && (machine == nil || entry.machineFilterValue == machine)
                && (engine == nil || entry.engine == engine)
                && entry.matchesSearch(needle)
        }
    }

    /// Two engines can both have a volume called `data`. The UI identity of the
    /// later one gets the owner appended; commands still go out under `reference`.
    static func makeIdentitiesUnique(_ list: [VolumeEntry]) -> [VolumeEntry] {
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

/// Apple's volumes plus the containers that mount them -> `VolumeEntry` rows.
enum AppleVolumeMapper {
    static func entries(volumes: [VolumeInfo], containers: [ContainerInfo]) -> [VolumeEntry] {
        var usedBy: [String: [String]] = [:]
        var binds: [String: [String]] = [:]
        for container in containers {
            for mount in container.configuration.mounts ?? [] {
                if let name = mount.type?.volume?.name {
                    usedBy[name, default: []].append(container.id)
                } else if let source = mount.source, !source.isEmpty {
                    binds[source, default: []].append(container.id)
                }
            }
        }
        let named = volumes.map { VolumeEntry(apple: $0, usedBy: (usedBy[$0.name] ?? []).uniqued().sorted()) }
        let bound = binds.map { source, users in
            VolumeEntry(
                id: "bind:" + source, reference: source, name: source, kind: .apple, storage: .bind,
                path: source, usedBy: users.uniqued().sorted()
            )
        }.sorted { $0.name < $1.name }
        return named + bound
    }
}

extension Array where Element: Hashable {
    fileprivate func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
