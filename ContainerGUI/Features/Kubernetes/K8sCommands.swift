import Foundation

/// The `container k8s` argv the app builds.
///
/// Kept apart from `K8sStore` so the arguments can be tested without a running
/// service — the plugin needs one even to print its own `--help`, so a live
/// check is not a substitute here.
enum K8sCommands {

    /// `container k8s create`.
    ///
    /// Every optional field is omitted rather than sent empty: a blank
    /// `--cpus` is an error from the CLI, not a default. There is deliberately
    /// no node-count option — the plugin provisions exactly one node carrying
    /// both the control-plane and worker roles, and offers no way to add more.
    static func create(
        name: String,
        cpus: String,
        memory: String,
        nodeImage: String,
        cniManifest: String,
        removeOnStop: Bool
    ) -> [String] {
        var args = ["k8s", "create", "--name", name]
        if !cpus.isEmpty { args.append(contentsOf: ["--cpus", cpus]) }
        if !memory.isEmpty { args.append(contentsOf: ["--memory", memory]) }
        if !nodeImage.isEmpty { args.append(contentsOf: ["--node-image", nodeImage]) }
        if !cniManifest.isEmpty { args.append(contentsOf: ["--cni", cniManifest]) }
        if removeOnStop { args.append("--rm") }
        return args
    }
}
