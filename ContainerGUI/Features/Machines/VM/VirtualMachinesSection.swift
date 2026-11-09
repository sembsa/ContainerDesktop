import SwiftUI

/// The QEMU machines, listed under the container machines with a way into each screen.
struct VirtualMachinesSection: View {
    let store: VirtualMachineStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Maszyny wirtualne")
                .font(.headline)
            ForEach(store.items) { vm in
                HStack(spacing: 10) {
                    Image(systemName: vm.isWindows ? "pc" : "desktopcomputer")
                        .foregroundStyle(.indigo)
                    Text(vm.name).fontWeight(.medium)
                    StatusDot(state: vm.isRunning ? "running" : "stopped")
                    Text(vm.isRunning ? "Uruchomiona" : "Zatrzymana")
                        .foregroundStyle(vm.isRunning ? Color.green : Color.secondary)
                    Spacer()
                    Button("Podgląd", systemImage: "play.display") {
                        openWindow(id: VMPreviewWindow.windowID, value: vm.id)
                    }
                    .buttonStyle(.glass)
                    .disabled(!vm.isRunning)
                }
            }
        }
        .padding(Padding.card)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }
}
