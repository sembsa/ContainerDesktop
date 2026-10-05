import SwiftUI
import AppKit

/// "Maszyny zewnętrzne": Docker engines on other machines, reached over SSH.
/// Their containers appear in the main Containers list under a badge with the
/// entry's label.
struct ExternalMachinesView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: UUID?
    @State private var editing: DockerEndpoint?
    @State private var isAdding = false
    @State private var pendingRemoval: DockerEndpoint?

    private var store: ExternalMachineStore { model.externalMachines }

    var body: some View {
        Group {
            if store.machines.isEmpty {
                EmptyStateView(
                    symbol: "server.rack",
                    title: String(localized: "Brak maszyn zewnętrznych"),
                    message: String(localized: "Dodaj maszynę z silnikiem Docker (Docker Desktop, Colima lub zwykły Docker) dostępną przez SSH. Jej kontenery pojawią się na liście kontenerów z plakietką z nazwą maszyny."),
                    actionTitle: String(localized: "Dodaj maszynę…"),
                    action: { isAdding = true },
                    tint: .brown
                )
            } else {
                table
            }
        }
        .navigationTitle("Maszyny zewnętrzne")
        .task { await store.testAll() }
        .toolbar {
            ToolbarItemGroup {
                Button { isAdding = true } label: { Label("Dodaj", systemImage: "plus") }
                Button { Task { await store.testAll() } } label: { Label("Odśwież", systemImage: "arrow.clockwise") }
                    .disabled(store.machines.isEmpty)
            }
        }
        .sheet(isPresented: $isAdding) {
            ExternalMachineForm(original: nil).environment(model)
        }
        .sheet(item: $editing) { machine in
            ExternalMachineForm(original: machine).environment(model)
        }
        .confirmationDialog(
            "Usunąć maszynę zewnętrzną?",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            presenting: pendingRemoval
        ) { machine in
            Button("Usuń", role: .destructive) {
                store.remove(machine.id)
                pendingRemoval = nil
            }
            Button("Anuluj", role: .cancel) { pendingRemoval = nil }
        } message: { machine in
            Text(String(format: String(localized: "Maszyna „%@” zostanie usunięta z aplikacji. Kontenery na niej pozostaną nietknięte."), machine.label))
        }
    }

    private var table: some View {
        Table(store.machines, selection: $selection) {
            TableColumn("") { machine in
                StatusIndicator(status: store.status[machine.id] ?? .unknown, enabled: machine.enabled)
            }
            .width(20)

            TableColumn("Nazwa") { machine in
                Text(machine.label).fontWeight(.medium)
            }

            TableColumn("Host") { machine in
                Text(machine.sshUser.isEmpty ? machine.host : "\(machine.sshUser)@\(machine.host)")
                    .foregroundStyle(.secondary)
                    .help(machine.sshPort == DockerEndpoint.defaultSSHPort ? "" : "ssh -p \(machine.sshPort)")
            }

            TableColumn("Silnik") { machine in
                Text(store.detectedEngines[machine.id] ?? machine.engine.title)
                    .foregroundStyle(.secondary)
                    .help(machine.engine.title)
            }

            TableColumn("Stan") { machine in
                Text(statusText(for: machine))
                    .foregroundStyle(color(for: machine))
                    .lineLimit(2)
                    .help(statusText(for: machine))
            }

            TableColumn("Włączona") { machine in
                Toggle("", isOn: Binding(
                    get: { machine.enabled },
                    set: { store.setEnabled(machine.id, $0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            }
            .width(70)

            TableColumn("Akcje") { machine in
                HStack(spacing: 4) {
                    IconButton(symbol: "bolt.horizontal", description: String(localized: "Testuj połączenie")) {
                        Task { await store.test(machine.id) }
                    }
                    IconButton(symbol: "pencil", description: String(localized: "Edytuj")) { editing = machine }
                    IconButton(symbol: "trash", description: String(localized: "Usuń"), tint: .red) {
                        pendingRemoval = machine
                    }
                }
            }
            .width(110)
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            if let id = ids.first, let machine = store.machines.first(where: { $0.id == id }) {
                Button("Testuj połączenie") { Task { await store.test(id) } }
                Button("Edytuj…") { editing = machine }
                Divider()
                Button("Usuń…", role: .destructive) { pendingRemoval = machine }
            }
        }
    }

    private func statusText(for machine: DockerEndpoint) -> String {
        guard machine.enabled else { return String(localized: "wyłączona") }
        switch store.status[machine.id] ?? .unknown {
        case .unknown: return "—"
        case .checking: return String(localized: "sprawdzanie…")
        case .online: return String(localized: "online")
        case .offline(let reason): return String(format: String(localized: "offline: %@"), reason)
        }
    }

    private func color(for machine: DockerEndpoint) -> Color {
        guard machine.enabled else { return .secondary }
        switch store.status[machine.id] ?? .unknown {
        case .online: return .green
        case .offline: return .red
        default: return .secondary
        }
    }
}

private struct StatusIndicator: View {
    let status: ExternalMachineStore.Status
    let enabled: Bool

    var body: some View {
        if status == .checking {
            ProgressView().controlSize(.mini)
        } else {
            Circle().fill(color).frame(width: 9, height: 9)
        }
    }

    private var color: Color {
        guard enabled else { return .secondary }
        switch status {
        case .online: return .green
        case .offline: return .red
        default: return .secondary
        }
    }
}

// MARK: - Add / edit form

struct ExternalMachineForm: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    /// `nil` when adding.
    let original: DockerEndpoint?
    @State private var draft: DockerEndpoint
    @State private var showIssues = false
    @State private var testResult: ExternalMachineStore.Status?
    @State private var testedEngines: String?

    init(original: DockerEndpoint?) {
        self.original = original
        _draft = State(initialValue: original ?? DockerEndpoint())
    }

    private var store: ExternalMachineStore { model.externalMachines }
    private var issues: [DockerEndpoint.Issue] { store.validate(draft) }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Nazwa", text: $draft.label, prompt: Text("np. Serwer domowy"))
                    Picker("Silnik", selection: $draft.engine) {
                        ForEach(DockerEndpoint.Engine.allCases) { engine in
                            Text(engine.title).tag(engine)
                        }
                    }
                    TextField("Host", text: $draft.host, prompt: Text("host.example.com"))
                    TextField("Port SSH", value: $draft.sshPort, format: .number.grouping(.never))
                    TextField("Użytkownik SSH", text: $draft.sshUser, prompt: Text("opcjonalnie"))
                }
                Section {
                    HStack {
                        TextField("Plik klucza", text: optionalText($draft.identityFile), prompt: Text("opcjonalnie, np. ~/.ssh/id_ed25519"))
                        Button("Wybierz…") { chooseKey() }
                    }
                    TextField(
                        "Gniazdo na maszynie",
                        text: optionalText($draft.remoteSocketPath),
                        prompt: Text(draft.engine == .auto
                            ? String(localized: "opcjonalna dodatkowa ścieżka")
                            : draft.engine.defaultSocketPath)
                    )
                    Toggle("Włączona", isOn: $draft.enabled)
                } footer: {
                    Text("Aplikacja nie zapisuje haseł ani fraz kluczy. Połączenie używa agenta SSH lub niezaszyfrowanego klucza; nowe hosty są dodawane do known_hosts przy pierwszym połączeniu.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if showIssues, !issues.isEmpty {
                    Section {
                        ForEach(issues, id: \.self) { issue in
                            Label(issue.message, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .font(.callout)
                        }
                    }
                }
                if let testResult {
                    Section {
                        switch testResult {
                        case .checking: ProgressView().controlSize(.small)
                        case .online:
                            Label(
                                testedEngines.map { String(format: String(localized: "Połączenie działa. Wykryte silniki: %@"), $0) }
                                    ?? String(localized: "Połączenie działa."),
                                systemImage: "checkmark.circle.fill"
                            ).foregroundStyle(.green)
                        case .offline(let reason): Label(reason, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                        case .unknown: EmptyView()
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Button("Testuj połączenie") { Task { await runTest() } }
                    .disabled(!issues.filter { $0 != .duplicateLabel && $0 != .emptyLabel }.isEmpty || testResult == .checking)
                Spacer()
                Button("Anuluj", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(original == nil ? "Dodaj" : "Zapisz") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(showIssues && !issues.isEmpty)
            }
            .padding(12)
        }
        .frame(width: 520, height: 560)
    }

    private func save() {
        showIssues = true
        guard issues.isEmpty else { return }
        do {
            if original == nil {
                try store.add(draft)
            } else {
                try store.update(draft)
            }
            dismiss()
        } catch let error as ExternalMachineStore.ValidationError {
            _ = error
        } catch {
            model.present(error)
        }
    }

    private func runTest() async {
        showIssues = true
        testResult = .checking
        let outcome = await store.test(draft: draft)
        testedEngines = outcome.engines
        testResult = outcome.status
    }

    private func chooseKey() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh")
        if panel.runModal() == .OK, let url = panel.url { draft.identityFile = url.path }
    }

    /// `String?` field as a text field: empty means `nil`.
    private func optionalText(_ binding: Binding<String?>) -> Binding<String> {
        Binding(
            get: { binding.wrappedValue ?? "" },
            set: { binding.wrappedValue = $0.isEmpty ? nil : $0 }
        )
    }
}
