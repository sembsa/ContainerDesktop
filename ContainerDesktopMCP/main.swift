import Foundation

// cd-mcp: Container Desktop's MCP server. JSON-RPC on stdin/stdout, one message
// per line; stdout carries protocol messages only, everything else goes to stderr.

func log(_ message: String) {
    FileHandle.standardError.write(Data("cd-mcp: \(message)\n".utf8))
}

/// One writer, so two concurrent responses can never interleave on the pipe.
actor StdoutWriter {
    func write(_ line: String) {
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }
}

// A binary path set in the app's Settings lives in the app's defaults domain, not
// this helper's. Registered (in memory) rather than written, so nothing is persisted.
if let appPath = UserDefaults(suiteName: "com.containerdesktop.ContainerGUI")?.string(forKey: BinaryResolver.defaultsKey) {
    UserDefaults.standard.register(defaults: [BinaryResolver.defaultsKey: appPath])
}

let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
let server = MCPServer(tools: ContainerTools.all + VMTools.all, version: version)
let writer = StdoutWriter()
log("\(server.tools.count) tools, container CLI: \(BinaryResolver.resolve() ?? "not found")")

// Requests run concurrently so a long `image_pull` does not block `ping`; the
// group waits for all of them before the process exits on EOF.
await withTaskGroup(of: Void.self) { group in
    do {
        for try await line in FileHandle.standardInput.bytes.lines where !line.isEmpty {
            group.addTask {
                if let response = await server.handle(line: line) { await writer.write(response) }
            }
        }
    } catch {
        log("stdin: \(error)")
    }
}
