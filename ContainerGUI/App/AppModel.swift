import SwiftUI
import Observation

@MainActor @Observable
final class AppModel {
    enum Section: String, CaseIterable, Identifiable {
        case containers, images, volumes, networks, registries, machines, system

        var id: String { rawValue }

        var title: String {
            switch self {
            case .containers: String(localized: "Kontenery")
            case .images: String(localized: "Obrazy")
            case .volumes: String(localized: "Wolumeny")
            case .networks: String(localized: "Sieci")
            case .registries: String(localized: "Rejestry")
            case .machines: String(localized: "Maszyny")
            case .system: String(localized: "System")
            }
        }

        var symbol: String {
            switch self {
            case .containers: "shippingbox"
            case .images: "square.stack.3d.up"
            case .volumes: "externaldrive"
            case .networks: "network"
            case .registries: "key"
            case .machines: "desktopcomputer"
            case .system: "gearshape"
            }
        }

        var tint: Color {
            switch self {
            case .containers: .blue
            case .images: .purple
            case .volumes: .orange
            case .networks: .teal
            case .registries: .pink
            case .machines: .indigo
            case .system: .gray
            }
        }
    }

    var selection: Section = .containers
    var binaryFound: Bool
    var globalError: PresentedError?

    let system = SystemStore()
    let containers = ContainerStore()
    let images = ImageStore()
    let volumes = VolumeStore()
    let networks = NetworkStore()
    let registries = RegistryStore()
    let machines = MachineStore()
    let compose = ComposeStore()

    private var pollTask: Task<Void, Never>?
    var pollInterval: TimeInterval = 3

    init() {
        binaryFound = BinaryResolver.resolve() != nil
    }

    func bootstrap() async {
        binaryFound = BinaryResolver.resolve() != nil
        guard binaryFound else { return }
        await system.refreshState()
        guard system.serviceState.isRunning else { return }
        // Prefetch primary sections so switching is instant.
        await containers.refresh()
        await images.refresh()
        await volumes.refresh()
        await networks.refresh()
    }

    func refreshCurrent() async {
        if system.serviceState == .unknown { await system.refreshState() }
        guard system.serviceState.isRunning else { return }
        switch selection {
        case .containers: await containers.refresh()
        case .images: await images.refresh()
        case .volumes: await volumes.refresh()
        case .networks: await networks.refresh()
        case .registries: await registries.refresh()
        case .machines: await machines.refresh()
        case .system:
            await system.refreshDiskUsage()
            await system.refreshBuilder()
        }
    }

    func startService() async {
        await system.start()
        if let error = system.lastActionError { present(error) }
        await refreshCurrent()
    }

    func stopService() async {
        await system.stop()
        if let error = system.lastActionError { present(error) }
        if !system.serviceState.isRunning { clearStores() }
    }

    private func clearStores() {
        containers.items = []
        containers.error = nil
        images.items = []
        images.error = nil
        volumes.items = []
        volumes.error = nil
        networks.items = []
        networks.error = nil
        registries.items = []
        registries.error = nil
        machines.items = []
        machines.error = nil
        system.diskUsage = nil
        system.builderRunning = false
    }

    func present(_ error: Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        globalError = PresentedError(message: message)
    }

    // MARK: - Polling

    func startPolling() {
        stopPolling()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if !self.system.serviceState.isTransitioning {
                    await self.system.refreshState()
                    await self.refreshCurrent()
                }
                try? await Task.sleep(for: .seconds(self.pollInterval))
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }
}

struct PresentedError: Identifiable {
    let id = UUID()
    let message: String
}
