import SwiftUI

struct NetworksView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: NetworkInfo.ID?
    @State private var showCreate = false
    @State private var confirmation: NetworkConfirmation?

    enum NetworkConfirmation: Identifiable {
        case remove(NetworkInfo)
        case prune
        var id: String {
            switch self {
            case .remove(let network): "remove-\(network.id)"
            case .prune: "prune"
            }
        }
    }

    private var store: NetworkStore { model.networks }

    var body: some View {
        Group {
            if store.items.isEmpty, model.system.serviceState.isRunning {
                EmptyStateView(
                    symbol: "network",
                    title: String(localized: "Brak sieci"),
                    message: String(localized: "Utwórz sieć, aby połączyć kontenery."),
                    actionTitle: String(localized: "Utwórz sieć…"),
                    action: { showCreate = true },
                    tint: .teal
                )
            } else {
                Table(store.items, selection: $selection) {
                    TableColumn("Nazwa") { Text($0.name).fontWeight(.medium) }
                    TableColumn("Tryb") { Text($0.configuration.mode ?? "—").foregroundStyle(.secondary) }
                    TableColumn("Podsieć") { Text($0.status?.ipv4Subnet ?? "—").foregroundStyle(.secondary) }
                    TableColumn("Brama") { Text($0.status?.ipv4Gateway ?? "—").foregroundStyle(.secondary) }
                }
                .contextMenu(forSelectionType: NetworkInfo.ID.self) { ids in
                    if let id = ids.first, let network = store.items.first(where: { $0.id == id }) {
                        Button("Usuń…", role: .destructive) { confirmation = .remove(network) }
                            .disabled(network.name == "default")
                    }
                }
            }
        }
        .navigationTitle("Sieci")
        .task { await store.refresh() }
        .toolbar {
            ToolbarItemGroup {
                InfoTip(text: String(localized: "Kontenery w tej samej sieci widzą się nawzajem po nazwie. Domyślna sieć łączy wszystkie kontenery bez przypisanej sieci."), size: .regular)
                Button { showCreate = true } label: { Label("Utwórz", systemImage: "plus") }
                    .disabled(!model.system.serviceState.isRunning)
                Button { confirmation = .prune } label: { Label("Wyczyść", systemImage: "trash") }
                    .disabled(!model.system.serviceState.isRunning)
                Button { Task { await store.refresh() } } label: { Label("Odśwież", systemImage: "arrow.clockwise") }
            }
        }
        .sheet(isPresented: $showCreate) { NetworkCreateSheet().environment(model) }
        .confirmationDialog(
            confirmationTitle,
            isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }),
            presenting: confirmation
        ) { item in
            switch item {
            case .remove(let network):
                Button("Usuń", role: .destructive) {
                    Task { await perform { try await store.remove(network) } }
                }
                Button("Anuluj", role: .cancel) {}
            case .prune:
                Button("Usuń nieużywane", role: .destructive) {
                    Task { await perform { try await store.prune() } }
                }
                Button("Anuluj", role: .cancel) {}
            }
        } message: { item in
            switch item {
            case .remove(let network): Text("Sieć \(network.name) zostanie usunięta.")
            case .prune: Text("Usunięte zostaną wszystkie nieużywane sieci.")
            }
        }
    }

    private var confirmationTitle: String {
        switch confirmation {
        case .remove: String(localized: "Usunąć sieć?")
        case .prune: String(localized: "Usunąć nieużywane sieci?")
        case nil: ""
        }
    }

    private func perform(_ action: @escaping () async throws -> Void) async {
        do { try await action() }
        catch { model.present(error) }
    }
}

struct NetworkCreateSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var subnet = ""
    @State private var internalOnly = false
    @State private var isWorking = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "network")
                    .foregroundStyle(Color.teal.gradient)
                    .font(.title3)
                Text("Nowa sieć")
                    .font(.headline)
                Spacer()
            }
            .padding(12)
            Divider()
            // Form
            Form {
                Section {
                    TextField("Nazwa", text: $name)
                    TextField("Podsieć (np. 10.0.0.0/24 — opcjonalnie)", text: $subnet)
                    Toggle("Tylko sieć hosta (internal)", isOn: $internalOnly)
                } header: {
                    HStack(spacing: 5) {
                        Image(systemName: "network")
                            .foregroundStyle(Color.teal.gradient)
                        Text("Sieć")
                        InfoTip(text: String(localized: "Osobna sieć izoluje grupę kontenerów. Kontenery w tej samej sieci widzą się nawzajem po nazwie (lokalny DNS)."))
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            // Footer
            HStack {
                Spacer()
                Button("Anuluj") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    Task { await create() }
                } label: {
                    if isWorking { ProgressView().controlSize(.small) } else { Text("Utwórz") }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.glassProminent)
                .disabled(name.isEmpty || isWorking)
            }
            .padding(12)
        }
        .frame(width: 480)
    }

    private func create() async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await model.networks.create(name: name, subnet: subnet, internalOnly: internalOnly)
            dismiss()
        } catch {
            model.present(error)
        }
    }
}
