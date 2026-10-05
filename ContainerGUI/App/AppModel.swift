import SwiftUI
import Observation

@MainActor @Observable
final class AppModel {
    enum Section: String, CaseIterable, Identifiable {
        case containers, images, volumes, networks, kubernetes, workloads, helm, registries, machines, externalMachines, system

        var id: String { rawValue }

        var title: String {
            switch self {
            case .containers: String(localized: "Kontenery")
            case .images: String(localized: "Obrazy")
            case .volumes: String(localized: "Wolumeny")
            case .networks: String(localized: "Sieci")
            case .kubernetes: String(localized: "Kubernetes")
            case .workloads: String(localized: "Obciążenia")
            case .helm: String(localized: "Helm")
            case .registries: String(localized: "Rejestry")
            case .machines: String(localized: "Maszyny")
            case .externalMachines: String(localized: "Maszyny zewnętrzne")
            case .system: String(localized: "System")
            }
        }

        var symbol: String {
            switch self {
            case .containers: "shippingbox"
            case .images: "square.stack.3d.up"
            case .volumes: "externaldrive"
            case .networks: "network"
            case .kubernetes: "square.stack.3d.up.fill"
            case .workloads: "circle.grid.3x3"
            case .helm: "shippingbox.fill"
            case .registries: "key"
            case .machines: "desktopcomputer"
            case .externalMachines: "server.rack"
            case .system: "gearshape"
            }
        }

        var tint: Color {
            switch self {
            case .containers: .blue
            case .images: .purple
            case .volumes: .orange
            case .networks: .teal
            case .kubernetes: .cyan
            case .workloads: .green
            case .helm: .mint
            case .registries: .pink
            case .machines: .indigo
            case .externalMachines: .brown
            case .system: .gray
            }
        }
    }

    var selection: Section = .containers
    /// A container another section asked the Containers list to select (the
    /// topology's "Open in list"). `ContainersView` takes it and clears it.
    var pendingContainerFocus: String?
    var binaryFound: Bool
    var globalError: PresentedError?

    let system = SystemStore()
    let containers = ContainerStore()
    let images = ImageStore()
    let volumes = VolumeStore()
    let networks = NetworkStore()
    let registries = RegistryStore()
    let machines = MachineStore()
    /// Docker engines on other machines, reached over SSH. Its list feeds the
    /// container store's extra runtimes.
    let externalMachines = ExternalMachineStore()
    let kubernetes = K8sStore()
    let workloads = WorkloadStore()
    let helm = HelmStore()
    let compose = ComposeStore()

    private var pollTask: Task<Void, Never>?
    var pollInterval: TimeInterval = 3

    init() {
        binaryFound = BinaryResolver.resolve() != nil
        containers.setExternal(externalMachines.machines, refreshNow: false)
        networks.runtimeProvider = { [containers] in containers.allRuntimes }
        volumes.runtimeProvider = { [containers] in containers.allRuntimes }
        networks.machineProvider = { [containers] in containers.externalEndpoints }
        externalMachines.onChange = { [containers, networks] machines in
            containers.setExternal(machines)
            Task { await networks.refresh() }
        }
    }

    /// Switches to Containers and selects `container` there: the machine and
    /// engine filters are cleared so it is in the list, and the search is set to
    /// its name so it is the one in sight.
    func openInContainerList(_ container: ContainerInfo) {
        containers.machineFilter = nil
        containers.engineFilter = nil
        pendingContainerFocus = container.id
        selection = .containers
    }

    func bootstrap() async {
        binaryFound = BinaryResolver.resolve() != nil
        guard binaryFound else { return }
        system.refreshRosetta()
        system.refreshAutostart()
        system.refreshContainerAutostart()
        await system.refreshState()
        guard system.serviceState.isRunning else { return }
        // Prefetch primary sections so switching is instant.
        await containers.refresh()
        syncContainerAutostart()
        await images.refresh()
        await volumes.refresh()
        await networks.refresh()
    }

    /// Records what is running so the login agent can bring it back.
    ///
    /// Does nothing unless container autostart is on and set to follow what
    /// runs; `syncAutostartWithRunning` writes only when the set changed, so
    /// calling this on every tick costs a set comparison.
    private func syncContainerAutostart() {
        system.syncAutostartWithRunning(containers.autostartCandidates.filter(\.isRunning).map(\.id))
    }

    func refreshCurrent() async {
        if system.serviceState == .unknown { await system.refreshState() }
        guard system.serviceState.isRunning else {
            // Apple's service is down; Docker containers can still be listed.
            await containers.refresh(appleAvailable: false)
            if selection == .networks { await networks.refresh(appleAvailable: false) }
            if selection == .volumes { await volumes.refresh(appleAvailable: false) }
            containers.publishWidgetSnapshot(serviceRunning: false)
            return
        }
        defer { containers.publishWidgetSnapshot(serviceRunning: true) }

        // Containers refresh on every tick regardless of the visible section:
        // the menu-bar extra, the sidebar count and the desktop widget all read
        // this store. Without it a user parked on, say, Helm would publish an
        // hour-old snapshot stamped with the current time — which would make the
        // widget's "how fresh is this" label a lie.
        await containers.refresh()
        syncContainerAutostart()

        switch selection {
        case .containers: break // just refreshed
        case .images: await images.refresh()
        case .volumes: await volumes.refresh()
        case .networks: await networks.refresh()
        case .registries: await registries.refresh()
        case .machines: await machines.refresh()
        // Probed by the view itself (each probe opens an SSH connection).
        case .externalMachines: break
        case .kubernetes: await kubernetes.refresh()
        // Objects are read on demand: one kubectl process per kind, and a
        // cluster holds enough of them that a three-second tick across seven
        // kinds would keep a laptop busy for nothing.
        case .workloads: break
        case .helm: await helm.refreshReleases()
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

    /// Restarts the background service — the fix for the post-upgrade state where
    /// the CLI on disk is newer than the apiserver still running in memory.
    func restartService() async {
        await system.stop()
        if !system.serviceState.isRunning { clearStores() }
        await system.start()
        if let error = system.lastActionError { present(error) }
        await refreshCurrent()
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
        kubernetes.clusters = []
        kubernetes.error = nil
        workloads.clearAll()
        helm.clearTarget()
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
