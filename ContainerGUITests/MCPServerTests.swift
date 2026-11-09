import XCTest

final class MCPServerTests: XCTestCase {

    private let echo = MCPTool(
        name: "echo",
        description: "Echoes 'text'",
        schema: #"{"type":"object","properties":{"text":{"type":"string"}},"required":["text"]}"#,
        readOnly: true
    ) { args in .text(try args.requiredString("text")) }

    private let failing = MCPTool(name: "fail", description: "", schema: "{}") { _ in
        throw CLIError.command(exitCode: 3, stderr: "boom\n")
    }

    private func respond(_ line: String, tools: [MCPTool]? = nil) async throws -> [String: Any]? {
        let server = MCPServer(tools: tools ?? [echo, failing])
        guard let reply = await server.handle(line: line) else { return nil }
        XCTAssertFalse(reply.contains("\n"), "a response must stay on one line")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])
    }

    // MARK: - JSON-RPC

    func testInitializeEchoesASupportedVersion() async throws {
        let reply = try await respond(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#)
        XCTAssertEqual(reply?["id"] as? Int, 1)
        let result = try XCTUnwrap(reply?["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, "2025-03-26")
        XCTAssertNotNil((result["capabilities"] as? [String: Any])?["tools"])
        XCTAssertEqual((result["serverInfo"] as? [String: Any])?["name"] as? String, "container-desktop")
    }

    func testInitializeAnswersAnUnknownVersionWithTheLatest() async throws {
        let reply = try await respond(#"{"jsonrpc":"2.0","id":"a","method":"initialize","params":{"protocolVersion":"1999-01-01"}}"#)
        XCTAssertEqual(reply?["id"] as? String, "a", "a string id round-trips as a string")
        XCTAssertEqual((reply?["result"] as? [String: Any])?["protocolVersion"] as? String, "2025-06-18")
    }

    func testNotificationsGetNoReply() async throws {
        let reply = try await respond(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        XCTAssertNil(reply)
    }

    func testPingAndUnknownMethodAndParseError() async throws {
        let ping = try await respond(#"{"jsonrpc":"2.0","id":7,"method":"ping"}"#)
        XCTAssertNotNil(ping?["result"] as? [String: Any])

        let unknown = try await respond(#"{"jsonrpc":"2.0","id":8,"method":"resources/list"}"#)
        XCTAssertEqual((unknown?["error"] as? [String: Any])?["code"] as? Int, -32601)

        let garbage = try await respond("{not json")
        XCTAssertEqual((garbage?["error"] as? [String: Any])?["code"] as? Int, -32700)
        XCTAssertTrue(garbage?["id"] is NSNull)
    }

    func testToolsListCarriesSchemaAndAnnotations() async throws {
        let reply = try await respond(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        let tools = try XCTUnwrap((reply?["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        let tool = try XCTUnwrap(tools.first)
        XCTAssertEqual(tool["name"] as? String, "echo")
        XCTAssertEqual((tool["inputSchema"] as? [String: Any])?["type"] as? String, "object")
        let annotations = try XCTUnwrap(tool["annotations"] as? [String: Any])
        XCTAssertEqual(annotations["readOnlyHint"] as? Bool, true)
        XCTAssertEqual(annotations["destructiveHint"] as? Bool, false)
    }

    func testToolCallSuccessErrorAndBadArguments() async throws {
        let ok = try await respond(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"echo","arguments":{"text":"hi"}}}"#)
        let result = try XCTUnwrap(ok?["result"] as? [String: Any])
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["type"] as? String, "text")
        XCTAssertEqual(content.first?["text"] as? String, "hi")
        XCTAssertNil(result["isError"])

        // A CLI failure is a tool result the agent reads, not a protocol error.
        let failed = try await respond(#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"fail"}}"#)
        let failure = try XCTUnwrap(failed?["result"] as? [String: Any])
        XCTAssertEqual(failure["isError"] as? Bool, true)
        XCTAssertEqual((failure["content"] as? [[String: Any]])?.first?["text"] as? String, "exit 3: boom")

        let missing = try await respond(#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"echo","arguments":{}}}"#)
        XCTAssertEqual((missing?["error"] as? [String: Any])?["code"] as? Int, -32602)

        let wrongType = try await respond(#"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"echo","arguments":{"text":5}}}"#)
        XCTAssertEqual((wrongType?["error"] as? [String: Any])?["code"] as? Int, -32602)

        let unknown = try await respond(#"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"nope"}}"#)
        XCTAssertEqual((unknown?["error"] as? [String: Any])?["code"] as? Int, -32602)
    }

    func testImageContentIsBase64() {
        let json = MCPContent.image(Data([0x89, 0x50]), mimeType: "image/png").json
        XCTAssertEqual(json, .object(["type": .string("image"), "data": .string("iVA="), "mimeType": .string("image/png")]))
    }

    func testTruncationKeepsTheHeadAndSaysSo() {
        let text = String(repeating: "a", count: 150)
        let cut = MCPToolResult.truncated(text, limit: 100)
        XCTAssertTrue(cut.hasPrefix(String(repeating: "a", count: 100)))
        XCTAssertTrue(cut.contains("truncated: 150 bytes"))
        XCTAssertEqual(MCPToolResult.truncated("short", limit: 100), "short")
    }

    // MARK: - The real registry

    func testEveryRealToolHasAValidSchemaAndAUniqueName() {
        let tools = ContainerTools.all + VMTools.all
        XCTAssertEqual(Set(tools.map(\.name)).count, tools.count)
        for tool in tools {
            guard case .object(let schema) = tool.inputSchema else { return XCTFail("\(tool.name): schema did not parse") }
            XCTAssertEqual(schema["type"], .string("object"), tool.name)
        }
        let destructive = Set(tools.filter { !$0.readOnly && $0.destructive }.map(\.name))
        XCTAssertTrue(destructive.isSuperset(of: ["container_delete", "image_delete", "volume_delete", "network_delete"]))
        XCTAssertTrue(tools.first { $0.name == "container_list" }!.readOnly)
    }

    // MARK: - Arguments → argv

    func testRunMapsArgumentsThroughTheBuilder() throws {
        let args = ToolArguments([
            "image": .string("nginx:alpine"),
            "name": .string("web"),
            "env": .object(["B": .string("2"), "A": .string("1 2")]),
            "ports": .array([.string("8080:80"), .string("127.0.0.1:5353:53/udp")]),
            "volumes": .array([.string("data:/data"), .string("/tmp/x:/x:ro")]),
            "command": .array([.string("sh"), .string("-c"), .string("echo hi there")]),
            "cpus": .number(2),
        ])
        XCTAssertEqual(try ContainerArgv.run(args), [
            "run", "--detach", "--name", "web", "--cpus", "2",
            "--publish", "8080:80/tcp", "--publish", "127.0.0.1:5353:53/udp",
            "--env", "A=1 2", "--env", "B=2",
            "--volume", "data:/data", "--volume", "/tmp/x:/x:ro",
            "--progress", "none",
            "nginx:alpine", "sh", "-c", "echo hi there",
        ])
    }

    func testRunRejectsBadInput() {
        XCTAssertThrowsError(try ContainerArgv.run(ToolArguments([:])))
        XCTAssertThrowsError(try ContainerArgv.port("80"))
        XCTAssertThrowsError(try ContainerArgv.volume("only"))
        XCTAssertEqual(try ContainerArgv.run(ToolArguments(["image": .string("a"), "detach": .bool(false), "remove": .bool(true)])),
                       ["run", "--rm", "--progress", "none", "a"])
    }

    func testOtherArgv() {
        XCTAssertEqual(ContainerArgv.list(all: true), ["ls", "-a"])
        XCTAssertEqual(ContainerArgv.logs(id: "c", tail: 50, boot: false), ["logs", "-n", "51", "c"])
        XCTAssertEqual(ContainerArgv.delete(id: "c", force: true), ["rm", "--force", "c"])
        XCTAssertEqual(ContainerArgv.exec(id: "c", command: ["ls", "-la"], workdir: "/srv", user: nil, env: [("K", "v")]),
                       ["exec", "--workdir", "/srv", "--env", "K=v", "c", "ls", "-la"])
        XCTAssertEqual(ContainerArgv.imagePull(reference: "alpine", platform: "linux/arm64"),
                       ["image", "pull", "--progress", "none", "--platform", "linux/arm64", "alpine"])
        XCTAssertEqual(ContainerArgv.volumeCreate(name: "v", size: "1G"), ["volume", "create", "-s", "1G", "v"])
        XCTAssertEqual(ContainerArgv.networkCreate(name: "n", subnet: "10.0.0.0/24", hostOnly: true),
                       ["network", "create", "--internal", "--subnet", "10.0.0.0/24", "n"])
        XCTAssertEqual(ContainerArgv.machineRun(name: "m", command: ["uname", "-a"], root: true),
                       ["machine", "run", "-n", "m", "--root", "--", "uname", "-a"])
        XCTAssertEqual(ContainerArgv.machineRun(name: nil, command: ["true"], root: false), ["machine", "run", "--", "true"])
    }

    // MARK: - App side

    func testClaudeCodeRegistrationCommand() {
        let path = "/Applications/ContainerGUI.app/Contents/Helpers/cd-mcp"
        XCTAssertEqual(MCPSetup.addArguments(helperPath: path),
                       ["mcp", "add", "--scope", "user", "container-desktop", "--", path])
        let snippet = MCPSetup.configSnippet(helperPath: "/A B/cd-mcp")
        let object = try? JSONSerialization.jsonObject(with: Data(snippet.utf8)) as? [String: [String: [String: String]]]
        XCTAssertEqual(object?["mcpServers"]?["container-desktop"]?["command"], "/A B/cd-mcp")
        XCTAssertEqual(MCPSetup.claudeCandidates(home: "/Users/x").last, "/Users/x/.local/bin/claude")
    }
}
