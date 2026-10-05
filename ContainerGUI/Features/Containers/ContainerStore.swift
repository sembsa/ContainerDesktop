import Foundation
import Observation
import WidgetKit

@MainActor @Observable
final class ContainerStore {
    var items: [ContainerInfo] = []
    var showAll = true
    var isLoading = false
    var error: CLIError?
    var pendingIDs: Set<String> = []

    /// Restricts the list to this Mac or to one external machine; `nil` shows all.
    var machineFilter: MachineFilter?
    /// Restricts the list to one runtime (Apple, Docker, Colima); `nil` shows all.
    /// Combines with `machineFilter`.
    var engineFilter: ContainerEngine?
    /// Engines whose CLI is installed.
    private(set) var installedRuntimes: Set<RuntimeKind> = [.apple]
    /// The last list error per engine other than the primary one. A stopped
    /// Docker daemon is normal, so it is recorded here instead of raised.
    private(set) var runtimeErrors: [String: CLIError] = [:]

    /// Machines present in the list, for the filter menu: this Mac first, then
    /// every external machine that has containers, by label. The current choice
    /// stays offered even when its last container is gone, so it can be cleared.
    var machineOptions: [MachineFilter] {
        var options = Set(items.map(\.machineFilterValue))
        if let machineFilter { options.insert(machineFilter) }
        return options.sorted()
    }

    /// Runtimes present in the list, in a fixed order (plus the current choice).
    var engineOptions: [ContainerEngine] {
        var options = Set(items.map(\.engine))
        if let engineFilter { options.insert(engineFilter) }
        return ContainerEngine.allCases.filter(options.contains)
    }

    /// `items` narrowed by the toolbar's machine and runtime filters.
    var filteredItems: [ContainerInfo] {
        ContainerSourceFilter.apply(machine: machineFilter, engine: engineFilter, to: items)
    }


    /// Items belonging to Apple's runtime — the only ones login autostart and
    /// the `container`-specific system pages know how to handle.
    var autostartCandidates: [ContainerInfo] {
        items.filter { $0.capabilities.contains(.autostart) }
    }

    /// Compose project names the user has collapsed in the list. Absent = expanded
    /// (Docker-Desktop-like default). Held on the store so the expand/collapse state
    /// survives `ContainersView` being recreated on sidebar navigation, and persisted
    /// across launches.
    var collapsedProjects: Set<String> = ContainerStore.loadCollapsed() {
        didSet { ContainerStore.saveCollapsed(collapsedProjects) }
    }

    private static let collapsedKey = "collapsedComposeProjects"
    private static func loadCollapsed() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: collapsedKey) ?? [])
    }
    private static func saveCollapsed(_ value: Set<String>) {
        UserDefaults.standard.set(Array(value), forKey: collapsedKey)
    }

    /// Latest per-container resource usage, keyed by container id. Feeds the
    /// live meters on the card list; empty in table mode.
    private(set) var liveStats: [String: LiveUsage] = [:]
    /// Rolling CPU history behind the menu bar's sparklines. Fed by the same
    /// three-second tick that fills `liveStats`, so it costs no extra process.
    private(set) var usageHistory = UsageHistories()

    /// One container's usage, with CPU already turned into a percentage.
    ///
    /// `container stats` reports cumulative CPU microseconds, so a percentage
    /// only exists between two samples — the previous reading is kept per
    /// container to derive it.
    struct LiveUsage: Sendable, Hashable {
        var cpuPercent: Double?
        var memoryUsedBytes: Int64?
        var memoryLimitBytes: Int64?
        var processCount: Int?

        var memoryFraction: Double? {
            guard let used = memoryUsedBytes, let limit = memoryLimitBytes, limit > 0 else { return nil }
            return Double(used) / Double(limit)
        }
    }

    private var previousSamples: [String: (sample: StatsSample, at: Date)] = [:]

    /// Apple-only housekeeping (`prune`, `stop --all`, `clean`); guarded by
    /// `RuntimeCapabilities` in the views.
    private let cli = ContainerCLI.shared
    private let builtInRuntimes: [any ContainerRuntime]
    /// One runtime per enabled external machine, rebuilt only when its entry
    /// changes so the tunnel and CPU bookkeeping survive a refresh.
    private var externalRuntimes: [(endpoint: DockerEndpoint, runtime: ExternalMachineRuntime)] = []

    private var runtimes: [any ContainerRuntime] {
        builtInRuntimes + externalRuntimes.map { $0.runtime as any ContainerRuntime }
    }

    /// The runtimes are injected so a test can substitute fakes; the defaults are
    /// the two local engines. External machines are added with `setExternal`.
    init(runtimes: [any ContainerRuntime] = [AppleRuntime(), DockerRuntime()]) {
        self.builtInRuntimes = runtimes
    }

    /// Every runtime in play (built-in and external), for sections that list
    /// the same engines — Networks shares them so tunnels and engine detection
    /// are not duplicated.
    var allRuntimes: [any ContainerRuntime] { runtimes }

    /// The enabled external machines.
    var externalEndpoints: [DockerEndpoint] { externalRuntimes.map(\.endpoint) }

    func runtime(for container: ContainerInfo) -> any ContainerRuntime {
        runtimes.first { $0.id == container.runtimeKey } ?? runtimes[0]
    }

    /// Feeds the enabled external machines in. Entries that did not change keep
    /// their runtime; containers of removed or disabled ones leave the list at
    /// once instead of waiting for the next poll.
    func setExternal(_ endpoints: [DockerEndpoint], refreshNow: Bool = true) {
        let wanted = endpoints.filter(\.enabled)
        externalRuntimes = wanted.map { endpoint in
            if let existing = externalRuntimes.first(where: { $0.endpoint == endpoint }) { return existing }
            return (endpoint, ExternalMachineRuntime(endpoint: endpoint))
        }
        let live = Set(runtimes.map(\.id))
        items = items.filter { live.contains($0.runtimeKey) }
        runtimeErrors = runtimeErrors.filter { live.contains($0.key) }
        if refreshNow { Task { await refresh() } }
    }

    var runningCount: Int { items.filter(\.isRunning).count }

    /// Lists every installed engine concurrently and merges the results.
    ///
    /// - Parameter appleAvailable: `false` while Apple's system service is down;
    ///   its CLI would only fail, but Docker containers should still show.
    ///
    /// Runs as its own task: a caller that goes away (a view's `.task` restarting,
    /// the 3 s poll) does not cancel a refresh that is under way — which would
    /// surface as a bogus "CancellationError" for every engine — and a caller
    /// that arrives meanwhile simply waits for that refresh instead of starting
    /// another.
    func refresh(appleAvailable: Bool = true) async {
        if let running = refreshInFlight {
            await running.value
            return
        }
        let task = Task { [self] in
            await performRefresh(appleAvailable: appleAvailable)
            refreshInFlight = nil
        }
        refreshInFlight = task
        await task.value
    }

    private var refreshInFlight: Task<Void, Never>?

    private func performRefresh(appleAvailable: Bool) async {
        if items.isEmpty { isLoading = true }
        defer { isLoading = false }

        let includeStopped = showAll
        let now = Date()
        let active = runtimes.filter { runtime in
            guard runtime.isInstalled, runtime.kind != .apple || appleAvailable else { return false }
            // An unreachable machine is retried every 20 s, not every poll —
            // each attempt can take seconds and would stall the whole list.
            if runtime.kind != .apple, let failed = lastFailure[runtime.id],
               now.timeIntervalSince(failed) < Self.retryAfterFailure { return false }
            return true
        }
        installedRuntimes = Set(builtInRuntimes.filter(\.isInstalled).map(\.kind))

        let results = await withTaskGroup(of: (String, Result<[ContainerInfo], Error>).self) { group in
            for runtime in active {
                group.addTask {
                    do {
                        let list = runtime.kind == .apple
                            ? try await runtime.list(includeStopped: includeStopped)
                            : try await Deadline.run(Self.listDeadline) {
                                try await runtime.list(includeStopped: includeStopped)
                            }
                        return (runtime.id, .success(list))
                    } catch { return (runtime.id, .failure(error)) }
                }
            }
            var collected: [String: Result<[ContainerInfo], Error>] = [:]
            for await (id, result) in group { collected[id] = result }
            return collected
        }

        var merged: [ContainerInfo] = []
        var primaryError: CLIError?
        for runtime in runtimes {
            let key = runtime.id
            switch results[key] {
            case .success(let list):
                runtimeErrors[key] = nil
                lastFailure[key] = nil
                merged.append(contentsOf: list)
            case .failure(let failure) where RefreshCancellation.isCancellation(failure):
                // Cancelled, not broken: keep the last good list, record nothing.
                merged.append(contentsOf: items.filter { $0.runtimeKey == key })
            case .failure(let failure):
                lastFailure[key] = Date()
                let cliError = (failure as? CLIError) ?? .command(exitCode: -1, stderr: failure.localizedDescription)
                if runtime.kind == .apple { primaryError = cliError } else { runtimeErrors[key] = cliError }
                // Apple's CLI keeps its last good list across a failed poll;
                // an engine that is simply gone (Docker quit, a laptop that
                // went offline) must not.
                if runtime.keepsLastListOnError {
                    merged.append(contentsOf: items.filter { $0.runtimeKey == key })
                }
            case nil:
                // Not asked this round (Apple's service is down, the CLI is
                // missing, or an unreachable machine is backing off): nothing
                // to show for it.
                break
            }
        }
        items = Self.makeIdentitiesUnique(merged)
        error = primaryError
        await refreshLiveStats()
    }

    private var lastFailure: [String: Date] = [:]
    private static let retryAfterFailure: TimeInterval = 20
    private static let listDeadline: Duration = .seconds(25)

    /// Two engines can both have a container called `web`. Identity (selection,
    /// meters, `ForEach`) is `id`, so the later one is renamed; commands still
    /// go out under `reference`.
    static func makeIdentitiesUnique(_ list: [ContainerInfo]) -> [ContainerInfo] {
        ContainerSourceFilter.makeIdentitiesUnique(list)
    }

    /// One stats call per engine covers every running container, so the card
    /// list's meters cost a single extra process per engine per refresh.
    private func refreshLiveStats() async {
        guard !items.isEmpty else {
            liveStats = [:]
            previousSamples = [:]
            return
        }

        // Samples come back keyed by the engine's own name; the store keys
        // everything by UI identity.
        var identity: [String: [String: String]] = [:]
        for container in items where container.isRunning {
            identity[container.runtimeKey, default: [:]][container.reference] = container.id
        }

        var samples: [StatsSample] = []
        var gotAny = false
        for runtime in runtimes {
            guard let names = identity[runtime.id] else { continue }
            guard let fetched = try? await runtime.stats(references: nil) else { continue }
            gotAny = true
            for sample in fetched {
                guard let id = names[sample.id] else { continue }
                samples.append(sample.withID(id))
            }
        }
        guard gotAny else { return }

        let now = Date()
        var updated: [String: LiveUsage] = [:]
        for sample in samples {
            var usage = LiveUsage(
                cpuPercent: nil,
                memoryUsedBytes: sample.memoryUsageBytes,
                memoryLimitBytes: sample.memoryLimitBytes,
                processCount: sample.numProcesses
            )
            if let previous = previousSamples[sample.id],
               let current = sample.cpuUsageUsec,
               let earlier = previous.sample.cpuUsageUsec {
                let elapsed = now.timeIntervalSince(previous.at)
                // Below ~0.2s the quantisation of the counter makes the result noise.
                if elapsed > 0.2, current >= earlier {
                    usage.cpuPercent = Double(current - earlier) / (elapsed * 1_000_000) * 100
                }
            }
            updated[sample.id] = usage
            previousSamples[sample.id] = (sample, now)
        }
        // Drop containers that stopped, so a stale meter can't linger.
        let alive = Set(samples.map(\.id))
        previousSamples = previousSamples.filter { alive.contains($0.key) }
        liveStats = updated
        // Only containers with a computed percentage take part: the first sample
        // after a container appears has no delta to measure against, and
        // recording a zero for it would draw a dip that never happened.
        usageHistory.record(updated.compactMapValues(\.cpuPercent))
    }

    /// Hands the current state to the desktop widget.
    ///
    /// Writing the file and asking WidgetKit to reload are deliberately on
    /// different clocks. The widget reads the file at the moment WidgetKit asks
    /// it for a timeline, so the file should simply be reasonably fresh — it is
    /// a local atomic write, and `refresh()` runs every 3 seconds. Reloads are
    /// the scarce resource: WidgetKit budgets roughly 40–70 a day, so one is
    /// requested only when something a widget actually shows has changed, and
    /// at most once a minute so a flapping container cannot drain the budget.
    ///
    /// Tying the write to the reload (the first version of this) meant CPU
    /// percentages never reached the widget at all: a container's usage is only
    /// known from the *second* sample onwards, by which time its state had
    /// stopped changing and nothing was being written any more.
    func publishWidgetSnapshot(serviceRunning: Bool) {
        let snapshot = WidgetSnapshot(
            generatedAt: Date(),
            serviceRunning: serviceRunning,
            containers: items.map { container in
                let usage = liveStats[container.id]
                return WidgetSnapshot.Entry(
                    id: container.id,
                    image: container.imageReference,
                    state: container.state,
                    ipv4: container.primaryIPv4Address,
                    project: container.composeProject,
                    cpuPercent: usage?.cpuPercent.map { ($0 * 10).rounded() / 10 },
                    memoryUsedBytes: usage?.memoryUsedBytes
                )
            }
        )
        // Compare everything except the timestamp and the constantly-drifting
        // usage numbers — otherwise nothing is ever "unchanged".
        let fingerprint = WidgetFingerprint(
            serviceRunning: snapshot.serviceRunning,
            entries: snapshot.containers.map { "\($0.id)|\($0.state)|\($0.ipv4 ?? "")" }
        )
        let stateChanged = fingerprint != lastWidgetFingerprint
        let now = Date()
        let fileIsStale = lastWidgetWrite.map { now.timeIntervalSince($0) >= Self.widgetWriteInterval } ?? true

        guard stateChanged || fileIsStale else { return }
        lastWidgetFingerprint = fingerprint
        lastWidgetWrite = now
        try? WidgetSnapshotStore.write(snapshot)

        guard stateChanged else { return }
        let reloadIsDue = lastWidgetReload.map { now.timeIntervalSince($0) >= Self.widgetReloadInterval } ?? true
        guard reloadIsDue else { return }
        lastWidgetReload = now
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// How often the snapshot file is refreshed even when nothing changed —
    /// keeps CPU/memory numbers current for whenever WidgetKit next reads it.
    private static let widgetWriteInterval: TimeInterval = 30
    /// Floor between reload requests, to protect the daily WidgetKit budget.
    private static let widgetReloadInterval: TimeInterval = 60

    private struct WidgetFingerprint: Equatable {
        let serviceRunning: Bool
        let entries: [String]
    }

    private var lastWidgetFingerprint: WidgetFingerprint?
    private var lastWidgetWrite: Date?
    private var lastWidgetReload: Date?

    // MARK: - Pending helper

    private func withPending(_ id: String, _ action: () async throws -> Void) async rethrows {
        pendingIDs.insert(id)
        defer { pendingIDs.remove(id) }
        try await action()
    }

    // MARK: - Lifecycle actions

    func start(_ container: ContainerInfo) async throws {
        try await withPending(container.id) {
            try await runtime(for: container).start(container.reference)
            await refresh()
        }
    }

    func stop(_ container: ContainerInfo) async throws {
        try await withPending(container.id) {
            try await runtime(for: container).stop(container.reference)
            await refresh()
        }
    }

    func kill(_ container: ContainerInfo) async throws {
        try await withPending(container.id) {
            try await runtime(for: container).kill(container.reference)
            await refresh()
        }
    }

    func restart(_ container: ContainerInfo) async throws {
        try await withPending(container.id) {
            try await runtime(for: container).restart(container.reference, wasRunning: container.isRunning)
            await refresh()
        }
    }

    /// Stops every running Apple container (menu bar quick action). Docker's
    /// containers are left alone: they are often long-lived services that
    /// something other than this app depends on.
    func stopAll() async throws {
        try await cli.run(["stop", "--all"], timeout: .seconds(120))
        await refresh()
    }

    func remove(_ container: ContainerInfo, force: Bool = false) async throws {
        try await withPending(container.id) {
            try await runtime(for: container).remove(container.reference, force: force)
            await refresh()
        }
    }

    /// Removes stopped Apple containers (`container prune`).
    func prune() async throws {
        try await cli.run(["prune"])
        await refresh()
    }

    // MARK: - Detail data

    func inspect(_ container: ContainerInfo) async throws -> String {
        try await runtime(for: container).inspect(container.reference)
    }

    func latestStats(_ container: ContainerInfo) async -> StatsSample? {
        let sample = try? await runtime(for: container).stats(references: [container.reference]).first
        return sample?.withID(container.id)
    }

    /// `logs --follow` with the requested history, through the owning engine.
    func logStream(_ container: ContainerInfo, tail: LogTailLimit) -> AsyncThrowingStream<String, Error> {
        runtime(for: container).logs(container.reference, tail: tail)
    }

    func writeFullLog(_ container: ContainerInfo, to url: URL) async throws {
        try await runtime(for: container).writeFullLog(container.reference, to: url.path)
    }

    func terminalTarget(_ container: ContainerInfo) -> TerminalTarget {
        runtime(for: container).terminalTarget(container.reference)
    }

    // MARK: - Files & export

    func export(_ container: ContainerInfo, to url: URL) async throws {
        try await runtime(for: container).export(container.reference, to: url)
    }

    func copyToContainer(_ container: ContainerInfo, localPath: String, destination: String) async throws {
        try await runtime(for: container).copyIn(container.reference, localPath: localPath, destination: destination)
    }

    func copyFromContainer(_ container: ContainerInfo, source: String, localPath: String) async throws {
        try await runtime(for: container).copyOut(container.reference, source: source, localPath: localPath)
    }

    /// Lists a directory inside a running container via `exec ls`.
    func listFiles(_ container: ContainerInfo, path: String) async throws -> [FileEntry] {
        try await runtime(for: container).listFiles(container.reference, path: path)
    }

    /// `container clean` — new in 1.4.1. Apple only (`RuntimeCapabilities.clean`).
    ///
    /// Trims the writable layers of a *running* container (its root filesystem
    /// unless read-only, plus every writable block mount), releasing the disk
    /// blocks they no longer use so the sparse image on the host shrinks back.
    /// It reclaims space; it does not reset or delete the container's data.
    func clean(_ container: ContainerInfo) async throws {
        try await cli.run(["clean", container.reference], timeout: .seconds(300))
        await refresh()
    }
}
