import SwiftUI
import AppKit

struct ContainerDetailView: View {
    @Environment(AppModel.self) private var model
    let container: ContainerInfo

    enum Tab: String, CaseIterable, Identifiable {
        case logs = "Logi"
        case stats = "Statystyki"
        case files = "Pliki"
        case inspect = "Inspect"
        case terminal = "Terminal"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .logs
    @State private var recreateTarget: ContainerInfo?

    private var store: ContainerStore { model.containers }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Picker("Widok", selection: $tab) {
                ForEach(Tab.allCases) { tab in
                    Text(LocalizedStringKey(tab.rawValue)).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(.background)
        .sheet(item: $recreateTarget) { c in
            RunContainerSheet(recreating: c)
                .environment(model)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .logs:
            LogsView(containerID: container.id)
                .id(container.id)
        case .stats:
            if container.isRunning {
                StatsView(containerID: container.id)
                    .id(container.id)
            } else {
                EmptyStateView(
                    symbol: "chart.line.uptrend.xyaxis",
                    title: String(localized: "Kontener nie działa"),
                    message: String(localized: "Statystyki są dostępne tylko dla uruchomionego kontenera."),
                    tint: .blue
                )
            }
        case .files:
            if container.isRunning {
                ContainerFilesView(container: container)
                    .id(container.id)
            } else {
                EmptyStateView(
                    symbol: "folder",
                    title: String(localized: "Kontener nie działa"),
                    message: String(localized: "Przeglądanie plików wymaga działającego kontenera. Eksport całego systemu plików jest dostępny przyciskiem Eksportuj."),
                    tint: .blue
                )
            }
        case .inspect:
            InspectView(container: container, fetchRaw: { try await store.inspect(container.id) })
                .id(container.id)
        case .terminal:
            if container.isRunning {
                TerminalSessionView(target: .container(id: container.id))
                    .id(container.id)
            } else {
                EmptyStateView(
                    symbol: "terminal",
                    title: String(localized: "Kontener nie działa"),
                    message: String(localized: "Uruchom kontener, aby otworzyć interaktywną powłokę."),
                    tint: .blue
                )
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            StatusDot(state: container.state)
            VStack(alignment: .leading, spacing: 3) {
                Text(container.id)
                    .font(.headline)
                    .foregroundStyle(.primary)
                HStack(spacing: 6) {
                    Text(container.imageReference)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(container.state)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background((container.isRunning ? Color.green : Color.secondary).opacity(0.15), in: Capsule())
                        .foregroundStyle(container.isRunning ? Color.green : Color.secondary)
                }
            }
            InfoTip(text: String(localized: "Szczegóły kontenera: Logi (stdout/stderr procesu), Statystyki na żywo, Pliki (przeglądanie przez exec), Inspect (pełna konfiguracja) i Terminal (interaktywna powłoka)."))
            Spacer()
            Button {
                exportContainer()
            } label: { Label("Eksportuj", systemImage: "arrow.down.doc") }
                .help("Eksportuj system plików kontenera do archiwum tar")
            actionButtons
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Since container 1.2.1 `container export` also works on live containers,
    /// so there is no stopped-state precondition any more.
    private func exportContainer() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(container.id).tar"
        panel.message = String(localized: "Zapisz system plików kontenera jako archiwum tar")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do { try await store.export(container, to: url) }
            catch { model.present(error) }
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        Button {
            recreateTarget = container
        } label: { Label("Zmień konfigurację…", systemImage: "slider.horizontal.3") }
            .disabled(store.pendingIDs.contains(container.id))
        if store.pendingIDs.contains(container.id) {
            ProgressView()
                .controlSize(.small)
            Text("Wykonuję…")
                .foregroundStyle(.secondary)
        } else if container.isRunning {
            Button {
                Task { await perform { try await store.stop(container) } }
            } label: { Label("Zatrzymaj", systemImage: "stop.fill") }
            Button {
                Task { await perform { try await store.restart(container) } }
            } label: { Label("Restart", systemImage: "arrow.clockwise") }
        } else {
            Button {
                Task { await perform { try await store.start(container) } }
            } label: { Label("Uruchom", systemImage: "play.fill") }
        }
    }

    private func perform(_ action: @escaping () async throws -> Void) async {
        do { try await action() }
        catch { model.present(error) }
    }
}
