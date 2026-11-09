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

    /// Sends a combination and gives the keyboard back to the screen, which the
    /// toolbar click took away.
    func send(_ combo: RFBKeys.Combo) {
        view.client?.sendCombo(combo.keysyms)
        view.window?.makeFirstResponder(view)
    }

    func setDesktopSize(width: Int, height: Int) {
        client?.setDesktopSize(width: width, height: height)
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

    @State private var hidesCursor = true
    @State private var busy: String?
    @State private var notice: String?
    @State private var failure: String?

    /// Live resize: per machine, off by default where the agent drives it,
    /// because the agent's coordinates assume the boot resolution.
    @State private var fitsWindow = false
    @State private var viewSize: CGSize = .zero
    @State private var resize: Task<Void, Never>?
    /// Windows only: nil until the display helper has been checked this session.
    @State private var helperReady: Bool?

    private var connected: Bool { session.status == .connected }

    var body: some View {
        RFBDisplay(view: session.view)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                viewSize = size
                scheduleFit()
            }
            .onChange(of: session.status) { if connected { scheduleFit() } }
            .overlay { overlay }
            .overlay(alignment: .top) { noticeBanner }
            .frame(minWidth: 640, minHeight: 400)
            .navigationTitle(vm?.name ?? String(localized: "Podgląd maszyny"))
            .navigationSubtitle(subtitle)
            .toolbar { toolbar }
            .alert("Nie udało się", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(failure ?? "") }
            .task { connect() }
            .onDisappear { session.disconnect() }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button { session.send(.ctrlAltDelete) } label: { Label("Ctrl+Alt+Del", systemImage: "lock.shield") }
                .iconHelp(String(localized: "Wyślij Ctrl+Alt+Del — ekran logowania, blokada, menedżer zadań"))
                .disabled(!connected)
            Button { session.send(.windows) } label: { Label("Klawisz Windows", systemImage: "square.grid.2x2") }
                .iconHelp(String(localized: "Klawisz Windows (menu Start)"))
                .disabled(!connected)
            Menu {
                Button("Uruchom… (Win+R)") { session.send(.run) }
                Button("Przełącz okna (Alt+Tab)") { session.send(.altTab) }
                Button("Zamknij okno (Alt+F4)") { session.send(.altF4) }
                Button("Menedżer zadań (Ctrl+Shift+Esc)") { session.send(.taskManager) }
                Button("Escape") { session.send(.escape) }
            } label: { Label("Skróty klawiszowe", systemImage: "keyboard") }
                .iconHelp(String(localized: "Skróty, których nie da się wysłać z klawiatury Maca"))
                .disabled(!connected)
        }

        ToolbarItemGroup {
            Button {
                hidesCursor.toggle()
                session.view.hidesLocalCursor = hidesCursor
            } label: {
                Label("Kursor macOS", systemImage: hidesCursor ? "cursorarrow.slash" : "cursorarrow")
            }
            .iconHelp(hidesCursor
                ? String(localized: "Pokaż kursor macOS nad obrazem")
                : String(localized: "Ukryj kursor macOS — zostaje tylko kursor systemu w maszynie"))
            .disabled(!connected)

            Button { setFitsWindow(!fitsWindow) } label: {
                Label("Dopasuj rozdzielczość do okna", systemImage: fitsWindow
                    ? "arrow.up.left.and.arrow.down.right.rectangle.fill"
                    : "arrow.up.left.and.arrow.down.right.rectangle")
            }
            .iconHelp(fitsWindow
                ? String(localized: "Przestań dopasowywać — wróć do stałej rozdzielczości 1280×800")
                : String(localized: "Dopasuj rozdzielczość maszyny do rozmiaru okna"))
            .disabled(!connected)

            Button { copyScreenshot() } label: { Label("Kopiuj zrzut ekranu", systemImage: "camera.viewfinder") }
                .iconHelp(String(localized: "Kopiuj zrzut ekranu maszyny do schowka"))
                .disabled(!connected)

            Menu {
                Button("Utwórz migawkę", systemImage: "camera") { perform(String(localized: "Zapisywanie migawki…"), notice: String(localized: "Migawka zapisana")) { vm in
                    try await VMEngine.createSnapshot(VMEngine.suggestedSnapshotTag(), of: vm)
                } }
                Divider()
                Button("Zatrzymaj", systemImage: "power") { perform(String(localized: "Zatrzymywanie…")) { vm in
                    try await VMEngine.stop(vm)
                } }
                Button("Wymuś zatrzymanie", systemImage: "xmark.octagon", role: .destructive) { perform(nil) { vm in
                    try await VMEngine.forceStop(vm)
                } }
            } label: { Label("Zasilanie", systemImage: "power") }
                .iconHelp(String(localized: "Zasilanie i migawki"))
                .disabled(!connected || busy != nil)
        }
    }

    // MARK: - Live resize

    private var fitsWindowKey: String { "vmPreview.fitsWindow.\(vmID)" }

    private func setFitsWindow(_ on: Bool) {
        fitsWindow = on
        UserDefaults.standard.set(on, forKey: fitsWindowKey)
        if on {
            scheduleFit()
        } else {
            resize?.cancel()
            // Back to the machine's own setting, which is also what it boots with.
            let size = QEMULauncher.displaySize(vm?.resolution ?? "1280x800", screen: CGDisplayBounds(CGMainDisplayID()).size)
            Task { await resizeGuest(width: size.width, height: size.height) }
        }
        session.view.window?.makeFirstResponder(session.view)
    }

    /// Waits for the window to settle: every switch blanks the guest's screen for a moment.
    private func scheduleFit() {
        guard fitsWindow, connected, viewSize != .zero else { return }
        resize?.cancel()
        resize = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            let size = RFB.desktopSize(fitting: viewSize)
            await resizeGuest(width: size.width, height: size.height)
        }
    }

    /// QEMU passes `SetDesktopSize` to the guest; Linux follows it on its own,
    /// Windows needs the display helper told as well (`WindowsDisplayHelper`).
    private func resizeGuest(width: Int, height: Int) async {
        guard let vm, connected, CGSize(width: width, height: height) != session.screenSize else { return }
        session.setDesktopSize(width: width, height: height)
        // ramfb (Windows Setup) has a fixed size and no agent yet.
        guard vm.isWindows, vm.display == .virtioGPU, helperReady != false else { return }
        do {
            if helperReady == nil {
                try await WindowsDisplayHelper.ensureInstalled(on: vm.directory)
                helperReady = true
            }
            try await WindowsDisplayHelper.request(width: width, height: height, on: vm.directory)
        } catch {
            // Usually no guest agent; one notice, then the window stops asking.
            helperReady = false
            let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            show(String(format: String(localized: "Nie udało się dopasować rozdzielczości: %@"), reason))
        }
    }

    private func copyScreenshot() {
        guard let image = session.view.currentImage else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))])
        show(String(localized: "Zrzut ekranu skopiowany"))
    }

    /// Runs an engine action on this machine; `progress` shows while it runs.
    private func perform(_ progress: String?, notice done: String? = nil, _ action: @escaping (VirtualMachine) async throws -> Void) {
        guard let vm else { return }
        busy = progress
        Task {
            defer { busy = nil }
            do {
                try await action(vm)
                if let done { show(done) }
            } catch {
                failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func show(_ text: String) {
        notice = text
        Task {
            try? await Task.sleep(for: .seconds(2))
            if notice == text { notice = nil }
        }
    }

    @ViewBuilder private var noticeBanner: some View {
        if let text = busy ?? notice {
            HStack(spacing: 8) {
                if busy != nil { ProgressView().controlSize(.small) }
                Text(text).font(.callout)
            }
            .padding(.horizontal, Padding.card)
            .padding(.vertical, Padding.chip)
            .glassEffect(in: .capsule)
            .padding(.top, Padding.card)
            .transition(.opacity)
        }
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
                if machineStopped {
                    Button("Uruchom", systemImage: "play.fill") { startMachine() }
                        .buttonStyle(.glassProminent)
                        .disabled(busy != nil)
                } else {
                    Button("Połącz ponownie") { connect() }
                        .buttonStyle(.glassProminent)
                }
            }
            .frame(maxWidth: 360)
            .padding(Padding.card)
            .glassEffect(in: .rect(cornerRadius: Radius.panel))
        }
    }

    /// Read fresh: the machine may have been stopped from here or from the section.
    private var machineStopped: Bool {
        guard let vm else { return false }
        return !VirtualMachineStore.scan(VirtualMachineStore.directory).contains { $0.id == vm.id && $0.isRunning }
    }

    private func startMachine() {
        guard let vm else { return }
        busy = String(localized: "Uruchamianie…")
        Task {
            defer { busy = nil }
            do {
                // start returns once VNC is up; the port can change on every start.
                _ = try await VMEngine.start(vm)
                connect()
            } catch {
                failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
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
        fitsWindow = UserDefaults.standard.object(forKey: fitsWindowKey) as? Bool ?? !vm.agentControl
        session.connect(to: vm)
    }
}
