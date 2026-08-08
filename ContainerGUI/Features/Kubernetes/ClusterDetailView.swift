import SwiftUI
import AppKit

/// What a cluster actually is, once you click it: its nodes, how to reach it,
/// what is deployed on it, and the copy-pasteable commands to work with it.
///
/// Selecting a card previously did nothing, which reads as a broken control
/// rather than a deliberate absence.
struct ClusterDetailView: View {
    @Environment(AppModel.self) private var model

    let cluster: K8sCluster

    @State private var tab: Tab = .overview
    @State private var releases: [HelmRelease] = []
    @State private var isLoadingReleases = false

    enum Tab: String, CaseIterable, Identifiable {
        case overview, nodes, access
        var id: String { rawValue }

        var title: String {
            switch self {
            case .overview: String(localized: "Przegląd")
            case .nodes: String(localized: "Węzły")
            case .access: String(localized: "Dostęp")
            }
        }
    }

    private var kubeconfigPath: String { KubeconfigManager.path(for: cluster.name) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()

            switch tab {
            case .overview: overview
            case .nodes: nodes
            case .access: access
            }
        }
        .task(id: cluster.id) { await loadReleases() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "helm")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Color.cyan.gradient, in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 1) {
                Text(cluster.name).font(.headline)
                Text(cluster.isRunning ? String(localized: "Klaster działa") : String(localized: "Klaster zatrzymany"))
                    .font(.caption)
                    .foregroundStyle(cluster.isRunning ? Color.green : .secondary)
            }
            Spacer()
            if cluster.isRunning {
                Button("Wdrożenia Helm", systemImage: "shippingbox") {
                    model.selection = .helm
                    Task { await model.helm.select(cluster: cluster.name) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Overview

    private var overview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                factGrid
                releasesSection
            }
            .padding(12)
        }
    }

    private var factGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
            fact(String(localized: "Węzły"), "\(cluster.nodes.count)", "circle.grid.2x2")
            fact(String(localized: "Rdzenie"), cluster.controlPlane?.cpus ?? "—", "cpu")
            fact(String(localized: "Pamięć"), cluster.controlPlane?.memory ?? "—", "memorychip")
            fact(String(localized: "Adres"), cluster.controlPlane?.address ?? "—", "network")
            if let port = cluster.controlPlane?.apiServerHostPort {
                fact(String(localized: "API serwera"), "localhost:\(port)", "point.3.connected.trianglepath.dotted")
            }
            fact(
                String(localized: "Wdrożenia"),
                isLoadingReleases ? "…" : "\(releases.count)",
                "shippingbox"
            )
        }
    }

    private func fact(_ title: String, _ value: String, _ symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 10))
                    .foregroundStyle(.cyan)
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 9))
    }

    @ViewBuilder
    private var releasesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "shippingbox.fill").foregroundStyle(Color.mint.gradient)
                Text("Wdrożenia Helm").font(.subheadline.weight(.semibold))
                Spacer()
                if isLoadingReleases { ProgressView().controlSize(.small) }
            }
            if !HelmCLI.isInstalled {
                Text("Zainstaluj helm (brew install helm), aby zobaczyć wdrożenia.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if !cluster.isRunning {
                Text("Uruchom klaster, aby zobaczyć wdrożenia.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if releases.isEmpty && !isLoadingReleases {
                Text("Brak wdrożeń w tym klastrze.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(releases) { release in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(release.isDeployed ? Color.green : Color.orange)
                            .frame(width: 6, height: 6)
                        Text(release.name).font(.callout)
                        Text(release.chart)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(release.namespace)
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.quaternary.opacity(0.6), in: Capsule())
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 9))
    }

    // MARK: - Nodes

    private var nodes: some View {
        ScrollView {
            VStack(spacing: 6) {
                ForEach(cluster.nodes) { node in
                    HStack(spacing: 10) {
                        StatusDot(state: node.state)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(node.name).font(.callout.weight(.medium))
                            Text(node.role).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(node.cpus.isEmpty ? "—" : "\(node.cpus) CPU")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text(node.memory)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text(node.address.isEmpty ? "—" : node.address)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    .padding(10)
                    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 9))
                }
            }
            .padding(12)
        }
    }

    // MARK: - Access

    private var access: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Aplikacja używa własnego pliku kubeconfig dla tego klastra i nie modyfikuje Twojego ~/.kube/config.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                commandRow(String(localized: "Plik kubeconfig aplikacji"), kubeconfigPath)
                commandRow(String(localized: "Pody"), "kubectl --kubeconfig \(kubeconfigPath) --context \(cluster.name) get pods -A")
                commandRow(String(localized: "Wdrożenia Helm"), "helm --kubeconfig \(kubeconfigPath) --kube-context \(cluster.name) list -A")
                if let port = cluster.controlPlane?.apiServerHostPort {
                    commandRow(String(localized: "Adres API"), "https://127.0.0.1:\(port)")
                }
            }
            .padding(12)
        }
    }

    private func commandRow(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Text(value)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
                Spacer()
                Button("Kopiuj", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                }
                .buttonStyle(.borderless)
                .labelStyle(.iconOnly)
                .controlSize(.small)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 9))
    }

    // MARK: - Data

    private func loadReleases() async {
        guard cluster.isRunning, HelmCLI.isInstalled else {
            releases = []
            return
        }
        isLoadingReleases = true
        defer { isLoadingReleases = false }
        guard let target = try? await KubeconfigManager.target(for: cluster.name) else {
            releases = []
            return
        }
        releases = (try? await HelmCLI.shared.json(
            ["list", "--all-namespaces"],
            on: target,
            as: [HelmRelease].self
        )) ?? []
    }
}
