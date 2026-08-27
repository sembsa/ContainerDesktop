import Foundation
import Observation

/// The objects living inside a local cluster, read through `kubectl`.
///
/// The `container k8s` plugin has no object API, so everything here is a kubectl
/// call bound to a `ClusterKubeconfig` — the app never touches
/// `~/.kube/config`, which `container k8s create` rewrites.
///
/// There is no polling. Each kind is one process launch, and a cluster holds
/// enough objects that a three-second tick across seven kinds would keep a
/// laptop busy for nothing. Reads happen on demand: switching kind, switching
/// namespace, pressing refresh, and after any action that changes something.
@MainActor @Observable
final class WorkloadStore {

    /// What the section can list. `resource` is the name kubectl knows.
    enum Kind: String, CaseIterable, Identifiable {
        case pods, deployments, services, configMaps, secrets, nodes, namespaces

        var id: String { rawValue }

        var title: String {
            switch self {
            case .pods: String(localized: "Pody")
            case .deployments: String(localized: "Deploymenty")
            case .services: String(localized: "Serwisy")
            case .configMaps: String(localized: "ConfigMapy")
            case .secrets: String(localized: "Sekrety")
            case .nodes: String(localized: "Węzły")
            case .namespaces: String(localized: "Namespace'y")
            }
        }

        var resource: String {
            switch self {
            case .pods: "pods"
            case .deployments: "deployments"
            case .services: "services"
            case .configMaps: "configmaps"
            case .secrets: "secrets"
            case .nodes: "nodes"
            case .namespaces: "namespaces"
            }
        }

        /// Nodes and namespaces are not namespaced, so neither `-n` nor `-A`
        /// applies to them.
        var isClusterScoped: Bool {
            self == .nodes || self == .namespaces
        }

        var symbol: String {
            switch self {
            case .pods: "cube"
            case .deployments: "square.stack.3d.up"
            case .services: "network"
            case .configMaps: "doc.text"
            case .secrets: "key"
            case .nodes: "server.rack"
            case .namespaces: "folder"
            }
        }
    }

    // MARK: - Selection

    static let clusterStorageKey = "workloadsCluster"

    /// Which cluster the section is pointed at, remembered across launches.
    var clusterName: String? {
        didSet {
            guard clusterName != oldValue else { return }
            UserDefaults.standard.set(clusterName, forKey: Self.clusterStorageKey)
            target = nil
            clearObjects()
        }
    }

    var kind: Kind = .pods
    /// nil means every namespace (`-A`).
    var namespace: String?

    // MARK: - Contents

    var pods: [K8sPod] = []
    var deployments: [K8sDeployment] = []
    var services: [K8sService] = []
    var configMaps: [K8sConfigMap] = []
    var secrets: [K8sSecret] = []
    var nodes: [K8sNodeObject] = []
    var namespaces: [K8sNamespace] = []

    var isLoading = false
    var error: String?
    /// Object ids with an action in flight.
    var busyIDs: Set<String> = []

    private(set) var target: ClusterKubeconfig?

    private let cli = KubectlCLI.shared

    init() {
        clusterName = UserDefaults.standard.string(forKey: Self.clusterStorageKey)
    }

    var isKubectlInstalled: Bool { KubectlCLI.isInstalled }

    // MARK: - Loading

    /// Writes a fresh kubeconfig for the selected cluster and reads the current
    /// kind. Called when the section appears and whenever the selection changes.
    func refresh() async {
        guard let clusterName, !clusterName.isEmpty else {
            clearObjects()
            return
        }
        guard isKubectlInstalled else {
            error = CLIError.kubectlNotInstalled.errorDescription
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let target = try await resolvedTarget(for: clusterName)
            try await load(kind, on: target)
            // The namespace picker needs its options whatever kind is shown.
            if namespaces.isEmpty || kind == .namespaces {
                namespaces = try await cli.list(
                    kind: "namespaces", namespace: nil, clusterScoped: true,
                    as: K8sNamespace.self, on: target
                )
            }
            error = nil
        } catch let failure {
            clearObjects()
            error = (failure as? LocalizedError)?.errorDescription ?? failure.localizedDescription
        }
    }

    private func resolvedTarget(for cluster: String) async throws -> ClusterKubeconfig {
        if let target, target.cluster == cluster { return target }
        // `k8s write-config` appends, so KubeconfigManager removes the stale file
        // first; the result carries no current-context, hence --context on every call.
        let fresh = try await KubeconfigManager.target(for: cluster)
        target = fresh
        return fresh
    }

    private func load(_ kind: Kind, on target: ClusterKubeconfig) async throws {
        let scope = kind.isClusterScoped ? nil : namespace
        switch kind {
        case .pods:
            pods = try await cli.list(kind: kind.resource, namespace: scope, as: K8sPod.self, on: target)
        case .deployments:
            deployments = try await cli.list(kind: kind.resource, namespace: scope, as: K8sDeployment.self, on: target)
        case .services:
            services = try await cli.list(kind: kind.resource, namespace: scope, as: K8sService.self, on: target)
        case .configMaps:
            configMaps = try await cli.list(kind: kind.resource, namespace: scope, as: K8sConfigMap.self, on: target)
        case .secrets:
            secrets = try await cli.list(kind: kind.resource, namespace: scope, as: K8sSecret.self, on: target)
        case .nodes:
            nodes = try await cli.list(kind: kind.resource, namespace: nil, clusterScoped: true, as: K8sNodeObject.self, on: target)
        case .namespaces:
            namespaces = try await cli.list(kind: kind.resource, namespace: nil, clusterScoped: true, as: K8sNamespace.self, on: target)
        }
    }

    private func clearObjects() {
        pods = []
        deployments = []
        services = []
        configMaps = []
        secrets = []
        nodes = []
        error = nil
    }

    func clearAll() {
        clearObjects()
        namespaces = []
        target = nil
    }

    // MARK: - Reading one object

    func describe(kind: String, name: String, namespace: String) async throws -> String {
        guard let target else { throw CLIError.kubectlNotInstalled }
        return try await cli.describe(kind: kind, name: name, namespace: namespace, on: target)
    }

    nonisolated func logStream(
        pod: String,
        namespace: String,
        container: String?,
        tail: Int?,
        follow: Bool,
        on target: ClusterKubeconfig
    ) -> AsyncThrowingStream<String, Error> {
        KubectlCLI.shared.logStream(
            pod: pod, namespace: namespace, container: container,
            tail: tail, follow: follow, on: target
        )
    }

    // MARK: - Actions

    func delete(kind: String, name: String, namespace: String, id: String) async throws {
        guard let target else { throw CLIError.kubectlNotInstalled }
        try await withBusy(id) {
            try await cli.delete(kind: kind, name: name, namespace: namespace, on: target)
        }
        await refresh()
    }

    func scale(deployment: String, namespace: String, replicas: Int, id: String) async throws {
        guard let target else { throw CLIError.kubectlNotInstalled }
        try await withBusy(id) {
            try await cli.scale(deployment: deployment, namespace: namespace, replicas: replicas, on: target)
        }
        await refresh()
    }

    func rolloutRestart(deployment: String, namespace: String, id: String) async throws {
        guard let target else { throw CLIError.kubectlNotInstalled }
        try await withBusy(id) {
            try await cli.rolloutRestart(deployment: deployment, namespace: namespace, on: target)
        }
        await refresh()
    }

    private func withBusy<T>(_ id: String, _ action: () async throws -> T) async throws -> T {
        busyIDs.insert(id)
        defer { busyIDs.remove(id) }
        return try await action()
    }
}
