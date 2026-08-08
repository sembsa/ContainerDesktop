import SwiftUI
import AppKit

/// Local Kubernetes clusters run by the `container k8s` plugin.
struct KubernetesView: View {
    @Environment(AppModel.self) private var model

    @State private var showCreate = false
    @State private var loadImageTarget: K8sCluster?
    @State private var deleteTarget: K8sCluster?

    private var store: K8sStore { model.kubernetes }

    var body: some View {
        Group {
            switch store.availability {
            case .versionMismatch(let cli, let service):
                versionMismatchState(cli: cli, service: service)
            case .unsupported:
                unsupportedState
            case .unknown where store.clusters.isEmpty:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            default:
                if store.clusters.isEmpty {
                    emptyState
                } else {
                    clusterList
                }
            }
        }
        .navigationTitle("Kubernetes")
        .toolbar { toolbarContent }
        .task { await store.refresh() }
        .sheet(isPresented: $showCreate) {
            CreateClusterSheet()
        }
        .sheet(item: $loadImageTarget) { cluster in
            LoadImageSheet(cluster: cluster)
        }
        .alert(item: $deleteTarget) { cluster in
            Alert(
                title: Text("Usunąć klaster?"),
                message: Text(String(
                    format: String(localized: "Klaster „%@” i wszystkie uruchomione w nim obciążenia zostaną trwale usunięte."),
                    cluster.name
                )),
                primaryButton: .destructive(Text("Usuń")) {
                    Task { await perform { try await store.delete(cluster) } }
                },
                secondaryButton: .cancel(Text("Anuluj"))
            )
        }
    }

    // MARK: - Cluster list

    private var clusterList: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                if let error = store.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                }
                ForEach(store.clusters) { cluster in
                    clusterCard(cluster)
                }
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private func clusterCard(_ cluster: K8sCluster) -> some View {
        let isPending = store.pendingNames.contains(cluster.name)

        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "helm")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(Color.cyan.gradient, in: RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 2) {
                    Text(cluster.name).font(.headline)
                    if let node = cluster.controlPlane {
                        Text(nodeSummary(node))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if isPending {
                    ProgressView().controlSize(.small)
                } else {
                    clusterActions(cluster)
                }
            }

            Divider()

            ForEach(cluster.nodes) { node in
                HStack(spacing: 8) {
                    StatusDot(state: node.state)
                    Text(node.name).font(.callout)
                    Text(node.role)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.15), in: Capsule())
                    Spacer()
                    Text(node.address.isEmpty ? "—" : node.address)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    if let port = node.apiServerHostPort {
                        Text(verbatim: ":\(port)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    private func nodeSummary(_ node: K8sNode) -> String {
        [node.state, node.cpus.isEmpty ? nil : "\(node.cpus) CPU", node.memory]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    @ViewBuilder
    private func clusterActions(_ cluster: K8sCluster) -> some View {
        if !cluster.isRunning {
            Button("Uruchom", systemImage: "play.fill") {
                Task { await perform { try await store.start(cluster) } }
            }
            .buttonStyle(.borderless)
        }
        Button("Helm", systemImage: "shippingbox.and.arrow.backward") {
            model.selection = .helm
            Task { await model.helm.select(cluster: cluster.name) }
        }
        .buttonStyle(.borderless)
        .disabled(!cluster.isRunning)
        .help("Przejdź do Helm dla tego klastra")

        Menu {
            Button("Wczytaj obraz do klastra…", systemImage: "square.and.arrow.down") {
                loadImageTarget = cluster
            }
            .disabled(!cluster.isRunning)
            Button("Zapisz kubeconfig…", systemImage: "doc.badge.gearshape") {
                exportKubeconfig(cluster)
            }
            Button("Kopiuj polecenie kubectl", systemImage: "doc.on.doc") {
                let command = "kubectl --context \(cluster.name) get pods -A"
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
            }
            Divider()
            Button("Usuń klaster…", systemImage: "trash", role: .destructive) {
                deleteTarget = cluster
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 28)
    }

    // MARK: - States

    private var emptyState: some View {
        EmptyStateView(
            symbol: "helm",
            title: String(localized: "Brak klastrów Kubernetes"),
            message: String(localized: "Utwórz lokalny klaster, aby uruchamiać w nim obciążenia i wdrożenia Helm. Pierwsze uruchomienie pobiera obraz węzła (ok. 850 MB) i trwa ok. 1–2 minuty."),
            actionTitle: String(localized: "Utwórz klaster…"),
            action: { showCreate = true },
            tint: .cyan
        )
    }

    private var unsupportedState: some View {
        EmptyStateView(
            symbol: "exclamationmark.triangle",
            title: String(localized: "Wtyczka k8s jest niedostępna"),
            message: String(localized: "Lokalne klastry Kubernetes wymagają container 1.2.1 lub nowszego, zainstalowanego z pakietu instalacyjnego. Zaktualizuj narzędzie container i spróbuj ponownie."),
            tint: .orange
        )
    }

    private func versionMismatchState(cli: String, service: String) -> some View {
        EmptyStateView(
            symbol: "arrow.triangle.2.circlepath",
            title: String(localized: "Usługa container wymaga restartu"),
            message: String(format: String(localized: "Narzędzie wiersza poleceń jest w wersji %@, a działająca w tle usługa nadal w %@. Po aktualizacji pakietu trzeba zrestartować usługę, aby wtyczka k8s zaczęła działać."), cli, service),
            actionTitle: String(localized: "Uruchom ponownie usługę"),
            action: { Task { await restartService() } },
            tint: .orange
        )
    }

    private func restartService() async {
        await model.stopService()
        await model.startService()
        await store.refresh()
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button("Utwórz klaster…", systemImage: "plus") { showCreate = true }
        }
        ToolbarItem {
            Button("Odśwież", systemImage: "arrow.clockwise") {
                Task { await store.refresh() }
            }
        }
    }

    // MARK: - Helpers

    private func exportKubeconfig(_ cluster: K8sCluster) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(cluster.name).kubeconfig"
        panel.message = String(localized: "Zapisz kontekst klastra do pliku kubeconfig")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await perform { try await store.exportKubeconfig(cluster, to: url.path) } }
    }

    private func perform(_ action: () async throws -> Void) async {
        do { try await action() } catch { model.present(error) }
    }
}
