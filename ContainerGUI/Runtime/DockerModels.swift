import Foundation

// MARK: - Raw Docker output (decoders only; nothing outside the runtime layer uses these)

/// One line of `docker ps -a --format '{{json .}}'`. Every field is a string.
struct DockerPSRow: Decodable, Sendable, Hashable {
    let ID: String
    let Names: String
    let Image: String?
    let State: String?
    let Status: String?
    let Ports: String?
    let Labels: String?
    let Networks: String?
    let Mounts: String?
    let CreatedAt: String?
    let Command: String?

    /// Parses the newline-delimited JSON `--format '{{json .}}'` produces.
    static func decodeLines(_ output: String) throws -> [DockerPSRow] {
        try DockerJSONLines.decode(DockerPSRow.self, from: output)
    }
}

/// One line of `docker stats --no-stream --format '{{json .}}'`.
struct DockerStatsRow: Decodable, Sendable, Hashable {
    let ID: String
    let Name: String
    let CPUPerc: String?
    let MemUsage: String?
    let NetIO: String?
    let BlockIO: String?
    let PIDs: String?

    static func decodeLines(_ output: String) throws -> [DockerStatsRow] {
        try DockerJSONLines.decode(DockerStatsRow.self, from: output)
    }
}

enum DockerJSONLines {
    static func decode<T: Decodable>(_ type: T.Type, from output: String) throws -> [T] {
        let decoder = JSONDecoder()
        var result: [T] = []
        for line in output.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            do {
                result.append(try decoder.decode(T.self, from: Data(trimmed.utf8)))
            } catch {
                throw CLIError.decoding(String(describing: error))
            }
        }
        return result
    }
}

/// An element of the array `docker inspect` prints. Only the fields the app
/// uses are declared; the Inspect tab shows the raw text, not this.
struct DockerInspect: Decodable, Sendable, Hashable {
    let Id: String
    let Name: String
    let Created: String?
    let Path: String?
    let Args: [String]?
    let Platform: String?
    let Image: String?
    let State: State?
    let Config: Config?
    let HostConfig: HostConfig?
    let NetworkSettings: NetworkSettings?
    let Mounts: [Mount]?

    struct State: Decodable, Sendable, Hashable {
        let Status: String?
        let Running: Bool?
        let StartedAt: String?
    }

    struct Config: Decodable, Sendable, Hashable {
        let Hostname: String?
        let Image: String?
        let Env: [String]?
        let WorkingDir: String?
        let Labels: [String: String]?
    }

    struct HostConfig: Decodable, Sendable, Hashable {
        let NetworkMode: String?
        let PortBindings: [String: [PortBinding]?]?
        let ReadonlyRootfs: Bool?
        let Runtime: String?
        let NanoCpus: Int64?
        let Memory: Int64?
        let MaskedPaths: [String]?
        let ReadonlyPaths: [String]?
    }

    struct PortBinding: Decodable, Sendable, Hashable {
        let HostIp: String?
        let HostPort: String?
    }

    struct NetworkSettings: Decodable, Sendable, Hashable {
        let Ports: [String: [PortBinding]?]?
        let Networks: [String: Endpoint]?
    }

    struct Endpoint: Decodable, Sendable, Hashable {
        let IPAddress: String?
        let IPPrefixLen: Int?
    }

    struct Mount: Decodable, Sendable, Hashable {
        let `Type`: String?
        let Name: String?
        let Source: String?
        let Destination: String?
    }

    /// `docker inspect` prints a JSON array, even for one container.
    static func decodeArray(_ output: String) throws -> [DockerInspect] {
        guard let data = output.data(using: .utf8), !data.isEmpty else {
            throw CLIError.decoding(String(localized: "pusta odpowiedź"))
        }
        do {
            return try JSONDecoder().decode([DockerInspect].self, from: data)
        } catch {
            throw CLIError.decoding(String(describing: error))
        }
    }
}

// MARK: - Normalisation

/// Maps Docker's vocabulary onto the models the Apple runtime already uses, so
/// views and stores render both engines identically.
///
/// | Docker                                   | Model field                                   |
/// |------------------------------------------|-----------------------------------------------|
/// | inspect `Name` (without `/`)             | `id`, `configuration.id`, `runtimeReference`  |
/// | `Config.Image`                           | `configuration.image.reference`               |
/// | `Image` (sha256 image id)                | `configuration.image.descriptor.digest`       |
/// | `Created`                                | `configuration.creationDate`                  |
/// | `State.Status` (running/exited/created…) | `status.state` (running / stopped / as-is)    |
/// | `State.StartedAt` (when running)         | `status.startedDate`                          |
/// | `Config.Labels` (+ compose aliases)      | `configuration.labels`                        |
/// | `Path`, `Args`, `Config.Env/WorkingDir`  | `configuration.initProcess`                   |
/// | `NetworkSettings.Ports` / `PortBindings` | `configuration.publishedPorts`                |
/// | `Mounts`                                 | `configuration.mounts`                        |
/// | `NetworkSettings.Networks[*].IPAddress`  | `status.networks[*].ipv4Address` (CIDR form)  |
/// | `HostConfig.NanoCpus` / `Memory`         | `configuration.resources` (when limited)      |
/// | `HostConfig.ReadonlyRootfs`              | `configuration.readOnly`                      |
/// | `HostConfig.Runtime`                     | `configuration.runtimeHandler`                |
/// | image architecture (`image inspect`)     | `configuration.platform.architecture`         |
enum DockerContainerMapper {

    /// Docker has seven states, the app's views know two: "running" and anything
    /// else. Exited/created/dead collapse to Apple's "stopped"; paused and
    /// restarting stay as they are and render in the neutral (orange) colour.
    static func normalizedState(_ dockerState: String?) -> String {
        switch (dockerState ?? "").lowercased() {
        case "running": "running"
        case "exited", "created", "dead", "": "stopped"
        default: (dockerState ?? "").lowercased()
        }
    }

    // MARK: Inspect -> ContainerInfo

    /// - Parameter architectures: image id -> architecture, from `image inspect`.
    static func map(_ inspect: DockerInspect, architectures: [String: String] = [:]) -> ContainerInfo {
        let name = inspect.Name.hasPrefix("/") ? String(inspect.Name.dropFirst()) : inspect.Name
        let state = normalizedState(inspect.State?.Status)
        let host = inspect.HostConfig

        var labels = inspect.Config?.Labels ?? [:]
        // Compose grouping in the list keys off `compose.project` / `compose.service`.
        if labels["compose.project"] == nil, let project = labels["com.docker.compose.project"] {
            labels["compose.project"] = project
        }
        if labels["compose.service"] == nil, let service = labels["com.docker.compose.service"] {
            labels["compose.service"] = service
        }

        let networkEndpoints = (inspect.NetworkSettings?.Networks ?? [:]).sorted { $0.key < $1.key }
        let networkNames: [String] = networkEndpoints.isEmpty
            ? [host?.NetworkMode].compactMap { $0 }.filter { !$0.isEmpty }
            : networkEndpoints.map(\.key)

        let statusNetworks: [ContainerInfo.Status.NetworkStatus] = networkEndpoints.compactMap { entry in
            guard let ip = entry.value.IPAddress, !ip.isEmpty else { return nil }
            let cidr = entry.value.IPPrefixLen.map { "\(ip)/\($0)" } ?? ip
            return .init(hostname: inspect.Config?.Hostname, ipv4Address: cidr, network: entry.key)
        }

        let resources: ContainerInfo.Configuration.Resources? = {
            let cpus = (host?.NanoCpus).flatMap { $0 > 0 ? Int(($0 + 999_999_999) / 1_000_000_000) : nil }
            let memory = (host?.Memory).flatMap { $0 > 0 ? $0 : nil }
            return cpus == nil && memory == nil ? nil : .init(cpus: cpus, memoryInBytes: memory)
        }()

        let imageID = inspect.Image
        let configuration = ContainerInfo.Configuration(
            id: name,
            image: .init(
                reference: inspect.Config?.Image ?? imageID ?? "",
                descriptor: imageID.map { .init(digest: $0) }
            ),
            creationDate: inspect.Created.flatMap(parseDate),
            labels: labels,
            resources: resources,
            platform: .init(architecture: imageID.flatMap { architectures[$0] }, os: inspect.Platform ?? "linux"),
            initProcess: .init(
                executable: inspect.Path,
                arguments: inspect.Args,
                environment: inspect.Config?.Env,
                workingDirectory: inspect.Config?.WorkingDir
            ),
            publishedPorts: publishedPorts(from: inspect),
            mounts: (inspect.Mounts ?? []).map(mapMount),
            rosetta: nil,
            runtimeHandler: host?.Runtime,
            readOnly: host?.ReadonlyRootfs,
            ssh: nil,
            virtualization: nil,
            networks: networkNames.map { .init(network: $0) },
            readonlyPaths: host?.ReadonlyPaths,
            maskedPaths: host?.MaskedPaths
        )

        let started: Date? = state == "running" ? inspect.State?.StartedAt.flatMap(parseDate) : nil
        return ContainerInfo(
            id: name,
            configuration: configuration,
            status: .init(state: state, startedDate: started, networks: statusNetworks),
            runtime: .docker,
            runtimeReference: name
        )
    }

    private static func mapMount(_ mount: DockerInspect.Mount) -> ContainerInfo.Configuration.Mount {
        let volume: ContainerInfo.Configuration.Mount.MountType? =
            mount.Type == "volume" ? .init(volume: .init(name: mount.Name)) : nil
        return .init(source: mount.Source, destination: mount.Destination, type: volume)
    }

    /// Published ports for a running container come from `NetworkSettings.Ports`;
    /// a stopped one has none there, so its configured `PortBindings` are used.
    private static func publishedPorts(from inspect: DockerInspect) -> [ContainerInfo.Configuration.PublishedPort] {
        let live = inspect.NetworkSettings?.Ports ?? [:]
        let hasLive = live.values.contains { ($0 ?? []).isEmpty == false }
        let source = hasLive ? live : (inspect.HostConfig?.PortBindings ?? [:])

        var result: [ContainerInfo.Configuration.PublishedPort] = []
        for (key, bindings) in source.sorted(by: { $0.key < $1.key }) {
            let parts = key.split(separator: "/")
            let containerPort = parts.first.flatMap { Int($0) }
            let proto = parts.count > 1 ? String(parts[1]) : "tcp"
            for binding in bindings ?? [] {
                guard let hostPort = binding.HostPort.flatMap({ Int($0) }) else { continue }
                let address = (binding.HostIp?.isEmpty ?? true) ? "0.0.0.0" : binding.HostIp
                // Docker lists IPv4 and IPv6 wildcard bindings separately; one
                // row per mapping is enough.
                if address == "::", result.contains(where: { $0.hostPort == hostPort && $0.containerPort == containerPort && $0.proto == proto }) {
                    continue
                }
                result.append(.init(hostAddress: address, hostPort: hostPort, containerPort: containerPort, proto: proto))
            }
        }
        return result
    }

    // MARK: ps row -> ContainerInfo (fallback when inspect is unavailable)

    static func map(_ row: DockerPSRow) -> ContainerInfo {
        let name = row.Names.split(separator: ",").first.map(String.init) ?? row.ID
        var labels: [String: String] = [:]
        for pair in (row.Labels ?? "").split(separator: ",") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2 { labels[String(kv[0])] = String(kv[1]) }
        }
        if let project = labels["com.docker.compose.project"] { labels["compose.project"] = project }
        if let service = labels["com.docker.compose.service"] { labels["compose.service"] = service }

        let configuration = ContainerInfo.Configuration(
            id: name,
            image: .init(reference: row.Image ?? "", descriptor: nil),
            creationDate: nil,
            labels: labels,
            resources: nil,
            platform: .init(architecture: nil, os: "linux"),
            initProcess: nil,
            publishedPorts: parsePorts(row.Ports ?? ""),
            mounts: nil,
            rosetta: nil,
            runtimeHandler: nil,
            readOnly: nil,
            ssh: nil,
            virtualization: nil,
            networks: (row.Networks ?? "").split(separator: ",").map { .init(network: String($0)) },
            readonlyPaths: nil,
            maskedPaths: nil
        )
        return ContainerInfo(
            id: name,
            configuration: configuration,
            status: .init(state: normalizedState(row.State), startedDate: nil, networks: nil),
            runtime: .docker,
            runtimeReference: name
        )
    }

    /// Parses `0.0.0.0:8088->80/tcp, :::8088->80/tcp, 443/tcp`.
    static func parsePorts(_ text: String) -> [ContainerInfo.Configuration.PublishedPort] {
        var result: [ContainerInfo.Configuration.PublishedPort] = []
        for chunk in text.split(separator: ",") {
            let item = chunk.trimmingCharacters(in: .whitespaces)
            guard let arrow = item.range(of: "->") else { continue }   // exposed but unpublished
            let left = item[..<arrow.lowerBound]
            let right = item[arrow.upperBound...]
            guard let colon = left.lastIndex(of: ":"),
                  let hostPort = Int(left[left.index(after: colon)...]) else { continue }
            let address = String(left[..<colon])
            let rightParts = right.split(separator: "/")
            guard let containerPort = rightParts.first.flatMap({ Int($0) }) else { continue }
            let proto = rightParts.count > 1 ? String(rightParts[1]) : "tcp"
            if address == "::" || address == "[::]" { continue }
            result.append(.init(hostAddress: address.isEmpty ? "0.0.0.0" : address, hostPort: hostPort, containerPort: containerPort, proto: proto))
        }
        return result
    }

    // MARK: Stats row -> StatsSample

    /// - Parameter cpuMicroseconds: cumulative CPU time. Docker only reports a
    ///   percentage, so the runtime integrates it into the same monotonically
    ///   growing counter Apple's CLI emits; the store and the charts then turn
    ///   it back into a rate without knowing which engine produced it.
    static func map(_ row: DockerStatsRow, cpuMicroseconds: Int64?) -> StatsSample {
        let (memUsed, memLimit) = bytePair(row.MemUsage)
        let (netRx, netTx) = bytePair(row.NetIO)
        let (blockRead, blockWrite) = bytePair(row.BlockIO)
        return StatsSample(
            id: row.Name,
            cpuUsageUsec: cpuMicroseconds,
            memoryUsageBytes: memUsed,
            memoryLimitBytes: memLimit,
            blockReadBytes: blockRead,
            blockWriteBytes: blockWrite,
            networkRxBytes: netRx,
            networkTxBytes: netTx,
            numProcesses: row.PIDs.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        )
    }

    /// `"12.5%"` -> 12.5
    static func parsePercent(_ text: String?) -> Double? {
        guard let text else { return nil }
        return Double(text.trimmingCharacters(in: CharacterSet(charactersIn: "% ")))
    }

    /// `"9.035MiB / 15.6GiB"` -> both sides in bytes.
    static func bytePair(_ text: String?) -> (Int64?, Int64?) {
        guard let text else { return (nil, nil) }
        let parts = text.split(separator: "/", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2 else { return (nil, nil) }
        return (parseBytes(parts[0]), parseBytes(parts[1]))
    }

    /// Docker prints decimal units for I/O (`kB`, `MB`) and binary ones for
    /// memory (`MiB`, `GiB`).
    static func parseBytes(_ text: String) -> Int64? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let unitStart = trimmed.firstIndex(where: { $0.isLetter }) else { return nil }
        guard let value = Double(trimmed[..<unitStart].trimmingCharacters(in: .whitespaces)) else { return nil }
        let multipliers: [String: Double] = [
            "b": 1,
            "kb": 1e3, "mb": 1e6, "gb": 1e9, "tb": 1e12,
            "kib": 1024, "mib": 1_048_576, "gib": 1_073_741_824, "tib": 1_099_511_627_776,
        ]
        guard let multiplier = multipliers[String(trimmed[unitStart...]).lowercased()] else { return nil }
        return Int64(value * multiplier)
    }

    // MARK: Dates

    /// Docker timestamps carry nanoseconds (`2026-10-04T07:23:29.018136046Z`);
    /// `ISO8601DateFormatter` only copes with milliseconds, so the fraction is cut.
    static func parseDate(_ text: String) -> Date? {
        var value = text
        if let dot = value.firstIndex(of: "."), let zone = value.lastIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }), zone > dot {
            let fraction = value[value.index(after: dot)..<zone]
            value.replaceSubrange(value.index(after: dot)..<zone, with: String(fraction.prefix(3)))
        }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: value) { return date }
        return ISO8601DateFormatter().date(from: value)
    }
}
