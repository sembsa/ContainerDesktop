import Foundation

/// A network as reported by `container network ls --format json`.
struct NetworkInfo: Codable, Identifiable, Sendable, Hashable {
    let id: String
    let configuration: Configuration
    let status: Status?

    var name: String { configuration.name }

    struct Configuration: Codable, Sendable, Hashable {
        let name: String
        let mode: String?
        let plugin: String?
        let creationDate: Date?
        let labels: [String: String]?
    }

    struct Status: Codable, Sendable, Hashable {
        let ipv4Gateway: String?
        let ipv4Subnet: String?
        let ipv6Subnet: String?
    }
}
