import SwiftUI

struct ImagesView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: ImageInfo.ID?
    @State private var activeSheet: ImageSheet?
    @State private var confirmation: ImageConfirmation?
    @State private var detailTarget: ImageInfo?

    private var store: ImageStore { model.images }

    enum ImageSheet: Identifiable {
        case pull, build, run(String)
        var id: String {
            switch self {
            case .pull: "pull"
            case .build: "build"
            case .run(let reference): "run-\(reference)"
            }
        }
    }

    enum ImageConfirmation: Identifiable {
        case remove(ImageInfo)
        case prune
        var id: String {
            switch self {
            case .remove(let image): "remove-\(image.id)"
            case .prune: "prune"
            }
        }
    }

    var body: some View {
        Group {
            if store.items.isEmpty, model.system.serviceState.isRunning {
                EmptyStateView(
                    symbol: "square.stack.3d.up",
                    title: String(localized: "Brak obrazów"),
                    message: String(localized: "Pobierz obraz z rejestru, aby zacząć."),
                    actionTitle: String(localized: "Pobierz obraz…"),
                    action: { activeSheet = .pull },
                    tint: .purple
                )
            } else {
                table
            }
        }
        .navigationTitle("Obrazy")
        .task { await store.refresh() }
        .toolbar { toolbarContent }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .pull: PullImageSheet().environment(model)
            case .build: BuildImageSheet().environment(model)
            case .run(let reference): RunContainerSheet(presetImage: reference).environment(model)
            }
        }
        .sheet(item: $detailTarget) { img in
            ImageDetailSheet(image: img).environment(model)
        }
        .confirmationDialog(
            confirmationTitle,
            isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }),
            presenting: confirmation
        ) { item in
            confirmationButtons(item)
        } message: { item in
            confirmationMessage(item)
        }
    }

    private var table: some View {
        Table(store.items, selection: $selection) {
            TableColumn("Repozytorium") { Text($0.repository).fontWeight(.medium) }
            TableColumn("Tag") { Text($0.tag).foregroundStyle(.secondary) }
            TableColumn("Digest") {
                Text($0.shortDigest)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            TableColumn("Rozmiar") { Text(Format.bytes($0.totalSize)) }
        }
        .contextMenu(forSelectionType: ImageInfo.ID.self) { ids in
            if let id = ids.first, let image = store.items.first(where: { $0.id == id }) {
                Button(String(localized: "Szczegóły obrazu…"), systemImage: "info.circle") { detailTarget = image }
                Divider()
                Button("Uruchom kontener…") { activeSheet = .run(image.reference) }
                Divider()
                Button("Usuń…", role: .destructive) { confirmation = .remove(image) }
            }
        } primaryAction: { ids in
            if let id = ids.first, let image = store.items.first(where: { $0.id == id }) {
                detailTarget = image
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
                InfoTip(text: String(localized: "Obraz to tylko-do-odczytu szablon z systemem plików i konfiguracją, z którego uruchamia się kontenery. Pobierz gotowy (pull) albo zbuduj własny z Dockerfile (build)."), size: .regular)
            Button { activeSheet = .pull } label: { Label("Pobierz", systemImage: "arrow.down.circle") }
                .disabled(!model.system.serviceState.isRunning)
            Button { activeSheet = .build } label: { Label("Zbuduj", systemImage: "hammer") }
                .disabled(!model.system.serviceState.isRunning)
            Button { confirmation = .prune } label: { Label("Wyczyść", systemImage: "trash") }
                .disabled(!model.system.serviceState.isRunning)
            Button { Task { await store.refresh() } } label: { Label("Odśwież", systemImage: "arrow.clockwise") }
        }
    }

    private var confirmationTitle: String {
        switch confirmation {
        case .remove: String(localized: "Usunąć obraz?")
        case .prune: String(localized: "Usunąć nieużywane obrazy?")
        case nil: ""
        }
    }

    @ViewBuilder
    private func confirmationButtons(_ item: ImageConfirmation) -> some View {
        switch item {
        case .remove(let image):
            Button("Usuń", role: .destructive) {
                Task { await perform { try await store.remove(image, force: true) } }
            }
            Button("Anuluj", role: .cancel) {}
        case .prune:
            Button("Usuń nieużywane", role: .destructive) {
                Task { await perform { try await store.prune() } }
            }
            Button("Anuluj", role: .cancel) {}
        }
    }

    @ViewBuilder
    private func confirmationMessage(_ item: ImageConfirmation) -> some View {
        switch item {
        case .remove(let image): Text("Obraz \(image.reference) zostanie usunięty.")
        case .prune: Text("Usunięte zostaną wszystkie nieużywane obrazy.")
        }
    }

    private func perform(_ action: @escaping () async throws -> Void) async {
        do { try await action() }
        catch { model.present(error) }
    }
}
