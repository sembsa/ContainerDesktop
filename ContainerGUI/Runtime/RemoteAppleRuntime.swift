import Foundation

/// Apple's `container` CLI on a remote machine, driven over SSH. Same mapping
/// as `AppleRuntime`, but every command is `ssh <target> <binary> ...`.
///
/// Copying files in or out and exporting need a local counterpart of the remote
/// CLI and are not offered; listing, inspect, lifecycle, logs, stats and a
/// directory listing are.
struct RemoteAppleRuntime: Sendable {
    let endpoint: DockerEndpoint
    /// Absolute path of the remote `container` binary. Never a bare name: a
    /// non-interactive ssh session has no Homebrew directory on its PATH.
    let binary: String

    private static let ssh = "/usr/bin/ssh"

    /// Finds the remote `container` binary by absolute candidate path
    /// (`/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin`), then `command -v`.
    /// Read-only. Returns nil when the machine has no Apple `container` CLI.
    static func locate(endpoint: DockerEndpoint) async throws -> String? {
        let result = try await ProcessRunner.run(
            executable: ssh,
            arguments: SSHCommand.probe(endpoint: endpoint),
            input: RemoteEngineProbe.script,
            timeout: .seconds(30)
        )
        guard result.exitCode == 0 else {
            throw CLIError.from(exitCode: result.exitCode, stderr: result.stderr, stdout: result.stdout)
        }
        return RemoteEngineProbe.parse(result.stdout).appleBinary
    }

    private func run(_ arguments: [String], timeout: Duration? = .seconds(60)) async throws -> String {
        guard binary.hasPrefix("/") else {
            throw CLIError.command(exitCode: -1, stderr: String(localized: "Na maszynie nie znaleziono polecenia container."))
        }
        let result = try await ProcessRunner.run(
            executable: Self.ssh,
            arguments: SSHCommand.remote(endpoint: endpoint, command: [binary] + arguments),
            timeout: timeout
        )
        guard result.exitCode == 0 else {
            throw CLIError.from(exitCode: result.exitCode, stderr: result.stderr, stdout: result.stdout)
        }
        return result.stdout
    }

    func list(includeStopped: Bool) async throws -> [ContainerInfo] {
        let output = try await run(["ls"] + (includeStopped ? ["-a"] : []) + ["--format", "json"], timeout: .seconds(25))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode([ContainerInfo].self, from: Data(output.utf8))
                .filter { $0.configuration.labels?["com.apple.container.plugin"] != "k8s" }
        } catch {
            throw CLIError.decoding(String(describing: error))
        }
    }

    func inspect(_ reference: String) async throws -> String { try await run(["inspect", reference]) }

    // MARK: Networks (read-only)

    func listNetworks() async throws -> [NetworkEntry] {
        let output = try await run(["network", "ls", "--format", "json"], timeout: .seconds(25))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode([NetworkInfo].self, from: Data(output.utf8)).map(NetworkEntry.init(apple:))
        } catch {
            throw CLIError.decoding(String(describing: error))
        }
    }

    func inspectNetwork(_ reference: String) async throws -> String {
        try await run(["network", "inspect", reference], timeout: .seconds(25))
    }

    // MARK: Volumes (read-only)

    func listVolumes() async throws -> [VolumeEntry] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let output = try await run(["volume", "ls", "--format", "json"], timeout: .seconds(25))
        let volumes: [VolumeInfo]
        do {
            volumes = try decoder.decode([VolumeInfo].self, from: Data(output.utf8))
        } catch {
            throw CLIError.decoding(String(describing: error))
        }
        let containers = (try? await list(includeStopped: true)) ?? []
        return AppleVolumeMapper.entries(volumes: volumes, containers: containers)
    }

    func inspectVolume(_ reference: String) async throws -> String {
        try await run(["volume", "inspect", reference], timeout: .seconds(25))
    }

    func start(_ reference: String) async throws { try await run(["start", reference]) }
    func stop(_ reference: String) async throws { try await run(["stop", reference], timeout: .seconds(90)) }
    func kill(_ reference: String) async throws { try await run(["kill", reference]) }

    func restart(_ reference: String, wasRunning: Bool) async throws {
        if wasRunning {
            do { try await run(["stop", reference], timeout: .seconds(90)) }
            catch let error as CLIError { guard AppleRuntime.isAlreadyStoppedError(error) else { throw error } }
        }
        try await run(["start", reference])
    }

    func remove(_ reference: String, force: Bool) async throws {
        try await run(["rm"] + (force ? ["--force"] : []) + [reference])
    }

    func logs(_ reference: String, tail: LogTailLimit) -> AsyncThrowingStream<String, Error> {
        // Apple's CLI needs the N+1 trick (see `LogTailLimit.arguments`).
        ProcessLineReader(
            binary: Self.ssh,
            arguments: SSHCommand.remote(endpoint: endpoint, command: [binary, "logs"] + tail.arguments + ["--follow", reference])
        ).lines()
    }

    func writeFullLog(_ reference: String, to path: String) async throws {
        let result = try await ProcessRunner.run(
            executable: Self.ssh,
            arguments: SSHCommand.remote(endpoint: endpoint, command: [binary, "logs", reference]),
            outputPath: path,
            timeout: .seconds(600)
        )
        if result.exitCode != 0 { throw CLIError.command(exitCode: result.exitCode, stderr: result.stderr) }
    }

    func stats(references: [String]?) async throws -> [StatsSample] {
        let output = try await run(["stats", "--no-stream", "--format", "json"] + (references ?? []), timeout: .seconds(25))
        do { return try JSONDecoder().decode([StatsSample].self, from: Data(output.utf8)) }
        catch { throw CLIError.decoding(String(describing: error)) }
    }

    func listFiles(_ reference: String, path: String) async throws -> [FileEntry] {
        FileEntry.parse(lsOutput: try await run(["exec", reference, "ls", "-la", path]))
    }

    func terminalTarget(_ reference: String) -> TerminalTarget {
        .sshCommand(arguments: SSHCommand.remote(endpoint: endpoint, command: [binary, "exec", "-it", reference, "sh"], tty: true))
    }

    static var unsupported: CLIError {
        .command(exitCode: -1, stderr: String(localized: "Ta operacja nie jest dostępna dla kontenerów Apple na maszynie zewnętrznej."))
    }
}
