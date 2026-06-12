import SwiftUI

/// Sheet that browses and copies files on a volume via a helper container.
struct VolumeFilesView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let volume: VolumeInfo

    private var store: VolumeStore { model.volumes }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "externaldrive")
                Text("Zawartość wolumenu: \(volume.name)").font(.headline)
                Spacer()
                Button("Zamknij") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            FileBrowser(
                list: { path in
                    try await store.listFiles(volume, path: path)
                },
                upload: { localURL, currentPath in
                    try await store.copyToVolume(
                        volume,
                        localPath: localURL.path,
                        destination: join(currentPath, localURL.lastPathComponent)
                    )
                },
                download: { entry, directory, currentPath in
                    try await store.copyFromVolume(
                        volume,
                        source: join(currentPath, entry.name),
                        localPath: directory.path
                    )
                },
                onError: { model.present($0) }
            )
        }
        .frame(width: 660, height: 540)
    }

    private func join(_ base: String, _ name: String) -> String {
        base == "/" ? "/\(name)" : "\(base)/\(name)"
    }
}
