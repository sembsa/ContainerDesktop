import SwiftUI
import AppKit

/// Helm releases, chart catalogue and repositories for the selected cluster.
struct HelmView: View {
    @Environment(AppModel.self) private var model

    enum Tab: String, CaseIterable, Identifiable {
        case releases, charts, repositories
        var id: String { rawValue }

        var title: String {
            switch self {
            case .releases: String(localized: "Wdrożenia")
            case .charts: String(localized: "Charty")
            case .repositories: String(localized: "Repozytoria")
            }
        }
    }

    @State private var tab: Tab = .releases
    @State private var installChart: HelmChart?
    @State private var upgradeTarget: HelmRelease?
    @State private var historyTarget: HelmRelease?
    @State private var uninstallTarget: HelmRelease?
    @State private var search = ""
    @State private var newRepoName = ""
    @State private var newRepoURL = ""

    private var store: HelmStore { model.helm }

    var body: some View {
        Group {
            if !store.isHelmInstalled {
                helmMissingState
            } else {
                VStack(spacing: 0) {
                    clusterBar
                    Divider()
                    Picker("", selection: $tab) {
                        ForEach(Tab.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .padding(10)
                    Divider()
                    content
                }
            }
        }
        .navigationTitle("Helm")
        .toolbar { toolbarContent }
        .task { await bootstrap() }
        .sheet(item: $installChart) { chart in
            InstallChartSheet(chart: chart, upgrading: nil)
        }
        .sheet(item: $upgradeTarget) { release in
            InstallChartSheet(
                chart: HelmChart(name: release.chartName, version: release.chartVersion ?? "", appVersion: nil, description: nil),
                upgrading: release
            )
        }
        .sheet(item: $historyTarget) { release in
            ReleaseHistorySheet(release: release)
        }
        .alert(item: $uninstallTarget) { release in
            Alert(
                title: Text("Odinstalować wdrożenie?"),
                message: Text(String(
                    format: String(localized: "Wdrożenie „%@” w przestrzeni nazw „%@” zostanie usunięte z klastra."),
                    release.name, release.namespace
                )),
                primaryButton: .destructive(Text("Odinstaluj")) {
                    Task { await perform { try await store.uninstall(release) } }
                },
                secondaryButton: .cancel(Text("Anuluj"))
            )
        }
    }

    private func bootstrap() async {
        await store.refreshRepositories()
        if store.targetCluster == nil, let first = model.kubernetes.clusters.first(where: \.isRunning) {
            await store.select(cluster: first.name)
        }
    }

    // MARK: - Cluster bar

    private var clusterBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .foregroundStyle(Color.cyan.gradient)
            Text("Klaster")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("", selection: clusterBinding) {
                Text("— wybierz —").tag("")
                ForEach(model.kubernetes.clusters) { cluster in
                    Text(cluster.name)
                        .tag(cluster.name)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 240)
            InfoTip(text: String(localized: "Wszystkie polecenia helm są wykonywane wyłącznie na wybranym tu klastrze — aplikacja używa własnego pliku kubeconfig i nie modyfikuje Twojego ~/.kube/config."))
            Spacer()
            if store.isLoadingReleases {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var clusterBinding: Binding<String> {
        Binding(
            get: { store.targetCluster ?? "" },
            set: { name in
                Task {
                    if name.isEmpty { store.clearTarget() } else { await store.select(cluster: name) }
                }
            }
        )
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .releases: releasesTab
        case .charts: chartsTab
        case .repositories: repositoriesTab
        }
    }

    // MARK: Releases

    @ViewBuilder
    private var releasesTab: some View {
        if store.targetCluster == nil {
            EmptyStateView(
                symbol: "point.3.connected.trianglepath.dotted",
                title: String(localized: "Nie wybrano klastra"),
                message: String(localized: "Wybierz klaster powyżej albo utwórz nowy w sekcji Kubernetes."),
                tint: .cyan
            )
        } else if store.releases.isEmpty {
            EmptyStateView(
                symbol: "shippingbox",
                title: String(localized: "Brak wdrożeń"),
                message: String(localized: "Znajdź chart w zakładce Charty i zainstaluj go w tym klastrze."),
                actionTitle: String(localized: "Przejdź do chartów"),
                action: { tab = .charts },
                tint: .cyan
            )
        } else {
            List {
                ForEach(store.releases) { release in
                    releaseRow(release)
                }
            }
        }
    }

    private func releaseRow(_ release: HelmRelease) -> some View {
        HStack(spacing: 10) {
            StatusDot(state: release.isDeployed ? "running" : release.status)
            VStack(alignment: .leading, spacing: 2) {
                Text(release.name).font(.headline)
                HStack(spacing: 6) {
                    Text(release.chart)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let appVersion = release.appVersion, !appVersion.isEmpty {
                        Text("app \(appVersion)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            Text(release.namespace)
                .font(.caption)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Color.secondary.opacity(0.15), in: Capsule())
            Text(String(format: String(localized: "rew. %@"), release.revision))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            if store.pendingIDs.contains(release.id) {
                ProgressView().controlSize(.small)
            } else {
                Menu {
                    Button("Aktualizuj / zmień values…", systemImage: "arrow.up.circle") {
                        upgradeTarget = release
                    }
                    Button("Historia i wycofanie…", systemImage: "clock.arrow.circlepath") {
                        historyTarget = release
                    }
                    Divider()
                    Button("Odinstaluj…", systemImage: "trash", role: .destructive) {
                        uninstallTarget = release
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 28)
            }
        }
        .padding(.vertical, 3)
    }

    // MARK: Charts

    private var chartsTab: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Szukaj chartów w repozytoriach…", text: $search)
                    .textFieldStyle(.plain)
                    .onSubmit { Task { await store.search(search) } }
                if store.isSearching { ProgressView().controlSize(.small) }
            }
            .padding(10)
            Divider()

            if store.searchResults.isEmpty {
                EmptyStateView(
                    symbol: "square.stack.3d.up",
                    title: String(localized: "Znajdź chart"),
                    message: String(localized: "Wpisz nazwę i naciśnij Enter. Przeszukiwane są repozytoria dodane w zakładce Repozytoria — odśwież je, jeśli wyniki wyglądają na nieaktualne."),
                    tint: .cyan
                )
            } else {
                List {
                    ForEach(store.searchResults) { chart in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(chart.name).font(.headline)
                                if let description = chart.description, !description.isEmpty {
                                    Text(description)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(chart.version).font(.caption.monospacedDigit())
                                if let appVersion = chart.appVersion, !appVersion.isEmpty {
                                    Text("app \(appVersion)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Button("Zainstaluj…") { installChart = chart }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(store.targetCluster == nil)
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
        }
    }

    // MARK: Repositories

    private var repositoriesTab: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                TextField("nazwa", text: $newRepoName)
                    .frame(width: 140)
                TextField("https://…", text: $newRepoURL)
                Button("Dodaj") {
                    Task {
                        await perform { try await store.addRepository(name: newRepoName, url: newRepoURL) }
                        newRepoName = ""
                        newRepoURL = ""
                    }
                }
                .disabled(newRepoName.isEmpty || newRepoURL.isEmpty)
            }
            .padding(10)
            Divider()

            if store.repositories.isEmpty {
                EmptyStateView(
                    symbol: "tray.2",
                    title: String(localized: "Brak repozytoriów"),
                    message: String(localized: "Dodaj repozytorium chartów, aby móc je przeszukiwać i instalować."),
                    tint: .cyan
                )
            } else {
                List {
                    ForEach(store.repositories) { repository in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(repository.name).font(.headline)
                                Text(repository.url)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                            Spacer()
                            Button("Usuń", systemImage: "trash", role: .destructive) {
                                Task { await perform { try await store.removeRepository(repository) } }
                            }
                            .buttonStyle(.borderless)
                            .labelStyle(.iconOnly)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
    }

    // MARK: - States & toolbar

    private var helmMissingState: some View {
        EmptyStateView(
            symbol: "shippingbox",
            title: String(localized: "Nie znaleziono narzędzia helm"),
            message: String(localized: "Zarządzanie wdrożeniami wymaga zainstalowanego klienta Helm. Zainstaluj go poleceniem „brew install helm”, a następnie odśwież tę sekcję."),
            actionTitle: String(localized: "Kopiuj polecenie instalacji"),
            action: {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("brew install helm", forType: .string)
            },
            tint: .orange
        )
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem {
            Button("Aktualizuj repozytoria", systemImage: "arrow.down.circle") {
                Task { await perform { try await store.updateRepositories() } }
            }
            .disabled(!store.isHelmInstalled)
        }
        ToolbarItem {
            Button("Odśwież", systemImage: "arrow.clockwise") {
                Task {
                    await store.refreshRepositories()
                    await store.refreshReleases()
                }
            }
            .disabled(!store.isHelmInstalled)
        }
    }

    private func perform(_ action: () async throws -> Void) async {
        do { try await action() } catch { model.present(error) }
    }
}

/// `helm history` with a rollback action per revision.
struct ReleaseHistorySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let release: HelmRelease

    @State private var revisions: [HelmRevision] = []
    @State private var isLoading = true
    @State private var errorText: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(Color.cyan.gradient)
                    .font(.title3)
                Text(String(format: String(localized: "Historia: %@"), release.name))
                    .font(.headline)
                Spacer()
            }
            .padding(12)
            Divider()

            if isLoading {
                ProgressView().frame(maxWidth: .infinity, minHeight: 160)
            } else if let errorText {
                Label(errorText, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .padding()
            } else {
                List {
                    ForEach(revisions.reversed()) { revision in
                        HStack(spacing: 10) {
                            Text("#\(revision.revision)")
                                .font(.headline.monospacedDigit())
                                .frame(width: 44, alignment: .leading)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(revision.chart).font(.callout)
                                if let description = revision.description {
                                    Text(description)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Text(revision.status)
                                .font(.caption)
                                .foregroundStyle(revision.status == "deployed" ? .green : .secondary)
                            if String(revision.revision) != release.revision {
                                Button("Wycofaj tutaj") {
                                    Task {
                                        do {
                                            try await model.helm.rollback(release, to: revision.revision)
                                            dismiss()
                                        } catch { errorText = error.localizedDescription }
                                    }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            Divider()
            HStack {
                Spacer()
                Button("Zamknij") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(width: 620, height: 460)
        .task {
            do { revisions = try await model.helm.history(of: release) }
            catch { errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
            isLoading = false
        }
    }
}
