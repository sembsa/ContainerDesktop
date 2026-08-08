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

    private let cli = ContainerCLI.shared

    var runningCount: Int { items.filter(\.isRunning).count }

    func refresh() async {
        if items.isEmpty { isLoading = true }
        defer { isLoading = false }
        do {
            let args = showAll ? ["ls", "-a"] : ["ls"]
            // Kubernetes node containers belong to the Kubernetes section; showing
            // them here invites deleting a cluster's control plane by mistake.
            items = try await cli.json(args, as: [ContainerInfo].self)
                .filter { $0.configuration.labels?["com.apple.container.plugin"] != "k8s" }
            error = nil
            await refreshLiveStats()
        } catch let cliError as CLIError {
            error = cliError
        } catch {
            self.error = .command(exitCode: -1, stderr: error.localizedDescription)
        }
    }

    /// One `container stats --no-stream` call covers every running container,
    /// so the card list's meters cost a single extra process per refresh.
    private func refreshLiveStats() async {
        guard !items.isEmpty else {
            liveStats = [:]
            previousSamples = [:]
            return
        }
        guard let samples = try? await cli.json(
            ["stats", "--no-stream"],
            as: [StatsSample].self,
            timeout: .seconds(20)
        ) else { return }

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
            try await cli.run(["start", container.id])
            await refresh()
        }
    }

    func stop(_ container: ContainerInfo) async throws {
        try await withPending(container.id) {
            try await cli.run(["stop", container.id])
            await refresh()
        }
    }

    func kill(_ container: ContainerInfo) async throws {
        try await withPending(container.id) {
            try await cli.run(["kill", container.id])
            await refresh()
        }
    }

    func restart(_ container: ContainerInfo) async throws {
        try await withPending(container.id) {
            if container.isRunning {
                do {
                    try await cli.run(["stop", container.id])
                } catch let error as CLIError {
                    guard Self.isAlreadyStoppedError(error) else { throw error }
                }
            }
            try await cli.run(["start", container.id])
            await refresh()
        }
    }

    /// Stops every running container (menu bar quick action).
    func stopAll() async throws {
        try await cli.run(["stop", "--all"], timeout: .seconds(120))
        await refresh()
    }

    private static func isAlreadyStoppedError(_ error: CLIError) -> Bool {
        guard case .command(_, let stderr) = error else { return false }
        let lower = stderr.lowercased()
        return lower.contains("not running") || lower.contains("already stopped") || lower.contains("stopped")
    }

    func remove(_ container: ContainerInfo, force: Bool = false) async throws {
        try await withPending(container.id) {
            var args = ["rm"]
            if force { args.append("--force") }
            args.append(container.id)
            try await cli.run(args)
            await refresh()
        }
    }

    func prune() async throws {
        try await cli.run(["prune"])
        await refresh()
    }

    // MARK: - Detail data

    func inspect(_ id: String) async throws -> String {
        try await cli.run(["inspect", id])
    }

    func latestStats(_ id: String) async -> StatsSample? {
        let samples = try? await cli.json(["stats", "--no-stream", id], as: [StatsSample].self)
        return samples?.first
    }

    // MARK: - Files & export

    func export(_ container: ContainerInfo, to url: URL) async throws {
        try await cli.run(["export", "--output", url.path, container.id])
    }

    func copyToContainer(_ container: ContainerInfo, localPath: String, destination: String) async throws {
        try await cli.run(["cp", localPath, "\(container.id):\(destination)"])
    }

    func copyFromContainer(_ container: ContainerInfo, source: String, localPath: String) async throws {
        try await cli.run(["cp", "\(container.id):\(source)", localPath])
    }

    /// Lists a directory inside a running container via `exec ls`.
    func listFiles(_ container: ContainerInfo, path: String) async throws -> [FileEntry] {
        let output = try await cli.run(["exec", container.id, "ls", "-la", path])
        return FileEntry.parse(lsOutput: output)
    }
}
