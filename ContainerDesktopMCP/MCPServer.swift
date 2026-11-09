import Foundation

// The Model Context Protocol, the small part of it `cd-mcp` speaks: JSON-RPC 2.0,
// one message per line on stdin/stdout, and the `tools` capability only.
// Hand-written on purpose — it is a few dozen lines, not worth a dependency.

/// One item of a tool result.
enum MCPContent: Sendable, Equatable {
    case text(String)
    /// Base64 is done on encoding; pass the raw bytes (e.g. a VM screenshot PNG).
    case image(Data, mimeType: String)

    var json: JSONValue {
        switch self {
        case .text(let text):
            .object(["type": .string("text"), "text": .string(text)])
        case .image(let data, let mimeType):
            .object(["type": .string("image"), "data": .string(data.base64EncodedString()), "mimeType": .string(mimeType)])
        }
    }
}

struct MCPToolResult: Sendable, Equatable {
    var content: [MCPContent]
    var isError = false

    /// Output past this many UTF-8 bytes is cut, with a note saying so: an agent's
    /// context is the scarce thing, and a 900 KB image list helps nobody.
    static let maxTextBytes = 100_000

    static func text(_ text: String, isError: Bool = false) -> MCPToolResult {
        MCPToolResult(content: [.text(truncated(text))], isError: isError)
    }

    static func truncated(_ text: String, limit: Int = maxTextBytes) -> String {
        let utf8 = text.utf8
        guard utf8.count > limit else { return text }
        // Cutting on a byte may split a scalar; decoding repairs it with U+FFFD.
        let head = String(decoding: utf8.prefix(limit), as: UTF8.self)
        return head + "\n\n[output truncated: \(utf8.count) bytes total, first \(limit) shown]"
    }

    var json: JSONValue {
        var object: [String: JSONValue] = ["content": .array(content.map(\.json))]
        if isError { object["isError"] = .bool(true) }
        return .object(object)
    }
}

/// A tool an agent can call. Add new ones to `ContainerTools.all` or `VMTools.all`.
struct MCPTool: Sendable {
    let name: String
    let description: String
    /// JSON Schema for `arguments`, written as a JSON literal.
    let inputSchema: JSONValue
    let readOnly: Bool
    /// Only meaningful when not read-only (MCP defaults it to true there).
    let destructive: Bool
    let handler: @Sendable (ToolArguments) async throws -> MCPToolResult

    init(
        name: String,
        description: String,
        schema: String,
        readOnly: Bool = false,
        destructive: Bool = false,
        handler: @escaping @Sendable (ToolArguments) async throws -> MCPToolResult
    ) {
        self.name = name
        self.description = description
        // A malformed literal is a programming error caught by `tools/list` tests.
        self.inputSchema = (try? JSONDecoder().decode(JSONValue.self, from: Data(schema.utf8))) ?? .null
        self.readOnly = readOnly
        self.destructive = destructive
        self.handler = handler
    }

    var listing: JSONValue {
        .object([
            "name": .string(name),
            "description": .string(description),
            "inputSchema": inputSchema,
            "annotations": .object([
                "readOnlyHint": .bool(readOnly),
                "destructiveHint": .bool(!readOnly && destructive),
            ]),
        ])
    }
}

/// Bad arguments from the client: answered as JSON-RPC -32602, not a tool error.
struct InvalidParams: Error, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
}

/// A tool that ran and failed for a reason the agent should read (`isError`).
struct ToolFailure: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

/// Typed access to a `tools/call` `arguments` object.
struct ToolArguments: Sendable {
    let values: [String: JSONValue]

    init(_ values: [String: JSONValue] = [:]) { self.values = values }

    func string(_ key: String) throws -> String? {
        switch values[key] {
        case nil, .null: return nil
        case .string(let value): return value
        default: throw InvalidParams("'\(key)' must be a string")
        }
    }

    func requiredString(_ key: String) throws -> String {
        guard let value = try string(key), !value.isEmpty else {
            throw InvalidParams("'\(key)' is required")
        }
        return value
    }

    func int(_ key: String) throws -> Int? {
        switch values[key] {
        case nil, .null: return nil
        case .number(let value) where value.rounded() == value: return Int(value)
        default: throw InvalidParams("'\(key)' must be an integer")
        }
    }

    func bool(_ key: String) throws -> Bool? {
        switch values[key] {
        case nil, .null: return nil
        case .bool(let value): return value
        default: throw InvalidParams("'\(key)' must be a boolean")
        }
    }

    func strings(_ key: String) throws -> [String] {
        switch values[key] {
        case nil, .null: return []
        case .array(let items):
            return try items.map {
                guard case .string(let value) = $0 else { throw InvalidParams("'\(key)' must be an array of strings") }
                return value
            }
        default: throw InvalidParams("'\(key)' must be an array of strings")
        }
    }

    /// `{"KEY": "value"}`, returned sorted so the argv is deterministic.
    func stringMap(_ key: String) throws -> [(String, String)] {
        switch values[key] {
        case nil, .null: return []
        case .object(let object):
            return try object.keys.sorted().map { name in
                guard case .string(let value) = object[name] else {
                    throw InvalidParams("'\(key).\(name)' must be a string")
                }
                return (name, value)
            }
        default: throw InvalidParams("'\(key)' must be an object of strings")
        }
    }
}

/// Dispatches JSON-RPC messages to the tool registry. Stateless, so requests can
/// be handled concurrently.
struct MCPServer: Sendable {
    static let latestProtocolVersion = "2025-06-18"
    static let supportedProtocolVersions: Set<String> = ["2025-06-18", "2025-03-26", "2024-11-05"]

    let tools: [MCPTool]
    var name = "container-desktop"
    var version = "dev"

    /// Handles one line; returns the response line, or nil for a notification.
    func handle(line: String) async -> String? {
        guard let message = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)),
              case .object(let object) = message else {
            return encode(Self.error(id: .null, code: -32700, message: "Parse error"))
        }
        let id = object["id"]
        guard case .string(let method)? = object["method"] else {
            // A response from the client, or junk. Neither gets an answer without an id.
            return id.map { encode(Self.error(id: $0, code: -32600, message: "Invalid Request")) }
        }
        let params: [String: JSONValue] = if case .object(let p)? = object["params"] { p } else { [:] }

        // Notifications (`notifications/initialized`, `notifications/cancelled`) get no reply.
        guard let id else { return nil }

        let response: JSONValue
        switch method {
        case "initialize":
            response = Self.result(id: id, initializeResult(params))
        case "ping":
            response = Self.result(id: id, .object([:]))
        case "tools/list":
            response = Self.result(id: id, .object(["tools": .array(tools.map(\.listing))]))
        case "tools/call":
            response = await call(id: id, params: params)
        default:
            response = Self.error(id: id, code: -32601, message: "Method not found: \(method)")
        }
        return encode(response)
    }

    private func initializeResult(_ params: [String: JSONValue]) -> JSONValue {
        var version = Self.latestProtocolVersion
        if case .string(let requested)? = params["protocolVersion"],
           Self.supportedProtocolVersions.contains(requested) {
            version = requested
        }
        return .object([
            "protocolVersion": .string(version),
            "capabilities": .object(["tools": .object([:])]),
            "serverInfo": .object(["name": .string(name), "version": .string(self.version)]),
        ])
    }

    private func call(id: JSONValue, params: [String: JSONValue]) async -> JSONValue {
        guard case .string(let name)? = params["name"] else {
            return Self.error(id: id, code: -32602, message: "Missing tool name")
        }
        guard let tool = tools.first(where: { $0.name == name }) else {
            return Self.error(id: id, code: -32602, message: "Unknown tool: \(name)")
        }
        let arguments: ToolArguments
        switch params["arguments"] {
        case nil, .null: arguments = ToolArguments()
        case .object(let values): arguments = ToolArguments(values)
        default: return Self.error(id: id, code: -32602, message: "'arguments' must be an object")
        }
        do {
            return Self.result(id: id, try await tool.handler(arguments).json)
        } catch let invalid as InvalidParams {
            return Self.error(id: id, code: -32602, message: invalid.message)
        } catch {
            return Self.result(id: id, MCPToolResult.text(Self.describe(error), isError: true).json)
        }
    }

    /// English, raw text for the agent. `CLIError.errorDescription` is localized
    /// through a strings table this helper does not ship, so it would be Polish.
    static func describe(_ error: Error) -> String {
        switch error {
        case let failure as ToolFailure:
            return failure.message
        case let cli as CLIError:
            switch cli {
            case .notInstalled: return "The `container` CLI was not found (looked in /usr/local/bin and /opt/homebrew/bin)."
            case .serviceNotRunning: return "The container system service is not running. Start it with `container system start`."
            case .command(let code, let stderr): return "exit \(code): \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
            case .timeout(let seconds, let command): return "`container \(command)` timed out after \(seconds) s and was terminated."
            case .decoding(let message): return "Could not decode CLI output: \(message)"
            case .helmNotInstalled, .kubectlNotInstalled: return String(describing: cli)
            }
        default:
            return String(describing: error)
        }
    }

    static func result(id: JSONValue, _ result: JSONValue) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": id, "result": result])
    }

    static func error(id: JSONValue, code: Int, message: String) -> JSONValue {
        .object([
            "jsonrpc": .string("2.0"), "id": id,
            "error": .object(["code": .number(Double(code)), "message": .string(message)]),
        ])
    }

    /// Compact encoding never emits a raw newline, which keeps the stream line-delimited.
    private func encode(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) }
            ?? #"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Internal error"}}"#
    }
}
