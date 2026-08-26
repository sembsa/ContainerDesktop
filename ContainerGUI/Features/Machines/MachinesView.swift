import SwiftUI

struct MachinesView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: MachineInfo.ID?
    @State private var showCreate = false
    @State private var pendingDelete: MachineInfo?

    private var store: MachineStore { model.machines }

    private var selectedMachine: MachineInfo? {
        guard let selection else { return nil }
        return store.items.first { $0.id == selection }
    }

    var body: some View {
        Group {
            if store.items.isEmpty, model.system.serviceState.isRunning {
                EmptyStateView(
                    symbol: "desktopcomputer",
                    title: String(localized: "Brak maszyn"),
                    message: String(localized: "Maszyna to trwała, lekka maszyna wirtualna Linux — w odróżnieniu od kontenera nie znika po zakończeniu procesu. Możesz otworzyć w niej shell, przejrzeć jej logi, zmienić przydział CPU i pamięci oraz zamontować katalog domowy."),
                    actionTitle: String(localized: "Utwórz maszynę…"),
                    action: { showCreate = true },
                    tint: .indigo
                )
            } else {
                GeometryReader { geo in
                    VSplitView {
                        table
                            .frame(
                                minHeight: 130,
                                maxHeight: selectedMachine == nil ? .infinity : max(geo.size.height * 0.4, 130)
                            )
                        if let selected = selectedMachine {
                            MachineDetailView(machine: selected)
                                .frame(minHeight: 320, maxHeight: .infinity)
                        }
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

    private var table: some View {
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
                    if store.busyNames.contains(machine.name) {
                        ProgressView().controlSize(.small)
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
                if machine.isRunning {
                    Button("Zatrzymaj") {
                        Task { await perform { try await store.stop(machine) } }
                    }
                } else {
                    Button("Uruchom") {
                        Task { await perform { try await store.boot(machine) } }
                    }
                }
                Button("Ustaw jako domyślną") {
                    Task { await perform { try await store.setDefault(machine) } }
                }
                .disabled(machine.isDefault == true)
                Divider()
                Button("Usuń…", role: .destructive) { pendingDelete = machine }
            }
        }
    }

    private func perform(_ action: @escaping () async throws -> Void) async {
        do { try await action() }
        catch { model.present(error) }
    }
}

/// `container machine create` — the CLI takes a dozen flags here and the form
/// used to offer two of them.
///
/// Creation is streamed rather than awaited: it fetches and unpacks an image
/// before booting the VM, and reports `[1/3] Fetching image` style progress that
/// is worth showing instead of hiding behind a spinner with a timeout.
struct MachineCreateSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var options = MachineCommands.CreateOptions(image: "")
    @State private var isCreating = false
    @State private var finished = false
    @State private var output: [LogLine] = []

    var body: some View {
        VStack(spacing: 0) {
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

            Form {
                Section {
                    TextField("Obraz bazowy", text: $options.image, prompt: Text(verbatim: "alpine:3.22"))
                    TextField("Nazwa", text: $options.name)
                    Toggle("Ustaw jako domyślną", isOn: $options.setDefault)
                    Toggle("Nie uruchamiaj po utworzeniu", isOn: $options.noBoot)
                } header: {
                    HStack(spacing: 5) {
                        Image(systemName: "desktopcomputer")
                            .foregroundStyle(Color.indigo.gradient)
                        Text("Maszyna wirtualna")
                    }
                }

                Section {
                    TextField("Rdzenie", text: $options.cpus, prompt: Text(verbatim: "4"))
                    TextField("Pamięć", text: $options.memory, prompt: Text(verbatim: "8G"))
                    Picker("Katalog domowy", selection: $options.homeMount) {
                        ForEach(MachineCommands.HomeMount.allCases) { mount in
                            Text(mount.title).tag(mount)
                        }
                    }
                    Text("Puste pola zostawiają decyzję CLI — domyślnie to połowa pamięci systemu.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    HStack(spacing: 5) {
                        Image(systemName: "slider.horizontal.3")
                            .foregroundStyle(Color.teal.gradient)
                        Text("Zasoby")
                    }
                }

                Section {
                    TextField("Platforma", text: $options.platform, prompt: Text(verbatim: "linux/arm64"))
                    Toggle("Wirtualizacja zagnieżdżona", isOn: $options.nestedVirtualization)
                    Text("Wymaga Apple Silicon M3 lub nowszego, macOS 15+ oraz jądra z CONFIG_KVM=y.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("Własne jądro", text: $options.kernelPath, prompt: Text(verbatim: "/ścieżka/do/vmlinux"))
                } header: {
                    HStack(spacing: 5) {
                        Image(systemName: "cpu")
                            .foregroundStyle(Color.orange.gradient)
                        Text("Zaawansowane")
                    }
                }

                if !output.isEmpty {
                    Section {
                        StreamLogBox(lines: output)
                            .frame(minHeight: 140)
                    } header: {
                        HStack(spacing: 5) {
                            Image(systemName: "terminal.fill")
                                .foregroundStyle(Color.gray.gradient)
                            Text("Postęp")
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(isCreating)

            Divider()
            HStack {
                if isCreating {
                    Text("Pobieranie obrazu i uruchamianie maszyny wirtualnej.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(finished ? "Gotowe" : "Anuluj") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    Task { await create() }
                } label: {
                    if isCreating { ProgressView().controlSize(.small) } else { Text("Utwórz") }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.glassProminent)
                .disabled(options.image.isEmpty || isCreating)
            }
            .padding(12)
        }
        .frame(width: 640)
    }

    private func create() async {
        isCreating = true
        finished = false
        output = []
        defer { isCreating = false }

        do {
            for try await line in model.machines.createStream(options) {
                output.append(LogLine(text: line))
            }
            finished = true
        } catch {
            output.append(LogLine(text: String(format: String(localized: "[błąd: %@]"), error.localizedDescription)))
        }
        await model.machines.refresh()
    }
}
