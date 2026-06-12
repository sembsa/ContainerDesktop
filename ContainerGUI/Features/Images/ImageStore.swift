import Foundation
import Observation

@MainActor @Observable
final class ImageStore {
    var items: [ImageInfo] = []
    var isLoading = false
    var error: CLIError?

    private let cli = ContainerCLI.shared

    func refresh() async {
        if items.isEmpty { isLoading = true }
        defer { isLoading = false }
        do {
            items = try await cli.json(["image", "ls"], as: [ImageInfo].self)
            error = nil
        } catch let cliError as CLIError {
            error = cliError
        } catch {
            self.error = .command(exitCode: -1, stderr: error.localizedDescription)
        }
    }

    func remove(_ image: ImageInfo, force: Bool = false) async throws {
        var args = ["image", "rm"]
        if force { args.append("--force") }
        args.append(image.reference)
        try await cli.run(args)
        await refresh()
    }

    func prune() async throws {
        try await cli.run(["image", "prune"])
        await refresh()
    }

    func tag(_ image: ImageInfo, newReference: String) async throws {
        try await cli.run(["image", "tag", image.reference, newReference])
        await refresh()
    }

    func inspect(_ reference: String) async throws -> String {
        try await cli.run(["image", "inspect", reference])
    }
}
