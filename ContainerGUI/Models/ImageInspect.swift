import Foundation

// MARK: - Top-level

/// Decoded result of `container image inspect <ref>` (an array of one element).
struct ImageInspect: Codable, Sendable, Hashable {
    let configuration: InspectConfiguration
    let id: String
    let variants: [Variant]

    // MARK: - Configuration

    struct InspectConfiguration: Codable, Sendable, Hashable {
        let name: String
        let creationDate: String?
        let descriptor: Descriptor

        struct Descriptor: Codable, Sendable, Hashable {
            let digest: String
            let mediaType: String?
            let size: Int64
        }
    }

    // MARK: - Variant

    struct Variant: Codable, Sendable, Hashable {
        let config: VariantConfig?
        let digest: String
        let platform: Platform
        let size: Int64?

        struct Platform: Codable, Sendable, Hashable {
            let architecture: String?
            let os: String?
        }

        /// True for attestation manifests (platform.os == "unknown").
        var isAttestation: Bool { platform.os == "unknown" }

        /// Human-readable platform label, e.g. "linux/arm64".
        var platformLabel: String {
            let parts = [platform.os, platform.architecture].compactMap { $0 }
            return parts.isEmpty ? "unknown" : parts.joined(separator: "/")
        }
    }

    // MARK: - VariantConfig

    struct VariantConfig: Codable, Sendable, Hashable {
        let architecture: String?
        let os: String?
        /// ISO 8601 with optional fractional seconds — kept as String to avoid
        /// decoding failures (standard .iso8601 strategy rejects fractional seconds).
        let created: String?
        let config: RuntimeConfig?
        let history: [HistoryEntry]?
        let rootfs: RootFS?
    }

    // MARK: - RuntimeConfig

    struct RuntimeConfig: Codable, Sendable, Hashable {
        let cmd: [String]?
        let entrypoint: [String]?
        let env: [String]?
        let workingDir: String?
        let labels: [String: String]?
        let exposedPorts: [String: EmptyObject]?

        enum CodingKeys: String, CodingKey {
            case cmd = "Cmd"
            case entrypoint = "Entrypoint"
            case env = "Env"
            case workingDir = "WorkingDir"
            case labels = "Labels"
            case exposedPorts = "ExposedPorts"
        }
    }

    /// Placeholder value type for `ExposedPorts` map entries (always empty `{}`).
    struct EmptyObject: Codable, Sendable, Hashable {}

    // MARK: - HistoryEntry

    struct HistoryEntry: Codable, Sendable, Hashable {
        let createdBy: String?
        let emptyLayer: Bool?
        let comment: String?
        /// ISO 8601 creation timestamp (may contain fractional seconds).
        let created: String?

        enum CodingKeys: String, CodingKey {
            case createdBy = "created_by"
            case emptyLayer = "empty_layer"
            case comment
            case created
        }

        /// Shell-noise stripped command suitable for display.
        var displayCommand: String {
            guard var cmd = createdBy else { return "" }
            // Strip shell wrapper prefixes
            for prefix in ["/bin/sh -c #(nop) ", "/bin/sh -c "] {
                if cmd.hasPrefix(prefix) {
                    cmd = String(cmd.dropFirst(prefix.count))
                    break
                }
            }
            // Strip buildkit suffix
            if let range = cmd.range(of: " # buildkit") {
                cmd = String(cmd[..<range.lowerBound])
            }
            return cmd.trimmingCharacters(in: .whitespaces)
        }
    }

    // MARK: - RootFS

    struct RootFS: Codable, Sendable, Hashable {
        let diffIds: [String]?
        let type: String?

        enum CodingKeys: String, CodingKey {
            case diffIds = "diff_ids"
            case type
        }
    }
}

// MARK: - Date formatting helper

extension String {
    /// Formats an ISO 8601 timestamp string (with or without fractional seconds)
    /// to "YYYY-MM-DD HH:MM:SS" by taking the first 19 characters and replacing "T".
    var formattedTimestamp: String {
        guard count >= 19 else { return self }
        return String(prefix(19)).replacingOccurrences(of: "T", with: " ")
    }
}
