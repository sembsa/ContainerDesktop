import Foundation
import Yams

/// Errors raised while parsing a docker-compose document. Messages are localized
/// (Polish source, English translation) via `String(localized:)`.
enum ComposeParseError: Error, LocalizedError, Equatable {
    /// The document could not be parsed as YAML, or its top level is not a mapping.
    case invalidYAML(String)
    /// The document has no top-level `services:` mapping.
    case noServices
    /// A specific service could not be interpreted.
    case service(name: String, problem: String)

    var errorDescription: String? {
        switch self {
        case .invalidYAML(let detail):
            return String(format: String(localized: "Nieprawidłowy YAML: %@"), detail)
        case .noServices:
            return String(localized: "Plik compose nie zawiera sekcji services:.")
        case .service(let name, let problem):
            return String(format: String(localized: "Usługa „%@”: %@"), name, problem)
        }
    }
}

/// Parses docker-compose documents into a `ComposeProject`.
///
/// Supports the subset of compose features that map cleanly onto `container run`
/// invocations. Unsupported keys are skipped and reported via `warnings`.
enum ComposeParser {
    /// Parses `yaml`. `projectName` is the fallback project name; a top-level
    /// `name:` in the document overrides it. Throws `ComposeParseError`.
    static func parse(_ yaml: String, projectName: String) throws -> ComposeProject {
        let loaded: Any?
        do {
            loaded = try Yams.load(yaml: yaml)
        } catch {
            throw ComposeParseError.invalidYAML(String(describing: error))
        }

        guard let root = loaded as? [String: Any] else {
            throw ComposeParseError.invalidYAML(String(localized: "dokument najwyższego poziomu nie jest mapą"))
        }

        guard let servicesRaw = root["services"] as? [String: Any], !servicesRaw.isEmpty else {
            throw ComposeParseError.noServices
        }

        // Resolve project name: top-level `name:` wins, else fallback parameter.
        // `stringValue` also coerces numbers/bools so e.g. `name: 123` works.
        let yamlName = stringValue(root["name"])
        let nameFromYAML = (yamlName?.isEmpty == false)
        let rawName = nameFromYAML ? yamlName! : projectName
        let resolvedProjectName = normalizeProjectName(rawName)

        var warnings: [String] = []

        // Top-level named volumes: declare existence requirement.
        if let topVolumes = root["volumes"] as? [String: Any] {
            let names = topVolumes.keys.sorted()
            if !names.isEmpty {
                warnings.append(
                    String(format: String(localized: "zadeklarowane wolumeny muszą istnieć: %@"),
                           names.joined(separator: ", "))
                )
            }
        }

        // Parse each service (alphabetical key order for determinism).
        var services: [ComposeService] = []
        for serviceName in servicesRaw.keys.sorted() {
            guard let dict = servicesRaw[serviceName] as? [String: Any] else {
                throw ComposeParseError.service(
                    name: serviceName,
                    problem: String(localized: "definicja usługi nie jest mapą")
                )
            }
            let service = try parseService(name: serviceName, dict: dict, warnings: &warnings)
            services.append(service)
        }

        // Order services: all init tasks first (topo-sorted among themselves),
        // then regular services (topo-sorted by depends_on).
        let ordered = try orderServices(services)

        return ComposeProject(
            name: resolvedProjectName,
            services: ordered,
            warnings: warnings,
            nameFromYAML: nameFromYAML
        )
    }

    // MARK: - Service parsing

    /// Keys handled explicitly; anything else outside this set is reported once.
    private static let knownServiceKeys: Set<String> = [
        "image", "build", "container_name", "command", "entrypoint",
        "working_dir", "user", "environment", "ports", "volumes", "depends_on",
        "x-init",
    ]

    private static func parseService(
        name: String,
        dict: [String: Any],
        warnings: inout [String]
    ) throws -> ComposeService {
        // build: is not supported — require a prebuilt image instead.
        if dict["build"] != nil {
            throw ComposeParseError.service(
                name: name,
                problem: String(localized: "usługa używa build: — wskaż gotowy obraz (image:), budowanie z compose nie jest wspierane")
            )
        }

        guard let image = stringValue(dict["image"]), !image.isEmpty else {
            throw ComposeParseError.service(
                name: name,
                problem: String(localized: "brak wymaganego pola image:")
            )
        }

        let containerName = stringValue(dict["container_name"])
        let command = commandString(dict["command"])
        let entrypoint = commandString(dict["entrypoint"])
        let workdir = stringValue(dict["working_dir"]) ?? ""
        let user = stringValue(dict["user"]) ?? ""
        let environment = parseEnvironment(dict["environment"])
        let ports = parsePorts(dict["ports"], service: name, warnings: &warnings)
        let volumes = parseVolumes(dict["volumes"], service: name, warnings: &warnings)
        let dependsOn = parseDependsOn(dict["depends_on"], service: name, warnings: &warnings)
        let isInit = parseBool(dict["x-init"])

        // Report unsupported keys, once per key.
        for key in dict.keys.sorted() where !knownServiceKeys.contains(key) {
            warnings.append(
                String(format: String(localized: "pominięto nieobsługiwane pole: %1$@ (usługa %2$@)"), key, name)
            )
        }

        return ComposeService(
            name: name,
            image: image,
            containerName: containerName,
            command: command,
            entrypoint: entrypoint,
            workdir: workdir,
            user: user,
            environment: environment,
            ports: ports,
            volumes: volumes,
            dependsOn: dependsOn,
            isInit: isInit
        )
    }

    // MARK: - Field helpers

    /// Interprets a YAML value as a boolean. Accepts native bools, the strings
    /// "true"/"1" (case-insensitive), and the number 1.
    private static func parseBool(_ value: Any?) -> Bool {
        switch value {
        case let b as Bool: return b
        case let i as Int: return i == 1
        case let s as String:
            let lower = s.lowercased()
            return lower == "true" || lower == "1"
        case let n as NSNumber where !(value is String):
            return n.intValue == 1
        default: return false
        }
    }

    /// Converts a scalar YAML value (String, number, bool) into a String.
    private static func stringValue(_ value: Any?) -> String? {
        switch value {
        case let s as String: return s
        case let b as Bool: return b ? "true" : "false"
        case let i as Int: return String(i)
        case let d as Double: return String(d)
        case let n as NSNumber: return n.stringValue
        default: return nil
        }
    }

    /// `command`/`entrypoint`: a string, or a list joined into one shell string.
    private static func commandString(_ value: Any?) -> String {
        switch value {
        case let s as String:
            return s
        case let list as [Any]:
            let tokens = list.compactMap { stringValue($0) }
            return RunCommandBuilder.joinCommand(tokens)
        default:
            return ""
        }
    }

    /// `environment`: a `{K: V}` map or a `["K=V", "K"]` list, normalized to pairs.
    private static func parseEnvironment(_ value: Any?) -> [(key: String, value: String)] {
        switch value {
        case let map as [String: Any]:
            return map.keys.sorted().map { key in
                (key: key, value: stringValue(map[key]) ?? "")
            }
        case let list as [Any]:
            return list.compactMap { entry -> (key: String, value: String)? in
                guard let raw = stringValue(entry) else { return nil }
                if let eq = raw.firstIndex(of: "=") {
                    let key = String(raw[raw.startIndex..<eq])
                    let val = String(raw[raw.index(after: eq)...])
                    return (key: key, value: val)
                }
                return (key: raw, value: "")
            }
        default:
            return []
        }
    }

    /// `ports`: short ("8080:80", "8080:80/udp"), bare number (8080 → "8080:8080"),
    /// or long syntax (`{target:, published:, protocol:}`).
    private static func parsePorts(
        _ value: Any?,
        service: String,
        warnings: inout [String]
    ) -> [String] {
        guard let list = value as? [Any] else { return [] }
        var result: [String] = []
        for entry in list {
            if let str = entry as? String {
                result.append(str)
            } else if let i = entry as? Int {
                result.append("\(i):\(i)")
            } else if let n = entry as? NSNumber, !(entry is String) {
                let i = n.intValue
                result.append("\(i):\(i)")
            } else if let map = entry as? [String: Any] {
                guard let target = stringValue(map["target"]) else {
                    warnings.append(
                        String(format: String(localized: "pominięto wpis portu bez pola target (usługa %@)"), service)
                    )
                    continue
                }
                guard let published = stringValue(map["published"]), !published.isEmpty else {
                    warnings.append(
                        String(format: String(localized: "pominięto port bez pola published (usługa %@)"), service)
                    )
                    continue
                }
                var spec = "\(published):\(target)"
                if let proto = stringValue(map["protocol"]), !proto.isEmpty {
                    spec += "/\(proto)"
                }
                result.append(spec)
            }
        }
        return result
    }

    /// `volumes`: short "src:dst[:ro]" strings, or long syntax (`type/source/target`).
    private static func parseVolumes(
        _ value: Any?,
        service: String,
        warnings: inout [String]
    ) -> [String] {
        guard let list = value as? [Any] else { return [] }
        var result: [String] = []
        for entry in list {
            if let str = entry as? String {
                result.append(str)
            } else if let map = entry as? [String: Any] {
                let type = stringValue(map["type"]) ?? "volume"
                guard type == "bind" || type == "volume" else {
                    warnings.append(
                        String(format: String(localized: "pominięto wolumen typu %1$@ (usługa %2$@)"), type, service)
                    )
                    continue
                }
                guard let source = stringValue(map["source"]), !source.isEmpty,
                      let target = stringValue(map["target"]), !target.isEmpty else {
                    warnings.append(
                        String(format: String(localized: "pominięto wolumen bez source/target (usługa %@)"), service)
                    )
                    continue
                }
                var spec = "\(source):\(target)"
                if let readOnly = map["read_only"] as? Bool, readOnly {
                    spec += ":ro"
                }
                result.append(spec)
            }
        }
        return result
    }

    /// `depends_on`: a list of names, or a `{name: {condition}}` map.
    private static func parseDependsOn(
        _ value: Any?,
        service: String,
        warnings: inout [String]
    ) -> [String] {
        switch value {
        case let list as [Any]:
            return list.compactMap { stringValue($0) }
        case let map as [String: Any]:
            for key in map.keys.sorted() {
                if let conditionMap = map[key] as? [String: Any],
                   let condition = stringValue(conditionMap["condition"]),
                   condition != "service_started" {
                    warnings.append(
                        String(format: String(localized: "zignorowano warunek depends_on „%1$@” dla %2$@ (obsługiwane jest tylko uruchomienie)"),
                               condition, service)
                    )
                }
            }
            return map.keys.sorted()
        default:
            return []
        }
    }

    // MARK: - Ordering

    /// Orders services so init tasks (`x-init`) come first — topo-sorted among
    /// themselves — followed by regular services topo-sorted by `depends_on`.
    ///
    /// An init task may depend on another init task, but never on a regular
    /// service (init tasks run before any regular service starts). Such a
    /// dependency throws `ComposeParseError.service`.
    private static func orderServices(_ services: [ComposeService]) throws -> [ComposeService] {
        let initServices = services.filter { $0.isInit }
        let regularServices = services.filter { !$0.isInit }
        let initNames = Set(initServices.map(\.name))
        let regularNames = Set(regularServices.map(\.name))

        // Reject init → regular dependencies (init runs before regular services).
        for service in initServices {
            for dep in service.dependsOn where regularNames.contains(dep) {
                throw ComposeParseError.service(
                    name: service.name,
                    problem: String(format: String(localized: "usługa init nie może zależeć od zwykłej usługi: %@"), dep)
                )
            }
        }

        // Topo-sort each group independently. For init tasks, only count
        // dependencies on other init tasks (regular deps were already rejected).
        let orderedInit = try topoSort(initServices, scope: initNames)
        let orderedRegular = try topoSort(regularServices, scope: regularNames)
        return orderedInit + orderedRegular
    }

    // MARK: - Topological sort

    /// Orders services so that each comes after its `depends_on` targets.
    /// Deterministic: alphabetical within each readiness level. Detects cycles.
    /// Only dependencies inside `scope` are considered (others are ignored).
    private static func topoSort(_ services: [ComposeService], scope: Set<String>? = nil) throws -> [ComposeService] {
        let byName = Dictionary(uniqueKeysWithValues: services.map { ($0.name, $0) })
        var inDegree: [String: Int] = [:]
        var dependents: [String: [String]] = [:] // dependency -> services that depend on it

        for service in services {
            inDegree[service.name, default: 0] += 0
            // Only count dependencies that exist as services within this scope.
            let deps = service.dependsOn.filter { dep in
                byName[dep] != nil && (scope?.contains(dep) ?? true)
            }
            inDegree[service.name] = deps.count
            for dep in deps {
                dependents[dep, default: []].append(service.name)
            }
        }

        // Kahn's algorithm; ready set drained alphabetically for stable output.
        var ready = inDegree.filter { $0.value == 0 }.map(\.key).sorted()
        var ordered: [ComposeService] = []
        var resolved: Set<String> = []

        while !ready.isEmpty {
            let next = ready.removeFirst()
            guard let service = byName[next] else { continue }
            ordered.append(service)
            resolved.insert(next)
            var newlyReady: [String] = []
            for dependent in dependents[next, default: []] {
                inDegree[dependent, default: 0] -= 1
                if inDegree[dependent] == 0 { newlyReady.append(dependent) }
            }
            ready.append(contentsOf: newlyReady)
            ready.sort()
        }

        if ordered.count != services.count {
            let remaining = services.map(\.name).filter { !resolved.contains($0) }.sorted()
            throw ComposeParseError.service(
                name: remaining.first ?? "?",
                problem: String(format: String(localized: "cykl zależności: %@"), remaining.joined(separator: " → "))
            )
        }

        return ordered
    }

    // MARK: - Project name

    /// Normalizes a project name to `[a-z0-9-]` (lowercase, spaces → "-").
    static func normalizeProjectName(_ raw: String) -> String {
        let lower = raw.lowercased()
        var result = ""
        for scalar in lower.unicodeScalars {
            if (scalar >= "a" && scalar <= "z") || (scalar >= "0" && scalar <= "9") {
                result.unicodeScalars.append(scalar)
            } else if scalar == " " || scalar == "_" || scalar == "-" || scalar == "." {
                result.append("-")
            }
            // Drop any other character.
        }
        // Collapse repeated dashes and trim leading/trailing dashes.
        while result.contains("--") {
            result = result.replacingOccurrences(of: "--", with: "-")
        }
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return result.isEmpty ? "compose" : result
    }
}
