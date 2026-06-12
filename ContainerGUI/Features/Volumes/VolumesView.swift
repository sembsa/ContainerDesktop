import SwiftUI

struct VolumesView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: VolumeInfo.ID?
    @State private var activeSheet: VolumeSheet?
    @State private var confirmation: VolumeConfirmation?

    private var store: VolumeStore { model.volumes }

    enum VolumeSheet: Identifiable {
        case create
        case browse(VolumeInfo)
        var id: String {
            switch self {
            case .create: "create"
            case .browse(let volume): "browse-\(volume.id)"
            }
        }
    }

    enum VolumeConfirmation: Identifiable {
        case remove(VolumeInfo)
        case prune
        var id: String {
            switch self {
            case .remove(let volume): "remove-\(volume.id)"
            case .prune: "prune"
            }
        }
    }

    var body: some View {
        Group {
            if store.items.isEmpty, model.system.serviceState.isRunning {
                EmptyStateView(
                    symbol: "externaldrive",
                    title: String(localized: "Brak wolumenów"),
                    message: String(localized: "Utwórz wolumen, aby trwale przechowywać dane kontenerów."),
                    actionTitle: String(localized: "Utwórz wolumen…"),
                    action: { activeSheet = .create },
                    tint: .orange
                )
            } else {
                Table(store.items, selection: $selection) {
                    TableColumn("Nazwa") { Text($0.name).fontWeight(.medium) }
                    TableColumn("Format") { Text($0.configuration.format ?? "—").foregroundStyle(.secondary) }
                    TableColumn("Rozmiar") { Text(Format.bytes($0.configuration.sizeInBytes)) }
                    TableColumn("Źródło") { Text($0.configuration.source ?? "—").foregroundStyle(.secondary) }
                }
                .contextMenu(forSelectionType: VolumeInfo.ID.self) { ids in
                    if let id = ids.first, let volume = store.items.first(where: { $0.id == id }) {
                        Button("Przeglądaj zawartość…") { activeSheet = .browse(volume) }
                        Divider()
                        Button("Usuń…", role: .destructive) { confirmation = .remove(volume) }
                    }
                }
            }
        }
        .navigationTitle("Wolumeny")
        .task { await store.refresh() }
        .toolbar {
            ToolbarItemGroup {
                InfoTip(text: String(localized: "Wolumen to trwały dysk dla kontenerów — dane przetrwają usunięcie i odtworzenie kontenera. Podłączasz go w dialogu uruchamiania w sekcji Wolumeny."), size: .regular)
                Button { activeSheet = .create } label: { Label("Utwórz", systemImage: "plus") }
                    .disabled(!model.system.serviceState.isRunning)
                Button { confirmation = .prune } label: { Label("Wyczyść", systemImage: "trash") }
                    .disabled(!model.system.serviceState.isRunning)
                Button { Task { await store.refresh() } } label: { Label("Odśwież", systemImage: "arrow.clockwise") }
            }
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .create: VolumeCreateSheet().environment(model)
            case .browse(let volume): VolumeFilesView(volume: volume).environment(model)
            }
        }
        .confirmationDialog(
            confirmationTitle,
            isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }),
            presenting: confirmation
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

struct VolumeCreateSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var size = ""
    @State private var isWorking = false

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
                    TextField("Nazwa", text: $name)
                    HStack(spacing: 6) {
                        TextField("Rozmiar (np. 512M, 2G — opcjonalnie)", text: $size)
                        InfoTip(text: String(localized: "Rozmiar wolumenu: liczba z jednostką K/M/G/T, np. 512M albo 2G."))
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
            try await model.volumes.create(name: name, size: size)
            dismiss()
        } catch {
            model.present(error)
        }
    }
}
