import XCTest

/// The `container k8s` plugin has no `--format json`, so the GUI reads its
/// fixed-width table. These cases are captured from CLI 1.2.2.
final class K8sListParserTests: XCTestCase {
    func testParsesSingleNodeCluster() {
        let output = """
        CLUSTER   NODE      ROLE           STATE    CPUS  MEMORY   ADDR          PORTS
        gui-test  gui-test  control-plane  running  4     6144 MB  192.168.69.4  6445->6443
        """

        let nodes = K8sListParser.parse(output)

        XCTAssertEqual(nodes.count, 1)
        let node = try! XCTUnwrap(nodes.first)
        XCTAssertEqual(node.cluster, "gui-test")
        XCTAssertEqual(node.name, "gui-test")
        XCTAssertEqual(node.role, "control-plane")
        XCTAssertEqual(node.state, "running")
        XCTAssertEqual(node.cpus, "4")
        // Splitting on whitespace would lose the unit here.
        XCTAssertEqual(node.memory, "6144 MB")
        XCTAssertEqual(node.address, "192.168.69.4")
        XCTAssertEqual(node.ports, "6445->6443")
        XCTAssertTrue(node.isRunning)
        XCTAssertTrue(node.isControlPlane)
        XCTAssertEqual(node.apiServerHostPort, 6445)
    }

    func testEmptyTableYieldsNoNodes() {
        let output = "CLUSTER  NODE  ROLE  STATE  CPUS  MEMORY  ADDR  PORTS"
        XCTAssertTrue(K8sListParser.parse(output).isEmpty)
    }

    func testUnrecognisedOutputYieldsNoNodes() {
        XCTAssertTrue(K8sListParser.parse("error: unknown subcommand 'k8s'").isEmpty)
        XCTAssertTrue(K8sListParser.parse("").isEmpty)
    }

    /// A stopped cluster leaves ADDR and PORTS blank; the row must still parse.
    func testStoppedClusterWithBlankTrailingColumns() {
        let output = """
        CLUSTER   NODE      ROLE           STATE    CPUS  MEMORY   ADDR          PORTS
        stopped1  stopped1  control-plane  stopped  2     2048 MB
        """

        let nodes = K8sListParser.parse(output)

        XCTAssertEqual(nodes.count, 1)
        let node = try! XCTUnwrap(nodes.first)
        XCTAssertEqual(node.state, "stopped")
        XCTAssertEqual(node.address, "")
        XCTAssertEqual(node.ports, "")
        XCTAssertFalse(node.isRunning)
        XCTAssertNil(node.apiServerHostPort)
    }

    func testGroupsNodesIntoClustersPreservingOrder() {
        let output = """
        CLUSTER  NODE            ROLE           STATE    CPUS  MEMORY   ADDR          PORTS
        beta     beta            control-plane  running  4     4096 MB  192.168.69.5  6446->6443
        alpha    alpha           control-plane  running  4     4096 MB  192.168.69.4  6445->6443
        alpha    alpha-worker    worker         running  2     2048 MB  192.168.69.6
        """

        let clusters = K8sCluster.group(K8sListParser.parse(output))

        XCTAssertEqual(clusters.map(\.name), ["beta", "alpha"])
        XCTAssertEqual(clusters.last?.nodes.count, 2)
        XCTAssertEqual(clusters.last?.controlPlane?.name, "alpha")
        XCTAssertTrue(clusters.allSatisfy(\.isRunning))
    }

    // MARK: - Version comparison behind the "restart the service" hint

    func testExtractsVersionNumbers() {
        XCTAssertEqual(
            ContainerVersion.number(in: "container CLI version 1.2.2 (build: release, commit: 0190097)"),
            "1.2.2"
        )
        XCTAssertEqual(
            ContainerVersion.number(in: "apiserver.version  container-apiserver version 1.2.0 (build: release)"),
            "1.2.0"
        )
        XCTAssertNil(ContainerVersion.number(in: "no version here"))
    }
}
