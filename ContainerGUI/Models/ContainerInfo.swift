import Foundation

/// A container as reported by `container ls -a --format json` / `container inspect`.
struct ContainerInfo: Codable, Identifiable, Sendable, Hashable {
    let id: String
    let configuration: Configuration
    let status: Status?

    /// Which engine reported this container. Never part of the JSON: Apple's CLI
    /// does not emit it and Docker output is mapped by `DockerContainerMapper`.
    var runtime: RuntimeKind = .apple
    /// Engine-local name used on that engine's command line. `nil` means `id`.
    /// Differs from `id` only when a Docker container shares its name with an
    /// Apple one and `id` had to be made unique for the list.
    var runtimeReference: String? = nil
    /// Which configured runtime instance owns the container: `nil` for the
    /// built-in Apple/Docker runtimes, an external machine's runtime id
    /// (`docker:<uuid>`) for a container reached over SSH.
    var runtimeID: String? = nil
    /// Label of the external machine (the entry's name in External Machines),
    /// exactly as the user typed it. `nil` for containers on this Mac.
    var machineLabel: String? = nil
    /// Where the container runs. Stored apart from `machineLabel` so nothing has
    /// to parse a combined string.
    var location: ContainerLocation = .local
    /// The engine actually running it when that is finer than `runtime`
    /// (Colima is a Docker-API engine). `nil` means the engine follows `runtime`.
    var engineOverride: ContainerEngine? = nil

    private enum CodingKeys: String, CodingKey {
        case id, configuration, status
    }

    /// What to pass to the owning engine's CLI.
    var reference: String { runtimeReference ?? id }

    /// Key matching `ContainerRuntime.id`.
    var runtimeKey: String { runtimeID ?? runtime.rawValue }

    /// The engine shown as the runtime tag: "Apple", "Docker" or "Colima".
    var engine: ContainerEngine { engineOverride ?? (runtime == .apple ? .apple : .docker) }

    /// Text of the location tag, localized: "Local" / "External".
    var locationTitle: String { location.title }

    /// The three list tags, in display order: location, machine name (external
    /// only), runtime.
    var sourceTags: [SourceTag] {
        var tags = [SourceTag(kind: .location, text: locationTitle)]
        if location == .external, let machineLabel { tags.append(SourceTag(kind: .machine, text: machineLabel)) }
        tags.append(SourceTag(kind: .runtime, text: engine.title))
        return tags
    }

    /// Everything the search field matches against for the tags.
    var sourceSearchStrings: [String] { sourceTags.map(\.text) }

    /// Whether the search field's text (already lowercased and trimmed) matches
    /// the id, image, Compose project / service, IP, or any of the three tags.
    func matchesSearch(_ needle: String) -> Bool {
        guard !needle.isEmpty else { return true }
        let fields = [id, imageReference, composeProject ?? "", composeService ?? "", primaryIPv4Address ?? ""]
        return (fields + sourceSearchStrings).contains { $0.lowercased().contains(needle) }
    }

    /// Suffix that tells two same-named containers apart: machine label (when
    /// external) and runtime, e.g. "Docker" or "studio · Colima".
    var disambiguator: String {
        ([machineLabel].compactMap { $0 } + [engine.title]).joined(separator: " · ")
    }

    /// The same container under another UI identity or owner. `reference` is
    /// preserved, so commands still address the engine-local name. Passing a
    /// `machineLabel` makes the container external.
    func with(
        id newID: String? = nil,
        reference newReference: String? = nil,
        runtimeID: String? = nil,
        machineLabel: String? = nil,
        engine: ContainerEngine? = nil
    ) -> ContainerInfo {
        ContainerInfo(
            id: newID ?? id,
            configuration: configuration,
            status: status,
            runtime: runtime,
            runtimeReference: newReference ?? reference,
            runtimeID: runtimeID ?? self.runtimeID,
            machineLabel: machineLabel ?? self.machineLabel,
            location: machineLabel != nil ? .external : location,
            engineOverride: engine ?? engineOverride
        )
    }

    var state: String { status?.state ?? "stopped" }
    var isRunning: Bool { state.lowercased() == "running" }
    var imageReference: String { configuration.image.reference }
    var primaryIPv4: String? { status?.networks?.first?.ipv4Address }

    /// `primaryIPv4` without the CIDR suffix — the CLI reports `192.168.69.4/24`,
    /// which is noise anywhere the address is shown as an identifier.
    var primaryIPv4Address: String? {
        primaryIPv4.map { String($0.split(separator: "/").first ?? "") }
    }

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
        let networks: [NetworkRef]?
        /// `--read-only-path` (container 1.2.1). Note the lowercase "o" — the
        /// CLI emits `readonlyPaths`, not `readOnlyPaths`.
        let readonlyPaths: [String]?
        /// `--masked-path` (container 1.2.1).
        let maskedPaths: [String]?

        struct NetworkRef: Codable, Sendable, Hashable {
            let network: String?
        }

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
