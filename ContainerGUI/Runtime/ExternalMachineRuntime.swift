import Foundation
import os

/// One external machine as a single `ContainerRuntime`, however many engines it
/// runs.
///
/// With the engine type `auto` the machine is probed (`RemoteEngineProbe`) and
/// every engine that answers is listed and merged: the remote docker CLI's
/// current context, Docker Desktop, each Colima profile, a plain
/// `/var/run/docker.sock`, and Apple's `container` CLI. Each container comes
/// back tagged with the machine label and the engine (machineLabel "studio", engine Colima).
///
/// Everything engine-specific stays in here. A container's `reference` carries
/// the engine it belongs to (`<engine key> <name>`), so the store and views
/// keep treating it as an opaque string.
final class ExternalMachineRuntime: ContainerRuntime, @unchecked Sendable {
    /// Backend behind one detected engine.
    enum Backend: Sendable {
        case docker(DockerRuntime)
        case apple(RemoteAppleRuntime)
    }

    struct Engine: Sendable {
        let key: String      // socket path, or "apple"
        let title: String    // "Colima", "Docker Desktop", "Apple"
        let backend: Backend
    }

    let endpoint: DockerEndpoint
    let id: String
    let kind: RuntimeKind = .docker
    let sourceLabel: String?
    let capabilities: RuntimeCapabilities = .none
    let keepsLastListOnError = false

    private let tunnels: SSHTunnelManager
    private let state = OSAllocatedUnfairLock(initialState: State())

    private struct State {
        var engines: [Engine] = []
        var detectedAt: Date?
        var detection: Task<[Engine], Error>?
    }

    private static let redetectAfter: TimeInterval = 120
    private static let separator: Character = "\u{1F}"

    init(endpoint: DockerEndpoint, tunnels: SSHTunnelManager = .shared) {
        self.endpoint = endpoint
        self.id = Self.runtimeKey(for: endpoint)
        self.sourceLabel = endpoint.label
        self.tunnels = tunnels
    }

    var isInstalled: Bool { DockerBinaryResolver.resolve() != nil || endpoint.engine == .appleContainer }

    /// The runtime id of the machine behind `endpoint` (`ContainerInfo.runtimeKey`).
    static func runtimeKey(for endpoint: DockerEndpoint) -> String { "machine:\(endpoint.id.uuidString)" }

    // MARK: - Reference encoding

    static func encode(engine key: String, name: String) -> String { "\(key)\(separator)\(name)" }

    static func decode(_ reference: String) -> (engine: String, name: String)? {
        guard let index = reference.firstIndex(of: separator) else { return nil }
        return (String(reference[..<index]), String(reference[reference.index(after: index)...]))
    }

    private func resolve(_ reference: String) throws -> (Engine, String) {
        guard let (key, name) = Self.decode(reference),
              let engine = state.withLock({ $0.engines.first { $0.key == key } }) else {
            throw CLIError.command(exitCode: -1, stderr: String(localized: "Silnik na maszynie zewnętrznej nie jest już dostępny. Odśwież listę."))
        }
        return (engine, name)
    }

    // MARK: - Detection

    /// Engines currently known, detecting them first when needed. Concurrent
    /// callers share one detection.
    func engines(forceRefresh: Bool = false) async throws -> [Engine] {
        let task: Task<[Engine], Error> = state.withLock { state in
            if !forceRefresh, let detectedAt = state.detectedAt, !state.engines.isEmpty,
               Date().timeIntervalSince(detectedAt) < Self.redetectAfter {
                let known = state.engines
                return Task { known }
            }
            if let running = state.detection { return running }
            let created = Task { try await self.detect() }
            state.detection = created
            return created
        }
        defer { state.withLock { $0.detection = nil } }
        let found = try await task.value
        state.withLock { $0.engines = found; $0.detectedAt = Date() }
        return found
    }

    private func detect() async throws -> [Engine] {
        switch endpoint.engine {
        case .dockerDesktop, .colima, .ssh:
            let socket = endpoint.effectiveSocketPath
            return [dockerEngine(socket: socket, home: nil)]

        case .appleContainer:
            let probe = try await runProbe()
            guard let binary = probe.appleBinary else {
                throw CLIError.command(exitCode: -1, stderr: String(localized: "Na maszynie nie znaleziono polecenia container."))
            }
            return [appleEngine(binary: binary)]

        case .auto:
            let probe = try await runProbe()
            let extra = endpoint.remoteSocketPath?.trimmingCharacters(in: .whitespaces)
            var found: [Engine] = []

            // Several paths can lead to one engine (`/var/run/docker.sock` is
            // usually a link to Docker Desktop's). Ask each who it is and keep
            // the first of every distinct engine id.
            let candidates = RemoteEngineProbe.candidates(from: probe, extra: extra?.isEmpty == true ? nil : extra)
            let identified = await withTaskGroup(of: (Int, Engine, String?)?.self) { group in
                for (index, socket) in candidates.enumerated() {
                    group.addTask {
                        var engine = self.dockerEngine(socket: socket, home: probe.home)
                        // A path like /Users/Shared/x/.run/docker.sock says nothing
                        // about the engine; the CLI's context name does.
                        if socket == probe.contextSocket, engine.title == "Docker",
                           let named = RemoteEngineProbe.engineTitle(forContext: probe.contextName) {
                            engine = Engine(key: engine.key, title: named, backend: engine.backend)
                        }
                        guard case .docker(let runtime) = engine.backend,
                              let identity = try? await Deadline.run(.seconds(25), { try await runtime.engineID() })
                        else { return nil }
                        return (index, engine, identity)
                    }
                }
                var all: [(Int, Engine, String?)] = []
                for await item in group { if let item { all.append(item) } }
                return all.sorted { $0.0 < $1.0 }
            }
            var seenIdentities = Set<String>()
            for (_, engine, identity) in identified {
                if let identity, !identity.isEmpty, !seenIdentities.insert(identity).inserted { continue }
                found.append(engine)
            }
            if let binary = probe.appleBinary { found.append(appleEngine(binary: binary)) }
            guard !found.isEmpty else {
                throw CLIError.command(exitCode: -1, stderr: String(localized: "Nie wykryto żadnego silnika kontenerów dostępnego dla tego użytkownika SSH."))
            }
            return found
        }
    }

    private func dockerEngine(socket: String, home: String?) -> Engine {
        var derived = endpoint
        derived.engine = .ssh
        derived.remoteSocketPath = socket
        let title = endpoint.engine == .auto || home != nil
            ? RemoteEngineProbe.engineTitle(forSocket: socket, home: home)
            : (endpoint.engine == .ssh ? "Docker" : endpoint.engine == .colima ? "Colima" : "Docker Desktop")
        return Engine(key: socket, title: title, backend: .docker(DockerRuntime(endpoint: derived, tunnels: tunnels)))
    }

    private func appleEngine(binary: String) -> Engine {
        Engine(key: "apple", title: "Apple", backend: .apple(RemoteAppleRuntime(endpoint: endpoint, binary: binary)))
    }

    private func runProbe() async throws -> RemoteEngineProbe.Result {
        let result = try await ProcessRunner.run(
            executable: "/usr/bin/ssh",
            arguments: SSHCommand.probe(endpoint: endpoint),
            input: RemoteEngineProbe.script,
            timeout: .seconds(30)
        )
        guard result.exitCode == 0 else {
            throw CLIError.from(exitCode: result.exitCode, stderr: result.stderr, stdout: result.stdout)
        }
        return RemoteEngineProbe.parse(result.stdout)
    }

    /// What "Test connection" shows: the engines that answered.
    func ping() async throws -> String {
        let found = try await engines(forceRefresh: true)
        var answering: [String] = []
        for engine in found {
            switch engine.backend {
            case .docker(let runtime):
                if (try? await Deadline.run(.seconds(25), { try await runtime.ping() })) != nil { answering.append(engine.title) }
            case .apple(let runtime):
                if (try? await Deadline.run(.seconds(25), { try await runtime.list(includeStopped: false) })) != nil { answering.append(engine.title) }
            }
        }
        guard !answering.isEmpty else {
            throw CLIError.command(exitCode: -1, stderr: String(localized: "Silniki wykryto, ale żaden nie odpowiada."))
        }
        return answering.joined(separator: ", ")
    }

    // MARK: - Listing

    func list(includeStopped: Bool) async throws -> [ContainerInfo] {
        let found = try await engines()
        let outcomes = await withTaskGroup(of: (Engine, Result<[ContainerInfo], Error>).self) { group in
            for engine in found {
                group.addTask {
                    do {
                        let list: [ContainerInfo]
                        switch engine.backend {
                        case .docker(let runtime): list = try await runtime.list(includeStopped: includeStopped)
                        case .apple(let runtime): list = try await runtime.list(includeStopped: includeStopped)
                        }
                        return (engine, .success(list))
                    } catch { return (engine, .failure(error)) }
                }
            }
            var all: [(Engine, Result<[ContainerInfo], Error>)] = []
            for await item in group { all.append(item) }
            return all
        }

        var merged: [ContainerInfo] = []
        var firstError: Error?
        for engine in found {
            guard let outcome = outcomes.first(where: { $0.0.key == engine.key })?.1 else { continue }
            switch outcome {
            case .success(let list):
                for container in list {
                    merged.append(container.with(
                        reference: Self.encode(engine: engine.key, name: container.reference),
                        runtimeID: id,
                        machineLabel: endpoint.label,
                        engine: ContainerEngine(engineTitle: engine.title)
                    ))
                }
            case .failure(let error):
                firstError = firstError ?? error
            }
        }
        // A failure may mean the engine set changed (Colima stopped, a profile
        // started): look again next time.
        if firstError != nil { state.withLock { $0.detectedAt = nil } }
        if merged.isEmpty, let firstError { throw firstError }
        return merged
    }

    // MARK: - Networks (read-only)

    /// Networks of every engine on the machine, merged like `list`. An engine
    /// that fails does not hide the others; only when all fail is it an error.
    func listNetworks() async throws -> [NetworkEntry] {
        let found = try await engines()
        let outcomes = await withTaskGroup(of: (Engine, Result<[NetworkEntry], Error>).self) { group in
            for engine in found {
                group.addTask {
                    do {
                        let list: [NetworkEntry]
                        switch engine.backend {
                        case .docker(let runtime): list = try await runtime.listNetworks()
                        case .apple(let runtime): list = try await runtime.listNetworks()
                        }
                        return (engine, .success(list))
                    } catch { return (engine, .failure(error)) }
                }
            }
            var all: [(Engine, Result<[NetworkEntry], Error>)] = []
            for await item in group { all.append(item) }
            return all
        }

        var merged: [NetworkEntry] = []
        var firstError: Error?
        var anySucceeded = false
        for engine in found {
            guard let outcome = outcomes.first(where: { $0.0.key == engine.key })?.1 else { continue }
            switch outcome {
            case .success(let list):
                anySucceeded = true
                for network in list {
                    merged.append(network.with(
                        reference: Self.encode(engine: engine.key, name: network.reference),
                        runtimeID: id,
                        machineLabel: endpoint.label,
                        engine: ContainerEngine(engineTitle: engine.title)
                    ))
                }
            case .failure(let error):
                firstError = firstError ?? error
            }
        }
        if firstError != nil { state.withLock { $0.detectedAt = nil } }
        if !anySucceeded, let firstError { throw firstError }
        return merged
    }

    func inspectNetwork(_ reference: String) async throws -> String {
        let (engine, name) = try resolve(reference)
        switch engine.backend {
        case .docker(let r): return try await r.inspectNetwork(name)
        case .apple(let r): return try await r.inspectNetwork(name)
        }
    }

    // MARK: - Volumes (read-only)

    /// Volumes of every engine on the machine, merged like `listNetworks`.
    func listVolumes() async throws -> [VolumeEntry] {
        let found = try await engines()
        let outcomes = await withTaskGroup(of: (Engine, Result<[VolumeEntry], Error>).self) { group in
            for engine in found {
                group.addTask {
                    do {
                        let list: [VolumeEntry]
                        switch engine.backend {
                        case .docker(let runtime): list = try await runtime.listVolumes()
                        case .apple(let runtime): list = try await runtime.listVolumes()
                        }
                        return (engine, .success(list))
                    } catch { return (engine, .failure(error)) }
                }
            }
            var all: [(Engine, Result<[VolumeEntry], Error>)] = []
            for await item in group { all.append(item) }
            return all
        }

        var merged: [VolumeEntry] = []
        var firstError: Error?
        var anySucceeded = false
        for engine in found {
            guard let outcome = outcomes.first(where: { $0.0.key == engine.key })?.1 else { continue }
            switch outcome {
            case .success(let list):
                anySucceeded = true
                for volume in list {
                    merged.append(volume.with(
                        // Bind rows are keyed by host path, which is not unique across engines.
                        id: "\(engine.key)|\(volume.id)",
                        reference: Self.encode(engine: engine.key, name: volume.reference),
                        runtimeID: id,
                        machineLabel: endpoint.label,
                        engine: ContainerEngine(engineTitle: engine.title)
                    ))
                }
            case .failure(let error):
                firstError = firstError ?? error
            }
        }
        if firstError != nil { state.withLock { $0.detectedAt = nil } }
        if !anySucceeded, let firstError { throw firstError }
        return merged
    }

    func inspectVolume(_ reference: String) async throws -> String {
        let (engine, name) = try resolve(reference)
        switch engine.backend {
        case .docker(let r): return try await r.inspectVolume(name)
        case .apple(let r): return try await r.inspectVolume(name)
        }
    }

    // MARK: - Per-container operations (dispatch on the engine in the reference)

    func inspect(_ reference: String) async throws -> String {
        let (engine, name) = try resolve(reference)
        switch engine.backend {
        case .docker(let r): return try await r.inspect(name)
        case .apple(let r): return try await r.inspect(name)
        }
    }

    func start(_ reference: String) async throws {
        let (engine, name) = try resolve(reference)
        switch engine.backend {
        case .docker(let r): try await r.start(name)
        case .apple(let r): try await r.start(name)
        }
    }

    func stop(_ reference: String) async throws {
        let (engine, name) = try resolve(reference)
        switch engine.backend {
        case .docker(let r): try await r.stop(name)
        case .apple(let r): try await r.stop(name)
        }
    }

    func kill(_ reference: String) async throws {
        let (engine, name) = try resolve(reference)
        switch engine.backend {
        case .docker(let r): try await r.kill(name)
        case .apple(let r): try await r.kill(name)
        }
    }

    func restart(_ reference: String, wasRunning: Bool) async throws {
        let (engine, name) = try resolve(reference)
        switch engine.backend {
        case .docker(let r): try await r.restart(name, wasRunning: wasRunning)
        case .apple(let r): try await r.restart(name, wasRunning: wasRunning)
        }
    }

    func remove(_ reference: String, force: Bool) async throws {
        let (engine, name) = try resolve(reference)
        switch engine.backend {
        case .docker(let r): try await r.remove(name, force: force)
        case .apple(let r): try await r.remove(name, force: force)
        }
    }

    func logs(_ reference: String, tail: LogTailLimit) -> AsyncThrowingStream<String, Error> {
        guard let (key, name) = Self.decode(reference),
              let engine = state.withLock({ $0.engines.first { $0.key == key } }) else {
            return AsyncThrowingStream { $0.finish(throwing: CLIError.command(exitCode: -1, stderr: "engine not detected")) }
        }
        switch engine.backend {
        case .docker(let r): return r.logs(name, tail: tail)
        case .apple(let r): return r.logs(name, tail: tail)
        }
    }

    func writeFullLog(_ reference: String, to path: String) async throws {
        let (engine, name) = try resolve(reference)
        switch engine.backend {
        case .docker(let r): try await r.writeFullLog(name, to: path)
        case .apple(let r): try await r.writeFullLog(name, to: path)
        }
    }

    func stats(references: [String]?) async throws -> [StatsSample] {
        let found = try await engines()
        var wanted: [String: [String]] = [:]       // engine key -> names
        if let references {
            for reference in references {
                if let (key, name) = Self.decode(reference) { wanted[key, default: []].append(name) }
            }
        }
        var samples: [StatsSample] = []
        for engine in found {
            let names: [String]? = references == nil ? nil : wanted[engine.key]
            if references != nil, names == nil { continue }
            let fetched: [StatsSample]
            switch engine.backend {
            case .docker(let r): fetched = (try? await r.stats(references: names)) ?? []
            case .apple(let r): fetched = (try? await r.stats(references: names)) ?? []
            }
            samples += fetched.map { $0.withID(Self.encode(engine: engine.key, name: $0.id)) }
        }
        return samples
    }

    func listFiles(_ reference: String, path: String) async throws -> [FileEntry] {
        let (engine, name) = try resolve(reference)
        switch engine.backend {
        case .docker(let r): return try await r.listFiles(name, path: path)
        case .apple(let r): return try await r.listFiles(name, path: path)
        }
    }

    func copyIn(_ reference: String, localPath: String, destination: String) async throws {
        let (engine, name) = try resolve(reference)
        switch engine.backend {
        case .docker(let r): try await r.copyIn(name, localPath: localPath, destination: destination)
        case .apple: throw RemoteAppleRuntime.unsupported
        }
    }

    func copyOut(_ reference: String, source: String, localPath: String) async throws {
        let (engine, name) = try resolve(reference)
        switch engine.backend {
        case .docker(let r): try await r.copyOut(name, source: source, localPath: localPath)
        case .apple: throw RemoteAppleRuntime.unsupported
        }
    }

    func export(_ reference: String, to url: URL) async throws {
        let (engine, name) = try resolve(reference)
        switch engine.backend {
        case .docker(let r): try await r.export(name, to: url)
        case .apple: throw RemoteAppleRuntime.unsupported
        }
    }

    func terminalTarget(_ reference: String) -> TerminalTarget {
        guard let (key, name) = Self.decode(reference),
              let engine = state.withLock({ $0.engines.first { $0.key == key } }) else {
            return .sshCommand(arguments: ["-V"])
        }
        switch engine.backend {
        case .docker(let r): return r.terminalTarget(name)
        case .apple(let r): return r.terminalTarget(name)
        }
    }
}
