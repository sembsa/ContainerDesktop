import Foundation

/// `container` argv for each tool. Pure, so the mapping is unit-tested without
/// a running service.
enum ContainerArgv {
    static let defaultLogLines = 200

    static func list(all: Bool) -> [String] { all ? ["ls", "-a"] : ["ls"] }

    /// One line more than asked: the CLI's tail hands back the first line cut
    /// mid-way (apple/container#2022), same as `LogTailLimit`. Dropped on arrival.
    static func logs(id: String, tail: Int, boot: Bool) -> [String] {
        ["logs"] + (boot ? ["--boot"] : []) + ["-n", String(tail + 1), id]
    }

    static func delete(id: String, force: Bool) -> [String] {
        ["rm"] + (force ? ["--force"] : []) + [id]
    }

    static func exec(id: String, command: [String], workdir: String?, user: String?, env: [(String, String)]) -> [String] {
        var args = ["exec"]
        if let workdir, !workdir.isEmpty { args += ["--workdir", workdir] }
        if let user, !user.isEmpty { args += ["--user", user] }
        for (key, value) in env { args += ["--env", "\(key)=\(value)"] }
        return args + [id] + command
    }

    /// `container run`, through the app's own `RunCommandBuilder`.
    static func run(_ arguments: ToolArguments) throws -> [String] {
        var config = RunConfiguration()
        config.image = try arguments.requiredString("image")
        config.name = try arguments.string("name") ?? ""
        config.network = try arguments.string("network") ?? ""
        config.cpus = try arguments.int("cpus").map(String.init) ?? ""
        config.memory = try arguments.string("memory") ?? ""
        config.workdir = try arguments.string("workdir") ?? ""
        config.removeOnExit = try arguments.bool("remove") ?? false
        // The builder tokenizes `command`; joinCommand is its documented inverse.
        config.command = RunCommandBuilder.joinCommand(try arguments.strings("command"))
        config.environment = try arguments.stringMap("env").map { RunConfiguration.KeyValue(key: $0.0, value: $0.1) }
        config.ports = try arguments.strings("ports").map(port)
        config.volumes = try arguments.strings("volumes").map(volume)
        return RunCommandBuilder.arguments(for: config, progress: "none", detach: try arguments.bool("detach") ?? true)
    }

    /// `8080:80` or `127.0.0.1:8080:80/udp`.
    static func port(_ spec: String) throws -> RunConfiguration.PortMapping {
        let (body, proto) = spec.split(separator: "/", maxSplits: 1).map(String.init).splitFirst()
        let parts = body.split(separator: ":").map(String.init)
        guard parts.count >= 2, let container = parts.last, Int(container) != nil else {
            throw InvalidParams("port '\(spec)' must look like HOST:CONTAINER[/tcp|udp]")
        }
        return RunConfiguration.PortMapping(host: parts.dropLast().joined(separator: ":"), container: container, proto: proto ?? "tcp")
    }

    /// `name-or-/host/path:/container/path[:ro]`.
    static func volume(_ spec: String) throws -> RunConfiguration.VolumeMount {
        var parts = spec.split(separator: ":").map(String.init)
        let readOnly = parts.count == 3 && parts.last == "ro"
        if readOnly { parts.removeLast() }
        guard parts.count == 2 else {
            throw InvalidParams("volume '\(spec)' must look like SOURCE:DESTINATION[:ro]")
        }
        return RunConfiguration.VolumeMount(source: parts[0], destination: parts[1], readOnly: readOnly)
    }

    static func imagePull(reference: String, platform: String?) -> [String] {
        ["image", "pull", "--progress", "none"] + (platform.map { ["--platform", $0] } ?? []) + [reference]
    }

    static func volumeCreate(name: String, size: String?) -> [String] {
        ["volume", "create"] + (size.map { ["-s", $0] } ?? []) + [name]
    }

    static func networkCreate(name: String, subnet: String?, hostOnly: Bool) -> [String] {
        ["network", "create"] + (hostOnly ? ["--internal"] : []) + (subnet.map { ["--subnet", $0] } ?? []) + [name]
    }

    /// `--` is mandatory before a command with its own flags (see `MachineCommands`).
    static func machineRun(name: String?, command: [String], root: Bool) -> [String] {
        ["machine", "run"] + (name.map { ["-n", $0] } ?? []) + (root ? ["--root"] : []) + ["--"] + command
    }
}

private extension Array where Element == String {
    func splitFirst() -> (String, String?) { (first ?? "", count > 1 ? self[1] : nil) }
}

/// The v1 tools: thin wrappers over the `container` CLI.
enum ContainerTools {
    private static var cli: ContainerCLI { .shared }

    static let all: [MCPTool] = [
        MCPTool(
            name: "container_list",
            description: "List containers (compact summary: id, image, state, IP, ports, labels). Running only unless all=true. Kubernetes cluster nodes are hidden, as in the app.",
            schema: #"{"type":"object","properties":{"all":{"type":"boolean","description":"Include stopped containers"}}}"#,
            readOnly: true
        ) { args in
            let items = try await cli.json(ContainerArgv.list(all: try args.bool("all") ?? false), as: [ContainerInfo].self)
            return .text(try encode(items.filter { !isClusterNode($0) }.map(ContainerSummary.init)))
        },
        MCPTool(
            name: "container_inspect",
            description: "Full JSON configuration and status of one container.",
            schema: idSchema,
            readOnly: true
        ) { args in
            .text(try await cli.run(["inspect", try args.requiredString("id")]))
        },
        MCPTool(
            name: "container_logs",
            description: "Last lines of a container's stdout/stderr log.",
            schema: #"{"type":"object","properties":{"id":{"type":"string"},"tail":{"type":"integer","description":"Lines from the end (default 200)"},"boot":{"type":"boolean","description":"Show the VM boot log instead"}},"required":["id"]}"#,
            readOnly: true
        ) { args in
            let tail = max(1, try args.int("tail") ?? ContainerArgv.defaultLogLines)
            let output = try await cli.run(ContainerArgv.logs(id: try args.requiredString("id"), tail: tail, boot: try args.bool("boot") ?? false))
            let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
            return .text(lines.suffix(tail).joined(separator: "\n"))
        },
        MCPTool(
            name: "container_run",
            description: "Create and start a container from an image. Detached by default; returns the container id. With detach=false waits up to 10 minutes and returns stdout, stderr and the exit code.",
            schema: #"""
            {"type":"object","properties":{
              "image":{"type":"string"},
              "name":{"type":"string"},
              "command":{"type":"array","items":{"type":"string"},"description":"Process arguments after the image"},
              "env":{"type":"object","additionalProperties":{"type":"string"}},
              "ports":{"type":"array","items":{"type":"string"},"description":"HOST:CONTAINER[/tcp|udp], e.g. 8080:80"},
              "volumes":{"type":"array","items":{"type":"string"},"description":"SOURCE:DESTINATION[:ro]; source is a volume name or host path"},
              "network":{"type":"string"},
              "cpus":{"type":"integer"},
              "memory":{"type":"string","description":"e.g. 1G"},
              "workdir":{"type":"string"},
              "remove":{"type":"boolean","description":"Delete the container when it exits"},
              "detach":{"type":"boolean","description":"Default true"}},
             "required":["image"]}
            """#
        ) { args in
            let argv = try ContainerArgv.run(args)
            if try args.bool("detach") ?? true {
                return .text(try await cli.run(argv, timeout: .seconds(600)))
            }
            return processResult(try await cli.runRaw(argv, timeout: .seconds(600)))
        },
        MCPTool(name: "container_start", description: "Start a stopped container.", schema: idSchema) { args in
            try await cli.run(["start", try args.requiredString("id")], timeout: .seconds(120))
            return .text("started")
        },
        MCPTool(name: "container_stop", description: "Stop a running container. Refuses Kubernetes cluster nodes.", schema: idSchema) { args in
            let id = try args.requiredString("id")
            try await refuseClusterNode(id)
            try await cli.run(["stop", id], timeout: .seconds(120))
            return .text("stopped")
        },
        MCPTool(
            name: "container_delete",
            description: "Delete a container (its writable filesystem is lost). Refuses Kubernetes cluster nodes.",
            schema: #"{"type":"object","properties":{"id":{"type":"string"},"force":{"type":"boolean","description":"Delete even if running"}},"required":["id"]}"#,
            destructive: true
        ) { args in
            let id = try args.requiredString("id")
            try await refuseClusterNode(id)
            try await cli.run(ContainerArgv.delete(id: id, force: try args.bool("force") ?? false), timeout: .seconds(120))
            return .text("deleted")
        },
        MCPTool(
            name: "container_exec",
            description: "Run a non-interactive command in a running container. Returns stdout, stderr and the exit code (exec propagates it faithfully, also through sh -c).",
            schema: #"""
            {"type":"object","properties":{
              "id":{"type":"string"},
              "command":{"type":"array","items":{"type":"string"},"description":"e.g. [\"sh\",\"-c\",\"ls /\"]"},
              "workdir":{"type":"string"},
              "user":{"type":"string"},
              "env":{"type":"object","additionalProperties":{"type":"string"}},
              "timeout":{"type":"integer","description":"Seconds (default 120)"}},
             "required":["id","command"]}
            """#,
            destructive: true
        ) { args in
            let id = try args.requiredString("id")
            let command = try args.strings("command")
            guard !command.isEmpty else { throw InvalidParams("'command' is required") }
            try await refuseClusterNode(id)
            let argv = ContainerArgv.exec(id: id, command: command, workdir: try args.string("workdir"), user: try args.string("user"), env: try args.stringMap("env"))
            return processResult(try await cli.runRaw(argv, timeout: .seconds(max(1, try args.int("timeout") ?? 120))))
        },
        MCPTool(
            name: "image_list",
            description: "List local images (reference, short digest, size, platforms).",
            schema: emptySchema,
            readOnly: true
        ) { _ in
            .text(try encode(try await cli.json(["image", "ls"], as: [ImageInfo].self).map(ImageSummary.init)))
        },
        MCPTool(
            name: "image_pull",
            description: "Pull an image from a registry (up to 15 minutes).",
            schema: #"{"type":"object","properties":{"reference":{"type":"string","description":"e.g. docker.io/library/alpine:latest"},"platform":{"type":"string","description":"e.g. linux/arm64"}},"required":["reference"]}"#
        ) { args in
            let reference = try args.requiredString("reference")
            try await cli.run(ContainerArgv.imagePull(reference: reference, platform: try args.string("platform")), timeout: .seconds(900))
            return .text("pulled \(reference)")
        },
        MCPTool(
            name: "image_delete",
            description: "Delete a local image.",
            schema: #"{"type":"object","properties":{"reference":{"type":"string"}},"required":["reference"]}"#,
            destructive: true
        ) { args in
            try await cli.run(["image", "rm", try args.requiredString("reference")])
            return .text("deleted")
        },
        MCPTool(name: "volume_list", description: "List volumes (raw CLI JSON).", schema: emptySchema, readOnly: true) { _ in
            .text(try await cli.run(["volume", "ls", "--format", "json"]))
        },
        MCPTool(
            name: "volume_create",
            description: "Create a named volume.",
            schema: #"{"type":"object","properties":{"name":{"type":"string"},"size":{"type":"string","description":"e.g. 10G"}},"required":["name"]}"#
        ) { args in
            let name = try args.requiredString("name")
            try await cli.run(ContainerArgv.volumeCreate(name: name, size: try args.string("size")))
            return .text("created volume \(name)")
        },
        MCPTool(name: "volume_delete", description: "Delete a volume and all data in it.", schema: nameSchema, destructive: true) { args in
            try await cli.run(["volume", "rm", try args.requiredString("name")])
            return .text("deleted")
        },
        MCPTool(name: "network_list", description: "List networks (raw CLI JSON).", schema: emptySchema, readOnly: true) { _ in
            .text(try await cli.run(["network", "ls", "--format", "json"]))
        },
        MCPTool(
            name: "network_create",
            description: "Create a network.",
            schema: #"{"type":"object","properties":{"name":{"type":"string"},"subnet":{"type":"string","description":"CIDR, e.g. 192.168.100.0/24"},"internal":{"type":"boolean","description":"Host-only"}},"required":["name"]}"#
        ) { args in
            let name = try args.requiredString("name")
            try await cli.run(ContainerArgv.networkCreate(name: name, subnet: try args.string("subnet"), hostOnly: try args.bool("internal") ?? false))
            return .text("created network \(name)")
        },
        MCPTool(name: "network_delete", description: "Delete a network.", schema: nameSchema, destructive: true) { args in
            try await cli.run(["network", "rm", try args.requiredString("name")])
            return .text("deleted")
        },
        MCPTool(name: "machine_list", description: "List container machines (raw CLI JSON).", schema: emptySchema, readOnly: true) { _ in
            .text(try await cli.run(["machine", "ls", "--format", "json"]))
        },
        MCPTool(
            name: "machine_run",
            description: "Run a non-interactive command in a container machine, booting it if needed. Returns stdout, stderr and exit code. Pass the program directly: through `sh -c` machine run reports exit 0 whatever happened.",
            schema: #"""
            {"type":"object","properties":{
              "name":{"type":"string","description":"Machine; the default machine when omitted"},
              "command":{"type":"array","items":{"type":"string"}},
              "root":{"type":"boolean","description":"Run as root instead of the host user"},
              "timeout":{"type":"integer","description":"Seconds (default 300)"}},
             "required":["command"]}
            """#,
            destructive: true
        ) { args in
            let command = try args.strings("command")
            guard !command.isEmpty else { throw InvalidParams("'command' is required") }
            let argv = ContainerArgv.machineRun(name: try args.string("name"), command: command, root: try args.bool("root") ?? false)
            return processResult(try await cli.runRaw(argv, timeout: .seconds(max(1, try args.int("timeout") ?? 300))))
        },
        MCPTool(
            name: "system_status",
            description: "Whether the container service runs, CLI and service versions, host and resource counts.",
            schema: emptySchema,
            readOnly: true
        ) { _ in
            let result = try await cli.runRaw(["system", "status", "--format", "json"], timeout: .seconds(15))
            guard result.exitCode == 0 else { return processResult(result) }
            var text = result.stdout
            if let status = try? JSONDecoder().decode(SystemStatus.self, from: Data(text.utf8)),
               let skew = status.versionSkew {
                text += "\n\nWARNING: version skew — CLI \(skew.cli), service \(skew.service). Restart the service (`container system stop && container system start`) before trusting other results."
            }
            return .text(text)
        },
    ]

    // MARK: - Helpers

    private static let emptySchema = #"{"type":"object","properties":{}}"#
    private static let idSchema = #"{"type":"object","properties":{"id":{"type":"string","description":"Container id or name"}},"required":["id"]}"#
    private static let nameSchema = #"{"type":"object","properties":{"name":{"type":"string"}},"required":["name"]}"#

    /// The same rule as `ContainerStore`: a node deleted from a list takes its cluster with it.
    static func isClusterNode(_ container: ContainerInfo) -> Bool {
        K8sCommands.nodeLabelValues.contains(container.configuration.labels?["com.apple.container.plugin"] ?? "")
    }

    private static func refuseClusterNode(_ id: String) async throws {
        let matches = try await cli.json(["inspect", id], as: [ContainerInfo].self, appendFormat: false)
        if matches.contains(where: isClusterNode) {
            throw ToolFailure("'\(id)' is a Kubernetes cluster node. Manage it with `container cluster` (stop/delete the whole cluster), not as a single container.")
        }
    }

    private static func processResult(_ result: ProcessRunner.CommandResult) -> MCPToolResult {
        .text("exit code: \(result.exitCode)\n--- stdout ---\n\(result.stdout)\n--- stderr ---\n\(result.stderr)", isError: result.exitCode != 0)
    }

    private static func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}

/// What an agent needs from `ls`; the full record is `container_inspect`.
struct ContainerSummary: Encodable {
    let id: String
    let image: String
    let state: String
    let ipv4: String?
    let ports: [String]
    let labels: [String: String]?

    init(_ info: ContainerInfo) {
        id = info.id
        image = info.imageReference
        state = info.state
        ipv4 = info.primaryIPv4Address
        ports = (info.configuration.publishedPorts ?? []).map {
            "\($0.hostAddress.map { "\($0):" } ?? "")\($0.hostPort ?? 0)->\($0.containerPort ?? 0)/\($0.proto ?? "tcp")"
        }
        labels = (info.configuration.labels?.isEmpty ?? true) ? nil : info.configuration.labels
    }
}

/// The raw image list is ~40 KB per image (every variant's full config).
struct ImageSummary: Encodable {
    let reference: String
    let digest: String
    let sizeBytes: Int64
    let platforms: [String]

    init(_ info: ImageInfo) {
        reference = info.reference
        digest = info.shortDigest
        sizeBytes = info.totalSize
        platforms = (info.variants ?? []).compactMap { variant in
            guard let os = variant.platform?.os, let arch = variant.platform?.architecture, os != "unknown" else { return nil }
            return [os, arch, variant.platform?.variant].compactMap { $0 }.joined(separator: "/")
        }
    }
}
