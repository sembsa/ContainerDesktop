import Foundation

/// Keys a chart declares in `values.schema.json` but does not ship in
/// `values.yaml`.
///
/// This gap is not academic: the Soneta chart requires `dblist` (an XML string
/// listing database connections) and it appears nowhere in `values.yaml`, so a
/// form generated from defaults alone can never offer it — the install just
/// fails schema validation with no field to fix. Reading the schema closes
/// that, and brings descriptions, enums and required markers along with it.
struct SchemaProperty: Hashable, Sendable {
    let path: String
    let type: String?
    let description: String?
    let enumValues: [String]
    let isRequired: Bool

    var kind: ValuesField.Kind {
        switch type {
        case "boolean": .boolean
        case "integer", "number": .number
        case "array": .stringList
        case "object": .yaml
        default: .string
        }
    }
}

enum ChartSchema {
    /// Parses `values.schema.json`. Returns an empty list for anything it does
    /// not understand — the form must degrade to the values.yaml-only version,
    /// never break.
    static func properties(fromSchema data: Data) -> [SchemaProperty] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
        let defs = (root["$defs"] as? [String: Any]) ?? (root["definitions"] as? [String: Any]) ?? [:]
        var result: [SchemaProperty] = []
        walk(root, path: [], required: requiredKeys(in: root), defs: defs, depth: 0, into: &result)
        return result
    }

    /// Keys the schema insists on, including the branches of a `oneOf` — the
    /// Soneta chart expresses "either dblist or listaBazDanych" that way, and
    /// both are worth surfacing so the user can pick one.
    private static func requiredKeys(in object: [String: Any]) -> Set<String> {
        var keys = Set((object["required"] as? [String]) ?? [])
        for branchKey in ["oneOf", "anyOf", "allOf"] {
            for branch in (object[branchKey] as? [[String: Any]]) ?? [] {
                keys.formUnion((branch["required"] as? [String]) ?? [])
            }
        }
        return keys
    }

    private static func walk(
        _ object: [String: Any],
        path: [String],
        required: Set<String>,
        defs: [String: Any],
        depth: Int,
        into result: inout [SchemaProperty]
    ) {
        // Charts nest deeply; past a few levels the generated rows stop being
        // useful and the YAML tab is the better tool.
        guard depth < 4 else { return }
        guard let properties = object["properties"] as? [String: Any] else { return }

        for (key, rawValue) in properties.sorted(by: { $0.key < $1.key }) {
            guard var value = rawValue as? [String: Any] else { continue }
            value = resolve(value, defs: defs)

            let childPath = path + [key]
            let type = typeName(of: value)

            result.append(
                SchemaProperty(
                    path: childPath.joined(separator: "."),
                    type: type,
                    description: value["description"] as? String,
                    enumValues: (value["enum"] as? [Any])?.compactMap { $0 as? String } ?? [],
                    isRequired: required.contains(key)
                )
            )

            if type == "object", value["properties"] != nil {
                walk(
                    value,
                    path: childPath,
                    required: requiredKeys(in: value),
                    defs: defs,
                    depth: depth + 1,
                    into: &result
                )
            }
        }
    }

    /// Follows a local `$ref` and flattens a single-branch `oneOf`, which is how
    /// charts spell "string or number" (Kubernetes quantities).
    private static func resolve(_ value: [String: Any], defs: [String: Any]) -> [String: Any] {
        var value = value
        if let ref = value["$ref"] as? String {
            let name = String(ref.split(separator: "/").last ?? "")
            if let target = defs[name] as? [String: Any] {
                var merged = target
                // Keep the local description — it is the more specific one.
                if let description = value["description"] { merged["description"] = description }
                value = merged
            }
        }
        return value
    }

    private static func typeName(of value: [String: Any]) -> String? {
        if let type = value["type"] as? String { return type }
        if let types = value["type"] as? [String] {
            return types.first { $0 != "null" } ?? types.first
        }
        // `oneOf: [{type: string}, {type: number}]` — take the first concrete one.
        for branchKey in ["oneOf", "anyOf"] {
            for branch in (value[branchKey] as? [[String: Any]]) ?? [] {
                if let type = branch["type"] as? String, type != "null" { return type }
            }
        }
        if value["properties"] != nil { return "object" }
        return nil
    }
}

extension ChartValues {
    /// Folds schema knowledge into the fields taken from `values.yaml`:
    /// annotates what is there, and appends what is declared but undefaulted.
    static func merge(fields: [ValuesField], schema: [SchemaProperty]) -> [ValuesField] {
        guard !schema.isEmpty else { return fields }
        let byPath = Dictionary(schema.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        var known = Set(fields.map(\.path))

        var merged = fields.map { field -> ValuesField in
            guard let property = byPath[field.path] else { return field }
            return ValuesField(
                path: field.path,
                components: field.components,
                kind: field.kind,
                defaultValue: field.defaultValue,
                comment: field.comment ?? property.description,
                isRequired: property.isRequired,
                enumValues: property.enumValues
            )
        }

        // Required-but-undefaulted keys go first: they are the ones blocking the
        // install, and burying them at the bottom of the form hides the fix.
        let additions = schema
            .filter { !known.contains($0.path) }
            .filter { property in
                // Only leaves; a bare object header with no value to type is noise.
                property.type != "object" || property.isRequired
            }
            .sorted { lhs, rhs in
                lhs.isRequired == rhs.isRequired ? lhs.path < rhs.path : lhs.isRequired
            }
            .map { property in
                ValuesField(
                    path: property.path,
                    components: property.path.split(separator: ".").map(String.init),
                    kind: property.kind,
                    defaultValue: "",
                    comment: property.description,
                    isRequired: property.isRequired,
                    enumValues: property.enumValues
                )
            }

        for addition in additions where !known.contains(addition.path) {
            known.insert(addition.path)
            merged.append(addition)
        }
        return merged
    }
}
