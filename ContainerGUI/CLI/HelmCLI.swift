import Foundation

/// The single point of contact with the `helm` binary.
///
/// **Cluster isolation is the whole point of this type.** `helm` otherwise acts
/// on whatever `~/.kube/config` currently points at — which, for anyone running
/// this app, is likely a real cluster at work. `container k8s create` even
/// rewrites that file and switches the current context to the new local cluster.
/// So commands that touch a cluster take a `ClusterTarget` and always pass both
/// `--kubeconfig` and `--kube-context`; the app-managed kubeconfig it names is
/// written by `container k8s write-config` and holds nothing else.
///
/// `--kube-context` is not optional: the file `write-config` produces has no
/// `current-context` set, so `--kubeconfig` alone fails with
/// "kubernetes cluster unreachable ... localhost:8080".
///
/// Commands that need no cluster (repository management, chart search) go
/// through the `repo`-prefixed methods, which never see a target.
actor HelmCLI {
    static let shared = HelmCLI()

    /// Where a helm command is allowed to act. Constructing one requires a
    /// cluster name, so there is no way to spell "whatever kubectl points at".
    struct ClusterTarget: Sendable, Hashable {
        let cluster: String
        let kubeconfigPath: String

        var arguments: [String] {
            ["--kubeconfig", kubeconfigPath, "--kube-context", cluster]
        }
    }

    private let decoder = JSONDecoder()

    /// Helm operations legitimately take minutes (`install --wait` pulls images
    /// inside the cluster), so the default is far longer than ContainerCLI's.
    static let defaultTimeout: Duration = .seconds(300)

    // MARK: - Availability

    /// Path to `helm`, or nil when it isn't installed.
    nonisolated static func binaryPath() -> String? { HelmBinaryResolver.resolve() }

    nonisolated static var isInstalled: Bool { binaryPath() != nil }

    // MARK: - Cluster-scoped commands

    @discardableResult
    func run(
        _ arguments: [String],
        on target: ClusterTarget,
        timeout: Duration? = HelmCLI.defaultTimeout
    ) async throws -> String {
        try await execute(arguments + target.arguments, timeout: timeout)
    }

    func json<T: Decodable>(
        _ arguments: [String],
        on target: ClusterTarget,
        as type: T.Type = T.self,
        timeout: Duration? = HelmCLI.defaultTimeout
    ) async throws -> T {
        try await decode(arguments + ["-o", "json"] + target.arguments, timeout: timeout)
    }

    /// Line stream for long operations (`install`, `upgrade`) so the sheet can
    /// show progress instead of freezing on a five-minute call.
    nonisolated func stream(_ arguments: [String], on target: ClusterTarget) -> AsyncThrowingStream<String, Error> {
        guard let binary = HelmBinaryResolver.resolve() else {
            return AsyncThrowingStream { $0.finish(throwing: CLIError.helmNotInstalled) }
        }
        return ProcessLineReader(
            binary: binary,
            arguments: arguments + target.arguments,
            failOnNonZeroExit: true
        ).lines()
    }

    // MARK: - Cluster-free commands (repositories, chart metadata)

    @discardableResult
    func runRepo(_ arguments: [String], timeout: Duration? = HelmCLI.defaultTimeout) async throws -> String {
        try await execute(arguments, timeout: timeout)
    }

    func jsonRepo<T: Decodable>(
        _ arguments: [String],
        as type: T.Type = T.self,
        timeout: Duration? = HelmCLI.defaultTimeout
    ) async throws -> T {
        try await decode(arguments + ["-o", "json"], timeout: timeout)
    }

    // MARK: - Execution

    private func execute(_ arguments: [String], timeout: Duration?) async throws -> String {
        guard let binary = HelmBinaryResolver.resolve() else { throw CLIError.helmNotInstalled }
        let result = try await ProcessRunner.run(executable: binary, arguments: arguments, timeout: timeout)
        guard result.exitCode == 0 else {
            throw CLIError.command(exitCode: result.exitCode, stderr: Self.cleanStderr(result.stderr))
        }
        return result.stdout
    }

    private func decode<T: Decodable>(_ arguments: [String], timeout: Duration?) async throws -> T {
        let output = try await execute(arguments, timeout: timeout)
        // `helm list` on an empty cluster prints nothing at all rather than "[]".
        guard let data = output.data(using: .utf8), !data.isEmpty else {
            if let empty = [] as? T { return empty }
            throw CLIError.decoding(String(localized: "pusta odpowiedź"))
        }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw CLIError.decoding(String(describing: error))
        }
    }

    /// helm writes structured warnings about unrelated repositories to stderr on
    /// almost every call (`level=WARN msg="repo is corrupt or missing"`). They
    /// would drown the actual error in the alert, so drop them.
    private static func cleanStderr(_ stderr: String) -> String {
        let kept = stderr
            .split(separator: "\n", omittingEmptySubsequences: true)
            .filter { !$0.hasPrefix("level=WARN") }
        return kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Locates `helm`. Homebrew on Apple silicon installs to `/opt/homebrew/bin`,
/// which a GUI app launched from Finder does not have on its PATH.
enum HelmBinaryResolver {
    static let defaultsKey = "helmBinaryPath"

    static let candidatePaths = [
        "/opt/homebrew/bin/helm",
        "/usr/local/bin/helm",
        "/usr/bin/helm",
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
