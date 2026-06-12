import SwiftUI
import AppKit

struct ContainersView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: ContainerInfo.ID?
    @State private var showRunSheet = false
    @State private var recreateTarget: ContainerInfo?
    @State private var confirmation: ContainerConfirmation?

    enum ContainerConfirmation: Identifiable {
        case remove(ContainerInfo)
        case prune
        var id: String {
            switch self {
            case .remove(let container): "remove-\(container.id)"
            case .prune: "prune"
            }
        }
    }

    private var store: ContainerStore { model.containers }

    private var selectedContainer: ContainerInfo? {
        store.items.first { $0.id == selection }
    }

    var body: some View {
        GeometryReader { geo in
            VSplitView {
                // VSplitView ignores idealHeight, so cap the list instead:
                // with the list at most 40% tall, the detail always gets >=60%.
                listSection
                    .frame(
                        minHeight: 130,
                        maxHeight: selectedContainer == nil ? .infinity : max(geo.size.height * 0.4, 130)
                    )
                if let selected = selectedContainer {
                    ContainerDetailView(container: selected)
                        .frame(minHeight: 320, maxHeight: .infinity)
                }
            }
        }
        .navigationTitle("Kontenery")
        .task { await store.refresh() }
        .toolbar { toolbarContent }
        .sheet(isPresented: $showRunSheet) {
            RunContainerSheet()
                .environment(model)
        }
        .sheet(item: $recreateTarget) { container in
            RunContainerSheet(recreating: container)
                .environment(model)
        }
        .confirmationDialog(
            confirmationTitle,
            isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }),
            presenting: confirmation
        ) { item in
            switch item {
            case .remove(let container):
                Button("Usuń", role: .destructive) {
                    Task { await perform { try await store.remove(container, force: true) } }
                }
                Button("Anuluj", role: .cancel) {}
            case .prune:
                Button("Usuń zatrzymane", role: .destructive) {
                    Task { await perform { try await store.prune() } }
                }
                Button("Anuluj", role: .cancel) {}
            }
        } message: { item in
            switch item {
            case .remove(let container): Text("Kontener \(container.id) zostanie nieodwracalnie usunięty.")
            case .prune: Text("Usunięte zostaną wszystkie zatrzymane kontenery.")
            }
        }
    }

    private var confirmationTitle: String {
        switch confirmation {
        case .remove: String(localized: "Usunąć kontener?")
        case .prune: String(localized: "Usunąć zatrzymane kontenery?")
        case nil: ""
        }
    }

    @ViewBuilder
    private var listSection: some View {
        if store.items.isEmpty {
            if model.system.serviceState.isRunning {
                EmptyStateView(
                    symbol: "shippingbox",
                    title: String(localized: "Brak kontenerów"),
                    message: String(localized: "Uruchom kontener z obrazu, aby zobaczyć go tutaj."),
                    actionTitle: String(localized: "Uruchom kontener…"),
                    action: { showRunSheet = true },
                    tint: .blue
                )
            } else {
                Color.clear
            }
        } else {
            Table(store.items, selection: $selection) {
                TableColumn("") { container in
                    Group {
                        if store.pendingIDs.contains(container.id) {
                            ProgressView()
                                .controlSize(.mini)
                        } else {
                            StatusDot(state: container.state)
                        }
                    }
                    .animation(.easeInOut(duration: 0.2), value: store.pendingIDs.contains(container.id))
                }
                .width(20)

                TableColumn("Nazwa") { container in
                    Text(container.id).fontWeight(.medium)
                }

                TableColumn("Obraz") { container in
                    Text(container.imageReference)
                        .foregroundStyle(.secondary)
                }

                TableColumn("Stan") { container in
                    Text(container.state)
                        .foregroundStyle(container.isRunning ? Color.green : Color.secondary)
                }

                TableColumn("Adres IP") { container in
                    Text(container.primaryIPv4 ?? "—")
                        .foregroundStyle(.secondary)
                }

                TableColumn("Porty") { container in
                    Text(container.configuration.publishedPorts?.map(\.display).joined(separator: ", ") ?? "—")
                        .foregroundStyle(.secondary)
                }
            }
            .contextMenu(forSelectionType: ContainerInfo.ID.self) { ids in
                if let id = ids.first, let container = store.items.first(where: { $0.id == id }) {
                    rowActions(for: container)
                }
            }
        }
    }

    @ViewBuilder
    private func rowActions(for container: ContainerInfo) -> some View {
        let isPending = store.pendingIDs.contains(container.id)
        if isPending {
            Text("Akcja w toku…")
        } else if container.isRunning {
            Button("Zatrzymaj") { Task { await perform { try await store.stop(container) } } }
            Button("Uruchom ponownie") { Task { await perform { try await store.restart(container) } } }
            Button("Zabij") { Task { await perform { try await store.kill(container) } } }
        } else {
            Button("Uruchom") { Task { await perform { try await store.start(container) } } }
        }
        Divider()
        Button("Zmień polecenie / konfigurację…", systemImage: "slider.horizontal.3") {
            recreateTarget = container
        }
        .disabled(isPending)
        Divider()
        Button("Eksportuj do tar…") { exportContainer(container) }
            .disabled(isPending)
        Button("Usuń…", role: .destructive) { confirmation = .remove(container) }
            .disabled(isPending)
    }

    private func exportContainer(_ container: ContainerInfo) {
        guard !container.isRunning else {
            model.present(CLIError.command(
                exitCode: -1,
                stderr: String(localized: "Eksport wymaga zatrzymanego kontenera. Zatrzymaj kontener i spróbuj ponownie.")
            ))
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(container.id).tar"
        panel.message = String(localized: "Zapisz system plików kontenera jako archiwum tar")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await perform { try await store.export(container, to: url) } }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                showRunSheet = true
            } label: {
                Label("Uruchom kontener", systemImage: "plus")
            }
            .disabled(!model.system.serviceState.isRunning)

            Button {
                confirmation = .prune
            } label: {
                Label("Wyczyść zatrzymane", systemImage: "trash")
            }
            .disabled(!model.system.serviceState.isRunning)

            Button {
                Task { await store.refresh() }
            } label: {
                Label("Odśwież", systemImage: "arrow.clockwise")
            }
            .keyboardShortcut("r")
        }
    }

    private func perform(_ action: @escaping () async throws -> Void) async {
        do { try await action() }
        catch { model.present(error) }
    }
}

/// Colored status indicator for a container state.
struct StatusDot: View {
    let state: String

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 9, height: 9)
            .help(state)
    }

    private var color: Color {
        switch state.lowercased() {
        case "running": .green
        case "stopped", "exited": .secondary
        default: .orange
        }
    }
}
