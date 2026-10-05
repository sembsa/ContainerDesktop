import Foundation

/// A Docker engine on another machine, reached over SSH.
///
/// This is the single source of truth for external machines: the settings UI
/// edits these values, `ExternalMachineStore` persists them, and
/// `DockerRuntime(endpoint:)` is built from them. Nothing secret lives here — an
/// identity file is a *path*; passphrases and passwords are never stored, and
/// the SSH connection runs with `BatchMode` so it never prompts for one.
struct DockerEndpoint: Codable, Identifiable, Hashable, Sendable {
    enum Engine: String, Codable, CaseIterable, Identifiable, Sendable {
        /// Probe the machine and use every engine that answers.
        case auto
        case dockerDesktop
        case colima
        case ssh
        /// Apple's `container` CLI on the remote machine.
        case appleContainer

        var id: String { rawValue }

        var title: String {
            switch self {
            case .auto: String(localized: "Wykryj automatycznie")
            case .appleContainer: String(localized: "Apple container (CLI)")
            case .dockerDesktop: String(localized: "Docker Desktop (gniazdo)")
            case .colima: "Colima"
            case .ssh: String(localized: "Docker przez SSH")
            }
        }

        /// Where the engine's API socket lives on the remote machine when the
        /// entry does not name one.
        var defaultSocketPath: String {
            switch self {
            case .auto, .appleContainer: ""
            
            case .dockerDesktop: "~/.docker/run/docker.sock"
            case .colima: "~/.colima/default/docker.sock"
            case .ssh: "/var/run/docker.sock"
            }
        }
    }

    static let defaultSSHPort = 22

    var id = UUID()
    var label = ""
    var engine: Engine = .auto
    var host = ""
    var sshPort = DockerEndpoint.defaultSSHPort
    var sshUser = ""
    /// Path to a private key file. Optional; the SSH agent and `~/.ssh/config`
    /// still apply when it is empty.
    var identityFile: String?
    /// `nil` or empty means the engine's default.
    var remoteSocketPath: String?
    var enabled = true

    var runtimeID: String { "docker:\(id.uuidString)" }

    var effectiveSocketPath: String {
        let custom = remoteSocketPath?.trimmingCharacters(in: .whitespaces) ?? ""
        return custom.isEmpty ? engine.defaultSocketPath : custom
    }

    /// Identifies one SSH tunnel: a machine can have several (one per engine
    /// socket found on it).
    var tunnelKey: String { "\(id.uuidString)|\(effectiveSocketPath)" }

    /// `user@host` or `host`.
    var sshTarget: String {
        let user = sshUser.trimmingCharacters(in: .whitespaces)
        let hostName = host.trimmingCharacters(in: .whitespaces)
        return user.isEmpty ? hostName : "\(user)@\(hostName)"
    }

    /// Everything that decides how a tunnel is built; when it changes the old
    /// tunnel has to be replaced.
    var connectionSignature: String {
        [sshTarget, "\(sshPort)", identityFile ?? "", effectiveSocketPath].joined(separator: "|")
    }

    // MARK: - Validation

    enum Issue: Equatable, Hashable, Sendable {
        case emptyLabel
        case duplicateLabel
        case emptyHost
        case invalidHost
        case invalidPort
        case invalidUser
        case identityFileNotFound
        case invalidSocketPath

        var message: String {
            switch self {
            case .emptyLabel: String(localized: "Podaj nazwę maszyny.")
            case .duplicateLabel: String(localized: "Maszyna o tej nazwie już istnieje.")
            case .emptyHost: String(localized: "Podaj adres hosta.")
            case .invalidHost: String(localized: "Adres hosta zawiera niedozwolone znaki.")
            case .invalidPort: String(localized: "Port SSH musi być liczbą od 1 do 65535.")
            case .invalidUser: String(localized: "Nazwa użytkownika SSH zawiera niedozwolone znaki.")
            case .identityFileNotFound: String(localized: "Nie znaleziono pliku klucza.")
            case .invalidSocketPath: String(localized: "Ścieżka gniazda musi być bezwzględna (lub zaczynać się od ~/) i nie może zawierać spacji ani dwukropków.")
            }
        }
    }

    /// Hosts and users end up as ssh arguments, so a leading `-` (which ssh
    /// would read as an option) and anything outside this alphabet is refused.
    private static let hostAllowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_:[]%")
    private static let userAllowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")

    /// Field-level problems, in form order. Duplicate labels need the other
    /// entries and are added by `ExternalMachineStore.validate`.
    func validate(fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> [Issue] {
        var issues: [Issue] = []
        if label.trimmingCharacters(in: .whitespaces).isEmpty { issues.append(.emptyLabel) }

        let hostName = host.trimmingCharacters(in: .whitespaces)
        if hostName.isEmpty {
            issues.append(.emptyHost)
        } else if hostName.hasPrefix("-")
                    || hostName.unicodeScalars.contains(where: { !Self.hostAllowed.contains($0) }) {
            issues.append(.invalidHost)
        }

        if !(1...65535).contains(sshPort) { issues.append(.invalidPort) }

        let user = sshUser.trimmingCharacters(in: .whitespaces)
        if !user.isEmpty,
           user.hasPrefix("-") || user.unicodeScalars.contains(where: { !Self.userAllowed.contains($0) }) {
            issues.append(.invalidUser)
        }

        let key = (identityFile ?? "").trimmingCharacters(in: .whitespaces)
        if !key.isEmpty, !fileExists(Self.expandingTilde(key)) { issues.append(.identityFileNotFound) }

        let socket = (remoteSocketPath ?? "").trimmingCharacters(in: .whitespaces)
        if !socket.isEmpty {
            let absolute = socket.hasPrefix("/") || socket.hasPrefix("~/")
            let clean = !socket.contains(":") && !socket.contains(where: { $0.isWhitespace || $0.isNewline })
            if !absolute || !clean { issues.append(.invalidSocketPath) }
        }
        return issues
    }

    static func expandingTilde(_ path: String) -> String {
        guard path == "~" || path.hasPrefix("~/") else { return path }
        return NSHomeDirectory() + path.dropFirst()
    }

    /// The trimmed form that is stored.
    func normalized() -> DockerEndpoint {
        var copy = self
        copy.label = label.trimmingCharacters(in: .whitespaces)
        copy.host = host.trimmingCharacters(in: .whitespaces)
        copy.sshUser = sshUser.trimmingCharacters(in: .whitespaces)
        let key = (identityFile ?? "").trimmingCharacters(in: .whitespaces)
        copy.identityFile = key.isEmpty ? nil : key
        let socket = (remoteSocketPath ?? "").trimmingCharacters(in: .whitespaces)
        copy.remoteSocketPath = socket.isEmpty ? nil : socket
        return copy
    }
}
