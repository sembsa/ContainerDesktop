import SwiftUI
import AppKit

/// Where QEMU and the machines live, and the driver download every Windows
/// install shares.
struct VirtualMachinesSettings: View {
    @State private var cacheSize: Int64 = 0
    @State private var confirmClear = false
    @State private var clearError: String?

    private var qemuInstalled: Bool { FileManager.default.isExecutableFile(atPath: QEMULauncher.qemu) }
    private var vmFolderExists: Bool { FileManager.default.fileExists(atPath: VirtualMachineStore.directory.path) }
    /// An install in progress boots from the cached virtio-win ISO.
    private var installing: Bool { VirtualMachineStore.scan(VirtualMachineStore.directory).contains(where: \.installing) }

    var body: some View {
        Form {
            Section {
                LabeledContent("Ścieżka") {
                    HStack(spacing: 6) {
                        Image(systemName: qemuInstalled ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(qemuInstalled ? .green : .red)
                        Text(verbatim: QEMULauncher.qemu)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                if !qemuInstalled {
                    Text("Nie znaleziono QEMU. Zainstaluj je poleceniem brew install qemu.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            } header: {
                Text(verbatim: "QEMU")
            }

            Section("Folder maszyn") {
                LabeledContent("Ścieżka") {
                    Text(verbatim: VirtualMachineStore.directory.path)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Button("Pokaż w Finderze") {
                    NSWorkspace.shared.activateFileViewerSelecting([VirtualMachineStore.directory])
                }
                .buttonStyle(.glass)
                .disabled(!vmFolderExists)
            }

            Section {
                LabeledContent("Rozmiar") {
                    Text(Format.bytes(cacheSize))
                        .foregroundStyle(.secondary)
                }
                Button("Wyczyść") { confirmClear = true }
                    .buttonStyle(.glass)
                    .disabled(cacheSize == 0 || installing)
                if let clearError {
                    Text(verbatim: clearError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Pamięć podręczna sterowników")
            } footer: {
                (installing
                    ? Text("Nie można wyczyścić w trakcie instalacji Windows.")
                    : Text("Obraz sterowników virtio-win, pobierany raz i używany przy każdej instalacji Windows. Po wyczyszczeniu zostanie pobrany ponownie."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .settingsTab(height: 430)
        .onAppear { cacheSize = Self.size(of: WindowsInstaller.cacheDirectory) }
        .confirmationDialog("Wyczyścić pamięć podręczną sterowników?", isPresented: $confirmClear) {
            Button("Wyczyść", role: .destructive) { clearCache() }
            Button("Anuluj", role: .cancel) {}
        } message: {
            Text("Obraz sterowników virtio-win zostanie pobrany ponownie przy następnej instalacji Windows.")
        }
    }

    private func clearCache() {
        do {
            try FileManager.default.removeItem(at: WindowsInstaller.cacheDirectory)
            clearError = nil
        } catch {
            clearError = error.localizedDescription
        }
        cacheSize = Self.size(of: WindowsInstaller.cacheDirectory)
    }

    /// Bytes on disk under `url`; zero when it does not exist.
    private static func size(of url: URL) -> Int64 {
        let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey])
        var total: Int64 = 0
        while let file = files?.nextObject() as? URL {
            total += Int64((try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}
