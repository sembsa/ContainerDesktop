import Foundation
import Observation

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

    private let cli = ContainerCLI.shared

    var runningCount: Int { items.filter(\.isRunning).count }

    func refresh() async {
        if items.isEmpty { isLoading = true }
        defer { isLoading = false }
        do {
            let args = showAll ? ["ls", "-a"] : ["ls"]
            items = try await cli.json(args, as: [ContainerInfo].self)
            error = nil
        } catch let cliError as CLIError {
            error = cliError
        } catch {
            self.error = .command(exitCode: -1, stderr: error.localizedDescription)
        }
    }

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
