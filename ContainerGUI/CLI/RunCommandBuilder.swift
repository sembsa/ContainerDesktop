import Foundation

/// Form-backed model describing how to run a container.
struct RunConfiguration {
    var image = ""
    var name = ""
    var command = ""
    var cpus = ""
    var memory = ""
    var network = ""
    var workdir = ""
    var user = ""
    var entrypoint = ""
    var arch = ""
    var rosetta = false
    var removeOnExit = false
    var ports: [PortMapping] = []
    var environment: [KeyValue] = []
    var volumes: [VolumeMount] = []
    var labels: [KeyValue] = []

    struct PortMapping: Identifiable, Hashable {
        let id = UUID()
        var host = ""
        var container = ""
        var proto = "tcp"
    }

    struct KeyValue: Identifiable, Hashable {
        let id = UUID()
        var key = ""
        var value = ""
    }

    struct VolumeMount: Identifiable, Hashable {
        let id = UUID()
        var source = ""
        var destination = ""
        var readOnly = false
    }
}

/// Translates a `RunConfiguration` into `container run` arguments.
///
/// The GUI always runs detached (`-d`) so the calling Task never blocks on a
/// foreground process; interactive shells are provided via the Terminal tab.
enum RunCommandBuilder {
    static func arguments(for config: RunConfiguration, progress: String? = nil) -> [String] {
        var args = ["run", "--detach"]

        if config.removeOnExit { args.append("--rm") }
        if config.rosetta { args.append("--rosetta") }
        if !config.arch.isEmpty { args.append(contentsOf: ["--arch", config.arch]) }

        appendOption(&args, "--name", config.name)
        appendOption(&args, "--cpus", config.cpus)
        appendOption(&args, "--memory", config.memory)
        appendOption(&args, "--network", config.network)
        appendOption(&args, "--workdir", config.workdir)
        appendOption(&args, "--user", config.user)
        appendOption(&args, "--entrypoint", config.entrypoint)

        for port in config.ports where !port.host.isEmpty && !port.container.isEmpty {
            let proto = port.proto.isEmpty ? "tcp" : port.proto
            args.append(contentsOf: ["--publish", "\(port.host):\(port.container)/\(proto)"])
        }

        for variable in config.environment where !variable.key.isEmpty {
            args.append(contentsOf: ["--env", "\(variable.key)=\(variable.value)"])
        }

        for label in config.labels where !label.key.isEmpty {
            args.append(contentsOf: ["--label", "\(label.key)=\(label.value)"])
        }

        for mount in config.volumes where !mount.source.isEmpty && !mount.destination.isEmpty {
            var spec = "\(mount.source):\(mount.destination)"
            if mount.readOnly { spec += ":ro" }
            args.append(contentsOf: ["--volume", spec])
        }

        if let progress {
            args.append(contentsOf: ["--progress", progress])
        }

        args.append(config.image)

        if !config.command.isEmpty {
            args.append(contentsOf: tokenize(config.command))
        }

        return args
    }

    /// Renders the equivalent shell command for preview purposes (single line).
    static func previewCommand(for config: RunConfiguration) -> String {
        (["container"] + arguments(for: config)).joined(separator: " ")
    }

    /// Multi-line shell preview: one option (with its value) per line, joined with " \\" continuations.
    ///
    /// Line 1: "container run" + all value-less flags (--detach, --rm, --rosetta)
    /// Then: each flag+value pair on its own line
    /// Last line: image + optional command tokens (quoted if they contain spaces)
    static func previewLines(for config: RunConfiguration) -> [String] {
        let allArgs = arguments(for: config)
        // allArgs[0] == "run"
        var lines: [String] = []
        var idx = 1 // skip "run"

        // Collect leading boolean flags (no value) into first line
        var firstLine = "container run"
        while idx < allArgs.count {
            let arg = allArgs[idx]
            if arg.hasPrefix("--") {
                // Check if next element is a value (doesn't start with -) or there is no next element
                let nextIdx = idx + 1
                let nextIsValue = nextIdx < allArgs.count && !allArgs[nextIdx].hasPrefix("-")
                if nextIsValue {
                    // This flag takes a value — stop collecting into first line
                    break
                } else {
                    firstLine += " \(arg)"
                    idx += 1
                }
            } else {
                break
            }
        }
        lines.append(firstLine)

        // Process remaining flag+value pairs and positional args (image + command)
        while idx < allArgs.count {
            let arg = allArgs[idx]
            if arg.hasPrefix("-") {
                let nextIdx = idx + 1
                if nextIdx < allArgs.count && !allArgs[nextIdx].hasPrefix("-") {
                    let value = shellQuote(allArgs[nextIdx])
                    lines.append("\(arg) \(value)")
                    idx += 2
                } else {
                    lines.append(arg)
                    idx += 1
                }
            } else {
                // Positional: image and optional command tokens
                var positional = shellQuote(arg)
                idx += 1
                while idx < allArgs.count {
                    positional += " \(shellQuote(allArgs[idx]))"
                    idx += 1
                }
                lines.append(positional)
            }
        }

        return lines
    }

    /// Wraps a shell token in double quotes if it contains spaces, quotes, or backslashes.
    private static func shellQuote(_ arg: String) -> String {
        guard arg.contains(" ") || arg.contains("\"") || arg.contains("\\") else { return arg }
        let escaped = arg
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    /// Splits a string into argv tokens like a POSIX shell:
    /// - Whitespace (spaces, tabs) separates tokens.
    /// - Single quotes preserve the literal value of all characters.
    /// - Double quotes allow `\"` and `\\` escapes; other characters are literal.
    /// - A backslash outside quotes escapes the immediately following character.
    /// - An unclosed quote treats the remainder of the string literally (leniency).
    /// - Multiple whitespace characters between tokens are ignored.
    /// - An empty string or all-whitespace input returns `[]`.
    static func tokenize(_ command: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var index = command.startIndex

        while index < command.endIndex {
            let ch = command[index]

            switch ch {
            case "'":
                // Single-quoted region — everything literal until closing '
                index = command.index(after: index)
                while index < command.endIndex && command[index] != "'" {
                    current.append(command[index])
                    index = command.index(after: index)
                }
                // Skip closing ' if present; if not, we've consumed to end (leniency)
                if index < command.endIndex { index = command.index(after: index) }

            case "\"":
                // Double-quoted region — \" and \\ are escape sequences
                index = command.index(after: index)
                while index < command.endIndex && command[index] != "\"" {
                    if command[index] == "\\" {
                        let nextIdx = command.index(after: index)
                        if nextIdx < command.endIndex {
                            let next = command[nextIdx]
                            if next == "\"" || next == "\\" {
                                current.append(next)
                                index = command.index(after: nextIdx)
                                continue
                            }
                        }
                    }
                    current.append(command[index])
                    index = command.index(after: index)
                }
                // Skip closing " if present; if not, leniency applies
                if index < command.endIndex { index = command.index(after: index) }

            case "\\":
                // Backslash outside quotes: escape next character literally
                let nextIdx = command.index(after: index)
                if nextIdx < command.endIndex {
                    current.append(command[nextIdx])
                    index = command.index(after: nextIdx)
                } else {
                    // Trailing backslash: consume it literally
                    current.append(ch)
                    index = command.index(after: index)
                }

            case " ", "\t":
                // Whitespace: flush current token if non-empty
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                index = command.index(after: index)

            default:
                current.append(ch)
                index = command.index(after: index)
            }
        }

        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    /// Joins argv tokens into a shell-like string, quoting args that contain spaces or double-quote characters.
    ///
    /// - An argument without spaces or double quotes is returned as-is.
    /// - Otherwise the argument is wrapped in double quotes with internal `\` and `"` escaped.
    /// - Invariant: `tokenize(joinCommand(args)) == args` for well-formed argv.
    static func joinCommand(_ args: [String]) -> String {
        args.map { arg in
            guard arg.contains(" ") || arg.contains("\"") || arg.contains("\\") else { return arg }
            let escaped = arg
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        }.joined(separator: " ")
    }

    private static func appendOption(_ args: inout [String], _ flag: String, _ value: String) {
        guard !value.isEmpty else { return }
        args.append(contentsOf: [flag, value])
    }
}
