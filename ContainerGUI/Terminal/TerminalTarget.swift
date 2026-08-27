import Foundation

/// What the embedded terminal attaches to.
///
/// A container shell and a machine shell differ by nothing but these arguments,
/// so they live here rather than being spelled out in two near-identical views.
/// Kept free of SwiftUI so the logic tests can compile it on its own.
enum TerminalTarget: Sendable, Hashable {
    case container(id: String)
    /// `asRoot` maps to `--root`, which runs as root instead of matching the host user.
    case machine(name: String, asRoot: Bool)
    case pod(name: String, namespace: String, container: String?, kubeconfig: ClusterKubeconfig)

    /// Which executable runs the session. A pod exec cannot go through the
    /// `container` binary at all, so the view can no longer assume one.
    enum Binary: Sendable, Hashable { case container, kubectl }

    var binary: Binary {
        switch self {
        case .container, .machine: .container
        case .pod: .kubectl
        }
    }

    var arguments: [String] {
        switch self {
        case .container(let id):
            // A container image has no login shell to fall back on, so `sh` is named.
            return ["exec", "-it", id, "sh"]

        case .pod(let name, let namespace, let container, let kubeconfig):
            // Built by the same code that builds every other kubectl call, so the
            // `--` placement rule holds here too: the kubeconfig has to precede
            // the separator or it lands in the pod's shell.
            return KubectlCommands.exec(
                pod: name,
                namespace: namespace,
                container: container,
                command: ["sh"],
                on: kubeconfig
            )

        case .machine(let name, let asRoot):
            // No executable: `machine run` then opens the machine's login shell.
            // Nothing may follow the flags — a command would need a `--` separator.
            var args = ["machine", "run", "-n", name, "-i", "-t"]
            if asRoot { args.append("--root") }
            return args
        }
    }
}
