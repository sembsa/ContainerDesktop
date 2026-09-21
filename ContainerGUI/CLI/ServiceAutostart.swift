import Foundation

/// Starting the `container` service at login instead of from the app.
///
/// Starting it from inside the app binds the launchd job to the app: quitting
/// takes the service down with it. Started with no app in the chain it
/// survives — verified repeatedly. This removes the app from the chain
/// entirely by letting launchd load the service at login.
///
/// The plist is Apple's own, written by `container system start` and left in
/// Application Support, where launchd never looks. It already declares
/// `RunAtLoad` and allows the `Aqua` and `Background` session types; it is
/// simply never installed anywhere persistent. Linking rather than copying
/// means a future `container` release can change it without this going stale.
enum ServiceAutostart {
    static let label = "com.apple.container.apiserver"

    static var sourceURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/com.apple.container/apiserver/apiserver.plist")
    }

    static var agentURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    enum State: Equatable, Sendable {
        /// The service has never been started, so there is no plist to link to.
        case unavailable
        case off
        case on
        /// Something else already occupies the name — most likely a copy made
        /// by hand. Left alone rather than overwritten.
        case foreign
    }

    /// Decided from inputs so the rule can be tested without touching the disk.
    static func state(sourceExists: Bool, agentLinkTarget: String?, agentExists: Bool) -> State {
        guard sourceExists else { return .unavailable }
        guard agentExists else { return .off }
        guard let target = agentLinkTarget else { return .foreign }
        return target == sourceURL.path ? .on : .foreign
    }

    static func current(manager: FileManager = .default) -> State {
        state(
            sourceExists: manager.fileExists(atPath: sourceURL.path),
            agentLinkTarget: try? manager.destinationOfSymbolicLink(atPath: agentURL.path),
            agentExists: (try? manager.attributesOfItem(atPath: agentURL.path)) != nil
        )
    }

    static func enable(manager: FileManager = .default) throws {
        guard manager.fileExists(atPath: sourceURL.path) else {
            throw CLIError.command(
                exitCode: 1,
                stderr: String(localized: "Uruchom usługę choć raz — dopiero wtedy powstaje plik, do którego można się odwołać.")
            )
        }
        try manager.createDirectory(
            at: agentURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        if (try? manager.attributesOfItem(atPath: agentURL.path)) != nil {
            try manager.removeItem(at: agentURL)
        }
        try manager.createSymbolicLink(at: agentURL, withDestinationURL: sourceURL)
    }

    static func disable(manager: FileManager = .default) throws {
        guard current(manager: manager) == .on else { return }
        try manager.removeItem(at: agentURL)
    }
}
