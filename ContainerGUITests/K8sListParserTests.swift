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

    /// CLI 1.3.0 stopped filling the CLUSTER column. Captured verbatim from
    /// `container k8s list` on 1.3.0 (build d6de569) against a cluster created
    /// with `--name gui-k8s`: the name appears only under NODE, and the row was
    /// previously discarded as a stray log line — which left the Kubernetes and
    /// Helm sections empty on a machine that had a running cluster.
    func testTakesTheClusterFromTheNodeWhenTheColumnIsBlank() {
        let output = """
        CLUSTER  NODE     ROLE                  STATE    CPUS  MEMORY    ADDR          PORTS
                 gui-k8s  control-plane,worker  running  4     12288 MB  192.168.66.9  6445->6443
        """

        let nodes = K8sListParser.parse(output)

        XCTAssertEqual(nodes.count, 1)
        guard let node = nodes.first else { return XCTFail("brak wiersza") }
        XCTAssertEqual(node.cluster, "gui-k8s")
        XCTAssertEqual(node.name, "gui-k8s")
        // 1.3.0 also reports both roles on the single node.
        XCTAssertEqual(node.role, "control-plane,worker")
        XCTAssertTrue(node.isControlPlane)
        XCTAssertEqual(node.memory, "12288 MB")
        XCTAssertEqual(node.apiServerHostPort, 6445)
    }

    func testCarriesTheClusterNameOntoContinuationRows() {
        // Grouped-table rendering: the name is printed once for the group. Only
        // single-node clusters exist today, but the table has always been shaped
        // for more, and falling back to the node name per row would split one
        // cluster into several.
        let output = """
        CLUSTER   NODE       ROLE           STATE    CPUS  MEMORY   ADDR          PORTS
        big       big-cp     control-plane  running  4     6144 MB  192.168.69.4  6445->6443
                  big-w1     worker         running  2     2048 MB  192.168.69.5
        """

        let nodes = K8sListParser.parse(output)

        XCTAssertEqual(nodes.count, 2)
        XCTAssertEqual(nodes.map(\.cluster), ["big", "big"])
        XCTAssertEqual(nodes.map(\.name), ["big-cp", "big-w1"])
        XCTAssertEqual(K8sCluster.group(nodes).count, 1)
    }

    func testTwoClustersWithABlankColumnStayApart() {
        // The realistic 1.3.0 shape with more than one cluster: neither row names
        // its cluster, so each has to fall back to its own node rather than
        // inheriting the one above it.
        let output = """
        CLUSTER  NODE     ROLE                  STATE    CPUS  MEMORY   ADDR          PORTS
                 alpha    control-plane,worker  running  4     6144 MB  192.168.69.4  6445->6443
                 beta     control-plane,worker  stopped  2     2048 MB
        """

        let clusters = K8sCluster.group(K8sListParser.parse(output))

        XCTAssertEqual(clusters.map(\.name), ["alpha", "beta"])
    }

    func testRejectsRowsWithoutANodeName() {
        // NODE is the one column that must be filled for a line to be a row.
        let output = """
        CLUSTER   NODE      ROLE           STATE    CPUS  MEMORY   ADDR          PORTS
        orphan              control-plane  running  4     6144 MB  192.168.69.4  6445->6443
        """
        XCTAssertTrue(K8sListParser.parse(output).isEmpty)
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
