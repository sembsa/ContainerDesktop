import SwiftUI

/// Objects inside a local cluster: pods, deployments, services, configuration and
/// the cluster's own nodes and namespaces.
///
/// A section of its own rather than tabs inside the cluster detail, so it needs
/// its own cluster picker — the choice is remembered, because it is the same
/// cluster every time for most people.
///
/// The kind picker is a menu, not a segmented control. Seven labels in a
/// segmented control cannot compress and would push the window open, which is
/// exactly the bug the image detail sheet had (issue #19).
struct WorkloadsView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedID: String?

    private var store: WorkloadStore { model.workloads }
    private var clusters: [K8sCluster] { model.kubernetes.clusters }

    var body: some View {
        Group {
            if !store.isKubectlInstalled {
                EmptyStateView(
                    symbol: "circle.grid.3x3",
                    title: String(localized: "Nie znaleziono narzędzia kubectl"),
                    message: String(localized: "Obiekty klastra są czytane przez kubectl. Zainstaluj je poleceniem „brew install kubectl” albo wskaż ścieżkę w Ustawieniach."),
                    tint: .green
                )
            } else if clusters.isEmpty {
                EmptyStateView(
                    symbol: "circle.grid.3x3",
                    title: String(localized: "Brak klastrów"),
                    message: String(localized: "Najpierw utwórz klaster w sekcji Kubernetes. Obciążenia pokazują obiekty żyjące w wybranym klastrze."),
                    actionTitle: String(localized: "Przejdź do Kubernetes"),
                    action: { model.selection = .kubernetes },
                    tint: .green
                )
            } else {
                content
            }
        }
        .navigationTitle("Obciążenia")
        .task { await ensureClusterSelected() }
        .toolbar { toolbarContent }
    }

    private var content: some View {
        GeometryReader { geo in
            VSplitView {
                table
                    .frame(
                        minHeight: 130,
                        maxHeight: selectedID == nil ? .infinity : max(geo.size.height * 0.45, 130)
                    )
                detail
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            // Nothing to pick from until there is a cluster, and an empty picker
            // next to a "no clusters" screen reads as a broken control.
            if store.isKubectlInstalled, !clusters.isEmpty {
                Picker("Klaster", selection: clusterBinding) {
                    ForEach(clusters) { cluster in
                        Text(cluster.name).tag(cluster.name)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()

                // Text, not Label: a menu picker in the toolbar collapses a Label to
                // its icon alone, which left the control showing a cube and nothing else.
                Picker("Rodzaj", selection: kindBinding) {
                    ForEach(WorkloadStore.Kind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()

                if !store.kind.isClusterScoped {
                    Picker("Namespace", selection: namespaceBinding) {
                        Text("wszystkie").tag(String?.none)
                        ForEach(store.namespaces) { namespace in
                            Text(namespace.metadata.name).tag(String?.some(namespace.metadata.name))
                        }
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                }

                if store.isLoading { ProgressView().controlSize(.small) }

                Button {
                    Task { await store.refresh() }
                } label: {
                    Label("Odśwież", systemImage: "arrow.clockwise")
                }
            }
        }
    }

    private var clusterBinding: Binding<String> {
        Binding(
            get: { store.clusterName ?? clusters.first?.name ?? "" },
            set: { name in
                store.clusterName = name
                selectedID = nil
                Task { await store.refresh() }
            }
        )
    }

    private var kindBinding: Binding<WorkloadStore.Kind> {
        Binding(
            get: { store.kind },
            set: { kind in
                store.kind = kind
                selectedID = nil
                Task { await store.refresh() }
            }
        )
    }

    private var namespaceBinding: Binding<String?> {
        Binding(
            get: { store.namespace },
            set: { namespace in
                store.namespace = namespace
                selectedID = nil
                Task { await store.refresh() }
            }
        )
    }

    private func ensureClusterSelected() async {
        if model.kubernetes.clusters.isEmpty { await model.kubernetes.refresh() }
        let known = model.kubernetes.clusters.map(\.name)
        if store.clusterName == nil || !known.contains(store.clusterName ?? "") {
            store.clusterName = known.first
        }
        await store.refresh()
    }

    // MARK: - Tables

    @ViewBuilder
    private var table: some View {
        if let error = store.error {
            EmptyStateView(
                symbol: "exclamationmark.triangle",
                title: String(localized: "Nie udało się odczytać obiektów"),
                message: error,
                tint: .orange
            )
        } else {
            switch store.kind {
            case .pods: podsTable
            case .deployments: deploymentsTable
            case .services: servicesTable
            case .configMaps: configMapsTable
            case .secrets: secretsTable
            case .nodes: nodesTable
            case .namespaces: namespacesTable
            }
        }
    }

    private var podsTable: some View {
        Table(store.pods, selection: $selectedID) {
            TableColumn("Nazwa") { Text($0.metadata.name).fontWeight(.medium) }
                .width(min: 220)
            TableColumn("Namespace") { Text($0.metadata.namespace ?? "—").foregroundStyle(.secondary) }
            TableColumn("Stan") { pod in
                HStack(spacing: 5) {
                    StatusDot(state: pod.status?.phase?.lowercased() == "running" ? "running" : "stopped")
                    Text(pod.status?.phase ?? "—")
                        .foregroundStyle(pod.isReady ? Color.green : Color.secondary)
                }
            }
            TableColumn("Gotowe") { pod in
                Text(verbatim: "\(pod.readyContainers)/\(pod.totalContainers)")
                    .foregroundStyle(pod.isReady ? Color.secondary : Color.orange)
                    .monospacedDigit()
            }
            TableColumn("Restarty") { pod in
                Text(String(pod.restartCount))
                    .foregroundStyle(pod.restartCount > 0 ? Color.orange : Color.secondary)
                    .monospacedDigit()
            }
            TableColumn("Węzeł") { Text($0.spec?.nodeName ?? "—").foregroundStyle(.secondary) }
            TableColumn("IP") { Text($0.status?.podIP ?? "—").foregroundStyle(.secondary) }
        }
    }

    private var deploymentsTable: some View {
        Table(store.deployments, selection: $selectedID) {
            TableColumn("Nazwa") { Text($0.metadata.name).fontWeight(.medium) }
                .width(min: 220)
            TableColumn("Namespace") { Text($0.metadata.namespace ?? "—").foregroundStyle(.secondary) }
            TableColumn("Gotowe") { deployment in
                Text(verbatim: "\(deployment.readyReplicas)/\(deployment.desiredReplicas)")
                    .foregroundStyle(deployment.readyReplicas == deployment.desiredReplicas
                                     ? Color.secondary : Color.orange)
                    .monospacedDigit()
            }
            TableColumn("Obrazy") { deployment in
                Text(deployment.images.joined(separator: ", "))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(deployment.images.joined(separator: "\n"))
            }
        }
    }

    private var servicesTable: some View {
        Table(store.services, selection: $selectedID) {
            TableColumn("Nazwa") { Text($0.metadata.name).fontWeight(.medium) }
                .width(min: 200)
            TableColumn("Namespace") { Text($0.metadata.namespace ?? "—").foregroundStyle(.secondary) }
            TableColumn("Typ") { Text($0.spec?.type ?? "—").foregroundStyle(.secondary) }
            TableColumn("ClusterIP") { Text($0.spec?.clusterIP ?? "—").foregroundStyle(.secondary) }
            TableColumn("Porty") { service in
                Text(Self.portSummary(service))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var configMapsTable: some View {
        Table(store.configMaps, selection: $selectedID) {
            TableColumn("Nazwa") { Text($0.metadata.name).fontWeight(.medium) }
                .width(min: 220)
            TableColumn("Namespace") { Text($0.metadata.namespace ?? "—").foregroundStyle(.secondary) }
            TableColumn("Klucze") { configMap in
                Text(String(configMap.keys.count)).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }

    private var secretsTable: some View {
        Table(store.secrets, selection: $selectedID) {
            TableColumn("Nazwa") { Text($0.metadata.name).fontWeight(.medium) }
                .width(min: 220)
            TableColumn("Namespace") { Text($0.metadata.namespace ?? "—").foregroundStyle(.secondary) }
            TableColumn("Typ") { Text($0.type ?? "—").foregroundStyle(.secondary).lineLimit(1) }
            TableColumn("Klucze") { secret in
                Text(String(secret.keys.count)).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }

    private var nodesTable: some View {
        Table(store.nodes, selection: $selectedID) {
            TableColumn("Nazwa") { Text($0.metadata.name).fontWeight(.medium) }
                .width(min: 200)
            TableColumn("Stan") { node in
                HStack(spacing: 5) {
                    StatusDot(state: node.isReady ? "running" : "stopped")
                    Text(node.isReady ? String(localized: "Ready") : String(localized: "NotReady"))
                        .foregroundStyle(node.isReady ? Color.green : Color.orange)
                }
            }
            TableColumn("Kubelet") { Text($0.kubeletVersion ?? "—").foregroundStyle(.secondary) }
            TableColumn("CPU") { Text($0.capacityCPU ?? "—").foregroundStyle(.secondary) }
            TableColumn("Pamięć") { Text($0.capacityMemory ?? "—").foregroundStyle(.secondary) }
        }
    }

    private var namespacesTable: some View {
        Table(store.namespaces, selection: $selectedID) {
            TableColumn("Nazwa") { Text($0.metadata.name).fontWeight(.medium) }
                .width(min: 220)
            TableColumn("Stan") { Text($0.phase ?? "—").foregroundStyle(.secondary) }
            TableColumn("Utworzony") { namespace in
                Text(namespace.metadata.creationTimestamp?
                    .formatted(date: .abbreviated, time: .shortened) ?? "—")
                    .foregroundStyle(.secondary)
            }
        }
    }

    static func portSummary(_ service: K8sService) -> String {
        (service.spec?.ports ?? []).map { port in
            let target = port.targetPort?.text
            let base = [port.port.map(String.init), target].compactMap { $0 }.joined(separator: "→")
            if let nodePort = port.nodePort { return "\(base) (node \(nodePort))" }
            return base
        }
        .joined(separator: ", ")
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        switch store.kind {
        case .pods:
            if let pod = store.pods.first(where: { $0.id == selectedID }) {
                PodDetailView(pod: pod).frame(minHeight: 300, maxHeight: .infinity)
            }
        case .deployments:
            if let deployment = store.deployments.first(where: { $0.id == selectedID }) {
                DeploymentDetailView(deployment: deployment).frame(minHeight: 300, maxHeight: .infinity)
            }
        case .secrets:
            if let secret = store.secrets.first(where: { $0.id == selectedID }) {
                SecretDetailView(secret: secret).frame(minHeight: 300, maxHeight: .infinity)
            }
        case .services:
            if let service = store.services.first(where: { $0.id == selectedID }) {
                SimpleObjectDetailView(
                    title: service.metadata.name,
                    subtitle: service.spec?.type ?? "",
                    symbol: "network",
                    tint: .teal,
                    kind: "service",
                    name: service.metadata.name,
                    namespace: service.metadata.namespace ?? "default",
                    facts: [
                        (String(localized: "Typ"), service.spec?.type ?? "—"),
                        (String(localized: "ClusterIP"), service.spec?.clusterIP ?? "—"),
                        (String(localized: "Porty"), Self.portSummary(service)),
                    ]
                )
                .frame(minHeight: 300, maxHeight: .infinity)
            }
        case .configMaps:
            if let configMap = store.configMaps.first(where: { $0.id == selectedID }) {
                ConfigMapDetailView(configMap: configMap).frame(minHeight: 300, maxHeight: .infinity)
            }
        case .nodes:
            if let node = store.nodes.first(where: { $0.id == selectedID }) {
                SimpleObjectDetailView(
                    title: node.metadata.name,
                    subtitle: node.kubeletVersion ?? "",
                    symbol: "server.rack",
                    tint: .cyan,
                    kind: "node",
                    name: node.metadata.name,
                    namespace: nil,
                    facts: [
                        (String(localized: "Kubelet"), node.kubeletVersion ?? "—"),
                        (String(localized: "System"), node.status?.nodeInfo?.osImage ?? "—"),
                        (String(localized: "Architektura"), node.status?.nodeInfo?.architecture ?? "—"),
                        (String(localized: "Runtime"), node.status?.nodeInfo?.containerRuntimeVersion ?? "—"),
                        (String(localized: "CPU"), node.capacityCPU ?? "—"),
                        (String(localized: "Pamięć"), node.capacityMemory ?? "—"),
                    ]
                )
                .frame(minHeight: 300, maxHeight: .infinity)
            }
        case .namespaces:
            if let namespace = store.namespaces.first(where: { $0.id == selectedID }) {
                SimpleObjectDetailView(
                    title: namespace.metadata.name,
                    subtitle: namespace.phase ?? "",
                    symbol: "folder",
                    tint: .green,
                    kind: "namespace",
                    name: namespace.metadata.name,
                    namespace: nil,
                    facts: [(String(localized: "Stan"), namespace.phase ?? "—")]
                )
                .frame(minHeight: 300, maxHeight: .infinity)
            }
        }
    }
}
