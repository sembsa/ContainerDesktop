import Foundation

/// The single point of contact with the `kubectl` binary.
///
/// One actor per external binary, sharing `ProcessRunner` with `ContainerCLI`
/// and `HelmCLI` rather than reimplementing process handling. Everything here
/// takes a `ClusterKubeconfig`, so no call can reach a cluster the app does not
/// manage — the same discipline `HelmCLI` enforces, for the same reason:
/// `~/.kube/config` usually points at somebody's real cluster.
///
/// The argv itself lives in `KubectlCommands`, which is where the flag-placement
/// rules are spelled out and tested.
actor KubectlCLI {
    static let shared = KubectlCLI()

    private let decoder = KubectlJSON.decoder

    /// kubectl talks to a local cluster over localhost, so it is fast — but a
    /// `delete` waits for graceful termination, which is not.
    static let defaultTimeout: Duration = .seconds(60)

    // MARK: - Availability

    nonisolated static func binaryPath() -> String? { KubectlBinaryResolver.resolve() }

    nonisolated static var isInstalled: Bool { binaryPath() != nil }

    // MARK: - Reading

    /// Decodes a list of objects of one kind.
    func list<Item: Decodable & Sendable>(
        kind: String,
        namespace: String?,
        clusterScoped: Bool = false,
        as type: Item.Type,
        on target: ClusterKubeconfig
    ) async throws -> [Item] {
        let arguments = KubectlCommands.get(
            kind: kind,
            namespace: namespace,
            clusterScoped: clusterScoped,
            on: target
        )
        let output = try await execute(arguments, timeout: Self.defaultTimeout)
        guard let data = output.data(using: .utf8), !data.isEmpty else { return [] }
        do {
            return try decoder.decode(K8sList<Item>.self, from: data).items
        } catch {
            throw CLIError.decoding(String(describing: error))
        }
    }

    /// `describe` is prose meant to be read, not parsed.
    func describe(
        kind: String,
        name: String,
        namespace: String,
        on target: ClusterKubeconfig
    ) async throws -> String {
        try await execute(
            KubectlCommands.describe(kind: kind, name: name, namespace: namespace, on: target),
            timeout: Self.defaultTimeout
        )
    }

    nonisolated func logStream(
        pod: String,
        namespace: String,
        container: String?,
        tail: Int?,
        follow: Bool,
        on target: ClusterKubeconfig
    ) -> AsyncThrowingStream<String, Error> {
        guard let binary = KubectlBinaryResolver.resolve() else {
            return AsyncThrowingStream { $0.finish(throwing: CLIError.kubectlNotInstalled) }
        }
        return ProcessLineReader(
            binary: binary,
            arguments: KubectlCommands.logs(
                pod: pod,
                namespace: namespace,
                container: container,
                tail: tail,
                follow: follow,
                on: target
            ),
            failOnNonZeroExit: true
        ).lines()
    }

    // MARK: - Mutating

    @discardableResult
    func delete(
        kind: String,
        name: String,
        namespace: String,
        on target: ClusterKubeconfig
    ) async throws -> String {
        try await execute(
            KubectlCommands.delete(kind: kind, name: name, namespace: namespace, on: target),
            // A delete waits for the grace period before it returns.
            timeout: .seconds(120)
        )
    }

    @discardableResult
    func scale(
        deployment: String,
        namespace: String,
        replicas: Int,
        on target: ClusterKubeconfig
    ) async throws -> String {
        try await execute(
            KubectlCommands.scale(
                deployment: deployment,
                namespace: namespace,
                replicas: replicas,
                on: target
            ),
            timeout: Self.defaultTimeout
        )
    }

    @discardableResult
    func rolloutRestart(
        deployment: String,
        namespace: String,
        on target: ClusterKubeconfig
    ) async throws -> String {
        try await execute(
            KubectlCommands.rolloutRestart(deployment: deployment, namespace: namespace, on: target),
            timeout: Self.defaultTimeout
        )
    }

    // MARK: - Execution

    private func execute(_ arguments: [String], timeout: Duration?) async throws -> String {
        guard let binary = KubectlBinaryResolver.resolve() else { throw CLIError.kubectlNotInstalled }
        let result = try await ProcessRunner.run(executable: binary, arguments: arguments, timeout: timeout)
        guard result.exitCode == 0 else {
            throw CLIError.command(exitCode: result.exitCode, stderr: Self.cleanStderr(result.stderr))
        }
        return result.stdout
    }

    /// kubectl warns about deprecated API versions and about reading a kubeconfig
    /// with loose permissions on almost every call. Those lines would bury the
    /// actual error in an alert.
    private static func cleanStderr(_ stderr: String) -> String {
        let kept = stderr
            .split(separator: "\n", omittingEmptySubsequences: true)
            .filter { !$0.hasPrefix("Warning:") && !$0.contains("WARNING: Kubernetes configuration file is") }
        return kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Locates `kubectl`. A GUI app launched from Finder has none of these on its
/// PATH, and Docker Desktop's copy in `/usr/local/bin` is as common as
/// Homebrew's.
enum KubectlBinaryResolver {
    static let defaultsKey = "kubectlBinaryPath"

    static let candidatePaths = [
        "/usr/local/bin/kubectl",
        "/opt/homebrew/bin/kubectl",
        "/usr/bin/kubectl",
    ]

    static var overridePath: String? {
        get { UserDefaults.standard.string(forKey: defaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }

    static func resolve() -> String? {
        if let override = overridePath,
           !override.isEmpty,
           FileManager.default.isExecutableFile(atPath: override) {
            return override
        }
        for path in candidatePaths where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }
}
