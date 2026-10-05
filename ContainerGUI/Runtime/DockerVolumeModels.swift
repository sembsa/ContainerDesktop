import Foundation

/// One line of `docker volume ls --format '{{json .}}'`. Every field is a
/// string there, and unknown ones read `N/A`.
struct DockerVolumeRow: Decodable, Sendable {
    let Name: String
    let Driver: String?
    let Scope: String?
    let Mountpoint: String?
    /// `key=value,key=value`
    let Labels: String?

    static func decodeLines(_ output: String) throws -> [DockerVolumeRow] {
        try DockerJSONLines.decode(DockerVolumeRow.self, from: output)
    }
}

/// One element of `docker volume inspect` (a JSON array). `Labels` and
/// `Options` are `null` when empty.
struct DockerVolumeInspect: Decodable, Sendable {
    let Name: String
    let CreatedAt: String?
    let Driver: String?
    let Labels: [String: String]?
    let Mountpoint: String?
    let Scope: String?

    static func decodeArray(_ output: String) throws -> [DockerVolumeInspect] {
        do { return try JSONDecoder().decode([DockerVolumeInspect].self, from: Data(output.utf8)) }
        catch { throw CLIError.decoding(String(describing: error)) }
    }
}

/// The `Volumes` section of `docker system df -v --format json`. Sizes are
/// human-readable strings (`1.2kB`, `0B`, `N/A`).
struct DockerSystemDF: Decodable, Sendable {
    struct Volume: Decodable, Sendable {
        let Name: String
        let Size: String?
        let Links: String?
    }
    let Volumes: [Volume]?

    static func decode(_ output: String) throws -> DockerSystemDF {
        do { return try JSONDecoder().decode(DockerSystemDF.self, from: Data(output.trimmingCharacters(in: .whitespacesAndNewlines).utf8)) }
        catch { throw CLIError.decoding(String(describing: error)) }
    }

    /// volume name -> bytes, for the volumes whose size Docker reported.
    var sizes: [String: Int64] {
        var result: [String: Int64] = [:]
        for volume in Volumes ?? [] {
            if let bytes = DockerSize.parse(volume.Size) { result[volume.Name] = bytes }
        }
        return result
    }
}

/// Docker's `HumanSize` (decimal units): `0B`, `1.09kB`, `62.4MB`, `1.5GB`.
enum DockerSize {
    static func parse(_ text: String?) -> Int64? {
        guard let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty, text != "N/A" else { return nil }
        let units: [(String, Double)] = [("TB", 1e12), ("GB", 1e9), ("MB", 1e6), ("kB", 1e3), ("KB", 1e3), ("B", 1)]
        for (suffix, factor) in units where text.hasSuffix(suffix) {
            guard let number = Double(text.dropLast(suffix.count).trimmingCharacters(in: .whitespaces)) else { return nil }
            return Int64((number * factor).rounded())
        }
        return nil
    }
}

/// One mount of a container, from `docker container inspect --format '{{.Name}}\t{{json .Mounts}}'`.
struct DockerMount: Decodable, Sendable, Hashable {
    let `Type`: String?
    let Name: String?
    let Source: String?
    let Destination: String?
    let RW: Bool?
}

/// A container and its mounts: the source of "used by" and of bind-mount rows.
struct DockerContainerMounts: Sendable, Hashable {
    let container: String
    let mounts: [DockerMount]

    /// Lines of `/name<TAB>[{...}]`. A line that does not parse is skipped:
    /// this is decoration for the list, never a reason to fail it.
    static func parse(_ output: String) -> [DockerContainerMounts] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            var name = String(parts[0])
            if name.hasPrefix("/") { name.removeFirst() }
            guard !name.isEmpty,
                  let mounts = try? JSONDecoder().decode([DockerMount].self, from: Data(parts[1].utf8)) else { return nil }
            return DockerContainerMounts(container: name, mounts: mounts)
        }
    }
}

/// Docker's volume JSON -> `VolumeEntry`.
enum DockerVolumeMapper {
    static let composeProjectLabel = "com.docker.compose.project"

    /// - Parameters:
    ///   - inspected: `docker volume inspect` output; takes precedence over `rows`.
    ///   - sizes: from `docker system df -v`; omitted volumes show no size.
    ///   - mounts: every container's mounts, for "used by" and bind rows.
    static func entries(
        rows: [DockerVolumeRow],
        inspected: [DockerVolumeInspect],
        sizes: [String: Int64],
        mounts: [DockerContainerMounts],
        includeBindMounts: Bool = true
    ) -> [VolumeEntry] {
        let inspectedByName = Dictionary(inspected.map { ($0.Name, $0) }, uniquingKeysWith: { first, _ in first })
        var usedBy: [String: [String]] = [:]
        var binds: [String: [String]] = [:]
        for entry in mounts {
            for mount in entry.mounts {
                switch mount.Type {
                case "volume":
                    if let name = mount.Name, !name.isEmpty { usedBy[name, default: []].append(entry.container) }
                case "bind":
                    if let source = mount.Source, !source.isEmpty, !source.hasSuffix(".sock") {
                        binds[displayPath(source), default: []].append(entry.container)
                    }
                default: break
                }
            }
        }

        let named: [VolumeEntry] = rows.map { row in
            let detail = inspectedByName[row.Name]
            let labels = detail?.Labels ?? parseLabels(row.Labels)
            return VolumeEntry(
                id: row.Name, reference: row.Name, name: row.Name, kind: .docker,
                driver: nonEmpty(detail?.Driver ?? row.Driver),
                path: nonEmpty(detail?.Mountpoint ?? row.Mountpoint),
                scope: nonEmpty(detail?.Scope ?? row.Scope),
                sizeBytes: sizes[row.Name],
                createdAt: parseDate(detail?.CreatedAt),
                labels: labels,
                usedBy: (usedBy[row.Name] ?? []).sortedUnique()
            )
        }
        guard includeBindMounts else { return named }
        let bound = binds.map { source, users in
            VolumeEntry(
                id: "bind:" + source, reference: source, name: source, kind: .docker, storage: .bind,
                path: source, usedBy: users.sortedUnique()
            )
        }.sorted { $0.name < $1.name }
        return named + bound
    }

    /// Docker Desktop reports host paths under `/host_mnt`.
    static func displayPath(_ source: String) -> String {
        source.hasPrefix("/host_mnt/") ? String(source.dropFirst("/host_mnt".count)) : source
    }

    /// `a=b,c=d` -> dictionary (the `ls` form of labels).
    static func parseLabels(_ text: String?) -> [String: String] {
        guard let text, !text.isEmpty, text != "N/A" else { return [:] }
        var result: [String: String] = [:]
        for pair in text.split(separator: ",") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let key = kv.first, !key.isEmpty else { continue }
            result[String(key)] = kv.count > 1 ? String(kv[1]) : ""
        }
        return result
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value != "N/A" else { return nil }
        return value
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

extension Array where Element == String {
    fileprivate func sortedUnique() -> [String] {
        Array(Set(self)).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}
