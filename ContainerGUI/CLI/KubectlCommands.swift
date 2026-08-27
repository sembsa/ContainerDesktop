import Foundation

/// The `kubectl` argv the app builds, kept apart from the actor so the flags are
/// testable without a cluster.
///
/// Two placement rules, both established against kubectl v1.36.1:
///
/// - The target's flags are **appended**, never prefixed. `kubectl --kubeconfig X
///   get nodes` is rejected outright with "flags cannot be placed before plugin
///   name".
/// - `exec` is the exception: everything after `--` is the command line running
///   inside the pod, so the target has to land in front of the separator or
///   `--kubeconfig` would be handed to the pod's shell.
enum KubectlCommands {

    // MARK: - Reading

    static func get(
        kind: String,
        namespace: String?,
        clusterScoped: Bool = false,
        on target: ClusterKubeconfig
    ) -> [String] {
        var args = ["get", kind]
        // Nodes and namespaces are not namespaced; `-A` is accepted there but
        // says nothing, and `-n` would be a lie.
        if !clusterScoped {
            args.append(contentsOf: namespace.map { ["-n", $0] } ?? ["-A"])
        }
        args.append(contentsOf: ["-o", "json"])
        return args + target.kubectlArguments
    }

    static func logs(
        pod: String,
        namespace: String,
        container: String?,
        tail: Int?,
        follow: Bool,
        on target: ClusterKubeconfig
    ) -> [String] {
        var args = ["logs", pod, "-n", namespace]
        // Only needed for a multi-container pod; naming the sole container is
        // noise, and naming the wrong one is an error.
        if let container, !container.isEmpty { args.append(contentsOf: ["-c", container]) }
        if let tail { args.append(contentsOf: ["--tail", String(tail)]) }
        if follow { args.append("-f") }
        return args + target.kubectlArguments
    }

    /// `describe` prints prose, not JSON — it is the one read that is meant to be
    /// shown verbatim rather than decoded.
    static func describe(
        kind: String,
        name: String,
        namespace: String,
        on target: ClusterKubeconfig
    ) -> [String] {
        ["describe", kind, name, "-n", namespace] + target.kubectlArguments
    }

    // MARK: - Mutating

    static func delete(
        kind: String,
        name: String,
        namespace: String,
        on target: ClusterKubeconfig
    ) -> [String] {
        ["delete", kind, name, "-n", namespace] + target.kubectlArguments
    }

    static func scale(
        deployment: String,
        namespace: String,
        replicas: Int,
        on target: ClusterKubeconfig
    ) -> [String] {
        ["scale", "deployment", deployment, "--replicas", String(replicas), "-n", namespace]
            + target.kubectlArguments
    }

    static func rolloutRestart(
        deployment: String,
        namespace: String,
        on target: ClusterKubeconfig
    ) -> [String] {
        ["rollout", "restart", "deployment", deployment, "-n", namespace]
            + target.kubectlArguments
    }

    // MARK: - Exec

    static func exec(
        pod: String,
        namespace: String,
        container: String?,
        command: [String],
        on target: ClusterKubeconfig
    ) -> [String] {
        var args = ["exec", "-i", "-t", pod, "-n", namespace]
        if let container, !container.isEmpty { args.append(contentsOf: ["-c", container]) }
        // Target first: past the separator these would belong to the pod's shell.
        args.append(contentsOf: target.kubectlArguments)
        args.append("--")
        args.append(contentsOf: command)
        return args
    }
}
