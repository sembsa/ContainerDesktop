import XCTest

/// Verifies the `kubectl` argv the app builds.
///
/// Two rules here were established against kubectl v1.36.1 rather than assumed:
///
/// - Global flags may not precede the subcommand. `kubectl --kubeconfig X get
///   nodes` fails with "flags cannot be placed before plugin name", so the
///   target's flags are appended, the way `HelmCLI` already appends helm's.
/// - Appending them is wrong for `exec`, where everything after `--` belongs to
///   the command running inside the pod. `--kubeconfig` after `-- sh` would be
///   passed to the shell.
final class KubectlCommandsTests: XCTestCase {

    private let target = ClusterKubeconfig(
        cluster: "gui-k8s",
        kubeconfigPath: "/Users/me/Library/Application Support/ContainerDesktop/kubeconfigs/gui-k8s.yaml"
    )

    // MARK: - The target itself

    func testKubectlAndHelmSpellTheContextFlagDifferently() {
        // The same file, two spellings — this is why one neutral type renders both
        // instead of helm's arguments being reused for kubectl.
        XCTAssertEqual(
            target.kubectlArguments,
            ["--kubeconfig", target.kubeconfigPath, "--context", "gui-k8s"]
        )
        XCTAssertEqual(
            target.helmArguments,
            ["--kubeconfig", target.kubeconfigPath, "--kube-context", "gui-k8s"]
        )
    }

    func testTheContextIsNeverOmitted() {
        // The kubeconfig `k8s write-config` writes has no current-context, so
        // --kubeconfig alone reaches localhost:8080 and fails.
        XCTAssertTrue(target.kubectlArguments.contains("--context"))
    }

    // MARK: - Get

    func testGetAsksForJSONAcrossAllNamespaces() {
        let args = KubectlCommands.get(kind: "pods", namespace: nil, on: target)
        XCTAssertEqual(
            args,
            ["get", "pods", "-A", "-o", "json"] + target.kubectlArguments
        )
    }

    func testGetScopesToOneNamespace() {
        let args = KubectlCommands.get(kind: "deployments", namespace: "kube-system", on: target)
        XCTAssertEqual(
            args,
            ["get", "deployments", "-n", "kube-system", "-o", "json"] + target.kubectlArguments
        )
    }

    func testClusterScopedKindsTakeNoNamespaceFlagAtAll() {
        // `kubectl get nodes -A` is accepted but meaningless; namespaces and nodes
        // are not namespaced.
        let args = KubectlCommands.get(kind: "nodes", namespace: nil, clusterScoped: true, on: target)
        XCTAssertFalse(args.contains("-A"))
        XCTAssertFalse(args.contains("-n"))
        XCTAssertEqual(args.prefix(4), ["get", "nodes", "-o", "json"])
    }

    // MARK: - Logs

    func testPodLogsNameTheContainerAndTailTheHistory() {
        let args = KubectlCommands.logs(
            pod: "coredns-7d764666f9-cq4mq",
            namespace: "kube-system",
            container: "coredns",
            tail: 500,
            follow: true,
            on: target
        )
        XCTAssertEqual(
            args,
            ["logs", "coredns-7d764666f9-cq4mq", "-n", "kube-system",
             "-c", "coredns", "--tail", "500", "-f"] + target.kubectlArguments
        )
    }

    func testPodLogsOmitTheContainerWhenThereIsOnlyOne() {
        let args = KubectlCommands.logs(
            pod: "web", namespace: "default", container: nil, tail: nil, follow: false, on: target
        )
        XCTAssertEqual(args, ["logs", "web", "-n", "default"] + target.kubectlArguments)
    }

    // MARK: - Describe

    func testDescribeIsPlainTextAndNeverAsksForJSON() {
        let args = KubectlCommands.describe(kind: "pod", name: "web", namespace: "default", on: target)
        XCTAssertFalse(args.contains("json"))
        XCTAssertEqual(
            args,
            ["describe", "pod", "web", "-n", "default"] + target.kubectlArguments
        )
    }

    // MARK: - Mutations

    func testDeleteNamesTheKindAndNamespace() {
        XCTAssertEqual(
            KubectlCommands.delete(kind: "pod", name: "web", namespace: "default", on: target),
            ["delete", "pod", "web", "-n", "default"] + target.kubectlArguments
        )
    }

    func testScaleCarriesTheReplicaCount() {
        XCTAssertEqual(
            KubectlCommands.scale(deployment: "coredns", namespace: "kube-system", replicas: 3, on: target),
            ["scale", "deployment", "coredns", "--replicas", "3", "-n", "kube-system"]
                + target.kubectlArguments
        )
    }

    func testRolloutRestartTargetsTheDeployment() {
        XCTAssertEqual(
            KubectlCommands.rolloutRestart(deployment: "coredns", namespace: "kube-system", on: target),
            ["rollout", "restart", "deployment", "coredns", "-n", "kube-system"]
                + target.kubectlArguments
        )
    }

    // MARK: - Exec

    func testExecPutsTheTargetBeforeTheSeparator() {
        // The whole point: everything after `--` is the pod's command line.
        let args = KubectlCommands.exec(
            pod: "web", namespace: "default", container: "app", command: ["sh"], on: target
        )
        guard let separator = args.firstIndex(of: "--") else {
            return XCTFail("brak separatora -- w \(args)")
        }
        XCTAssertEqual(Array(args[(separator + 1)...]), ["sh"])
        for flag in target.kubectlArguments {
            guard let position = args.firstIndex(of: flag) else {
                return XCTFail("brak \(flag)")
            }
            XCTAssertLessThan(position, separator, "\(flag) trafiło za separator")
        }
    }

    func testExecOpensAnInteractiveTTY() {
        let args = KubectlCommands.exec(
            pod: "web", namespace: "default", container: nil, command: ["sh"], on: target
        )
        XCTAssertEqual(args.prefix(5), ["exec", "-i", "-t", "web", "-n"])
        XCTAssertFalse(args.contains("-c"))
    }
}
