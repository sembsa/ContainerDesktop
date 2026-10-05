import SwiftUI

struct VolumesView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: VolumeEntry.ID?
    @State private var activeSheet: VolumeSheet?
    @State private var confirmation: VolumeConfirmation?
    @State private var search = ""
    @AppStorage("volumeGrouping") private var grouping: ListGrouping = .machine
    @AppStorage("showBindMounts") private var showBindMounts = true
    @AppStorage("collapsedListGroups") private var collapsedGroups = ""

    private var store: VolumeStore { model.volumes }

    enum VolumeSheet: Identifiable {
        case create
        case browse(VolumeEntry)
        var id: String {
            switch self {
            case .create: "create"
            case .browse(let volume): "browse-\(volume.id)"
            }
        }
    }

    enum VolumeConfirmation: Identifiable {
        case remove(VolumeEntry)
        case prune
        var id: String {
            switch self {
            case .remove(let volume): "remove-\(volume.id)"
            case .prune: "prune"
            }
        }
    }

    /// Apple's service must be up to create or prune there; a local Docker
    /// engine can create without it.
    private var canCreate: Bool {
        model.system.serviceState.isRunning || model.containers.installedRuntimes.contains(.docker)
    }

    private var visible: [VolumeEntry] { store.filteredItems(showBindMounts: showBindMounts, search: search) }

    var body: some View {
        Group {
            if store.items.isEmpty, !store.isLoading {
                EmptyStateView(
                    symbol: "externaldrive",
                    title: String(localized: "Brak wolumenów"),
                    message: String(localized: "Utwórz wolumen, aby trwale przechowywać dane kontenerów."),
                    actionTitle: String(localized: "Utwórz wolumen…"),
                    action: { activeSheet = .create },
                    tint: .orange
                )
            } else if visible.isEmpty, !store.isLoading {
                EmptyStateView(
                    symbol: "magnifyingglass",
                    title: String(localized: "Brak wyników"),
                    message: String(localized: "Żaden wolumen nie pasuje do filtrów."),
                    tint: .secondary
                )
            } else {
                list
            }
        }
        .navigationTitle("Wolumeny")
        .searchable(text: $search, placement: .toolbar, prompt: Text("Szukaj wolumenów"))
        .safeAreaInset(edge: .bottom) { failureBanner }
        .task { await store.refresh(appleAvailable: model.system.serviceState.isRunning) }
        .toolbar {
            ToolbarItemGroup {
                sourcePicker
                GroupingPicker(selection: $grouping, options: ListGrouping.simple)
                Toggle(isOn: $showBindMounts) { Label("Montowania bind", systemImage: "folder") }
                    .toggleStyle(.button)
                    .help("Pokaż katalogi hosta montowane w kontenerach (bind mount)")
                InfoTip(text: String(localized: "Wolumen to trwały dysk dla kontenerów — dane przetrwają usunięcie i odtworzenie kontenera. Podłączasz go w dialogu uruchamiania w sekcji Wolumeny."), size: .regular)
                Button { activeSheet = .create } label: { Label("Utwórz", systemImage: "plus") }
                    .disabled(!canCreate)
                Button { confirmation = .prune } label: { Label("Wyczyść", systemImage: "trash") }
                    .disabled(!model.system.serviceState.isRunning)
                Button { Task { await store.refresh(appleAvailable: model.system.serviceState.isRunning, force: true) } } label: { Label("Odśwież", systemImage: "arrow.clockwise") }
            }
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .create: VolumeCreateSheet().environment(model)
            case .browse(let volume): VolumeFilesView(volume: volume).environment(model)
            }
        }
        .itemConfirmationDialog(
            Text(confirmationTitle),
            item: $confirmation
        ) { item in
            switch item {
            case .remove(let volume):
                Button("Usuń", role: .destructive) {
                    Task { await perform { try await store.remove(volume) } }
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
            case .remove(let volume): Text("Wolumen \(volume.name) zostanie usunięty.")
            case .prune: Text("Usunięte zostaną wszystkie nieużywane wolumeny.")
            }
        }
    }

    private var list: some View {
        List(selection: $selection) {
            if grouping.restricted(to: ListGrouping.simple) == .none {
                ForEach(visible) { volume in
                    VolumeRow(volume: volume).tag(volume.id)
                }
            } else {
                ForEach(ListGrouper.group(visible, by: grouping)) { section in
                    let collapseID = "volumes|" + section.id
                    let collapsed = CollapsedGroups.isCollapsed(collapseID, in: collapsedGroups)
                    Section {
                        if !collapsed {
                            ForEach(section.items) { volume in
                                VolumeRow(volume: volume).tag(volume.id)
                            }
                        }
                    } header: {
                        GroupHeader(title: section.title, count: section.count, isCollapsed: collapsed) {
                            collapsedGroups = CollapsedGroups.toggled(collapseID, in: collapsedGroups)
                        }
                    }
                }
            }
        }
        .contextMenu(forSelectionType: VolumeEntry.ID.self) { ids in
            if let id = ids.first, let volume = store.items.first(where: { $0.id == id }) {
                if volume.actions.contains(.browse), !volume.isBind {
                    Button("Przeglądaj zawartość…") { activeSheet = .browse(volume) }
                }
                if volume.actions.contains(.remove), !volume.isBind {
                    Divider()
                    Button("Usuń…", role: .destructive) { confirmation = .remove(volume) }
                }
            }
        }
    }

    /// Each picker is only offered when it has something to choose between,
    /// like the container list's.
    @ViewBuilder
    private var sourcePicker: some View {
        @Bindable var store = store
        if store.machineOptions.count > 1 {
            Picker("Maszyna", selection: $store.machineFilter) {
                Text("Wszystkie maszyny").tag(MachineFilter?.none)
                ForEach(store.machineOptions, id: \.self) { option in
                    Text(option.title).tag(Optional(option))
                }
            }
            .pickerStyle(.menu)
            .help("Pokaż wolumeny z jednej maszyny")
        }
        if store.engineOptions.count > 1 {
            Picker("Silnik", selection: $store.engineFilter) {
                Text("Wszystkie silniki").tag(ContainerEngine?.none)
                ForEach(store.engineOptions) { option in
                    Text(option.title).tag(Optional(option))
                }
            }
            .pickerStyle(.menu)
            .help("Pokaż wolumeny z jednego silnika")
        }
    }

    /// Sources that did not answer. They never block the rest of the list.
    @ViewBuilder
    private var failureBanner: some View {
        if !store.failures.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(store.failures) { failure in
                    Label {
                        Text(verbatim: "\(failure.source): \(failure.message)")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                    }
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)
        }
    }

    private var confirmationTitle: String {
        switch confirmation {
        case .remove: String(localized: "Usunąć wolumen?")
        case .prune: String(localized: "Usunąć nieużywane wolumeny?")
        case nil: ""
        }
    }

    private func perform(_ action: @escaping () async throws -> Void) async {
        do { try await action() }
        catch { model.present(error) }
    }
}

/// One volume: name, the three source tags, size and the containers using it.
struct VolumeRow: View {
    let volume: VolumeEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: volume.isBind ? "folder" : "externaldrive")
                    .foregroundStyle((volume.isBind ? Color.brown : Color.orange).gradient)
                Text(volume.name)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if volume.isBind {
                    SourceChip(text: String(localized: "bind"), tint: .brown)
                }
                VolumeBadge(volume: volume)
                Spacer()
                if let size = volume.sizeBytes {
                    Text(Format.bytes(size))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !volume.usedBy.isEmpty {
                    Text("Kontenery: \(volume.usedBy.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if !volume.isBind {
                    Text("nieużywany")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let line = detailLine {
                Text(line)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            if !volume.usedBy.isEmpty {
                Text(volume.usedBy.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 3)
    }

    /// `local · ext4 · /var/lib/docker/volumes/data/_data`
    private var detailLine: String? {
        var parts: [String] = []
        if !volume.isBind {
            if let driver = volume.driver { parts.append(driver) }
            if let format = volume.format { parts.append(format) }
            if let scope = volume.scope, scope != volume.driver { parts.append(scope) }
        }
        if !volume.isBind, let project = volume.composeProject { parts.append("compose: \(project)") }
        if !volume.isBind, let path = volume.path { parts.append(path) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

struct VolumeCreateSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var size = ""
    @State private var isWorking = false
    @State private var engine: RuntimeKind = .apple

    /// Engines on this Mac that can create a volume.
    private var engines: [RuntimeKind] {
        var list: [RuntimeKind] = []
        if model.system.serviceState.isRunning { list.append(.apple) }
        if model.containers.installedRuntimes.contains(.docker) { list.append(.docker) }
        return list
    }

    private var target: RuntimeKind { engines.contains(engine) ? engine : (engines.first ?? .apple) }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "externaldrive.fill")
                    .foregroundStyle(Color.orange.gradient)
                    .font(.title3)
                Text("Nowy wolumen")
                    .font(.headline)
                Spacer()
            }
            .padding(12)
            Divider()
            // Form
            Form {
                Section {
                    if engines.count > 1 {
                        Picker("Silnik", selection: $engine) {
                            ForEach(engines) { Text($0.badge).tag($0) }
                        }
                    }
                    TextField("Nazwa", text: $name)
                    if target == .apple {
                        HStack(spacing: 6) {
                            TextField("Rozmiar (np. 512M, 2G — opcjonalnie)", text: $size)
                            InfoTip(text: String(localized: "Rozmiar wolumenu: liczba z jednostką K/M/G/T, np. 512M albo 2G."))
                        }
                    }
                } header: {
                    HStack(spacing: 5) {
                        Image(systemName: "externaldrive.fill")
                            .foregroundStyle(Color.orange.gradient)
                        Text("Wolumen")
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
                .disabled(name.isEmpty || isWorking || engines.isEmpty)
            }
            .padding(12)
        }
        .frame(width: SheetWidth.narrow)
    }

    private func create() async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await model.volumes.create(name: name, size: size, on: target)
            dismiss()
        } catch {
            model.present(error)
        }
    }
}
