import Foundation

/// Locates the `docker` CLI. A GUI app does not inherit the shell `PATH`, so
/// well-known absolute locations are probed, with a `UserDefaults` override.
enum DockerBinaryResolver {
    static let defaultsKey = "dockerBinaryPath"

    static let candidatePaths = [
        "/usr/local/bin/docker",
        "/opt/homebrew/bin/docker",
        "/Applications/Docker.app/Contents/Resources/bin/docker",
    ]

    static var overridePath: String? {
        get { UserDefaults.standard.string(forKey: defaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }

    /// Path to a runnable `docker` binary, or `nil` when Docker is not installed.
    static func resolve() -> String? {
        if let override = overridePath,
           !override.isEmpty,
           FileManager.default.isExecutableFile(atPath: override) {
            return override
        }
        for path in candidatePaths where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }
}
