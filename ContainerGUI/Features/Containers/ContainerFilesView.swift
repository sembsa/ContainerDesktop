import SwiftUI

/// File browser for a running container (lists via `exec ls`, copies via `cp`).
struct ContainerFilesView: View {
    @Environment(AppModel.self) private var model
    let container: ContainerInfo

    private var store: ContainerStore { model.containers }

    var body: some View {
        FileBrowser(
            list: { path in
                try await store.listFiles(container, path: path)
            },
            upload: { localURL, currentPath in
                let destination = join(currentPath, localURL.lastPathComponent)
                try await store.copyToContainer(container, localPath: localURL.path, destination: destination)
            },
            download: { entry, directory, currentPath in
                try await store.copyFromContainer(
                    container,
                    source: join(currentPath, entry.name),
                    localPath: directory.path
                )
            },
            onError: { model.present($0) }
        )
        .id(container.id)
    }

    private func join(_ base: String, _ name: String) -> String {
        base == "/" ? "/\(name)" : "\(base)/\(name)"
    }
}
