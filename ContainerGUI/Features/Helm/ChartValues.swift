import Foundation
import Yams

/// One editable leaf of a chart's `values.yaml`.
struct ValuesField: Identifiable, Hashable {
    /// Dotted path, e.g. `image.tag`. Doubles as the identity and the key used
    /// when rebuilding an overrides document.
    let path: String
    let components: [String]
    let kind: Kind
    /// The chart's default, rendered as text (for `.complex`, as YAML).
    let defaultValue: String
    /// Comment lines sitting directly above the key in `values.yaml`.
    let comment: String?

    var id: String { path }
    var label: String { components.last ?? path }
    /// Everything but the leaf — the group this field is shown under.
    var group: String { components.dropLast().joined(separator: ".") }

    enum Kind: Hashable {
        case boolean
        case number
        case string
        /// A sequence of scalars (`imagePullSecrets: []`, `args: [--flag]`).
        /// Gets a real row editor — charts are full of these.
        case stringList
        /// Sequences of objects, map-valued leaves, unresolved aliases: shapes a
        /// row editor cannot represent, so they get a multi-line YAML box.
        case yaml
    }
}

/// Reads a chart's `values.yaml` into a flat, editable field list, and turns the
/// user's edits back into a **minimal** overrides document.
///
/// Minimal matters: `helm install -f` should carry only what the user changed,
/// the same file a person would hand-write. Shipping a full copy of values.yaml
/// pins every default and silently blocks chart upgrades from moving them.
enum ChartValues {
    // MARK: - Parsing

    static func fields(from yaml: String) throws -> [ValuesField] {
        guard let root = try Yams.compose(yaml: yaml) else { return [] }
        let comments = commentsByKeyPath(in: yaml)
        var fields: [ValuesField] = []
        walk(root, path: [], comments: comments, into: &fields)
        return fields
    }

    private static func walk(
        _ node: Node,
        path: [String],
        comments: [String: String],
        into fields: inout [ValuesField]
    ) {
        switch node {
        case .mapping(let mapping) where !path.isEmpty && mapping.isEmpty:
            // An empty map is a value the user may want to fill in.
            append(node, path: path, kind: .yaml, comments: comments, into: &fields)

        case .mapping(let mapping):
            for (keyNode, valueNode) in mapping {
                guard let key = keyNode.string else { continue }
                walk(valueNode, path: path + [key], comments: comments, into: &fields)
            }

        case .sequence(let sequence):
            // An empty sequence is the overwhelmingly common case in charts
            // (`imagePullSecrets: []`, `envs.web: []`) and is where the user
            // most wants to add entries — treat it as a scalar list.
            let isScalarList = sequence.allSatisfy { element in
                if case .scalar = element { return true }
                return false
            }
            append(node, path: path, kind: isScalarList ? .stringList : .yaml, comments: comments, into: &fields)

        case .scalar(let scalar):
            guard !path.isEmpty else { return }
            append(node, path: path, kind: kind(of: scalar), comments: comments, into: &fields)

        case .alias:
            // Yams resolves `*anchor` references while composing, so aliased
            // blocks arrive here already expanded into real mappings. This case
            // only catches an alias that could not be resolved (a dangling
            // anchor); show it as raw YAML instead of dropping the key.
            guard !path.isEmpty else { return }
            append(node, path: path, kind: .yaml, comments: comments, into: &fields)
        }
    }

    private static func append(
        _ node: Node,
        path: [String],
        kind: ValuesField.Kind,
        comments: [String: String],
        into fields: inout [ValuesField]
    ) {
        let dotted = path.joined(separator: ".")
        fields.append(
            ValuesField(
                path: dotted,
                components: path,
                kind: kind,
                defaultValue: render(node),
                comment: comments[dotted]
            )
        )
    }

    private static func kind(of scalar: Node.Scalar) -> ValuesField.Kind {
        let text = scalar.string
        if ["true", "false"].contains(text.lowercased()) { return .boolean }
        if !text.isEmpty, Double(text) != nil { return .number }
        return .string
    }

    private static func render(_ node: Node) -> String {
        switch node {
        case .scalar(let scalar):
            // YAML nulls read better as an empty field than as the word "null".
            return ["null", "~"].contains(scalar.string) ? "" : scalar.string
        case .alias(let alias):
            return "*\(alias.anchor.rawValue)"
        case .sequence(let sequence):
            // Scalar lists round-trip in flow style (`["a", "b"]`) so the row
            // editor and the stored edit are the same one-line string. Block
            // style would reformat on every trip through the two editors.
            let scalars: [String]? = sequence.reduce(into: [String]()) { result, element in
                if case .scalar(let scalar) = element { result.append(scalar.string) }
            }
            if let scalars, scalars.count == sequence.count {
                return flowList(scalars)
            }
            let dumped = (try? Yams.serialize(node: node)) ?? ""
            return dumped.trimmingCharacters(in: .whitespacesAndNewlines)
        case .mapping:
            let dumped = (try? Yams.serialize(node: node)) ?? ""
            return dumped.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    // MARK: - Scalar lists

    /// `["a", "b"]` — JSON is valid YAML, so this parses straight back.
    static func flowList(_ items: [String]) -> String {
        guard !items.isEmpty else { return "[]" }
        let encoded = items.map { item -> String in
            let data = (try? JSONEncoder().encode(item)) ?? Data("\"\"".utf8)
            return String(decoding: data, as: UTF8.self)
        }
        return "[" + encoded.joined(separator: ", ") + "]"
    }

    /// Reads a `.stringList` value back into rows for the editor.
    static func listItems(_ text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "[]" else { return [] }
        guard let loaded = try? Yams.load(yaml: trimmed) else { return [] }
        guard let array = loaded as? [Any] else { return [] }
        return array.map { element in
            if let string = element as? String { return string }
            if let bool = element as? Bool { return bool ? "true" : "false" }
            return String(describing: element)
        }
    }

    // MARK: - Comments

    /// Harvests the `#` comment block above each key.
    ///
    /// Yams drops comments, so this walks the raw text: indentation gives the
    /// nesting, which is enough for the well-formed values.yaml charts ship.
    /// Only used for help text, so a miss costs nothing.
    static func commentsByKeyPath(in yaml: String) -> [String: String] {
        var result: [String: String] = [:]
        var stack: [(indent: Int, key: String)] = []
        var pending: [String] = []

        for rawLine in yaml.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                pending.removeAll()
                continue
            }
            if trimmed.hasPrefix("#") {
                let text = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
                // "# --" and "# yaml-language-server:" are tooling markers.
                if !text.hasPrefix("yaml-language-server") {
                    pending.append(text.hasPrefix("--") ? String(text.dropFirst(2)).trimmingCharacters(in: .whitespaces) : text)
                }
                continue
            }
            guard !trimmed.hasPrefix("-") else {
                pending.removeAll()
                continue
            }
            guard let colon = trimmed.firstIndex(of: ":") else {
                pending.removeAll()
                continue
            }

            let key = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !key.contains(" ") else {
                pending.removeAll()
                continue
            }

            let indent = line.prefix(while: { $0 == " " }).count
            while let last = stack.last, last.indent >= indent { stack.removeLast() }
            stack.append((indent, key))

            if !pending.isEmpty {
                result[stack.map(\.key).joined(separator: ".")] = pending.joined(separator: " ")
            }
            pending.removeAll()
        }
        return result
    }

    // MARK: - Overrides

    /// Builds a minimal YAML document from the edited paths only.
    ///
    /// Values are re-parsed as YAML so `true`, `3`, `[]` and `{a: b}` keep their
    /// types instead of silently becoming strings — which the chart's
    /// `values.schema.json` would then reject.
    static func overridesYAML(edits: [String: String], fields: [ValuesField]) throws -> String {
        let kindByPath = Dictionary(fields.map { ($0.path, $0.kind) }, uniquingKeysWith: { first, _ in first })
        var tree: [String: Any] = [:]

        for (path, text) in edits.sorted(by: { $0.key < $1.key }) {
            let value = typedValue(text, kind: kindByPath[path] ?? .string)
            insert(value, at: path.split(separator: ".").map(String.init), into: &tree)
        }
        guard !tree.isEmpty else { return "" }
        return try Yams.dump(object: tree)
    }

    private static func typedValue(_ text: String, kind: ValuesField.Kind) -> Any {
        switch kind {
        case .boolean:
            return text.lowercased() == "true"
        case .number:
            if let integer = Int(text) { return integer }
            if let double = Double(text) { return double }
            return text
        case .string:
            // An emptied field means "no value", not the empty string, which is
            // what charts branch on with `if .Values.x`.
            if text.isEmpty { return NSNull() }
            return text
        case .stringList:
            // An emptied list must stay a list — `null` would make a chart's
            // `range .Values.args` fail rather than iterate nothing.
            return listItems(text)
        case .yaml:
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return NSNull() }
            return (try? Yams.load(yaml: text)) ?? text
        }
    }

    private static func insert(_ value: Any, at components: [String], into tree: inout [String: Any]) {
        guard let head = components.first else { return }
        if components.count == 1 {
            tree[head] = value
            return
        }
        var child = tree[head] as? [String: Any] ?? [:]
        insert(value, at: Array(components.dropFirst()), into: &child)
        tree[head] = child
    }

    /// Rejects malformed YAML before it reaches helm, so the user gets the error
    /// next to the editor instead of buried in command output.
    static func validate(_ yaml: String) -> String? {
        guard !yaml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        do {
            _ = try Yams.load(yaml: yaml)
            return nil
        } catch {
            return String(describing: error)
        }
    }

    /// Reads an overrides document back into per-path edits, so switching from
    /// the YAML tab to the form keeps what was typed.
    static func edits(fromOverrides yaml: String, fields: [ValuesField]) -> [String: String] {
        guard let root = try? Yams.compose(yaml: yaml), case .mapping = root else { return [:] }
        let known = Set(fields.map(\.path))
        var result: [String: String] = [:]
        collect(root, path: [], known: known, into: &result)
        return result
    }

    private static func collect(_ node: Node, path: [String], known: Set<String>, into result: inout [String: String]) {
        let dotted = path.joined(separator: ".")
        if !path.isEmpty, known.contains(dotted), !isMapping(node) {
            result[dotted] = render(node)
            return
        }
        guard case .mapping(let mapping) = node else {
            if !path.isEmpty { result[dotted] = render(node) }
            return
        }
        for (keyNode, valueNode) in mapping {
            guard let key = keyNode.string else { continue }
            collect(valueNode, path: path + [key], known: known, into: &result)
        }
    }

    private static func isMapping(_ node: Node) -> Bool {
        if case .mapping = node { return true }
        return false
    }
}
