import Foundation

/// A local cluster and the app-managed kubeconfig that names it.
///
/// **This type is how the app avoids `~/.kube/config`.** Constructing one
/// requires a cluster name and a file path, so there is no way to spell
/// "whatever kubectl happens to point at" — and `container k8s create` really
/// does rewrite the user's own kubeconfig and switch its current context, which
/// for anyone running this app likely points at a real cluster.
///
/// It renders the flags twice because the two CLIs disagree on the spelling:
/// helm wants `--kube-context`, kubectl wants `--context`. Neither may be
/// omitted — the file `container k8s write-config` produces carries no
/// `current-context`, so `--kubeconfig` alone ends up talking to
/// localhost:8080 and fails.
struct ClusterKubeconfig: Sendable, Hashable {
    let cluster: String
    let kubeconfigPath: String

    var kubectlArguments: [String] {
        ["--kubeconfig", kubeconfigPath, "--context", cluster]
    }

    var helmArguments: [String] {
        ["--kubeconfig", kubeconfigPath, "--kube-context", cluster]
    }
}
