import Foundation

/// The machine half of the toolbar's source filter.
enum MachineFilter: Hashable, Comparable {
    case local
    case machine(String)

    /// This Mac first, then machines alphabetically.
    static func < (lhs: MachineFilter, rhs: MachineFilter) -> Bool {
        switch (lhs, rhs) {
        case (.local, .machine): true
        case (.machine(let a), .machine(let b)): a.localizedCaseInsensitiveCompare(b) == .orderedAscending
        default: false
        }
    }

    var title: String {
        switch self {
        case .local: ContainerLocation.local.title
        case .machine(let label): label
        }
    }
}

extension ContainerInfo {
    var machineFilterValue: MachineFilter {
        location == .external ? .machine(machineLabel ?? "") : .local
    }
}

/// Pure list logic behind the Containers toolbar and list identities, kept apart
/// from `ContainerStore` so it can be tested without the app.
enum ContainerSourceFilter {
    /// Narrows `list` by machine and/or runtime; `nil` means no restriction.
    static func apply(machine: MachineFilter?, engine: ContainerEngine?, to list: [ContainerInfo]) -> [ContainerInfo] {
        list.filter { container in
            (machine == nil || container.machineFilterValue == machine)
                && (engine == nil || container.engine == engine)
        }
    }

    /// Two engines can both have a container called `web`. Identity (selection,
    /// meters, `ForEach`) is `id`, so the later one is renamed to
    /// `web@<machine label · runtime>`; commands still go out under `reference`.
    static func makeIdentitiesUnique(_ list: [ContainerInfo]) -> [ContainerInfo] {
        var seen = Set<String>()
        return list.map { container in
            var candidate = container.id
            if seen.contains(candidate) { candidate = "\(container.id)@\(container.disambiguator)" }
            var counter = 2
            while seen.contains(candidate) {
                candidate = "\(container.id)@\(container.disambiguator)-\(counter)"
                counter += 1
            }
            seen.insert(candidate)
            return candidate == container.id ? container : container.with(id: candidate)
        }
    }
}

// MARK: - Grouping

/// How a list (containers, networks, volumes) is split into sections.
enum ListGrouping: String, CaseIterable, Identifiable, Sendable {
    case none
    case machine
    case runtime
    case status
    case compose
    case image

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: String(localized: "Brak")
        case .machine: String(localized: "Maszyna")
        case .runtime: String(localized: "Silnik")
        case .status: String(localized: "Stan")
        case .compose: String(localized: "Projekt Compose")
        case .image: String(localized: "Obraz")
        }
    }

    /// Networks and volumes have no status, project or image to group by.
    static let simple: [ListGrouping] = [.none, .machine, .runtime]
    static let containers: [ListGrouping] = ListGrouping.allCases

    /// Falls back to `.none` when a stored choice does not apply to this list.
    func restricted(to allowed: [ListGrouping]) -> ListGrouping { allowed.contains(self) ? self : .none }
}

/// Identity and order of one section.
struct GroupKey: Hashable, Sendable {
    /// Stable across refreshes; prefixed with the grouping so collapse state of
    /// "machine:studio" and "runtime:studio" never collide.
    let id: String
    let title: String
    /// Sections sort by `rank`, then by title.
    let rank: Int
}

struct ListGroup<Item>: Identifiable {
    let id: String
    let title: String
    let items: [Item]
    var count: Int { items.count }
}

extension ListGroup: Sendable where Item: Sendable {}

/// What a row exposes to be grouped. `nil` puts it in no section of its own
/// (it lands in the trailing "Other" section).
protocol Groupable {
    func groupKey(for grouping: ListGrouping) -> GroupKey?
}

enum ListGrouper {
    /// Splits `items` into sections. Order inside a section is the input order.
    /// `.none` returns a single untitled section so callers can render it flat.
    static func group<Item: Groupable>(_ items: [Item], by grouping: ListGrouping) -> [ListGroup<Item>] {
        guard grouping != .none else {
            return items.isEmpty ? [] : [ListGroup(id: "all", title: "", items: items)]
        }
        var order: [GroupKey] = []
        var buckets: [String: [Item]] = [:]
        for item in items {
            let key = item.groupKey(for: grouping) ?? GroupKey(id: "\(grouping.rawValue):", title: String(localized: "Inne"), rank: Int.max)
            if buckets[key.id] == nil { order.append(key) }
            buckets[key.id, default: []].append(item)
        }
        return order
            .sorted { lhs, rhs in
                if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
            .map { ListGroup(id: $0.id, title: $0.title, items: buckets[$0.id] ?? []) }
    }
}

/// Which sections the user collapsed, stored as one string in `@AppStorage`.
/// Ids are namespaced by list ("containers|machine:studio").
enum CollapsedGroups {
    static func decode(_ stored: String) -> Set<String> {
        Set(stored.split(separator: "\n").map(String.init))
    }

    static func encode(_ set: Set<String>) -> String { set.sorted().joined(separator: "\n") }

    static func isCollapsed(_ id: String, in stored: String) -> Bool { decode(stored).contains(id) }

    static func toggled(_ id: String, in stored: String) -> String {
        var set = decode(stored)
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
        return encode(set)
    }
}

private func machineKey(_ filter: MachineFilter) -> GroupKey {
    switch filter {
    case .local: GroupKey(id: "machine:local", title: String(localized: "Ten Mac"), rank: 0)
    case .machine(let label): GroupKey(id: "machine:\(label)", title: label, rank: 1)
    }
}

private func engineKey(_ engine: ContainerEngine) -> GroupKey {
    GroupKey(id: "runtime:\(engine.rawValue)", title: engine.title, rank: ContainerEngine.allCases.firstIndex(of: engine) ?? 99)
}

extension ContainerInfo: Groupable {
    func groupKey(for grouping: ListGrouping) -> GroupKey? {
        switch grouping {
        case .none: nil
        case .machine: machineKey(machineFilterValue)
        case .runtime: engineKey(engine)
        case .status:
            isRunning
                ? GroupKey(id: "status:running", title: String(localized: "Działające"), rank: 0)
                : GroupKey(id: "status:stopped", title: String(localized: "Zatrzymane"), rank: 1)
        case .compose:
            composeProject.map { GroupKey(id: "compose:\($0)", title: $0, rank: 0) }
                ?? GroupKey(id: "compose:", title: String(localized: "Bez projektu Compose"), rank: 1)
        case .image: GroupKey(id: "image:\(imageReference)", title: imageReference, rank: 0)
        }
    }
}

extension NetworkEntry: Groupable {
    func groupKey(for grouping: ListGrouping) -> GroupKey? {
        switch grouping {
        case .machine: machineKey(machineFilterValue)
        case .runtime:
            kind == .wireguard
                ? GroupKey(id: "runtime:wireguard", title: NetworkEntry.wireGuardTitle, rank: ContainerEngine.allCases.count)
                : engineKey(engine)
        default: nil
        }
    }
}

extension VolumeEntry: Groupable {
    func groupKey(for grouping: ListGrouping) -> GroupKey? {
        switch grouping {
        case .machine: machineKey(machineFilterValue)
        case .runtime: engineKey(engine)
        default: nil
        }
    }
}
