import Foundation

/// A volume as reported by `container volume ls --format json`.
struct VolumeInfo: Codable, Identifiable, Sendable, Hashable {
    let id: String
    let configuration: Configuration

    var name: String { configuration.name }

    struct Configuration: Codable, Sendable, Hashable {
        let name: String
        let driver: String?
        let format: String?
        let sizeInBytes: Int64?
        let source: String?
        let creationDate: Date?
        let labels: [String: String]?
    }
}
