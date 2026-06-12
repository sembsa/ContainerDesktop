import Foundation

/// A parsed docker-compose project, ready to be materialized as a group of
/// `container run` invocations. Built by `ComposeParser`; consumed by `ComposeStore`.
struct ComposeProject: Sendable, Hashable {
    /// Project name — prefix for container names and the shared network.
    var name: String
    /// Services in launch order (already topologically sorted by `depends_on`).
    var services: [ComposeService]
    /// Human-readable parse warnings (Polish, via `String(localized:)`).
    var warnings: [String]
    /// `true` when `name` came from a top-level `name:` key in the YAML
    /// (rather than the fallback project name passed to the parser). The UI
    /// uses this to reflect the effective project name back into its text field.
    var nameFromYAML: Bool

    init(name: String, services: [ComposeService], warnings: [String], nameFromYAML: Bool = false) {
        self.name = name
        self.services = services
        self.warnings = warnings
        self.nameFromYAML = nameFromYAML
    }
}

/// A single service entry from a compose file.
struct ComposeService: Sendable, Hashable, Identifiable {
    var id: String { name }
    /// Service key from the YAML mapping.
    var name: String
    var image: String
    /// `container_name` from YAML; overrides the default `project-service` name.
    var containerName: String?
    /// Command as a single string (a YAML string, or a list joined via `RunCommandBuilder.joinCommand`).
    var command: String
    var entrypoint: String
    var workdir: String
    var user: String
    var environment: [(key: String, value: String)]
    /// Short-syntax port mappings, e.g. "8080:80" or "8080:80/udp".
    var ports: [String]
    /// Volume specs, e.g. "src:dst" or "src:dst:ro".
    var volumes: [String]
    var dependsOn: [String]
    /// Memory limit for the container VM (CLI --memory format, e.g. "4G", "512M").
    var memory: String = ""
    /// CPU limit (CLI --cpus).
    var cpus: String = ""
    /// `true` for one-off init tasks (compose extension `x-init: true`). Init
    /// services run first, sequentially and blocking, before regular services.
    var isInit: Bool

    /// The container's resolved name within the project.
    func resolvedName(project: String) -> String { containerName ?? "\(project)-\(name)" }

    // Tuple arrays aren't auto-Equatable/Hashable; provide explicit conformances.
    static func == (lhs: ComposeService, rhs: ComposeService) -> Bool {
        lhs.name == rhs.name
            && lhs.image == rhs.image
            && lhs.containerName == rhs.containerName
            && lhs.command == rhs.command
            && lhs.entrypoint == rhs.entrypoint
            && lhs.workdir == rhs.workdir
            && lhs.user == rhs.user
            && lhs.environment.count == rhs.environment.count
            && zip(lhs.environment, rhs.environment).allSatisfy { $0.key == $1.key && $0.value == $1.value }
            && lhs.ports == rhs.ports
            && lhs.volumes == rhs.volumes
            && lhs.dependsOn == rhs.dependsOn
            && lhs.memory == rhs.memory
            && lhs.cpus == rhs.cpus
            && lhs.isInit == rhs.isInit
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(name)
        hasher.combine(image)
        hasher.combine(containerName)
        hasher.combine(command)
        hasher.combine(entrypoint)
        hasher.combine(workdir)
        hasher.combine(user)
        for pair in environment {
            hasher.combine(pair.key)
            hasher.combine(pair.value)
        }
        hasher.combine(ports)
        hasher.combine(volumes)
        hasher.combine(dependsOn)
        hasher.combine(memory)
        hasher.combine(cpus)
        hasher.combine(isInit)
    }

    init(
        name: String,
        image: String,
        containerName: String? = nil,
        command: String = "",
        entrypoint: String = "",
        workdir: String = "",
        user: String = "",
        environment: [(key: String, value: String)] = [],
        ports: [String] = [],
        volumes: [String] = [],
        dependsOn: [String] = [],
        memory: String = "",
        cpus: String = "",
        isInit: Bool = false
    ) {
        self.name = name
        self.image = image
        self.containerName = containerName
        self.command = command
        self.entrypoint = entrypoint
        self.workdir = workdir
        self.user = user
        self.environment = environment
        self.ports = ports
        self.volumes = volumes
        self.dependsOn = dependsOn
        self.memory = memory
        self.cpus = cpus
        self.isInit = isInit
    }
}
