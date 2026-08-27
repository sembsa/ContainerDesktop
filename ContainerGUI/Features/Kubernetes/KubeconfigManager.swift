import Foundation

/// Owns the kubeconfigs the app uses when talking to a local cluster.
///
/// The app never reads or writes `~/.kube/config`. That file usually points at
/// a real cluster, and `helm uninstall` aimed at the wrong context is not a
/// mistake worth risking — so every cluster gets its own file under
/// Application Support, containing that one cluster and nothing else.
enum KubeconfigManager {
    /// `~/Library/Application Support/ContainerDesktop/kubeconfigs`.
    static var directory: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Library/Application Support")
        return base.appending(path: "ContainerDesktop/kubeconfigs")
    }

    static func path(for cluster: String) -> String {
        directory.appending(path: "\(cluster).yaml").path
    }

    /// Returns a target pointing at a freshly written kubeconfig for `cluster`.
    ///
    /// Two details of `container k8s write-config` matter here:
    /// - it *appends* to an existing file, so a stale copy is removed first;
    /// - the file it writes has no `current-context`, which is why every helm
    ///   call also passes `--kube-context` (see `ClusterKubeconfig`).
    static func target(for cluster: String) async throws -> ClusterKubeconfig {
        let path = path(for: cluster)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(atPath: path)
        try await ContainerCLI.shared.run(
            ["k8s", "write-config", "--name", cluster, "--kubeconfig", path],
            timeout: .seconds(60)
        )
        return ClusterKubeconfig(cluster: cluster, kubeconfigPath: path)
    }

    static func removeKubeconfig(for cluster: String) {
        try? FileManager.default.removeItem(atPath: path(for: cluster))
    }
}
