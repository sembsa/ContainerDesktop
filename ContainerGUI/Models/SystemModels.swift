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

/// `container system status --format json` → {"status":"running"|"unregistered"|"not running", ...}
struct SystemStatus: Decodable, Sendable {
    let status: String
    var serviceState: ServiceState { status.lowercased() == "running" ? .running : .stopped }
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
