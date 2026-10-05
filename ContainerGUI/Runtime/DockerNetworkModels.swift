import Foundation

/// One line of `docker network ls --format '{{json .}}'`. Every field is a
/// string there, including the booleans.
struct DockerNetworkRow: Decodable, Sendable {
    let ID: String
    let Name: String
    let Driver: String?
    let Scope: String?
    let Internal: String?
    let IPv6: String?
    let Labels: String?

    static func decodeLines(_ output: String) throws -> [DockerNetworkRow] {
        try DockerJSONLines.decode(DockerNetworkRow.self, from: output)
    }
}

/// One element of `docker network inspect` (a JSON array).
///
/// Everything but the name is optional: Docker emits `null` for an empty
/// `Containers`, `Labels` or `IPAM.Config`.
struct DockerNetworkInspect: Decodable, Sendable {
    let Name: String
    let Id: String?
    let Created: String?
    let Scope: String?
    let Driver: String?
    let EnableIPv6: Bool?
    let Internal: Bool?
    let IPAM: IPAM?
    let Containers: [String: Endpoint]?
    let Labels: [String: String]?

    struct IPAM: Decodable, Sendable {
        let Driver: String?
        let Config: [Config]?
    }

    struct Config: Decodable, Sendable {
        let Subnet: String?
        let Gateway: String?
    }

    struct Endpoint: Decodable, Sendable {
        let Name: String?
        let IPv4Address: String?
        let IPv6Address: String?
    }

    static func decodeArray(_ output: String) throws -> [DockerNetworkInspect] {
        do { return try JSONDecoder().decode([DockerNetworkInspect].self, from: Data(output.utf8)) }
        catch { throw CLIError.decoding(String(describing: error)) }
    }
}

/// Docker's network JSON -> `NetworkEntry`.
enum DockerNetworkMapper {
    /// Networks Docker creates itself and refuses to remove.
    static let builtInNames: Set<String> = ["bridge", "host", "none"]

    static func map(_ inspect: DockerNetworkInspect) -> NetworkEntry {
        let configs = inspect.IPAM?.Config ?? []
        let v4 = configs.first { ($0.Subnet ?? "").contains(".") && !($0.Subnet ?? "").contains(":") }
        let v6 = configs.first { ($0.Subnet ?? "").contains(":") }
        let attached = (inspect.Containers ?? [:])
            .map { NetworkEntry.Attachment(name: $0.value.Name ?? String($0.key.prefix(12)), ipv4Address: nonEmpty($0.value.IPv4Address)) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return NetworkEntry(
            id: inspect.Id ?? inspect.Name,
            reference: inspect.Name,
            name: inspect.Name,
            kind: .docker,
            driver: nonEmpty(inspect.Driver),
            scope: nonEmpty(inspect.Scope),
            ipv4Subnet: nonEmpty(v4?.Subnet),
            ipv4Gateway: nonEmpty(v4?.Gateway),
            ipv6Subnet: nonEmpty(v6?.Subnet),
            isInternal: inspect.Internal ?? false,
            isBuiltIn: builtInNames.contains(inspect.Name),
            createdAt: parseDate(inspect.Created),
            attached: attached
        )
    }

    /// `ls` knows no subnets or members; used when `inspect` fails.
    static func map(_ row: DockerNetworkRow) -> NetworkEntry {
        NetworkEntry(
            id: row.ID,
            reference: row.Name,
            name: row.Name,
            kind: .docker,
            driver: nonEmpty(row.Driver),
            scope: nonEmpty(row.Scope),
            isInternal: row.Internal?.lowercased() == "true",
            isBuiltIn: builtInNames.contains(row.Name)
        )
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}
