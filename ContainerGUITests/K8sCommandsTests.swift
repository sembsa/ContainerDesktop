import XCTest

/// The `container k8s create` argv.
///
/// The plugin refuses to print its own `--help` without a running service, so
/// these expectations were read off the upstream command definition
/// (`Sources/ContainerK8s/Commands/K8sCreate.swift`) rather than a live run.
final class K8sCommandsTests: XCTestCase {

    private func create(
        name: String = "k8s-dev", cpus: String = "", memory: String = "",
        nodeImage: String = "", cniManifest: String = "", removeOnStop: Bool = false
    ) -> [String] {
        K8sCommands.create(
            plugin: "k8s", name: name, cpus: cpus, memory: memory,
            nodeImage: nodeImage, cniManifest: cniManifest, removeOnStop: removeOnStop
        )
    }

    func testTheNameIsAlwaysSent() {
        XCTAssertEqual(create(), ["k8s", "create", "--name", "k8s-dev"])
    }

    func testEveryFieldIsPassedThrough() {
        let args = create(
            name: "demo", cpus: "4", memory: "8G",
            nodeImage: "docker.io/kindest/node:v1.34.11",
            cniManifest: "/Users/me/cilium.yaml", removeOnStop: true
        )
        XCTAssertEqual(
            args,
            ["k8s", "create", "--name", "demo", "--cpus", "4", "--memory", "8G",
             "--node-image", "docker.io/kindest/node:v1.34.11",
             "--cni", "/Users/me/cilium.yaml", "--rm"]
        )
    }

    func testEmptyFieldsAreOmittedRatherThanSentBlank() {
        // A blank `--cpus` is an error from the CLI, not a default.
        let args = create(cpus: "", memory: "", nodeImage: "", cniManifest: "")
        XCTAssertFalse(args.contains("--cpus"))
        XCTAssertFalse(args.contains("--memory"))
        XCTAssertFalse(args.contains("--node-image"))
        XCTAssertFalse(args.contains("--cni"))
    }

    func testTheCNIManifestIsSentAsOneArgumentEvenWithSpaces() {
        // The path goes to the process as argv, never through a shell, so a
        // space must not split it — and must not acquire quoting either.
        let args = create(cniManifest: "/Users/me/moje manifesty/cilium.yaml")
        guard let index = args.firstIndex(of: "--cni") else { return XCTFail("brak --cni") }
        XCTAssertEqual(args[index + 1], "/Users/me/moje manifesty/cilium.yaml")
    }

    func testRemoveOnStopIsAValuelessFlag() {
        XCTAssertEqual(create(removeOnStop: true).last, "--rm")
        XCTAssertFalse(create(removeOnStop: false).contains("--rm"))
    }

    // MARK: - Which plugin name the install answers to

    func testA16InstallAnswersToCluster() {
        let plugin = K8sCommands.plugin(binary: "/usr/local/bin/container") {
            $0 == "/usr/local/libexec/container/plugins/cluster"
        }
        XCTAssertEqual(plugin, "cluster")
    }

    func testAnOlderInstallKeepsK8s() {
        XCTAssertEqual(K8sCommands.plugin(binary: "/usr/local/bin/container") { _ in false }, "k8s")
    }

    func testTheRootFollowsTheBinaryNotAFixedPrefix() {
        // A Homebrew-style prefix must be looked up under its own libexec.
        let plugin = K8sCommands.plugin(binary: "/opt/homebrew/bin/container") {
            $0 == "/opt/homebrew/libexec/container-plugins/cluster"
        }
        XCTAssertEqual(plugin, "cluster")
    }

    func testNodesUnderEitherLabelAreRecognised() {
        // Missing one would put a control plane in the Containers list.
        XCTAssertEqual(K8sCommands.nodeLabelValues, ["k8s", "cluster"])
    }
}
