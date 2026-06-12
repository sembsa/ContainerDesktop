import Foundation
import Observation

@MainActor @Observable
final class MachineStore {
    var items: [MachineInfo] = []
    var isLoading = false
    var error: CLIError?

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

    func create(image: String, name: String) async throws {
        var args = ["machine", "create", image]
        if !name.isEmpty { args.append(contentsOf: ["--name", name]) }
        try await cli.run(args)
        await refresh()
    }

    func stop(_ machine: MachineInfo) async throws {
        try await cli.run(["machine", "stop", machine.name])
        await refresh()
    }

    func delete(_ machine: MachineInfo) async throws {
        try await cli.run(["machine", "delete", machine.name])
        await refresh()
    }

    func setDefault(_ machine: MachineInfo) async throws {
        try await cli.run(["machine", "set-default", machine.name])
        await refresh()
    }

    func inspect(_ name: String) async throws -> String {
        try await cli.run(["machine", "inspect", name])
    }
}
