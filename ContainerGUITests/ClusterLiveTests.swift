import XCTest

/// A real multi-node cluster (container 1.6+). Skipped unless `CD_LIVE=1`:
/// it boots two VMs and takes minutes.
///
/// `cluster create` merges into `~/.kube/config` and switches the current
/// context unless `KUBECONFIG` points elsewhere (ClusterHelper+Kubeconfig in
/// the plugin). The child process inherits this process's environment, so
/// setting it here keeps the developer's real kubeconfig out of the test.
final class ClusterLiveTests: XCTestCase {
    private let clusterName = "cdlive-k8s"
    private let cli = ContainerCLI.shared
    private let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("cdlive-k8s-" + UUID().uuidString)

    override func setUp() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CD_LIVE"] == "1", "set CD_LIVE=1 to run")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        setenv("KUBECONFIG", scratch.appendingPathComponent("merged").path, 1)
        _ = try? await cli.run([K8sCommands.plugin(), "delete", "--name", clusterName], timeout: .seconds(300))
    }

    override func tearDown() async throws {
        _ = try? await cli.run([K8sCommands.plugin(), "delete", "--name", clusterName], timeout: .seconds(300))
        unsetenv("KUBECONFIG")
        try? FileManager.default.removeItem(at: scratch)
    }

    private func kubectl(_ args: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/local/bin/kubectl")
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    func testAWorkerJoinsAndEveryNodeStaysOutOfTheContainersList() async throws {
        let create = K8sCommands.create(
            plugin: K8sCommands.plugin(), name: clusterName, cpus: "2", memory: "2G",
            nodeImage: "", cniManifest: "", removeOnStop: false, workers: 1
        )
        try await cli.run(create, timeout: .seconds(900))

        // The list the Kubernetes section parses: one cluster, two nodes.
        let table = try await cli.run([K8sCommands.plugin(), "list"])
        let cluster = try XCTUnwrap(K8sCluster.group(K8sListParser.parse(table)).first { $0.name == clusterName }, table)
        XCTAssertEqual(cluster.nodes.count, 2, table)
        XCTAssertTrue(cluster.nodes.contains { $0.role.contains("worker") }, table)

        // Both node containers carry the renamed label, and the Containers
        // list's filter hides them — a control plane must not be deletable there.
        let containers = try await cli.json(["ls", "-a"], as: [ContainerInfo].self)
        let nodes = containers.filter {
            K8sCommands.nodeLabelValues.contains($0.configuration.labels?["com.apple.container.plugin"] ?? "")
        }
        XCTAssertEqual(nodes.count, 2, "node containers by label")

        // The per-cluster kubeconfig the app writes for helm reaches both nodes.
        let path = scratch.appendingPathComponent("app").path
        try await cli.run([K8sCommands.plugin(), "write-config", "--name", clusterName, "--kubeconfig", path])
        let contexts = try kubectl(["config", "get-contexts", "-o", "name", "--kubeconfig", path])
        let context = try XCTUnwrap(contexts.output.split(separator: "\n").first.map(String.init), contexts.output)
        let ready = try kubectl(["--kubeconfig", path, "--context", context,
                                 "wait", "--for=condition=Ready", "nodes", "--all", "--timeout=240s"])
        XCTAssertEqual(ready.status, 0, ready.output)
        let listed = try kubectl(["--kubeconfig", path, "--context", context, "get", "nodes", "-o", "name"])
        XCTAssertEqual(listed.output.split(separator: "\n").count, 2, listed.output)
    }
}
