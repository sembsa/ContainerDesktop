import SwiftUI

/// One live VNC session, owned for as long as its preview window is open.
@MainActor @Observable
final class VMPreviewSession {
    enum Status: Equatable {
        case connecting
        case connected
        case disconnected(String?)
    }

    private(set) var status: Status = .connecting
    private(set) var screenSize: CGSize = .zero
    let view = RFBDisplayView()
    private var client: RFBClient?
    private var events: Task<Void, Never>?

    func connect(to vm: VirtualMachine) {
        disconnect()
        status = .connecting
        let client = RFBClient(port: vm.vncPort, password: vm.vncPassword)
        self.client = client
        view.client = client
        events = Task { [weak self] in
            await client.start()
            for await event in client.events {
                guard let self else { return }
                switch event {
                case .connected(let width, let height, _):
                    status = .connected
                    screenSize = CGSize(width: width, height: height)
                case .frame(let frame):
                    view.show(frame.image)
                case .disconnected(let reason):
                    status = .disconnected(reason)
                }
            }
        }
    }

    func unavailable(_ reason: String) {
        disconnect()
        status = .disconnected(reason)
    }

    func disconnect() {
        view.releaseEverything()
        events?.cancel()
        if let client { Task { await client.stop() } }
        client = nil
        view.client = nil
    }
}

/// The window behind "Podgląd": the machine's screen, live, and usable.
struct VMPreviewWindow: View {
    static let windowID = "vm-preview"
    let vmID: String
    @State private var session = VMPreviewSession()
    @State private var vm: VirtualMachine?

    var body: some View {
        RFBDisplay(view: session.view)
            .overlay { overlay }
            .frame(minWidth: 640, minHeight: 400)
            .navigationTitle(vm?.name ?? String(localized: "Podgląd maszyny"))
            .navigationSubtitle(subtitle)
            .task { connect() }
            .onDisappear { session.disconnect() }
    }

    private var subtitle: String {
        guard session.status == .connected, session.screenSize != .zero else { return "" }
        return "\(Int(session.screenSize.width))×\(Int(session.screenSize.height))"
    }

    @ViewBuilder private var overlay: some View {
        switch session.status {
        case .connected:
            EmptyView()
        case .connecting:
            ProgressView("Łączenie…")
                .padding(Padding.card)
                .glassEffect(in: .rect(cornerRadius: Radius.panel))
        case .disconnected(let reason):
            VStack(spacing: 10) {
                Image(systemName: "display.trianglebadge.exclamationmark")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("Rozłączono").font(.headline)
                if let reason { Text(reason).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center) }
                Button("Połącz ponownie") { connect() }
                    .buttonStyle(.glassProminent)
            }
            .frame(maxWidth: 360)
            .padding(Padding.card)
            .glassEffect(in: .rect(cornerRadius: Radius.panel))
        }
    }

    private func connect() {
        vm = VirtualMachineStore.scan(VirtualMachineStore.directory).first { $0.id == vmID }
        guard let vm else {
            session.unavailable(String(localized: "Nie znaleziono maszyny."))
            return
        }
        guard vm.isRunning else {
            session.unavailable(String(localized: "Maszyna nie jest uruchomiona."))
            return
        }
        session.connect(to: vm)
    }
}
