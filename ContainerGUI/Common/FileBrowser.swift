import SwiftUI
import AppKit

/// Reusable directory browser backed by injected list/upload/download closures.
/// Used both for containers (via `exec ls` + `cp`) and volumes (via an ephemeral
/// helper container + `cp`).
struct FileBrowser: View {
    let list: (_ path: String) async throws -> [FileEntry]
    let upload: (_ localURL: URL, _ currentPath: String) async throws -> Void
    let download: (_ entry: FileEntry, _ destinationDir: URL, _ currentPath: String) async throws -> Void
    let onError: (Error) -> Void

    @State private var path: String
    @State private var entries: [FileEntry] = []
    @State private var isLoading = false
    @State private var errorText: String?
    @State private var busyMessage: String?

    init(
        rootPath: String = "/",
        list: @escaping (_ path: String) async throws -> [FileEntry],
        upload: @escaping (_ localURL: URL, _ currentPath: String) async throws -> Void,
        download: @escaping (_ entry: FileEntry, _ destinationDir: URL, _ currentPath: String) async throws -> Void,
        onError: @escaping (Error) -> Void
    ) {
        _path = State(initialValue: rootPath)
        self.list = list
        self.upload = upload
        self.download = download
        self.onError = onError
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
        }
        .task { await load() }
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            Button { goUp() } label: { Image(systemName: "arrow.up") }
                .disabled(path == "/")
            TextField("Ścieżka", text: $path)
                .textFieldStyle(.roundedBorder)
                .onSubmit { Task { await load() } }
            InfoTip(text: String(localized: "Przeglądanie przez container exec ls — wymaga działającego kontenera. Kopiowanie plików: container cp w obie strony."))
            Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
            Button { performUpload() } label: { Label("Wyślij…", systemImage: "square.and.arrow.up") }
            if busyMessage != nil { ProgressView().controlSize(.small) }
        }
        .padding(8)
    }

    @ViewBuilder
    private var content: some View {
        if let errorText {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                Text(errorText).font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        } else {
            List {
                ForEach(entries) { entry in
                    HStack(spacing: 8) {
                        Image(systemName: entry.symbol)
                            .foregroundStyle(entry.isDirectory ? .blue : .secondary)
                        Text(entry.name)
                        Spacer()
                        if !entry.isDirectory, let size = entry.size {
                            Text(Format.bytes(size)).font(.caption).foregroundStyle(.secondary)
                        }
                        if !entry.isDirectory {
                            Button { performDownload(entry) } label: { Image(systemName: "square.and.arrow.down") }
                                .buttonStyle(.borderless)
                                .help("Pobierz na dysk")
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { if entry.isDirectory { enter(entry) } }
                }
            }
            .overlay {
                if isLoading { ProgressView() }
                else if entries.isEmpty { Text("Pusty katalog").foregroundStyle(.secondary) }
            }
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            entries = try await list(path)
            errorText = nil
        } catch {
            entries = []
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func enter(_ entry: FileEntry) {
        path = join(path, entry.name)
        Task { await load() }
    }

    private func goUp() {
        let components = path.split(separator: "/").dropLast()
        path = components.isEmpty ? "/" : "/" + components.joined(separator: "/")
        Task { await load() }
    }

    private func join(_ base: String, _ name: String) -> String {
        base == "/" ? "/\(name)" : "\(base)/\(name)"
    }

    private func performUpload() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "Wybierz plik lub folder do wysłania")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            busyMessage = String(localized: "Wysyłanie…")
            defer { busyMessage = nil }
            do {
                try await upload(url, path)
                await load()
            } catch {
                onError(error)
            }
        }
    }

    private func performDownload(_ entry: FileEntry) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = String(localized: "Wybierz folder docelowy")
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        Task {
            busyMessage = String(localized: "Pobieranie…")
            defer { busyMessage = nil }
            do {
                try await download(entry, directory, path)
            } catch {
                onError(error)
            }
        }
    }
}
