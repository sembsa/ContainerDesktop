import Foundation

/// A container as reported by `container ls -a --format json` / `container inspect`.
struct ContainerInfo: Codable, Identifiable, Sendable, Hashable {
    let id: String
    let configuration: Configuration
    let status: Status?

    var state: String { status?.state ?? "stopped" }
    var isRunning: Bool { state.lowercased() == "running" }
    var imageReference: String { configuration.image.reference }
    var primaryIPv4: String? { status?.networks?.first?.ipv4Address }

    // MARK: - Grouping helpers

    var composeProject: String? { configuration.labels?["compose.project"] }
    var composeService: String? { configuration.labels?["compose.service"] }
    var architecture: String? { configuration.platform?.architecture }

    struct Configuration: Codable, Sendable, Hashable {
        let id: String
        let image: ImageRef
        let creationDate: Date?
        let labels: [String: String]?
        let resources: Resources?
        let platform: Platform?
        let initProcess: InitProcess?
        let publishedPorts: [PublishedPort]?
        let mounts: [Mount]?
        let rosetta: Bool?
        let runtimeHandler: String?
        let readOnly: Bool?
        let ssh: Bool?
        let virtualization: Bool?

        struct ImageRef: Codable, Sendable, Hashable {
            let reference: String
            let descriptor: Descriptor?

            struct Descriptor: Codable, Sendable, Hashable {
                let digest: String?
            }
        }

        struct Resources: Codable, Sendable, Hashable {
            let cpus: Int?
            let memoryInBytes: Int64?
        }

        struct Platform: Codable, Sendable, Hashable {
            let architecture: String?
            let os: String?
        }

        struct InitProcess: Codable, Sendable, Hashable {
            let executable: String?
            let arguments: [String]?
            let environment: [String]?
            let workingDirectory: String?
        }

        struct PublishedPort: Codable, Sendable, Hashable, Identifiable {
            let hostAddress: String?
            let hostPort: Int?
            let containerPort: Int?
            let proto: String?

            var id: String { "\(hostAddress ?? "")-\(hostPort ?? 0)-\(containerPort ?? 0)-\(proto ?? "")" }
            var display: String {
                let host = (hostAddress.map { $0 == "0.0.0.0" ? "" : "\($0):" }) ?? ""
                return "\(host)\(hostPort ?? 0) → \(containerPort ?? 0)/\(proto ?? "tcp")"
            }
        }

        struct Mount: Codable, Sendable, Hashable, Identifiable {
            let source: String?
            let destination: String?
            let type: MountType?

            var id: String { "\(source ?? "")-\(destination ?? "")" }

            /// Returns the volume name when the mount is a named volume, otherwise the source path.
            var preferredSource: String? { type?.volume?.name ?? source }

            struct MountType: Codable, Sendable, Hashable {
                let volume: VolumeRef?

                struct VolumeRef: Codable, Sendable, Hashable {
                    let name: String?
                }
            }
        }
    }

    struct Status: Codable, Sendable, Hashable {
        let state: String
        let startedDate: Date?
        let networks: [NetworkStatus]?

        struct NetworkStatus: Codable, Sendable, Hashable {
            let hostname: String?
            let ipv4Address: String?
            let network: String?
        }
    }
}
