import Foundation

/// An image as reported by `container image ls --format json`.
struct ImageInfo: Codable, Identifiable, Sendable, Hashable {
    let id: String
    let configuration: Configuration
    let variants: [Variant]?

    var reference: String { configuration.name }
    var digest: String { configuration.descriptor.digest }
    var shortDigest: String {
        let raw = digest.replacingOccurrences(of: "sha256:", with: "")
        return String(raw.prefix(12))
    }
    var totalSize: Int64 {
        if let variants, !variants.isEmpty {
            return variants.compactMap(\.size).reduce(0, +)
        }
        return configuration.descriptor.size
    }

    /// Splits `docker.io/library/alpine:latest` into repository + tag for display.
    var repository: String {
        guard let colon = reference.lastIndex(of: ":"),
              !reference[reference.index(after: colon)...].contains("/") else {
            return reference
        }
        return String(reference[..<colon])
    }
    var tag: String {
        guard let colon = reference.lastIndex(of: ":"),
              !reference[reference.index(after: colon)...].contains("/") else {
            return "latest"
        }
        return String(reference[reference.index(after: colon)...])
    }

    struct Configuration: Codable, Sendable, Hashable {
        let name: String
        let descriptor: Descriptor
        let creationDate: Date?

        struct Descriptor: Codable, Sendable, Hashable {
            let digest: String
            let mediaType: String?
            let size: Int64
        }
    }

    struct Variant: Codable, Sendable, Hashable {
        let digest: String?
        let size: Int64?
        let platform: Platform?

        struct Platform: Codable, Sendable, Hashable {
            let architecture: String?
            let os: String?
            let variant: String?
        }
    }
}
