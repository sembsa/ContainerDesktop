import Foundation

/// A node of a local Kubernetes cluster, as listed by `container k8s list`.
///
/// The plugin has no `--format json`, so this comes from the fixed-width table
/// it prints. Every node is also a plain container carrying the labels
/// `com.apple.container.plugin=k8s` and `com.apple.container.resource.role`.
struct K8sNode: Identifiable, Hashable, Sendable {
    let cluster: String
    let name: String
    let role: String
    let state: String
    let cpus: String
    let memory: String
    let address: String
    let ports: String

    var id: String { "\(cluster)/\(name)" }
    var isRunning: Bool { state.lowercased() == "running" }
    var isControlPlane: Bool { role.lowercased().contains("control") }

    /// The host port the API server is reachable on, parsed out of `6445->6443`.
    var apiServerHostPort: Int? {
        guard let mapping = ports.split(separator: ",").first(where: { $0.contains("6443") }),
              let host = mapping.split(separator: "-").first
        else { return nil }
        return Int(host.trimmingCharacters(in: .whitespaces))
    }
}

/// One cluster with its nodes. `container k8s create` only makes single-node
/// clusters today, but the table is shaped for more, so we group anyway.
struct K8sCluster: Identifiable, Hashable, Sendable {
    let name: String
    let nodes: [K8sNode]

    var id: String { name }
    var isRunning: Bool { nodes.contains(where: \.isRunning) }
    var controlPlane: K8sNode? { nodes.first(where: \.isControlPlane) ?? nodes.first }

    /// Groups a flat node list into clusters, preserving first-seen order.
    static func group(_ nodes: [K8sNode]) -> [K8sCluster] {
        var order: [String] = []
        var byCluster: [String: [K8sNode]] = [:]
        for node in nodes {
            if byCluster[node.cluster] == nil { order.append(node.cluster) }
            byCluster[node.cluster, default: []].append(node)
        }
        return order.map { K8sCluster(name: $0, nodes: byCluster[$0] ?? []) }
    }
}

/// Reads version numbers out of the CLI's banners, so the app can tell a
/// freshly upgraded `container` from the older background service still running
/// behind it — the state a `.pkg` upgrade leaves until the service restarts.
enum ContainerVersion {
    /// Pulls the first `1.2.2`-shaped token out of a version banner.
    static func number(in text: String) -> String? {
        for token in text.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
            let candidate = token.trimmingCharacters(in: CharacterSet(charactersIn: "()v,"))
            let parts = candidate.split(separator: ".")
            if parts.count >= 2, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) {
                return candidate
            }
        }
        return nil
    }
}

/// Parses the fixed-width table printed by `container k8s list`.
///
/// Splitting on whitespace does not work: MEMORY renders as `6144 MB`, and a
/// missing ADDR/PORTS leaves the trailing columns blank. So we locate each
/// header label and slice every row on those column offsets instead.
///
///     CLUSTER   NODE      ROLE           STATE    CPUS  MEMORY   ADDR          PORTS
///     gui-test  gui-test  control-plane  running  4     6144 MB  192.168.69.4  6445->6443
enum K8sListParser {
    private static let headers = ["CLUSTER", "NODE", "ROLE", "STATE", "CPUS", "MEMORY", "ADDR", "PORTS"]

    static func parse(_ output: String) -> [K8sNode] {
        let lines = output
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        guard let headerIndex = lines.firstIndex(where: isHeader),
              let offsets = columnOffsets(in: lines[headerIndex])
        else { return [] }

        return lines[(headerIndex + 1)...].compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            let fields = slice(line, at: offsets)
            // CLUSTER and NODE are the only fields the plugin always fills in;
            // anything without them is a stray log line, not a row.
            guard !fields[0].isEmpty, !fields[1].isEmpty else { return nil }
            return K8sNode(
                cluster: fields[0],
                name: fields[1],
                role: fields[2],
                state: fields[3],
                cpus: fields[4],
                memory: fields[5],
                address: fields[6],
                ports: fields[7]
            )
        }
    }

    private static func isHeader(_ line: String) -> Bool {
        let tokens = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        return tokens.prefix(headers.count) == ArraySlice(headers)
    }

    /// Start index (in characters) of every header label, or nil if the header
    /// does not look like the layout this parser was written against.
    private static func columnOffsets(in header: String) -> [Int]? {
        let characters = Array(header)
        var offsets: [Int] = []
        var searchStart = 0
        for label in headers {
            guard let found = indexOf(Array(label), in: characters, from: searchStart) else { return nil }
            offsets.append(found)
            searchStart = found + label.count
        }
        return offsets
    }

    private static func indexOf(_ needle: [Character], in haystack: [Character], from start: Int) -> Int? {
        guard needle.count <= haystack.count else { return nil }
        var index = start
        while index + needle.count <= haystack.count {
            if Array(haystack[index..<(index + needle.count)]) == needle { return index }
            index += 1
        }
        return nil
    }

    /// Cuts a row on the header offsets. The final column runs to end of line;
    /// short rows (trailing columns blank) yield empty strings rather than crash.
    private static func slice(_ line: String, at offsets: [Int]) -> [String] {
        let characters = Array(line)
        return offsets.indices.map { position in
            let start = offsets[position]
            guard start < characters.count else { return "" }
            let end = position + 1 < offsets.count
                ? min(offsets[position + 1], characters.count)
                : characters.count
            guard start < end else { return "" }
            return String(characters[start..<end]).trimmingCharacters(in: .whitespaces)
        }
    }
}
