import SwiftUI

/// One container's snapshots: take one, restore one, delete one.
///
/// Restoring goes through `RunContainerSheet(recreating:restoring:)`, which
/// shows the full configuration before anything is replaced and snapshots the
/// current state first — so every restore can itself be undone.
struct ContainerSnapshotsSheet: View {
    let container: ContainerInfo

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var stopFirst = true
    @State private var isWorking = false
    @State private var errorText: String?
    @State private var restoreReference: String?
    @State private var deleteTarget: ImageInfo?

    private var snapshots: [ImageInfo] {
        ContainerSnapshots.snapshots(for: container.id, in: model.images.items)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "camera.shutter.button")
                Text(String(format: String(localized: "Migawki: %@"), container.id)).font(.headline)
                Spacer()
            }
            .padding(12)
            Divider()

            Form {
                Section {
                    if container.isRunning {
                        Toggle("Zatrzymaj na czas migawki", isOn: $stopFirst)
                    }
                    Button("Zrób migawkę teraz", systemImage: "camera.fill") { Task { await take() } }
                        .disabled(isWorking)
                } footer: {
                    Text("Migawka zapisuje system plików kontenera — bez wolumenów, więc dane trzymane w wolumenie nie cofną się razem z nią. Kontener zapisany w biegu jest jak po wyrwaniu wtyczki: baza danych może mieć niedokończone zapisy.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Historia") {
                    if snapshots.isEmpty {
                        Text("Brak migawek.").foregroundStyle(.secondary)
                    }
                    ForEach(snapshots) { image in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(label(for: image))
                                Text(Format.bytes(image.totalSize))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Przywróć…") { restoreReference = image.reference }
                                .disabled(isWorking)
                            IconButton(
                                symbol: "trash", description: String(localized: "Usuń migawkę"), tint: .red
                            ) { deleteTarget = image }
                            .disabled(isWorking)
                        }
                    }
                }
            }
            .formStyle(.grouped)

            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
            }
            HStack {
                if isWorking { ProgressView().controlSize(.small) }
                Spacer()
                Button("Gotowe") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: SheetWidth.standard, height: 520)
        .task { await model.images.refresh() }
        .sheet(isPresented: Binding(
            get: { restoreReference != nil },
            set: { if !$0 { restoreReference = nil } }
        )) {
            if let restoreReference {
                RunContainerSheet(recreating: container, restoring: restoreReference)
                    .environment(model)
            }
        }
        .confirmationDialog(
            "Usunąć migawkę?",
            isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
            presenting: deleteTarget
        ) { image in
            Button("Usuń", role: .destructive) { Task { await delete(image) } }
        } message: { image in
            Text(label(for: image))
        }
    }

    private func label(for image: ImageInfo) -> String {
        ContainerSnapshots.date(of: image.reference)?.formatted(date: .abbreviated, time: .standard)
            ?? image.tag
    }

    private func take() async {
        await perform { try await model.containers.snapshot(container, stopFirst: stopFirst) }
    }

    private func delete(_ image: ImageInfo) async {
        await perform { try await model.images.remove(image) }
    }

    private func perform(_ action: () async throws -> Void) async {
        isWorking = true
        errorText = nil
        defer { isWorking = false }
        do {
            try await action()
            await model.images.refresh()
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
