import Foundation
import Observation

/// The Volumes section's data: every engine's volumes (this Mac and each
/// external machine), normalised into `VolumeEntry`.
///
/// Mirrors `NetworkStore`'s refresh: every source is listed concurrently under
/// its own deadline, a source that fails is retried at most every 20 s, and one
/// failing source never hides the others.
@MainActor @Observable
final class VolumeStore {
    var items: [VolumeEntry] = []
    var isLoading = false
    /// The Apple engine's last error (the primary one, like `ContainerStore.error`).
    var error: CLIError?

    /// Restricts the list to this Mac or one external machine; `nil` shows all.
    var machineFilter: MachineFilter?
    /// Restricts the list to one runtime (Apple, Docker, Colima); `nil` shows all.
    var engineFilter: ContainerEngine?

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

    init(runtimes: [any ContainerRuntime] = [AppleRuntime(), DockerRuntime()]) {
        self.runtimeProvider = { runtimes }
    }

    // MARK: - Derived lists

    var machineOptions: [MachineFilter] {
        var options = Set(items.map(\.machineFilterValue))
        if let machineFilter { options.insert(machineFilter) }
        return options.sorted()
    }

    var engineOptions: [ContainerEngine] {
        var options = Set(items.map(\.engine))
        if let engineFilter { options.insert(engineFilter) }
        return ContainerEngine.allCases.filter(options.contains)
    }

    func filteredItems(showBindMounts: Bool = true, search: String = "") -> [VolumeEntry] {
        VolumeSourceFilter.apply(machine: machineFilter, engine: engineFilter, search: search, showBindMounts: showBindMounts, to: items)
    }

    /// Named Apple volumes on this Mac: what `container run --volume` can name.
    var localAppleItems: [VolumeEntry] {
        items.filter { $0.kind == .apple && $0.runtimeID == nil && !$0.isBind }
    }

    // MARK: - Refresh

    private var lastFailure: [String: Date] = [:]
    private var failureDetails: [String: SourceFailure] = [:]

    static let retryAfterFailure: TimeInterval = 20
    static let listDeadline: Duration = .seconds(25)

    /// - Parameters:
    ///   - appleAvailable: `false` while Apple's system service is down; its CLI
    ///     would only fail, but Docker volumes should still show.
    ///   - force: a manual refresh ignores the backoff after a failure.
    ///
    /// Runs as its own task, see `ContainerStore.refresh`.
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

        let active = runtimes.filter { runtime in
            guard runtime.isInstalled, runtime.kind != .apple || appleAvailable else { return false }
            if !force, runtime.kind != .apple, let failed = lastFailure[runtime.id],
               now.timeIntervalSince(failed) < Self.retryAfterFailure { return false }
            return true
        }

        let results = await withTaskGroup(of: (String, Result<[VolumeEntry], Error>).self) { group in
            for runtime in active {
                group.addTask {
                    do {
                        let list = runtime.kind == .apple
                            ? try await runtime.listVolumes()
                            : try await Deadline.run(Self.listDeadline) { try await runtime.listVolumes() }
                        return (runtime.id, .success(list))
                    } catch { return (runtime.id, .failure(error)) }
                }
            }
            var collected: [String: Result<[VolumeEntry], Error>] = [:]
            for await (id, result) in group { collected[id] = result }
            return collected
        }

        var merged: [VolumeEntry] = []
        var primaryError: CLIError?
        for runtime in runtimes {
            let key = runtime.id
            switch results[key] {
            case .success(let list):
                lastFailure[key] = nil
                failureDetails[key] = nil
                merged += list.map { entry in
                    entry.with(id: "\(entry.runtimeKey)|\(entry.storage.rawValue)|\(entry.reference)")
                }
            case .failure(let failure) where RefreshCancellation.isCancellation(failure):
                merged += items.filter { $0.runtimeKey == key }
            case .failure(let failure):
                lastFailure[key] = now
                let cliError = (failure as? CLIError) ?? .command(exitCode: -1, stderr: failure.localizedDescription)
                if runtime.kind == .apple { primaryError = cliError }
                failureDetails[key] = SourceFailure(
                    id: key,
                    source: runtime.sourceLabel ?? (runtime.kind == .apple ? "Apple" : "Docker"),
                    message: cliError.localizedDescription
                )
                // Apple's CLI keeps its last good list across a failed poll; an
                // engine that is simply gone must not.
                if runtime.keepsLastListOnError { merged += items.filter { $0.runtimeKey == key } }
            case nil:
                // Not asked this round (Apple's service is down, the CLI is
                // missing, or a machine is backing off; its footer line stays).
                if runtime.kind == .apple { failureDetails[key] = nil }
            }
        }

        // Entries of removed machines go at once.
        let liveRuntimeKeys = Set(runtimes.map(\.id))
        failureDetails = failureDetails.filter { liveRuntimeKeys.contains($0.key) }
        lastFailure = lastFailure.filter { liveRuntimeKeys.contains($0.key) }

        items = VolumeSourceFilter.makeIdentitiesUnique(Self.sorted(merged))
        error = primaryError
        failures = failureDetails.values.sorted { $0.source.localizedCaseInsensitiveCompare($1.source) == .orderedAscending }
    }

    /// This Mac first, then machines by label; inside each, Apple, Docker,
    /// Colima; named volumes before bind mounts; then by name.
    nonisolated static func sorted(_ list: [VolumeEntry]) -> [VolumeEntry] {
        func rank(_ entry: VolumeEntry) -> Int { ContainerEngine.allCases.firstIndex(of: entry.engine) ?? ContainerEngine.allCases.count }
        return list.enumerated().sorted { a, b in
            let (x, y) = (a.element, b.element)
            if x.machineFilterValue != y.machineFilterValue { return x.machineFilterValue < y.machineFilterValue }
            if rank(x) != rank(y) { return rank(x) < rank(y) }
            if x.isBind != y.isBind { return !x.isBind }
            let order = x.name.localizedCaseInsensitiveCompare(y.name)
            return order == .orderedSame ? a.offset < b.offset : order == .orderedAscending
        }.map(\.element)
    }

    // MARK: - Actions

    private func runtime(id: String) throws -> any ContainerRuntime {
        guard let runtime = runtimeProvider().first(where: { $0.id == id }) else { throw CLIError.volumeActionUnsupported }
        return runtime
    }

    /// Creates a volume on this Mac's Apple or Docker engine.
    func create(name: String, size: String?, on engine: RuntimeKind = .apple) async throws {
        let target = try runtime(id: engine.rawValue)
        guard target.volumeActions.contains(.create) else { throw CLIError.volumeActionUnsupported }
        try await target.createVolume(name: name, size: size)
        await refresh(force: true)
    }

    func remove(_ volume: VolumeEntry) async throws {
        guard volume.canRemove else { throw CLIError.volumeActionUnsupported }
        let owner = try runtime(id: volume.runtimeKey)
        guard owner.volumeActions.contains(.remove) else { throw CLIError.volumeActionUnsupported }
        try await owner.removeVolume(volume.reference)
        await refresh(force: true)
    }

    /// Apple only (`container volume prune`).
    func prune() async throws {
        let apple = try runtime(id: RuntimeKind.apple.rawValue)
        guard apple.volumeActions.contains(.prune) else { throw CLIError.volumeActionUnsupported }
        try await apple.pruneVolumes()
        await refresh(force: true)
    }

    func inspect(_ volume: VolumeEntry) async throws -> String {
        guard !volume.isBind else { throw CLIError.volumeActionUnsupported }
        return try await runtime(id: volume.runtimeKey).inspectVolume(volume.reference)
    }

    private let cli = ContainerCLI.shared

    // MARK: - File browsing (via an ephemeral helper container + cp)

    /// Image used as a throwaway helper to mount the volume. Alpine is small and
    /// ships `ls`/`sh`; it is pulled automatically if missing.
    private let helperImage = "alpine:latest"

    func listFiles(_ volume: VolumeEntry, path: String) async throws -> [FileEntry] {
        let output = try await cli.run(
            ["run", "--rm", "--progress", "none", "-v", "\(volume.name):/volume", helperImage, "ls", "-la", mountedPath(path)]
        )
        return FileEntry.parse(lsOutput: output)
    }

    func copyToVolume(_ volume: VolumeEntry, localPath: String, destination: String) async throws {
        try await withHelper(volume) { helper in
            let target = self.mountedPath(destination)
            let ran = (try? await self.cli.run(["cp", localPath, "\(helper):\(target)"])) != nil
            // Same silent-failure exposure as a plain container upload: `cp` can
            // exit 0 having written nothing, and here the helper is torn down
            // immediately afterwards, so nobody would ever notice.
            if ran, await ContainerCopyCheck.verify(
                containerID: helper, localPath: localPath, destination: target
            ) != .missing {
                return
            }
            try await ContainerFileTransfer.upload(
                containerID: helper,
                localURL: URL(fileURLWithPath: localPath),
                destination: target
            )
            if await ContainerCopyCheck.verify(
                containerID: helper, localPath: localPath, destination: target
            ) == .missing {
                throw ContainerCopyCheck.silentFailure(destination: destination)
            }
        }
    }

    func copyFromVolume(_ volume: VolumeEntry, source: String, localPath: String) async throws {
        try await withHelper(volume) { helper in
            let target = self.mountedPath(source)
            if (try? await self.cli.run(["cp", "\(helper):\(target)", localPath])) != nil { return }
            try await ContainerFileTransfer.download(
                containerID: helper, source: target, to: URL(fileURLWithPath: localPath)
            )
        }
    }

    private func withHelper(_ volume: VolumeEntry, _ body: (String) async throws -> Void) async throws {
        let helper = "cgui-helper-" + UUID().uuidString.prefix(8).lowercased()
        try await cli.run(["run", "-d", "--progress", "none", "--name", helper, "-v", "\(volume.name):/volume", helperImage, "sleep", "120"])
        do {
            try await body(helper)
            _ = try? await cli.run(["rm", "--force", helper])
        } catch {
            _ = try? await cli.run(["rm", "--force", helper])
            throw error
        }
    }

    /// Maps a volume-rooted path (e.g. `/sub/file`) to the helper mount (`/volume/sub/file`).
    private func mountedPath(_ path: String) -> String {
        path == "/" || path.isEmpty ? "/volume" : "/volume" + (path.hasPrefix("/") ? path : "/" + path)
    }
}
