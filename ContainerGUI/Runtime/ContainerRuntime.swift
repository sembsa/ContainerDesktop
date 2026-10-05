import Foundation

/// Which engine a container belongs to.
enum RuntimeKind: String, Codable, Sendable, CaseIterable, Hashable, Identifiable {
    case apple
    case docker

    var id: String { rawValue }

    /// Short badge text. Brand names, so not localized.
    var badge: String {
        switch self {
        case .apple: "Apple"
        case .docker: "Docker"
        }
    }
}

/// Where a container runs: this Mac, or a machine added under External Machines.
enum ContainerLocation: String, Codable, Sendable, Hashable {
    case local
    case external

    var title: String {
        switch self {
        case .local: String(localized: "Lokalny")
        case .external: String(localized: "Zewnętrzny")
        }
    }
}

/// The engine actually running a container, as shown on the runtime tag.
/// Brand names, so not localized.
enum ContainerEngine: String, Codable, Sendable, CaseIterable, Hashable, Identifiable {
    case apple
    case docker
    case colima

    var id: String { rawValue }

    var title: String {
        switch self {
        case .apple: "Apple"
        case .docker: "Docker"
        case .colima: "Colima"
        }
    }

    /// Maps a detected engine title ("Colima (work) [bob]", "Docker Desktop",
    /// "OrbStack", "Apple") to the tag. Anything on the Docker API that is not
    /// Colima counts as Docker.
    init(engineTitle: String) {
        if engineTitle.hasPrefix("Colima") { self = .colima }
        else if engineTitle.hasPrefix("Apple") { self = .apple }
        else { self = .docker }
    }
}

/// One chip in the container list.
struct SourceTag: Hashable, Sendable {
    enum Kind: Hashable, Sendable { case location, machine, runtime }
    let kind: Kind
    let text: String
}

/// Features that exist for one engine and not the other. The UI asks for a
/// capability rather than comparing against a `RuntimeKind`, so the views stay
/// free of `if docker` branches.
struct RuntimeCapabilities: OptionSet, Sendable, Hashable {
    let rawValue: Int

    /// "Change command / configuration" (re-create through `container run`).
    static let recreate = RuntimeCapabilities(rawValue: 1 << 0)
    /// `container clean` (trim writable layers).
    static let clean = RuntimeCapabilities(rawValue: 1 << 1)
    /// Login-time autostart through the app's launch agent.
    static let autostart = RuntimeCapabilities(rawValue: 1 << 2)
    /// Prune and "stop all" (menu bar) act on this engine.
    static let bulkActions = RuntimeCapabilities(rawValue: 1 << 3)

    static let apple: RuntimeCapabilities = [.recreate, .clean, .autostart, .bulkActions]
    static let docker: RuntimeCapabilities = []
    static let none: RuntimeCapabilities = []
}

/// Everything the Containers section needs from an engine.
///
/// Implementations normalise their output into the app's existing models
/// (`ContainerInfo`, `StatsSample`, `FileEntry`) so views and stores never see
/// engine-specific JSON. `reference` is always the engine-local identifier
/// (`ContainerInfo.reference`), not the UI identity.
protocol ContainerRuntime: Sendable {
    /// Unique per configured instance: `apple`, `docker`, or `docker:<uuid>`
    /// for an external machine. Matches `ContainerInfo.runtimeKey`.
    var id: String { get }
    var kind: RuntimeKind { get }
    /// Set for external machines: the entry's label, shown as the machine tag.
    var sourceLabel: String? { get }
    var capabilities: RuntimeCapabilities { get }

    /// Whether the engine's CLI is installed. Says nothing about the daemon.
    var isInstalled: Bool { get }

    /// Whether a failed poll leaves the previous list on screen (Apple's CLI
    /// hiccups) or empties it (a Docker daemon that quit has no containers).
    var keepsLastListOnError: Bool { get }

    func list(includeStopped: Bool) async throws -> [ContainerInfo]
    /// Pretty-printed raw JSON for the Inspect tab.
    func inspect(_ reference: String) async throws -> String

    func start(_ reference: String) async throws
    func stop(_ reference: String) async throws
    func kill(_ reference: String) async throws
    func restart(_ reference: String, wasRunning: Bool) async throws
    func remove(_ reference: String, force: Bool) async throws

    /// Line stream of `logs --follow` with the requested amount of history.
    func logs(_ reference: String, tail: LogTailLimit) -> AsyncThrowingStream<String, Error>
    /// Writes the complete log straight to a file.
    func writeFullLog(_ reference: String, to path: String) async throws

    /// Cumulative-counter samples for running containers. `references == nil`
    /// means every running container.
    func stats(references: [String]?) async throws -> [StatsSample]

    func listFiles(_ reference: String, path: String) async throws -> [FileEntry]
    func copyIn(_ reference: String, localPath: String, destination: String) async throws
    func copyOut(_ reference: String, source: String, localPath: String) async throws
    func export(_ reference: String, to url: URL) async throws

    func terminalTarget(_ reference: String) -> TerminalTarget

    // MARK: Networks

    /// What the Networks section may do on this engine. External machines are
    /// read-only; Apple-only actions (prune) stay gated behind it.
    var networkActions: NetworkActions { get }
    /// The engine's networks, normalised. Subnet and gateway where the engine
    /// reports them; attached containers where it lists them (Docker).
    func listNetworks() async throws -> [NetworkEntry]
    /// Pretty-printed raw JSON for one network.
    func inspectNetwork(_ reference: String) async throws -> String
    func createNetwork(name: String, subnet: String?, internalOnly: Bool) async throws
    func removeNetwork(_ reference: String) async throws
    func pruneNetworks() async throws

    // MARK: Volumes

    /// What the Volumes section may do on this engine. External machines are
    /// read-only; Apple-only actions (prune, browse) stay gated behind it.
    var volumeActions: VolumeActions { get }
    /// The engine's volumes, normalised, plus the bind mounts containers use.
    func listVolumes() async throws -> [VolumeEntry]
    /// Pretty-printed raw JSON for one volume.
    func inspectVolume(_ reference: String) async throws -> String
    func createVolume(name: String, size: String?) async throws
    func removeVolume(_ reference: String) async throws
    func pruneVolumes() async throws
}

extension ContainerRuntime {
    var volumeActions: VolumeActions { .none }
    func listVolumes() async throws -> [VolumeEntry] { [] }
    func inspectVolume(_ reference: String) async throws -> String { throw CLIError.volumeActionUnsupported }
    func createVolume(name: String, size: String?) async throws { throw CLIError.volumeActionUnsupported }
    func removeVolume(_ reference: String) async throws { throw CLIError.volumeActionUnsupported }
    func pruneVolumes() async throws { throw CLIError.volumeActionUnsupported }
}

extension CLIError {
    /// A volume action the engine (or a machine reached over SSH) does not offer.
    static var volumeActionUnsupported: CLIError {
        .command(exitCode: -1, stderr: String(localized: "Ta operacja na wolumenach nie jest dostępna dla tego silnika."))
    }
}

extension ContainerRuntime {
    var networkActions: NetworkActions { .none }
    func listNetworks() async throws -> [NetworkEntry] { [] }
    func inspectNetwork(_ reference: String) async throws -> String { throw CLIError.networkActionUnsupported }
    func createNetwork(name: String, subnet: String?, internalOnly: Bool) async throws { throw CLIError.networkActionUnsupported }
    func removeNetwork(_ reference: String) async throws { throw CLIError.networkActionUnsupported }
    func pruneNetworks() async throws { throw CLIError.networkActionUnsupported }
}

extension CLIError {
    /// A network action the engine (or a machine reached over SSH) does not offer.
    static var networkActionUnsupported: CLIError {
        .command(exitCode: -1, stderr: String(localized: "Ta operacja na sieciach nie jest dostępna dla tego silnika."))
    }
}

extension ContainerInfo {
    /// The runtime-neutral capabilities of the engine this container lives in.
    var capabilities: RuntimeCapabilities {
        // Anything reached through an external machine is driven remotely; the
        // local-CLI-only features (re-create, clean, autostart) do not apply,
        // even when the remote engine is Apple's.
        if runtimeID != nil { return .none }
        return runtime == .apple ? .apple : .docker
    }
}

/// Bounds an operation that can hang on a dead network (an SSH tunnel to a
/// laptop that went to sleep).
enum Deadline {
    /// Runs `operation`, giving up with a timeout error after `limit`. The
    /// slower of the two loses and is cancelled.
    static func run<T: Sendable>(
        _ limit: Duration,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: limit)
                throw CLIError.timeout(seconds: Int(limit.components.seconds), command: "docker")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
}
