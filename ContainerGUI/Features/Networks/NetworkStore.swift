import Foundation
import Observation

/// How the store reaches WireGuard on a machine. Injected so tests never
/// start a process.
struct WireGuardScanner: Sendable {
    var local: @Sendable (_ trySudo: Bool) async throws -> WireGuardScan
    var remote: @Sendable (_ endpoint: DockerEndpoint, _ trySudo: Bool) async throws -> WireGuardScan

    static let live = WireGuardScanner(
        local: { try await WireGuardProbe.scanLocal(trySudo: $0) },
        remote: { try await WireGuardProbe.scan(endpoint: $0, trySudo: $1) }
    )

    static let none = WireGuardScanner(
        local: { _ in WireGuardScan(status: .missing, wgBinary: nil, sudoAttempted: false, usedSudo: false, interfaces: []) },
        remote: { _, _ in WireGuardScan(status: .missing, wgBinary: nil, sudoAttempted: false, usedSudo: false, interfaces: []) }
    )
}

/// The Networks section's data: every engine's networks (this Mac and each
/// external machine) plus WireGuard interfaces, normalised into `NetworkEntry`.
///
/// Mirrors `ContainerStore`'s refresh: every source is listed concurrently under
/// its own deadline, a source that fails is retried at most every 20 s, and one
/// failing source never hides the others.
@MainActor @Observable
final class NetworkStore {
    var items: [NetworkEntry] = []
    var isLoading = false
    /// The Apple engine's last error (the primary one, like `ContainerStore.error`).
    var error: CLIError?

    /// Restricts the list to this Mac or one external machine; `nil` shows all.
    var machineFilter: MachineFilter?
    /// Restricts the list to one runtime (Apple, Docker, Colima, WireGuard).
    var runtimeFilter: NetworkRuntimeFilter?

    struct SourceFailure: Identifiable, Equatable {
        let id: String
        let source: String
        let message: String
    }
    /// Sources whose last refresh failed, for the footer. A stopped Docker
    /// daemon or an offline machine is normal and is not raised as an alert.
    private(set) var failures: [SourceFailure] = []

    /// The engines to list. Wired to the container store's runtimes by `AppModel`
    /// so a machine's tunnel and engine detection are shared.
    var runtimeProvider: @MainActor () -> [any ContainerRuntime]
    /// The enabled external machines, for their WireGuard interfaces.
    var machineProvider: @MainActor () -> [DockerEndpoint]
    private let wireGuard: WireGuardScanner

    init(
        runtimes: [any ContainerRuntime] = [AppleRuntime(), DockerRuntime()],
        machines: [DockerEndpoint] = [],
        wireGuard: WireGuardScanner = .live
    ) {
        self.runtimeProvider = { runtimes }
        self.machineProvider = { machines }
        self.wireGuard = wireGuard
    }

    // MARK: - Derived lists

    var machineOptions: [MachineFilter] {
        var options = Set(items.map(\.machineFilterValue))
        if let machineFilter { options.insert(machineFilter) }
        return options.sorted()
    }

    var runtimeOptions: [NetworkRuntimeFilter] {
        var options = Set(items.map(\.runtimeFilterValue))
        if let runtimeFilter { options.insert(runtimeFilter) }
        return NetworkRuntimeFilter.order.filter(options.contains)
    }

    var filteredItems: [NetworkEntry] {
        NetworkSourceFilter.apply(machine: machineFilter, runtime: runtimeFilter, to: items)
    }

    /// Apple networks on this Mac: what `container run --network` can name.
    var localAppleItems: [NetworkEntry] {
        items.filter { $0.kind == .apple && $0.runtimeID == nil }
    }

    // MARK: - Refresh

    private var lastFailure: [String: Date] = [:]
    private var wireGuardCache: [String: (at: Date, scan: WireGuardScan)] = [:]
    private var sudoRetryAfter: [String: Date] = [:]
    private var failureDetails: [String: SourceFailure] = [:]

    static let retryAfterFailure: TimeInterval = 20
    static let listDeadline: Duration = .seconds(25)
    static let wireGuardDeadline: Duration = .seconds(35)
    /// `wg` is polled less often than the 3 s tick: each remote scan is an ssh login.
    static let wireGuardTTL: TimeInterval = 15
    /// After `sudo -n` has failed, do not try it again for this long.
    static let sudoRetryInterval: TimeInterval = 300

    private enum Outcome: Sendable {
        case networks(String, Result<[NetworkEntry], Error>)
        case wireGuard(String, Result<WireGuardScan, Error>)
    }

    /// Local WireGuard has no runtime id of its own.
    private static let localWireGuardKey = "wg:local"

    static func wireGuardKey(for endpoint: DockerEndpoint) -> String { "wg:" + ExternalMachineRuntime.runtimeKey(for: endpoint) }

    /// - Parameter appleAvailable: `false` while Apple's system service is down;
    ///   its CLI would only fail, but Docker and WireGuard should still show.
    /// - Parameter force: a manual refresh. Ignores the retry backoff after a
    ///   failure, the WireGuard result cache and the five-minute wait after a
    ///   failed `sudo -n`, so a freshly added sudoers rule is picked up at once.
    ///
    /// Runs as its own task, see `ContainerStore.refresh`: a cancelled caller does
    /// not cancel it, a second caller waits for it (a forced one then refreshes
    /// again), and a cancellation that does reach a source is never an error.
    func refresh(appleAvailable: Bool = true, force: Bool = false) async {
        if let running = refreshInFlight {
            await running.value
            if !force { return }
        }
        let task = Task { [self] in
            await performRefresh(appleAvailable: appleAvailable, force: force)
            refreshInFlight = nil
        }
        refreshInFlight = task
        await task.value
    }

    private var refreshInFlight: Task<Void, Never>?

    private func performRefresh(appleAvailable: Bool, force: Bool) async {
        if items.isEmpty { isLoading = true }
        defer { isLoading = false }

        let now = Date()
        let runtimes = runtimeProvider()
        let endpoints = machineProvider()

        let active = runtimes.filter { runtime in
            guard runtime.isInstalled, runtime.kind != .apple || appleAvailable else { return false }
            if !force, runtime.kind != .apple, let failed = lastFailure[runtime.id],
               now.timeIntervalSince(failed) < Self.retryAfterFailure { return false }
            return true
        }

        // WireGuard targets that are due: cache expired and not backing off.
        struct Target { let key: String; let endpoint: DockerEndpoint?; let trySudo: Bool }
        var due: [Target] = []
        var wanted: [(key: String, endpoint: DockerEndpoint?)] = [(Self.localWireGuardKey, nil)]
        wanted += endpoints.map { (Self.wireGuardKey(for: $0), $0) }
        for (key, endpoint) in wanted {
            if !force, let cached = wireGuardCache[key], now.timeIntervalSince(cached.at) < Self.wireGuardTTL { continue }
            if !force, let failed = lastFailure[key], now.timeIntervalSince(failed) < Self.retryAfterFailure { continue }
            due.append(Target(key: key, endpoint: endpoint, trySudo: force || (sudoRetryAfter[key] ?? .distantPast) <= now))
        }
        let scanner = wireGuard

        let outcomes = await withTaskGroup(of: Outcome.self) { group in
            for runtime in active {
                group.addTask {
                    do {
                        let list = runtime.kind == .apple
                            ? try await runtime.listNetworks()
                            : try await Deadline.run(Self.listDeadline) { try await runtime.listNetworks() }
                        return .networks(runtime.id, .success(list))
                    } catch { return .networks(runtime.id, .failure(error)) }
                }
            }
            for target in due {
                group.addTask {
                    do {
                        let scan = try await Deadline.run(Self.wireGuardDeadline) {
                            if let endpoint = target.endpoint { return try await scanner.remote(endpoint, target.trySudo) }
                            return try await scanner.local(target.trySudo)
                        }
                        return .wireGuard(target.key, .success(scan))
                    } catch { return .wireGuard(target.key, .failure(error)) }
                }
            }
            var collected: [Outcome] = []
            for await outcome in group { collected.append(outcome) }
            return collected
        }

        var networkResults: [String: Result<[NetworkEntry], Error>] = [:]
        for outcome in outcomes {
            switch outcome {
            case .networks(let id, let result):
                networkResults[id] = result
            case .wireGuard(let key, let result):
                switch result {
                case .success(let scan):
                    wireGuardCache[key] = (now, scan)
                    lastFailure[key] = nil
                    failureDetails[key] = nil
                    if scan.status == .needsRoot, scan.sudoAttempted { sudoRetryAfter[key] = now.addingTimeInterval(Self.sudoRetryInterval) }
                    if scan.usedSudo { sudoRetryAfter[key] = nil }
                case .failure(let failure) where RefreshCancellation.isCancellation(failure):
                    // Cancelled, not broken: the cached scan and the last error stay as they were.
                    break
                case .failure(let failure):
                    wireGuardCache[key] = nil
                    lastFailure[key] = now
                    let label = Self.label(forWireGuard: key, endpoints: endpoints)
                    failureDetails[key] = SourceFailure(id: key, source: label + " · " + NetworkEntry.wireGuardTitle, message: Self.message(failure))
                }
            }
        }

        var merged: [NetworkEntry] = []
        var primaryError: CLIError?
        for runtime in runtimes {
            let key = runtime.id
            switch networkResults[key] {
            case .success(let list):
                lastFailure[key] = nil
                failureDetails[key] = nil
                merged += list.map { entry in
                    entry.with(id: "\(entry.runtimeKey)|\(entry.reference)")
                }
            case .failure(let failure) where RefreshCancellation.isCancellation(failure):
                merged += items.filter { $0.runtimeKey == key && $0.kind != .wireguard }
            case .failure(let failure):
                lastFailure[key] = now
                let cliError = (failure as? CLIError) ?? .command(exitCode: -1, stderr: failure.localizedDescription)
                if runtime.kind == .apple { primaryError = cliError }
                failureDetails[key] = SourceFailure(
                    id: key,
                    source: runtime.sourceLabel ?? (runtime.kind == .apple ? "Apple" : "Docker"),
                    message: Self.message(cliError)
                )
                // Apple's CLI keeps its last good list across a failed poll; an
                // engine that is simply gone must not.
                if runtime.keepsLastListOnError { merged += items.filter { $0.runtimeKey == key && $0.kind != .wireguard } }
            case nil:
                // Not asked this round (Apple's service is down, the CLI is
                // missing, or a machine is backing off).
                if runtime.kind == .apple { failureDetails[key] = nil }
            }
        }

        // WireGuard: cached scans stand in for the targets skipped this round.
        for (key, endpoint) in wanted {
            guard let scan = wireGuardCache[key]?.scan else { continue }
            for interface in scan.interfaces {
                var entry = NetworkEntry(wireGuard: interface)
                if let endpoint {
                    let runtimeKey = ExternalMachineRuntime.runtimeKey(for: endpoint)
                    entry = entry.with(runtimeID: runtimeKey, machineLabel: endpoint.label)
                }
                entry.id = "\(entry.runtimeKey)|wg|\(interface.name)"
                merged.append(entry)
            }
        }

        // Entries of removed machines go at once.
        let liveRuntimeKeys = Set(runtimes.map(\.id)).union(endpoints.map(ExternalMachineRuntime.runtimeKey(for:)))
        let liveWireGuardKeys = Set(wanted.map(\.key))
        wireGuardCache = wireGuardCache.filter { liveWireGuardKeys.contains($0.key) }
        failureDetails = failureDetails.filter { liveRuntimeKeys.contains($0.key) || liveWireGuardKeys.contains($0.key) }

        items = NetworkSourceFilter.makeIdentitiesUnique(Self.sorted(merged))
        error = primaryError
        failures = failureDetails.values.sorted { $0.source.localizedCaseInsensitiveCompare($1.source) == .orderedAscending }
    }

    /// This Mac first, then machines by label; inside each, Apple, Docker,
    /// Colima, WireGuard; then by name.
    nonisolated static func sorted(_ list: [NetworkEntry]) -> [NetworkEntry] {
        func rank(_ entry: NetworkEntry) -> Int {
            NetworkRuntimeFilter.order.firstIndex(of: entry.runtimeFilterValue) ?? NetworkRuntimeFilter.order.count
        }
        return list.enumerated().sorted { a, b in
            let (x, y) = (a.element, b.element)
            if x.machineFilterValue != y.machineFilterValue { return x.machineFilterValue < y.machineFilterValue }
            if rank(x) != rank(y) { return rank(x) < rank(y) }
            let order = x.name.localizedCaseInsensitiveCompare(y.name)
            return order == .orderedSame ? a.offset < b.offset : order == .orderedAscending
        }.map(\.element)
    }

    private static func message(_ failure: Error) -> String {
        if let cli = failure as? CLIError { return cli.localizedDescription }
        return failure.localizedDescription
    }

    private static func label(forWireGuard key: String, endpoints: [DockerEndpoint]) -> String {
        endpoints.first { wireGuardKey(for: $0) == key }?.label ?? "Mac"
    }

    /// Test hook: forget cached WireGuard scans so the next refresh scans again.
    func expireWireGuardCacheForTesting() { wireGuardCache = [:] }

    // MARK: - Actions

    private func runtime(id: String) throws -> any ContainerRuntime {
        guard let runtime = runtimeProvider().first(where: { $0.id == id }) else { throw CLIError.networkActionUnsupported }
        return runtime
    }

    /// Creates a network on this Mac's Apple or Docker engine.
    func create(name: String, subnet: String?, internalOnly: Bool, on engine: RuntimeKind = .apple) async throws {
        let target = try runtime(id: engine.rawValue)
        guard target.networkActions.contains(.create) else { throw CLIError.networkActionUnsupported }
        try await target.createNetwork(name: name, subnet: subnet, internalOnly: internalOnly)
        await refresh()
    }

    func remove(_ network: NetworkEntry) async throws {
        guard network.canRemove else { throw CLIError.networkActionUnsupported }
        let owner = try runtime(id: network.runtimeKey)
        guard owner.networkActions.contains(.remove) else { throw CLIError.networkActionUnsupported }
        try await owner.removeNetwork(network.reference)
        await refresh()
    }

    /// Apple only (`container network prune`).
    func prune() async throws {
        let apple = try runtime(id: RuntimeKind.apple.rawValue)
        guard apple.networkActions.contains(.prune) else { throw CLIError.networkActionUnsupported }
        try await apple.pruneNetworks()
        await refresh()
    }

    func inspect(_ network: NetworkEntry) async throws -> String {
        guard network.kind != .wireguard else { throw CLIError.networkActionUnsupported }
        return try await runtime(id: network.runtimeKey).inspectNetwork(network.reference)
    }
}
