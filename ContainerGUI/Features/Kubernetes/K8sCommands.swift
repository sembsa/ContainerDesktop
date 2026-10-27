import Foundation

/// The `container k8s` argv the app builds.
///
/// Kept apart from `K8sStore` so the arguments can be tested without a running
/// service — the plugin needs one even to print its own `--help`, so a live
/// check is not a substitute here.
enum K8sCommands {

    /// `k8s` until 1.6.0, `cluster` from then on (apple/container#2427).
    ///
    /// Read off the install rather than the version number: the CLI dispatches a
    /// subcommand to the plugin directory beside its own binary, so that
    /// directory is the ground truth. Checked on every call — it is one stat, and
    /// a CLI upgraded while the app runs must not leave it on the old name.
    static func plugin(
        binary: String? = BinaryResolver.resolve(),
        exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> String {
        guard let binary else { return "k8s" }
        // <root>/bin/container → <root>
        let root = URL(fileURLWithPath: binary).resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent().path
        let renamed = ["\(root)/libexec/container/plugins/cluster",
                       "\(root)/libexec/container-plugins/cluster"]
        return renamed.contains(where: exists) ? "cluster" : "k8s"
    }

    /// `com.apple.container.plugin` on a cluster node. The value was renamed
    /// along with the plugin, and a node missed by this filter shows up in the
    /// Containers list where its control plane can be deleted.
    static let nodeLabelValues: Set<String> = ["k8s", "cluster"]

    /// `container k8s create`.
    ///
    /// Every optional field is omitted rather than sent empty: a blank
    /// `--cpus` is an error from the CLI, not a default. There is deliberately
    /// no node-count option — the plugin provisions exactly one node carrying
    /// both the control-plane and worker roles, and offers no way to add more.
    static func create(
        plugin: String = plugin(),
        name: String,
        cpus: String,
        memory: String,
        nodeImage: String,
        cniManifest: String,
        removeOnStop: Bool
    ) -> [String] {
        var args = [plugin, "create", "--name", name]
        if !cpus.isEmpty { args.append(contentsOf: ["--cpus", cpus]) }
        if !memory.isEmpty { args.append(contentsOf: ["--memory", memory]) }
        if !nodeImage.isEmpty { args.append(contentsOf: ["--node-image", nodeImage]) }
        if !cniManifest.isEmpty { args.append(contentsOf: ["--cni", cniManifest]) }
        if removeOnStop { args.append("--rm") }
        return args
    }
}
