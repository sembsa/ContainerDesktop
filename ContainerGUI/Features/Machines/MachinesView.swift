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
                            // A table cell compresses flexible text, and a badge
                            // reading "domyś…" is worse than no badge. Widening the
                            // column alone did not help — the label itself has to
                            // refuse to shrink.
                            .fixedSize()
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.tint.opacity(0.2), in: Capsule())
                    }
                    if store.busyNames.contains(machine.name) {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .width(min: 200)
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

/// `container machine create`, with the template doing the typing.
///
/// The form used to open with two empty text fields; a base image is not
/// something anyone should have to remember, and the CLI was the first thing to
/// say a CPU count was wrong. Now a template fills the image in, proposes a name
/// that is not taken yet, and the fields complain while you type.
///
/// Creation is streamed rather than awaited: it fetches and unpacks an image
/// before booting the VM, and a template's own packages are installed after that
/// — the desktop one pulls about 260 MB, which nobody should watch behind a
/// spinner.
struct MachineCreateSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var template: MachineTemplate = MachineTemplate.all[0]
    @State private var options = MachineCommands.CreateOptions(image: "")
    @State private var isCreating = false
    @State private var failed = false
    @State private var output: [LogLine] = []
    @State private var didPrefill = false

    private var isShowingProgress: Bool { isCreating || failed }

    // MARK: - Validation

    private var cpusProblem: String? { MachineFieldValidation.cpus(options.cpus) }
    private var memoryProblem: String? { MachineFieldValidation.memory(options.memory) }
    private var kernelProblem: String? { MachineFieldValidation.kernelPath(options.kernelPath) }

    private var nameProblem: String? {
        guard !options.name.isEmpty else { return nil }
        guard !model.machines.items.contains(where: { $0.name == options.name }) else {
            return String(localized: "Maszyna o tej nazwie już istnieje.")
        }
        return nil
    }

    private var canCreate: Bool {
        !options.image.isEmpty && !isCreating
            && cpusProblem == nil && memoryProblem == nil
            && kernelProblem == nil && nameProblem == nil
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if isShowingProgress {
                progress
            } else {
                form
            }

            Divider()
            footer
        }
        .frame(width: 640, height: 580)
        .task {
            guard !didPrefill else { return }
            didPrefill = true
            apply(template)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "desktopcomputer")
                .foregroundStyle(Color.indigo.gradient)
                .font(.title3)
            Text("Nowa maszyna")
                .font(.headline)
            Spacer()
        }
        .padding(12)
    }

    // MARK: - Progress

    private var progress: some View {
        VStack(alignment: .leading, spacing: 8) {
            StreamLogBox(lines: output)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if failed {
                Text("Tworzenie maszyny nie udało się. Popraw dane i spróbuj ponownie.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(12)
    }

    // MARK: - Form

    private var form: some View {
        Form {
            Section {
                Picker("Szablon", selection: $template) {
                    ForEach(MachineTemplate.all) { candidate in
                        Text(candidate.title).tag(candidate)
                    }
                }
                .onChange(of: template) { _, new in apply(new) }
                Text(template.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                HStack(spacing: 5) {
                    Image(systemName: "square.grid.2x2")
                        .foregroundStyle(Color.indigo.gradient)
                    Text("Szablon")
                }
            }

            Section {
                TextField("Obraz bazowy", text: $options.image, prompt: Text(verbatim: "alpine:3.22"))
                TextField("Nazwa", text: $options.name)
                problem(nameProblem)
                Toggle("Ustaw jako domyślną", isOn: $options.setDefault)
                Toggle("Nie uruchamiaj po utworzeniu", isOn: $options.noBoot)
                    // A template's packages need the machine running to install.
                    .disabled(!template.packages.isEmpty)
            } header: {
                HStack(spacing: 5) {
                    Image(systemName: "desktopcomputer")
                        .foregroundStyle(Color.indigo.gradient)
                    Text("Maszyna wirtualna")
                }
            }

            Section {
                TextField("Rdzenie", text: $options.cpus, prompt: Text(verbatim: "4"))
                problem(cpusProblem)
                TextField("Pamięć", text: $options.memory, prompt: Text(verbatim: "8G"))
                problem(memoryProblem)
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
                problem(kernelProblem)
            } header: {
                HStack(spacing: 5) {
                    Image(systemName: "cpu")
                        .foregroundStyle(Color.orange.gradient)
                    Text("Zaawansowane")
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func problem(_ message: String?) -> some View {
        if let message {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if isCreating {
                Text("Pobieranie obrazu i uruchamianie maszyny wirtualnej.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(failed ? "Zamknij" : "Anuluj") { dismiss() }
                .keyboardShortcut(.cancelAction)
            if failed {
                Button("Wróć do formularza") {
                    failed = false
                    output = []
                }
            } else {
                Button {
                    Task { await create() }
                } label: {
                    if isCreating { ProgressView().controlSize(.small) } else { Text("Utwórz") }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.glassProminent)
                .disabled(!canCreate)
            }
        }
        .padding(12)
    }

    // MARK: - Actions

    /// Fills the form from a template, proposing a name that is not taken.
    private func apply(_ template: MachineTemplate) {
        options.image = template.image
        options.name = template.suggestedName.isEmpty ? "" : freeName(from: template.suggestedName)
        if !template.packages.isEmpty { options.noBoot = false }
    }

    private func freeName(from base: String) -> String {
        let taken = Set(model.machines.items.map(\.name))
        guard taken.contains(base) else { return base }
        for suffix in 2...99 where !taken.contains("\(base)-\(suffix)") {
            return "\(base)-\(suffix)"
        }
        return base
    }

    private func create() async {
        isCreating = true
        failed = false
        output = []
        defer { isCreating = false }

        let name = options.name
        let packages = template.packages
        var succeeded = false
        do {
            for try await line in model.machines.createStream(options) {
                output.append(LogLine(text: line))
            }
            succeeded = true
        } catch {
            output.append(LogLine(text: String(format: String(localized: "[błąd: %@]"), error.localizedDescription)))
            failed = true
        }

        // The template's own packages go on after the machine is up. A failure
        // here leaves a usable machine, so it is reported rather than treated as
        // a failed creation.
        if succeeded, !packages.isEmpty, !name.isEmpty {
            output.append(LogLine(text: String(localized: "Doinstalowywanie pakietów szablonu…")))
            do {
                for try await line in model.machines.provisionStream(packages: packages, on: name) {
                    output.append(LogLine(text: line))
                }
            } catch {
                output.append(LogLine(text: String(format: String(localized: "[błąd: %@]"), error.localizedDescription)))
                failed = true
                succeeded = false
            }
        }

        await model.machines.refresh()
        if succeeded { dismiss() }
    }
}
