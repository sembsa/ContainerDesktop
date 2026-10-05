import Foundation

/// Apple's `container` CLI behind the `ContainerRuntime` interface.
///
/// A relocation, not a rewrite: every argument list below is the one
/// `ContainerStore`, `LogsView` and `StatsView` used to build themselves.
struct AppleRuntime: ContainerRuntime {
    let id = RuntimeKind.apple.rawValue
    let kind: RuntimeKind = .apple
    let sourceLabel: String? = nil
    let capabilities: RuntimeCapabilities = .apple
    let keepsLastListOnError = true
    private let cli: ContainerCLI

    init(cli: ContainerCLI = .shared) {
        self.cli = cli
    }

    var isInstalled: Bool { BinaryResolver.resolve() != nil }

    // MARK: - Listing

    func list(includeStopped: Bool) async throws -> [ContainerInfo] {
        let args = includeStopped ? ["ls", "-a"] : ["ls"]
        // Kubernetes node containers belong to the Kubernetes section; showing
        // them here invites deleting a cluster's control plane by mistake.
        return try await cli.json(args, as: [ContainerInfo].self)
            .filter { $0.configuration.labels?["com.apple.container.plugin"] != "k8s" }
    }

    func inspect(_ reference: String) async throws -> String {
        try await cli.run(["inspect", reference])
    }

    // MARK: - Lifecycle

    func start(_ reference: String) async throws {
        try await cli.run(["start", reference])
    }

    func stop(_ reference: String) async throws {
        try await cli.run(["stop", reference])
    }

    func kill(_ reference: String) async throws {
        try await cli.run(["kill", reference])
    }

    func restart(_ reference: String, wasRunning: Bool) async throws {
        if wasRunning {
            do {
                try await cli.run(["stop", reference])
            } catch let error as CLIError {
                guard Self.isAlreadyStoppedError(error) else { throw error }
            }
        }
        try await cli.run(["start", reference])
    }

    func remove(_ reference: String, force: Bool) async throws {
        var args = ["rm"]
        if force { args.append("--force") }
        args.append(reference)
        try await cli.run(args)
    }

    static func isAlreadyStoppedError(_ error: CLIError) -> Bool {
        guard case .command(_, let stderr) = error else { return false }
        let lower = stderr.lowercased()
        return lower.contains("not running") || lower.contains("already stopped") || lower.contains("stopped")
    }

    // MARK: - Logs

    func logs(_ reference: String, tail: LogTailLimit) -> AsyncThrowingStream<String, Error> {
        cli.stream(["logs"] + tail.arguments + ["--follow", reference])
    }

    func writeFullLog(_ reference: String, to path: String) async throws {
        let result = try await cli.runRedirecting(["logs", reference], outputPath: path)
        if result.exitCode != 0 {
            throw CLIError.command(exitCode: result.exitCode, stderr: result.stderr)
        }
    }

    // MARK: - Stats

    func stats(references: [String]?) async throws -> [StatsSample] {
        try await cli.json(
            ["stats", "--no-stream"] + (references ?? []),
            as: [StatsSample].self,
            timeout: .seconds(20)
        )
    }

    // MARK: - Files

    func listFiles(_ reference: String, path: String) async throws -> [FileEntry] {
        let output = try await cli.run(["exec", reference, "ls", "-la", path])
        return FileEntry.parse(lsOutput: output)
    }

    func copyIn(_ reference: String, localPath: String, destination: String) async throws {
        // `cp` first — it is the CLI's own path, and it handles cases the tar
        // fallback does not.
        let ran = (try? await cli.run(["cp", localPath, "\(reference):\(destination)"])) != nil

        // A zero exit status is not proof that anything was written. A container
        // created before the installed CLI runs an older guest agent, and on
        // 1.4.1 that agent accepts the upload, reports success, and writes
        // nothing. Look for the file rather than take the CLI's word for it.
        if ran, await ContainerCopyCheck.verify(
            containerID: reference, localPath: localPath, destination: destination
        ) != .missing {
            return
        }

        try await ContainerFileTransfer.upload(
            containerID: reference,
            localURL: URL(fileURLWithPath: localPath),
            destination: destination
        )

        if await ContainerCopyCheck.verify(
            containerID: reference, localPath: localPath, destination: destination
        ) == .missing {
            throw ContainerCopyCheck.silentFailure(destination: destination)
        }
    }

    func copyOut(_ reference: String, source: String, localPath: String) async throws {
        if (try? await cli.run(["cp", "\(reference):\(source)", localPath])) != nil { return }

        // `cp` reports "path not found" for files that plainly exist whenever the
        // container's guest agent is older than the installed CLI — which is
        // every container created before the last upgrade. `tar` over `exec`
        // still works, so the user gets their file instead of an explanation.
        try await ContainerFileTransfer.download(
            containerID: reference,
            source: source,
            to: URL(fileURLWithPath: localPath)
        )
    }

    func export(_ reference: String, to url: URL) async throws {
        try await cli.run(["export", "--output", url.path, reference])
    }

    // MARK: - Terminal

    func terminalTarget(_ reference: String) -> TerminalTarget {
        .container(id: reference)
    }

    // MARK: - Networks

    var networkActions: NetworkActions { .apple }

    func listNetworks() async throws -> [NetworkEntry] {
        try await cli.json(["network", "ls"], as: [NetworkInfo].self).map(NetworkEntry.init(apple:))
    }

    func inspectNetwork(_ reference: String) async throws -> String {
        try await cli.run(["network", "inspect", reference])
    }

    func createNetwork(name: String, subnet: String?, internalOnly: Bool) async throws {
        var args = ["network", "create"]
        if let subnet, !subnet.isEmpty { args.append(contentsOf: ["--subnet", subnet]) }
        if internalOnly { args.append("--internal") }
        args.append(name)
        try await cli.run(args)
    }

    func removeNetwork(_ reference: String) async throws {
        try await cli.run(["network", "rm", reference])
    }

    func pruneNetworks() async throws {
        try await cli.run(["network", "prune"])
    }

    // MARK: - Volumes

    var volumeActions: VolumeActions { .apple }

    func listVolumes() async throws -> [VolumeEntry] {
        let volumes = try await cli.json(["volume", "ls"], as: [VolumeInfo].self)
        // "Used by" and bind mounts come from the containers' mounts; the list
        // is decoration, so a failure there must not hide the volumes.
        let containers = (try? await cli.json(["ls", "-a"], as: [ContainerInfo].self)) ?? []
        return AppleVolumeMapper.entries(volumes: volumes, containers: containers)
    }

    func inspectVolume(_ reference: String) async throws -> String {
        try await cli.run(["volume", "inspect", reference])
    }

    func createVolume(name: String, size: String?) async throws {
        var args = ["volume", "create"]
        if let size, !size.isEmpty { args.append(contentsOf: ["-s", size]) }
        args.append(name)
        try await cli.run(args)
    }

    func removeVolume(_ reference: String) async throws {
        try await cli.run(["volume", "rm", reference])
    }

    func pruneVolumes() async throws {
        try await cli.run(["volume", "prune"])
    }
}
