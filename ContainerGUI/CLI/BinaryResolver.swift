import Foundation

/// Locates the `container` executable. A GUI app launched from Finder does not
/// inherit the shell `PATH`, so we probe well-known absolute locations and allow
/// a user-configured override stored in `UserDefaults`.
enum BinaryResolver {
    static let defaultsKey = "containerBinaryPath"

    static let candidatePaths = [
        "/usr/local/bin/container",
        "/opt/homebrew/bin/container",
    ]

    /// User-provided override path (set from Settings).
    static var overridePath: String? {
        get { UserDefaults.standard.string(forKey: defaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }

    /// Returns the path to a runnable `container` binary, or `nil` if none found.
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
