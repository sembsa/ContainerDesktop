import Foundation
import Observation

/// Local Kubernetes clusters managed by the `container k8s` plugin.
///
/// The plugin is EXPERIMENTAL and ships as a separate resource inside the
/// installer package, so it can be missing (older CLI) or present-but-broken
/// (CLI upgraded while the background apiserver still runs the old build — the
/// exact state a `.pkg` upgrade leaves behind until the service is restarted).
/// `availability` distinguishes those cases so the view can offer a fix rather
/// than an error.
@MainActor @Observable
final class K8sStore {
    enum Availability: Equatable {
        case unknown
        case available
        /// CLI and background service disagree — restarting the service fixes it.
        case versionMismatch(cli: String, service: String)
        /// The plugin isn't there at all (CLI older than 1.2.1).
        case unsupported(String)
    }

    var clusters: [K8sCluster] = []
    var availability: Availability = .unknown
    var error: String?
    /// Cluster names with an action in flight.
    var pendingNames: Set<String> = []

    private let cli = ContainerCLI.shared

    // MARK: - Loading

    func refresh() async {
        do {
            let output = try await cli.run(["k8s", "list"], timeout: .seconds(30))
            clusters = K8sCluster.group(K8sListParser.parse(output))
            availability = .available
            error = nil
        } catch {
            clusters = []
            await diagnose(error)
        }
    }

    /// Turns a failed `k8s list` into something the user can act on.
    private func diagnose(_ error: Error) async {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription

        // A CLI new enough to have the plugin, talking to an older apiserver, is
        // the common post-upgrade state; surface the restart instead of the raw
        // XPC noise.
        if let versions = await versionMismatch() {
            availability = .versionMismatch(cli: versions.cli, service: versions.service)
            self.error = nil
            return
        }

        let lowercased = message.lowercased()
        if lowercased.contains("unknown") || lowercased.contains("unexpected argument")
            || lowercased.contains("subcommand") {
            availability = .unsupported(message)
        } else {
            availability = .available
            self.error = message
        }
    }

    /// Whether the CLI and the background service are running different builds.
    ///
    /// This used to grep the human-readable status table for `apiserver.version`,
    /// a field 1.4.1 renamed to `server.version` — which silently killed the
    /// detection exactly when it mattered most. It now decodes the JSON payload
    /// and reuses `SystemStatus.versionSkew`, so there is one definition of skew
    /// for the whole app.
    ///
    /// It asks the CLI directly rather than reading `SystemStore`, because
    /// `diagnose` runs on a failed `k8s list` — which can happen long before the
    /// System page has ever been opened.
    private func versionMismatch() async -> SystemStatus.VersionSkew? {
        guard let result = try? await cli.runRaw(
                ["system", "status", "--format", "json"], timeout: .seconds(15)
              ),
              let data = result.stdout.data(using: .utf8),
              let status = try? JSONDecoder().decode(SystemStatus.self, from: data)
        else { return nil }

        return status.versionSkew
    }

    // MARK: - Actions

    private func withPending<T>(_ name: String, _ action: () async throws -> T) async rethrows -> T {
        pendingNames.insert(name)
        defer { pendingNames.remove(name) }
        return try await action()
    }

    func start(_ cluster: K8sCluster) async throws {
        try await withPending(cluster.name) {
            try await cli.run(["k8s", "start", "--name", cluster.name], timeout: .seconds(300))
        }
        await refresh()
    }

    func delete(_ cluster: K8sCluster) async throws {
        try await withPending(cluster.name) {
            try await cli.run(["k8s", "delete", "--name", cluster.name], timeout: .seconds(300))
        }
        KubeconfigManager.removeKubeconfig(for: cluster.name)
        await refresh()
    }

    func loadImage(_ image: String, into cluster: K8sCluster, platform: String?) async throws {
        var args = ["k8s", "load-image", "--name", cluster.name, image]
        if let platform, !platform.isEmpty { args.append(contentsOf: ["--platform", platform]) }
        try await withPending(cluster.name) {
            try await cli.run(args, timeout: .seconds(600))
        }
    }

    /// Streams `k8s create`, which pulls an ~850 MB node image and then waits
    /// for kubeadm — well over a minute even on a warm cache.
    nonisolated func createStream(
        name: String,
        cpus: String,
        memory: String,
        nodeImage: String,
        removeOnStop: Bool
    ) -> AsyncThrowingStream<String, Error> {
        var args = ["k8s", "create", "--name", name]
        if !cpus.isEmpty { args.append(contentsOf: ["--cpus", cpus]) }
        if !memory.isEmpty { args.append(contentsOf: ["--memory", memory]) }
        if !nodeImage.isEmpty { args.append(contentsOf: ["--node-image", nodeImage]) }
        if removeOnStop { args.append("--rm") }
        return ContainerCLI.shared.streamChecked(args)
    }

    /// Writes the cluster's context to a user-chosen kubeconfig. Distinct from
    /// the app-managed copy: this one is for the user's own `kubectl`.
    func exportKubeconfig(_ cluster: K8sCluster, to path: String) async throws {
        try await cli.run(
            ["k8s", "write-config", "--name", cluster.name, "--kubeconfig", path],
            timeout: .seconds(60)
        )
    }
}
