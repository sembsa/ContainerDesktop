import Foundation
import Observation

/// The configured external machines: the single list that both the settings UI
/// and the runtime layer (`DockerRuntime(endpoint:)`) read.
///
/// Persisted as JSON under Application Support. The file holds hosts, ports,
/// user names and *paths* to key files; no passwords, passphrases or key
/// material are ever written.
@MainActor @Observable
final class ExternalMachineStore {

    enum Status: Equatable, Sendable {
        case unknown
        case checking
        case online
        case offline(String)

        var isOnline: Bool { self == .online }
    }

    /// Thrown by `add`/`update` when the entry is not valid.
    struct ValidationError: Error, Equatable {
        let issues: [DockerEndpoint.Issue]
    }

    private(set) var machines: [DockerEndpoint] = []
    private(set) var status: [UUID: Status] = [:]
    /// Engines that answered the last successful test ("Colima, Docker Desktop").
    private(set) var detectedEngines: [UUID: String] = [:]

    /// Called with the full list after every change, so the container store can
    /// rebuild its runtimes. The store never reaches into the container store
    /// itself.
    var onChange: (@MainActor ([DockerEndpoint]) -> Void)?

    private let fileURL: URL
    /// Success carries the names of the engines that answered.
    private let checker: @Sendable (DockerEndpoint) async -> Result<String, Error>
    private let tunnelCloser: @Sendable (UUID) async -> Void
    private let fileExists: (String) -> Bool

    init(
        fileURL: URL = ExternalMachineStore.defaultFileURL,
        checker: @escaping @Sendable (DockerEndpoint) async -> Result<String, Error> = ExternalMachineStore.liveCheck,
        tunnelCloser: @escaping @Sendable (UUID) async -> Void = { await SSHTunnelManager.shared.close($0) },
        fileExists: @escaping (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) {
        self.fileURL = fileURL
        self.checker = checker
        self.tunnelCloser = tunnelCloser
        self.fileExists = fileExists
        machines = Self.load(from: fileURL)
    }

    var enabledMachines: [DockerEndpoint] { machines.filter(\.enabled) }

    // MARK: - Validation

    /// Field problems plus label uniqueness (case-insensitive, among the
    /// *other* entries, so editing an entry does not clash with itself).
    func validate(_ endpoint: DockerEndpoint) -> [DockerEndpoint.Issue] {
        var issues = endpoint.validate(fileExists: { [fileExists] in fileExists(DockerEndpoint.expandingTilde($0)) })
        let label = endpoint.label.trimmingCharacters(in: .whitespaces).lowercased()
        if !label.isEmpty,
           machines.contains(where: { $0.id != endpoint.id && $0.label.lowercased() == label }) {
            issues.insert(.duplicateLabel, at: 0)
        }
        return issues
    }

    // MARK: - Editing

    @discardableResult
    func add(_ endpoint: DockerEndpoint) throws -> DockerEndpoint {
        var entry = endpoint.normalized()
        entry.id = UUID()
        let issues = validate(entry)
        guard issues.isEmpty else { throw ValidationError(issues: issues) }
        machines.append(entry)
        commit()
        return entry
    }

    func update(_ endpoint: DockerEndpoint) throws {
        guard let index = machines.firstIndex(where: { $0.id == endpoint.id }) else { return }
        let entry = endpoint.normalized()
        let issues = validate(entry)
        guard issues.isEmpty else { throw ValidationError(issues: issues) }
        machines[index] = entry
        status[entry.id] = .unknown
        commit()
    }

    func remove(_ id: UUID) {
        machines.removeAll { $0.id == id }
        status[id] = nil
        detectedEngines[id] = nil
        commit()
        let closer = tunnelCloser
        Task { await closer(id) }
    }

    func setEnabled(_ id: UUID, _ enabled: Bool) {
        guard let index = machines.firstIndex(where: { $0.id == id }), machines[index].enabled != enabled else { return }
        machines[index].enabled = enabled
        status[id] = .unknown
        commit()
        if !enabled {
            let closer = tunnelCloser
            Task { await closer(id) }
        }
    }

    /// Pushes the list to the consumer and writes it to disk.
    func commit() {
        save()
        onChange?(machines)
    }

    // MARK: - Connection test

    func test(_ id: UUID) async {
        guard let endpoint = machines.first(where: { $0.id == id }) else { return }
        status[id] = .checking
        let result = await checker(endpoint)
        // The entry may have been removed or edited while the check ran.
        guard machines.first(where: { $0.id == id }) == endpoint else { return }
        switch result {
        case .success(let engines):
            status[id] = .online
            detectedEngines[id] = engines
        case .failure(let error):
            status[id] = .offline(error.localizedDescription)
            detectedEngines[id] = nil
        }
    }

    /// Tests an entry that is not saved yet (the form's Test button).
    func test(draft endpoint: DockerEndpoint) async -> (status: Status, engines: String?) {
        switch await checker(endpoint.normalized()) {
        case .success(let engines): (.online, engines)
        case .failure(let error): (.offline(error.localizedDescription), nil)
        }
    }

    func testAll() async {
        for machine in enabledMachines { await test(machine.id) }
    }

    /// Opens the tunnel and asks the remote engine for its version.
    nonisolated static func liveCheck(_ endpoint: DockerEndpoint) async -> Result<String, Error> {
        let runtime = ExternalMachineRuntime(endpoint: endpoint)
        defer { Task { await SSHTunnelManager.shared.close(endpoint.id) } }
        do {
            return .success(try await Deadline.run(.seconds(90)) { try await runtime.ping() })
        } catch {
            return .failure(error)
        }
    }

    // MARK: - Persistence

    private struct FileFormat: Codable {
        var version = 1
        var machines: [DockerEndpoint]
    }

    static var defaultFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ContainerDesktop", isDirectory: true)
            .appendingPathComponent("external-machines.json")
    }

    private static func load(from url: URL) -> [DockerEndpoint] {
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(FileFormat.self, from: data) else { return [] }
        return file.machines
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(FileFormat(machines: machines)).write(to: fileURL, options: .atomic)
        } catch {
            // Losing the list on a read-only disk is not worth a crash; the
            // in-memory list keeps working for this session.
        }
    }
}
