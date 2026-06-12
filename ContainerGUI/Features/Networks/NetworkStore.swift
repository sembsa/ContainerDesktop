import Foundation
import Observation

@MainActor @Observable
final class NetworkStore {
    var items: [NetworkInfo] = []
    var isLoading = false
    var error: CLIError?

    private let cli = ContainerCLI.shared

    func refresh() async {
        if items.isEmpty { isLoading = true }
        defer { isLoading = false }
        do {
            items = try await cli.json(["network", "ls"], as: [NetworkInfo].self)
            error = nil
        } catch let cliError as CLIError {
            error = cliError
        } catch {
            self.error = .command(exitCode: -1, stderr: error.localizedDescription)
        }
    }

    func create(name: String, subnet: String?, internalOnly: Bool) async throws {
        var args = ["network", "create"]
        if let subnet, !subnet.isEmpty { args.append(contentsOf: ["--subnet", subnet]) }
        if internalOnly { args.append("--internal") }
        args.append(name)
        try await cli.run(args)
        await refresh()
    }

    func remove(_ network: NetworkInfo) async throws {
        try await cli.run(["network", "rm", network.name])
        await refresh()
    }

    func prune() async throws {
        try await cli.run(["network", "prune"])
        await refresh()
    }

    func inspect(_ name: String) async throws -> String {
        try await cli.run(["network", "inspect", name])
    }
}
