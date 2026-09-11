import Foundation

/// State of the `container` background system service.
enum ServiceState: Sendable, Equatable {
    case unknown
    case running
    case starting
    case stopping
    case stopped

    var isRunning: Bool { self == .running }
    var isTransitioning: Bool { self == .starting || self == .stopping }
}

/// Reduces a version banner to the bare number inside it.
///
/// The CLI reports versions two different ways: `client.version` is `1.4.1`,
/// while `server.version` is a whole `container-apiserver version 1.4.1
/// (build: release, commit: 9a8917c)` banner. Anything shown to a user, or
/// compared against another version, has to go through here first.
enum ContainerVersion {
    /// Pulls the first `1.2.2`-shaped token out of a version banner.
    static func number(in text: String) -> String? {
        for token in text.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
            let candidate = token.trimmingCharacters(in: CharacterSet(charactersIn: "()v,"))
            let parts = candidate.split(separator: ".")
            if parts.count >= 2, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) {
                return candidate
            }
        }
        return nil
    }
}

/// `container system status --format json`.
///
/// 1.4.1 restructured this payload — a documented breaking change. What used to
/// be a flat `apiserver.version` line is now `server.version`, and the output
/// gained `client`, `host`, `paths` and `resources` sections. Every section is
/// optional so that an older CLI, which carries only `status`, still decodes.
struct SystemStatus: Decodable, Sendable, Hashable {
    let status: String
    let client: Component?
    let server: Component?
    let host: Host?
    let paths: Paths?
    let resources: Resources?

    struct Component: Decodable, Sendable, Hashable {
        let appName: String?
        let build: String?
        let commit: String?
        let version: String?
    }

    struct Host: Decodable, Sendable, Hashable {
        let architecture: String?
        let cpus: Int?
        let operatingSystem: String?
    }

    struct Paths: Decodable, Sendable, Hashable {
        let appRoot: String?
        let installRoot: String?
        let logRoot: String?
    }

    struct Resources: Decodable, Sendable, Hashable {
        let containersRunning: Int?
        let containersTotal: Int?
        let images: Int?
    }

    var serviceState: ServiceState { status.lowercased() == "running" ? .running : .stopped }

    var clientVersionNumber: String? { client?.version.flatMap(ContainerVersion.number(in:)) }
    var serverVersionNumber: String? { server?.version.flatMap(ContainerVersion.number(in:)) }

    /// The CLI and the background service running different builds.
    ///
    /// A `.pkg` upgrade replaces every binary on disk but leaves the old
    /// apiserver running, so the new CLI talks to a service that predates it.
    /// The result is not a clean error: `cp` reports "path not found" for files
    /// that exist, `clean` fails with an XPC error, and the k8s plugin goes
    /// blank. Restarting the service is the fix.
    struct VersionSkew: Sendable, Hashable {
        let cli: String
        let service: String
    }

    var versionSkew: VersionSkew? {
        // A stopped service has nothing to disagree with, and the fix there is
        // "start", not "restart".
        guard serviceState == .running else { return nil }

        let cli = clientVersionNumber
        let service = serverVersionNumber

        // Commits are the stronger signal: one release builds every component
        // from a single commit, so two commits mean two different builds even
        // when the version numbers happen to match.
        if let clientCommit = client?.commit, let serverCommit = server?.commit,
           !clientCommit.isEmpty, !serverCommit.isEmpty, clientCommit != serverCommit {
            return VersionSkew(
                cli: cli ?? String(clientCommit.prefix(7)),
                service: service ?? String(serverCommit.prefix(7))
            )
        }

        guard let cli, let service, cli != service else { return nil }
        return VersionSkew(cli: cli, service: service)
    }
}

/// Disk usage as reported by `container system df --format json`.
struct DiskUsage: Codable, Sendable, Hashable {
    let containers: Entry?
    let images: Entry?
    let volumes: Entry?

    struct Entry: Codable, Sendable, Hashable {
        let active: Int?
        let reclaimable: Int64?
        let sizeInBytes: Int64?
        let total: Int?
    }
}

/// A stored registry login from `container registry ls --format json`.
/// Field names are best-effort and decode defensively.
struct RegistryLogin: Decodable, Identifiable, Sendable, Hashable {
    let id: String
    let hostname: String
    let username: String

    enum CodingKeys: String, CodingKey { case hostname, username }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hostname = (try? container.decode(String.self, forKey: .hostname)) ?? "—"
        username = (try? container.decode(String.self, forKey: .username)) ?? "—"
        id = hostname
    }
}

/// A container machine from `container machine ls --format json`.
struct MachineInfo: Decodable, Identifiable, Sendable, Hashable {
    let id: String                // machine name
    let status: String?
    let cpus: Int?
    let memoryBytes: Int64?
    let diskSizeBytes: Int64?
    let ipAddress: String?
    let isDefault: Bool?
    let createdDate: Date?

    var name: String { id }
    var isRunning: Bool { status?.lowercased() == "running" }

    enum CodingKeys: String, CodingKey {
        case id, status, cpus, ipAddress, createdDate
        case memoryBytes = "memory"
        case diskSizeBytes = "diskSize"
        case isDefault = "default"
    }
}

/// `container machine inspect` — deliberately separate from `MachineInfo`, which
/// mirrors `machine ls --format json`.
///
/// Inspect carries four things the list does not: how the home directory is
/// mounted, which image the machine was built from, its platform, and which host
/// user the shell runs as. It also rejects `--format json` outright (it already
/// prints JSON), so it has to be fetched with `appendFormat: false`.
struct MachineInspect: Decodable, Sendable, Hashable {
    let id: String
    let containerId: String?
    let status: String?
    let cpus: Int?
    let memoryBytes: Int64?
    let diskSizeBytes: Int64?
    let ipAddress: String?
    let homeMount: String?
    let createdDate: Date?
    let startedDate: Date?
    let platform: Platform?
    let image: SourceImage?
    let userSetup: UserSetup?

    struct Platform: Decodable, Sendable, Hashable {
        let architecture: String?
        let os: String?

        var label: String {
            [os, architecture].compactMap { $0 }.joined(separator: "/")
        }
    }

    struct SourceImage: Decodable, Sendable, Hashable {
        let reference: String?
        let descriptor: Descriptor?

        struct Descriptor: Decodable, Sendable, Hashable {
            let digest: String?
            let size: Int64?
        }
    }

    struct UserSetup: Decodable, Sendable, Hashable {
        let uid: Int?
        let gid: Int?
        let username: String?
    }

    var isRunning: Bool { status?.lowercased() == "running" }

    enum CodingKeys: String, CodingKey {
        case id, containerId, status, cpus, ipAddress, homeMount
        case createdDate, startedDate, platform, image, userSetup
        case memoryBytes = "memory"
        case diskSizeBytes = "diskSize"
    }
}
