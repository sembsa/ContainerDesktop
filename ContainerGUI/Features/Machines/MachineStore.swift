import Foundation
import Observation

@MainActor @Observable
final class MachineStore {
    var items: [MachineInfo] = []
    var isLoading = false
    var error: CLIError?
    /// Machines with an action in flight, so the UI can disable their controls
    /// instead of letting a second stop or boot pile onto the first.
    var busyNames: Set<String> = []

    private let cli = ContainerCLI.shared

    func refresh() async {
        if items.isEmpty { isLoading = true }
        defer { isLoading = false }
        do {
            items = try await cli.json(["machine", "ls"], as: [MachineInfo].self)
            error = nil
        } catch let cliError as CLIError {
            error = cliError
        } catch {
            self.error = .command(exitCode: -1, stderr: error.localizedDescription)
        }
    }

    // MARK: - Create

    /// Streams `machine create`, which fetches and unpacks an image before booting
    /// the VM. A one-shot call with a timeout is the wrong shape for that: the
    /// CLI reports `[1/3] Fetching image` style progress worth showing.
    nonisolated func createStream(_ options: MachineCommands.CreateOptions) -> AsyncThrowingStream<String, Error> {
        ContainerCLI.shared.streamChecked(MachineCommands.create(options))
    }

    // MARK: - Lifecycle

    /// Boots a stopped machine. There is no `machine start` subcommand — this goes
    /// through `machine run`, which boots the machine if necessary.
    func boot(_ machine: MachineInfo) async throws {
        try await withBusy(machine.name) {
            try await cli.run(MachineCommands.boot(name: machine.name), timeout: .seconds(300))
        }
        await refresh()
    }

    func stop(_ machine: MachineInfo) async throws {
        try await withBusy(machine.name) {
            try await cli.run(["machine", "stop", machine.name], timeout: .seconds(300))
        }
        await refresh()
    }

    func delete(_ machine: MachineInfo) async throws {
        try await withBusy(machine.name) {
            try await cli.run(["machine", "delete", machine.name], timeout: .seconds(300))
        }
        await refresh()
    }

    func setDefault(_ machine: MachineInfo) async throws {
        try await cli.run(["machine", "set-default", machine.name])
        await refresh()
    }

    // MARK: - Configuration

    /// Applies `machine set`. Returns the CLI's own reply, which is where the
    /// "changes take effect after restarting" note comes from — worth showing
    /// verbatim, because `machine ls` starts reporting the new numbers straight
    /// away while the running VM still has the old ones.
    @discardableResult
    func apply(_ settings: [MachineCommands.Setting], to machine: MachineInfo) async throws -> String {
        let arguments = MachineCommands.set(name: machine.name, settings: settings)
        guard !arguments.isEmpty else { return "" }
        let output = try await withBusy(machine.name) {
            try await cli.run(arguments, timeout: .seconds(60))
        }
        await refresh()
        return output
    }

    // MARK: - Inspect

    /// `machine inspect` prints JSON already and rejects `--format`, hence
    /// `appendFormat: false`. It answers with a single-element array.
    func inspect(_ name: String) async throws -> MachineInspect {
        let results = try await cli.json(
            ["machine", "inspect", name],
            as: [MachineInspect].self,
            appendFormat: false
        )
        guard let first = results.first else {
            throw CLIError.decoding(String(localized: "pusta odpowiedź"))
        }
        return first
    }

    // MARK: - Helpers

    private func withBusy<T>(_ name: String, _ action: () async throws -> T) async throws -> T {
        busyNames.insert(name)
        defer { busyNames.remove(name) }
        return try await action()
    }
}
