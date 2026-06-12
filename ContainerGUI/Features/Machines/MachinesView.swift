import SwiftUI

struct MachinesView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: MachineInfo.ID?
    @State private var showCreate = false
    @State private var pendingDelete: MachineInfo?

    private var store: MachineStore { model.machines }

    var body: some View {
        Group {
            if store.items.isEmpty, model.system.serviceState.isRunning {
                EmptyStateView(
                    symbol: "desktopcomputer",
                    title: String(localized: "Brak maszyn"),
                    message: String(localized: "Maszyna to trwała, lekka maszyna wirtualna Linux — w odróżnieniu od kontenera nie znika po zakończeniu procesu. Możesz w niej uruchamiać polecenia (container machine run), montować katalog domowy i używać jej jak małego serwera deweloperskiego."),
                    actionTitle: String(localized: "Utwórz maszynę…"),
                    action: { showCreate = true },
                    tint: .indigo
                )
            } else {
                Table(store.items, selection: $selection) {
                    TableColumn("Nazwa") { machine in
                        HStack {
                            Text(machine.name).fontWeight(.medium)
                            if machine.isDefault == true {
                                Text("domyślna")
                                    .font(.caption2)
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(.tint.opacity(0.2), in: Capsule())
                            }
                        }
                    }
                    TableColumn("Stan") { machine in
                        HStack(spacing: 5) {
                            StatusDot(state: machine.status ?? "")
                            Text(machine.status ?? "—")
                                .foregroundStyle(machine.isRunning ? Color.green : Color.secondary)
                        }
                    }
                    TableColumn("CPU") { Text($0.cpus.map(String.init) ?? "—").foregroundStyle(.secondary) }
                    TableColumn("Pamięć") { Text(Format.bytes($0.memoryBytes)).foregroundStyle(.secondary) }
                    TableColumn("Dysk") { Text(Format.bytes($0.diskSizeBytes)).foregroundStyle(.secondary) }
                    TableColumn("IP") { Text($0.ipAddress ?? "—").foregroundStyle(.secondary) }
                    TableColumn("Utworzona") { machine in
                        Text(machine.createdDate?.formatted(date: .abbreviated, time: .shortened) ?? "—")
                            .foregroundStyle(.secondary)
                    }
                }
                .contextMenu(forSelectionType: MachineInfo.ID.self) { ids in
                    if let id = ids.first, let machine = store.items.first(where: { $0.id == id }) {
                        Button("Ustaw jako domyślną") {
                            Task { await perform { try await store.setDefault(machine) } }
                        }
                        if machine.isRunning {
                            Button("Zatrzymaj") {
                                Task { await perform { try await store.stop(machine) } }
                            }
                        }
                        Divider()
                        Button("Usuń…", role: .destructive) { pendingDelete = machine }
                    }
                }
            }
        }
        .navigationTitle("Maszyny")
        .task { await store.refresh() }
        .toolbar {
            ToolbarItemGroup {
                Button { showCreate = true } label: { Label("Utwórz", systemImage: "plus") }
                    .disabled(!model.system.serviceState.isRunning)
                Button { Task { await store.refresh() } } label: { Label("Odśwież", systemImage: "arrow.clockwise") }
            }
        }
        .sheet(isPresented: $showCreate) { MachineCreateSheet().environment(model) }
        .confirmationDialog(
            "Usunąć maszynę?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { machine in
            Button("Usuń", role: .destructive) {
                Task { await perform { try await store.delete(machine) } }
            }
            Button("Anuluj", role: .cancel) {}
        } message: { machine in
            Text("Maszyna \(machine.name) zostanie usunięta.")
        }
    }

    private func perform(_ action: @escaping () async throws -> Void) async {
        do { try await action() }
        catch { model.present(error) }
    }
}

struct MachineCreateSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var image = ""
    @State private var name = ""
    @State private var isWorking = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "desktopcomputer")
                    .foregroundStyle(Color.indigo.gradient)
                    .font(.title3)
                Text("Nowa maszyna")
                    .font(.headline)
                Spacer()
            }
            .padding(12)
            Divider()
            // Form
            Form {
                Section {
                    TextField("Obraz bazowy (np. alpine:3.22)", text: $image)
                    TextField("Nazwa", text: $name)
                    Text("Utworzenie maszyny pobierze obraz i uruchomi maszynę wirtualną — może to chwilę potrwać.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    HStack(spacing: 5) {
                        Image(systemName: "desktopcomputer")
                            .foregroundStyle(Color.indigo.gradient)
                        Text("Maszyna wirtualna")
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
                .disabled(image.isEmpty || name.isEmpty || isWorking)
            }
            .padding(12)
        }
        .frame(width: 480)
    }

    private func create() async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await model.machines.create(image: image, name: name)
            dismiss()
        } catch {
            model.present(error)
        }
    }
}
