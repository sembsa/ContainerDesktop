import Foundation

/// The `docker` CLI behind the `ContainerRuntime` interface.
///
/// All Docker-specific commands and parsing live here and in `DockerModels`.
/// Output is normalised into `ContainerInfo` / `StatsSample` / `FileEntry`, so
/// nothing above this layer knows it is talking to Docker.
///
/// An actor only because of `cpuClock` (see `stats`); every command is a
/// one-shot `ProcessRunner` call.
actor DockerRuntime: ContainerRuntime {
    nonisolated let id: String
    nonisolated let kind: RuntimeKind = .docker
    nonisolated let sourceLabel: String?
    nonisolated let capabilities: RuntimeCapabilities = .docker
    nonisolated let keepsLastListOnError = false

    /// Overridable for tests; production resolves lazily on every call so that
    /// installing Docker while the app runs is picked up.
    private let binaryOverride: String?

    /// Last integrated CPU counter per container: Docker reports a percentage,
    /// the app's charts and meters consume Apple-style cumulative microseconds.
    private var cpuClock: [String: (at: Date, microseconds: Int64)] = [:]

    /// `nil` = the local Docker Desktop engine; otherwise a machine reached
    /// through an SSH tunnel.
    private let endpoint: DockerEndpoint?
    private let tunnels: SSHTunnelManager

    init(binary: String? = nil, endpoint: DockerEndpoint? = nil, tunnels: SSHTunnelManager = .shared) {
        self.binaryOverride = binary
        self.endpoint = endpoint
        self.tunnels = tunnels
        self.id = endpoint?.runtimeID ?? RuntimeKind.docker.rawValue
        self.sourceLabel = endpoint?.label
    }

    nonisolated var isInstalled: Bool { binary != nil }

    /// Tags what the mapper produced with this runtime's identity.
    private nonisolated func tagged(_ list: [ContainerInfo]) -> [ContainerInfo] {
        guard let sourceLabel else { return list }
        let engine: ContainerEngine = endpoint?.engine == .colima ? .colima : .docker
        return list.map { $0.with(runtimeID: id, machineLabel: sourceLabel, engine: engine) }
    }

    /// `-H unix://<tunnel>` for an external machine, nothing for the local one.
    private func hostArguments() async throws -> [String] {
        guard let endpoint else { return [] }
        return ["-H", "unix://" + (try await tunnels.socketPath(for: endpoint))]
    }

    private nonisolated func currentHost() -> String? {
        guard let endpoint, let socket = tunnels.currentSocket(for: endpoint) else { return nil }
        return "unix://" + socket
    }

    private nonisolated var binary: String? {
        binaryOverride ?? DockerBinaryResolver.resolve()
    }

    // MARK: - Process plumbing

    @discardableResult
    private func run(_ arguments: [String], timeout: Duration? = .seconds(60)) async throws -> String {
        guard let binary else { throw Self.notInstalled }
        let host = try await hostArguments()
        let result = try await ProcessRunner.run(executable: binary, arguments: host + arguments, timeout: timeout)
        guard result.exitCode == 0 else {
            throw CLIError.from(exitCode: result.exitCode, stderr: result.stderr, stdout: result.stdout)
        }
        return result.stdout
    }

    static let notInstalled = CLIError.command(
        exitCode: -1,
        stderr: "docker: command not found. Install Docker Desktop or set dockerBinaryPath."
    )

    /// The engine's own id, to tell apart two sockets that lead to one engine.
    func engineID() async throws -> String {
        try await run(["info", "--format", "{{.ID}}"], timeout: .seconds(20))
    }

    /// Server version, to prove the engine is reachable (Test connection).
    func ping() async throws -> String {
        try await run(["version", "--format", "{{.Server.Version}}"], timeout: .seconds(25))
    }

    // MARK: - Listing

    func list(includeStopped: Bool) async throws -> [ContainerInfo] {
        let psOutput = try await run(
            ["ps"] + (includeStopped ? ["-a"] : []) + ["--no-trunc", "--format", "{{json .}}"],
            timeout: .seconds(20)
        )
        let rows = try DockerPSRow.decodeLines(psOutput)
        guard !rows.isEmpty else { return [] }

        // `ps` has no mounts, env, IPs or creation time. One `inspect` for all
        // the ids fills them in; if it fails the plain `ps` rows still show.
        let ids = rows.map(\.ID)
        guard let inspectOutput = try? await run(["container", "inspect"] + ids, timeout: .seconds(30)),
              let inspected = try? DockerInspect.decodeArray(inspectOutput) else {
            return tagged(rows.map(DockerContainerMapper.map(_:)))
        }
        let architectures = await imageArchitectures(Set(inspected.compactMap(\.Image)))
        let byID = Dictionary(inspected.map { ($0.Id, $0) }, uniquingKeysWith: { first, _ in first })
        return tagged(rows.map { row in
            if let inspect = byID[row.ID] ?? inspected.first(where: { $0.Id.hasPrefix(row.ID) }) {
                return DockerContainerMapper.map(inspect, architectures: architectures)
            }
            return DockerContainerMapper.map(row)
        })
    }

    /// image id -> architecture, one call for all images. Best effort.
    private func imageArchitectures(_ imageIDs: Set<String>) async -> [String: String] {
        guard !imageIDs.isEmpty,
              let output = try? await run(
                ["image", "inspect", "--format", "{{.Id}} {{.Architecture}}"] + imageIDs.sorted(),
                timeout: .seconds(20)
              ) else { return [:] }
        var result: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ")
            if parts.count == 2 { result[String(parts[0])] = String(parts[1]) }
        }
        return result
    }

    func inspect(_ reference: String) async throws -> String {
        try await run(["container", "inspect", reference])
    }

    // MARK: - Lifecycle

    func start(_ reference: String) async throws {
        try await run(["start", reference])
    }

    func stop(_ reference: String) async throws {
        try await run(["stop", reference], timeout: .seconds(90))
    }

    func kill(_ reference: String) async throws {
        try await run(["kill", reference])
    }

    func restart(_ reference: String, wasRunning: Bool) async throws {
        try await run(["restart", reference], timeout: .seconds(120))
    }

    func remove(_ reference: String, force: Bool) async throws {
        try await run(["rm"] + (force ? ["--force"] : []) + [reference])
    }

    // MARK: - Logs

    nonisolated func logs(_ reference: String, tail: LogTailLimit) -> AsyncThrowingStream<String, Error> {
        guard let binary else { return AsyncThrowingStream { $0.finish(throwing: Self.notInstalled) } }
        // Exactly N lines, unlike Apple's CLI which needs N+1 to survive a cut
        // first line; `LogsView` only drops the first line when more than N arrive.
        let amount = tail == .all ? "all" : "\(tail.rawValue)"
        let arguments = ["logs", "--tail", amount, "--follow", reference]
        guard endpoint != nil else {
            return ProcessLineReader(binary: binary, arguments: arguments).lines()
        }
        // An external machine needs its tunnel first; open it, then relay.
        return AsyncThrowingStream { continuation in
            let relay = Task {
                do {
                    let host = try await self.hostArguments()
                    for try await line in ProcessLineReader(binary: binary, arguments: host + arguments).lines() {
                        continuation.yield(line)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in relay.cancel() }
        }
    }

    func writeFullLog(_ reference: String, to path: String) async throws {
        guard let binary else { throw Self.notInstalled }
        // `docker logs` writes the container's stderr to its own stderr. Merging
        // both into the file needs a shell redirect; arguments are passed
        // positionally so nothing is interpolated into the script.
        let host = try await hostArguments()
        let result = try await ProcessRunner.run(
            executable: "/bin/sh",
            arguments: ["-c", "exec \"$@\" > \"$0\" 2>&1", path, binary] + host + ["logs", reference],
            timeout: .seconds(600)
        )
        if result.exitCode != 0 {
            throw CLIError.command(exitCode: result.exitCode, stderr: result.stderr)
        }
    }

    // MARK: - Stats

    func stats(references: [String]?) async throws -> [StatsSample] {
        let output = try await run(
            ["stats", "--no-stream", "--format", "{{json .}}"] + (references ?? []),
            timeout: .seconds(30)
        )
        let rows = try DockerStatsRow.decodeLines(output)
        let now = Date()
        var samples: [StatsSample] = []
        for row in rows {
            let percent = DockerContainerMapper.parsePercent(row.CPUPerc) ?? 0
            let previous = cpuClock[row.Name]
            var microseconds = previous?.microseconds ?? 0
            if let previous {
                // 100% means one core fully busy, the same scale the store uses
                // for Apple's counter.
                let elapsed = max(0, now.timeIntervalSince(previous.at))
                microseconds += Int64(percent / 100 * elapsed * 1_000_000)
            }
            cpuClock[row.Name] = (now, microseconds)
            samples.append(DockerContainerMapper.map(row, cpuMicroseconds: microseconds))
        }
        if references == nil {
            let alive = Set(rows.map(\.Name))
            cpuClock = cpuClock.filter { alive.contains($0.key) }
        }
        return samples
    }

    // MARK: - Files

    func listFiles(_ reference: String, path: String) async throws -> [FileEntry] {
        let output = try await run(["exec", reference, "ls", "-la", path])
        return FileEntry.parse(lsOutput: output)
    }

    func copyIn(_ reference: String, localPath: String, destination: String) async throws {
        try await run(["cp", localPath, "\(reference):\(destination)"], timeout: .seconds(600))
    }

    func copyOut(_ reference: String, source: String, localPath: String) async throws {
        try await run(["cp", "\(reference):\(source)", localPath], timeout: .seconds(600))
    }

    func export(_ reference: String, to url: URL) async throws {
        try await run(["export", "--output", url.path, reference], timeout: .seconds(600))
    }

    // MARK: - Networks

    /// Local Docker can create and remove; prune is not offered (see `NetworkActions.docker`).
    /// A DockerRuntime built for an endpoint belongs to an external machine and is read-only.
    nonisolated var networkActions: NetworkActions { endpoint == nil ? .docker : .none }

    func listNetworks() async throws -> [NetworkEntry] {
        let lsOutput = try await run(["network", "ls", "--no-trunc", "--format", "{{json .}}"], timeout: .seconds(20))
        let rows = try DockerNetworkRow.decodeLines(lsOutput)
        guard !rows.isEmpty else { return [] }
        // `ls` has no subnets, gateways or members; one `inspect` for all of
        // them adds those. If it fails the plain rows still show.
        let entries: [NetworkEntry]
        if let output = try? await run(["network", "inspect"] + rows.map(\.ID), timeout: .seconds(20)),
           let inspected = try? DockerNetworkInspect.decodeArray(output), !inspected.isEmpty {
            entries = inspected.map(DockerNetworkMapper.map(_:))
        } else {
            entries = rows.map(DockerNetworkMapper.map(_:))
        }
        guard let sourceLabel else { return entries }
        let engine: ContainerEngine = endpoint?.engine == .colima ? .colima : .docker
        return entries.map { $0.with(runtimeID: id, machineLabel: sourceLabel, engine: engine) }
    }

    func inspectNetwork(_ reference: String) async throws -> String {
        try await run(["network", "inspect", reference], timeout: .seconds(20))
    }

    func createNetwork(name: String, subnet: String?, internalOnly: Bool) async throws {
        guard networkActions.contains(.create) else { throw CLIError.networkActionUnsupported }
        var args = ["network", "create"]
        if let subnet, !subnet.isEmpty { args.append(contentsOf: ["--subnet", subnet]) }
        if internalOnly { args.append("--internal") }
        args.append(name)
        try await run(args)
    }

    func removeNetwork(_ reference: String) async throws {
        guard networkActions.contains(.remove), !DockerNetworkMapper.builtInNames.contains(reference) else {
            throw CLIError.networkActionUnsupported
        }
        try await run(["network", "rm", reference])
    }

    // MARK: - Volumes

    /// Local Docker can create and remove; prune is not offered (like networks).
    /// A DockerRuntime built for an endpoint belongs to an external machine and is read-only.
    nonisolated var volumeActions: VolumeActions { endpoint == nil ? .docker : .none }

    /// `docker system df -v` walks every volume to size it, so it is not asked
    /// on every 3 s tick.
    private var cachedSizes: (at: Date, sizes: [String: Int64])?
    private static let sizeTTL: TimeInterval = 60

    func listVolumes() async throws -> [VolumeEntry] {
        let lsOutput = try await run(["volume", "ls", "--format", "{{json .}}"], timeout: .seconds(20))
        let rows = try DockerVolumeRow.decodeLines(lsOutput)

        // Everything below only adds detail; a failure leaves the plain rows.
        var inspected: [DockerVolumeInspect] = []
        if !rows.isEmpty,
           let output = try? await run(["volume", "inspect"] + rows.map(\.Name), timeout: .seconds(20)) {
            inspected = (try? DockerVolumeInspect.decodeArray(output)) ?? []
        }
        let sizes = rows.isEmpty ? [:] : await volumeSizes()
        let mounts = await containerMounts()

        let entries = DockerVolumeMapper.entries(rows: rows, inspected: inspected, sizes: sizes, mounts: mounts)
        guard let sourceLabel else { return entries }
        let engine: ContainerEngine = endpoint?.engine == .colima ? .colima : .docker
        return entries.map { $0.with(runtimeID: id, machineLabel: sourceLabel, engine: engine) }
    }

    private func volumeSizes() async -> [String: Int64] {
        if let cachedSizes, Date().timeIntervalSince(cachedSizes.at) < Self.sizeTTL { return cachedSizes.sizes }
        guard let output = try? await run(["system", "df", "-v", "--format", "json"], timeout: .seconds(30)),
              let df = try? DockerSystemDF.decode(output) else { return cachedSizes?.sizes ?? [:] }
        cachedSizes = (Date(), df.sizes)
        return df.sizes
    }

    private func containerMounts() async -> [DockerContainerMounts] {
        guard let idsOutput = try? await run(["container", "ls", "-a", "-q", "--no-trunc"], timeout: .seconds(20)) else { return [] }
        let ids = idsOutput.split(whereSeparator: \.isNewline).map(String.init)
        guard !ids.isEmpty,
              let output = try? await run(
                ["container", "inspect", "--format", "{{.Name}}{{\"\\t\"}}{{json .Mounts}}"] + ids,
                timeout: .seconds(20)
              ) else { return [] }
        return DockerContainerMounts.parse(output)
    }

    func inspectVolume(_ reference: String) async throws -> String {
        try await run(["volume", "inspect", reference], timeout: .seconds(20))
    }

    func createVolume(name: String, size: String?) async throws {
        guard volumeActions.contains(.create) else { throw CLIError.volumeActionUnsupported }
        try await run(["volume", "create", name])
        cachedSizes = nil
    }

    func removeVolume(_ reference: String) async throws {
        guard volumeActions.contains(.remove) else { throw CLIError.volumeActionUnsupported }
        try await run(["volume", "rm", reference])
        cachedSizes = nil
    }

    // MARK: - Terminal

    nonisolated func terminalTarget(_ reference: String) -> TerminalTarget {
        .dockerContainer(id: reference, host: currentHost())
    }
}
