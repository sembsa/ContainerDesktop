import XCTest

/// Verifies which shell the embedded terminal actually opens.
///
/// A container and a machine differ by nothing but these arguments, which is why
/// they live in one place instead of being spelled out in two near-identical views.
final class TerminalTargetTests: XCTestCase {

    // MARK: - Containers

    func testContainerOpensAShellThroughExec() {
        XCTAssertEqual(
            TerminalTarget.container(id: "acme-shop-api").arguments,
            ["exec", "-it", "acme-shop-api", "sh"]
        )
    }

    // MARK: - Machines

    func testMachineOpensItsLoginShell() {
        // No executable: `machine run` defaults to the login shell, which on a
        // machine is a real one — unlike a container, where `sh` has to be named.
        XCTAssertEqual(
            TerminalTarget.machine(name: "builder", asRoot: false).arguments,
            ["machine", "run", "-n", "builder", "-i", "-t"]
        )
    }

    func testMachineCanAskForRoot() {
        XCTAssertEqual(
            TerminalTarget.machine(name: "builder", asRoot: true).arguments,
            ["machine", "run", "-n", "builder", "-i", "-t", "--root"]
        )
    }

    func testMachineNeverAppendsACommand() {
        // Anything after the flags would need a `--` separator; the login shell
        // deliberately takes none, so the separator must not appear.
        let args = TerminalTarget.machine(name: "builder", asRoot: false).arguments
        XCTAssertFalse(args.contains("--"))
    }

    // MARK: - Pods

    private var kubeconfig: ClusterKubeconfig {
        ClusterKubeconfig(cluster: "gui-k8s", kubeconfigPath: "/tmp/gui-k8s.yaml")
    }

    func testPodShellGoesThroughKubectlRatherThanContainer() {
        // The other two targets run the `container` binary; a pod exec cannot.
        XCTAssertEqual(TerminalTarget.container(id: "web").binary, .container)
        XCTAssertEqual(TerminalTarget.machine(name: "builder", asRoot: false).binary, .container)
        XCTAssertEqual(
            TerminalTarget.pod(name: "web", namespace: "default", container: nil, kubeconfig: kubeconfig).binary,
            .kubectl
        )
    }

    func testPodShellIsBuiltByTheKubectlCommandBuilder() {
        let target = TerminalTarget.pod(
            name: "web", namespace: "default", container: "app", kubeconfig: kubeconfig
        )
        XCTAssertEqual(
            target.arguments,
            KubectlCommands.exec(
                pod: "web", namespace: "default", container: "app", command: ["sh"], on: kubeconfig
            )
        )
    }

    func testPodShellKeepsTheKubeconfigInFrontOfTheSeparator() {
        // Past `--` these flags would be arguments to the pod's shell.
        let args = TerminalTarget.pod(
            name: "web", namespace: "default", container: nil, kubeconfig: kubeconfig
        ).arguments
        guard let separator = args.firstIndex(of: "--") else {
            return XCTFail("brak separatora --")
        }
        XCTAssertLessThan(args.firstIndex(of: "--kubeconfig") ?? .max, separator)
        XCTAssertEqual(Array(args[(separator + 1)...]), ["sh"])
    }

    // MARK: - Composition with the Ghostty command line

    func testGhosttyCommandLineWrapsAMachineTarget() {
        // Ghostty takes one string, so the machine arguments have to survive the
        // same quoting path the container ones already do.
        let command = TerminalCommandLine.string(
            executable: "/usr/local/bin/container",
            arguments: TerminalTarget.machine(name: "builder", asRoot: false).arguments
        )
        XCTAssertEqual(
            command,
            "/bin/sh -c \"clear; exec /usr/local/bin/container machine run -n builder -i -t\""
        )
    }
}
