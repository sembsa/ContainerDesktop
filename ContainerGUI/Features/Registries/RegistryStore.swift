import Foundation
import Observation

@MainActor @Observable
final class RegistryStore {
    var items: [RegistryLogin] = []
    var isLoading = false
    var error: CLIError?

    private let cli = ContainerCLI.shared

    func refresh() async {
        if items.isEmpty { isLoading = true }
        defer { isLoading = false }
        do {
            items = try await cli.json(["registry", "ls"], as: [RegistryLogin].self)
            error = nil
        } catch let cliError as CLIError {
            error = cliError
        } catch {
            self.error = .command(exitCode: -1, stderr: error.localizedDescription)
        }
    }

    func login(server: String, username: String, password: String) async throws {
        try await cli.run(
            ["registry", "login", server, "--username", username, "--password-stdin"],
            input: password
        )
        await refresh()
    }

    func logout(_ login: RegistryLogin) async throws {
        try await cli.run(["registry", "logout", login.hostname])
        await refresh()
    }
}
