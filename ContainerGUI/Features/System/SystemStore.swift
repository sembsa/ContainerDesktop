import Foundation
import Observation

/// Owns the state of the `container` background service and disk usage.
@MainActor @Observable
final class SystemStore {
    var serviceState: ServiceState = .unknown
    /// The full `system status` payload, kept so the System page can show what
    /// the CLI now reports (host, paths, counts) and so version skew is visible
    /// everywhere rather than only when the k8s plugin fails.
    var status: SystemStatus?
    var diskUsage: DiskUsage?
    var properties: JSONValue?
    var dnsDomains: [String] = []
    var builderRunning = false
    var isBusy = false
    var lastActionError: CLIError?
    var transitionDetail: String?
    var systemLogs: String?
    var isLoadingLogs = false
    /// Whether x86-64 images can run at all: `container` turns Rosetta on for
    /// every amd64 image on an arm64 host, flag or no flag.
    var rosetta: RosettaStatus.Availability = .notApplicable
    var isInstallingRosetta = false
    /// Whether launchd starts the service at login instead of the app starting
    /// it — the app starting it is what binds the service to the app's lifetime.
    var autostart: ServiceAutostart.State = .unavailable
    /// Containers launchd should bring up at login, and whether the agent that
    /// does it is installed. The list file on disk is the single source of
    /// truth — keeping a second copy in preferences would only drift.
    var containerAutostart: ContainerAutostart.State = .off
    var autostartContainerIDs: [String] = []

    private let cli = ContainerCLI.shared
    private var epoch: UInt64 = 0

    /// Set when the CLI and the background service are running different builds.
    var versionSkew: SystemStatus.VersionSkew? { status?.versionSkew }

    func refreshState() async {
        guard !serviceState.isTransitioning else { return }
        let captured = epoch
        let fetched = await fetchStatus()
        guard epoch == captured, !serviceState.isTransitioning else { return }
        serviceState = fetched
    }

    private func fetchStatus() async -> ServiceState {
        do {
            let result = try await cli.runRaw(["system", "status", "--format", "json"], timeout: .seconds(15))
            if let data = result.stdout.data(using: .utf8),
               let decoded = try? JSONDecoder().decode(SystemStatus.self, from: data) {
                status = decoded
                return decoded.serviceState
            }
            status = nil
            return result.exitCode == 0 ? .running : .stopped
        } catch {
            status = nil
            return .stopped
        }
    }

    func start() async {
        guard !serviceState.isTransitioning else { return }
        epoch &+= 1
        serviceState = .starting
        lastActionError = nil
        do { try await cli.run(["system", "start", "--enable-kernel-install"], timeout: .seconds(300)) }
        catch let error as CLIError { lastActionError = error }
        catch { lastActionError = .command(exitCode: -1, stderr: error.localizedDescription) }
        let verified = await fetchStatus()
        epoch &+= 1
        serviceState = verified
        if verified != .running, lastActionError == nil {
            lastActionError = .command(exitCode: 0, stderr: String(localized: "Usługa nie wystartowała mimo zakończenia polecenia. Sprawdź: container system logs"))
        }
    }

    func stop() async {
        guard !serviceState.isTransitioning else { return }
        epoch &+= 1
        serviceState = .stopping
        transitionDetail = String(localized: "zatrzymuję kontenery")
        lastActionError = nil
        do { try await cli.run(["system", "stop"], timeout: .seconds(90)) }
        catch let error as CLIError { lastActionError = error }
        catch { lastActionError = .command(exitCode: -1, stderr: error.localizedDescription) }
        let verified = await fetchStatus()
        epoch &+= 1
        transitionDetail = nil
        serviceState = verified
        if verified == .running, lastActionError == nil {
            lastActionError = .command(exitCode: 0, stderr: String(localized: "Usługa nadal działa po próbie zatrzymania. Spróbuj ponownie lub wykonaj 'container system stop' w Terminalu."))
        }
    }

    /// Stop, then start. This is the documented fix for a `.pkg` upgrade that
    /// replaced every binary on disk but left the old apiserver running.
    func restart() async {
        await stop()
        await start()
    }

    func refreshAutostart() {
        autostart = ServiceAutostart.current()
    }

    func setAutostart(_ enabled: Bool) {
        do {
            if enabled { try ServiceAutostart.enable() } else { try ServiceAutostart.disable() }
            lastActionError = nil
        } catch let error as CLIError {
            lastActionError = error
        } catch {
            lastActionError = .command(exitCode: -1, stderr: error.localizedDescription)
        }
        refreshAutostart()
    }

    func refreshContainerAutostart() {
        containerAutostart = ContainerAutostart.current()
        let text = (try? String(contentsOf: ContainerAutostart.listURL, encoding: .utf8)) ?? ""
        autostartContainerIDs = ContainerAutostart.parseList(text)
    }

    func setContainerAutostart(_ enabled: Bool) {
        do {
            if enabled {
                guard let binary = BinaryResolver.resolve() else { throw CLIError.notInstalled }
                try ContainerAutostart.enable(binary: binary)
            } else {
                try ContainerAutostart.disable()
            }
            lastActionError = nil
        } catch let error as CLIError {
            lastActionError = error
        } catch {
            lastActionError = .command(exitCode: -1, stderr: error.localizedDescription)
        }
        refreshContainerAutostart()
    }

    /// Replaces the selection, dropping ids that no longer exist.
    func setAutostartContainers(_ selected: Set<String>, existing: [String]) {
        do {
            try ContainerAutostart.writeList(
                ContainerAutostart.pruned(selected: selected, existing: existing)
            )
            lastActionError = nil
        } catch {
            lastActionError = .command(exitCode: -1, stderr: error.localizedDescription)
        }
        refreshContainerAutostart()
    }

    func toggleAutostart(for id: String, existing: [String]) {
        var selected = Set(autostartContainerIDs)
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
        setAutostartContainers(selected, existing: existing)
    }

    func refreshRosetta() {
        rosetta = RosettaStatus.current()
    }

    /// Runs Apple's installer with administrator privileges, then re-checks.
    func installRosetta() async {
        isInstallingRosetta = true
        defer { isInstallingRosetta = false }
        do {
            try await RosettaStatus.install()
            lastActionError = nil
        } catch let error as CLIError {
            lastActionError = error
        } catch {
            lastActionError = .command(exitCode: -1, stderr: error.localizedDescription)
        }
        refreshRosetta()
    }

    func refreshDiskUsage() async {
        diskUsage = try? await cli.json(["system", "df"], as: DiskUsage.self)
    }

    func refreshProperties() async {
        properties = try? await cli.json(["system", "property", "list"], as: JSONValue.self)
    }

    func refreshDNS() async {
        dnsDomains = (try? await cli.json(["system", "dns", "list"], as: [String].self)) ?? []
    }

    func refreshBuilder() async {
        let output = (try? await cli.run(["builder", "status"])) ?? ""
        let lower = output.lowercased()
        builderRunning = lower.contains("running") && !lower.contains("not running")
    }

    // MARK: - Builder controls

    func startBuilder() async {
        isBusy = true
        defer { isBusy = false }
        do { try await cli.run(["builder", "start"]); lastActionError = nil }
        catch let error as CLIError { lastActionError = error }
        catch { lastActionError = .command(exitCode: -1, stderr: error.localizedDescription) }
        await refreshBuilder()
    }

    func stopBuilder() async {
        isBusy = true
        defer { isBusy = false }
        _ = try? await cli.run(["builder", "stop"])
        await refreshBuilder()
    }

    func deleteBuilder() async {
        isBusy = true
        defer { isBusy = false }
        _ = try? await cli.run(["builder", "delete"])
        await refreshBuilder()
    }

    func refreshSystemLogs(last: String = "5m") async {
        isLoadingLogs = true
        defer { isLoadingLogs = false }
        systemLogs = (try? await cli.run(["system", "logs", "--last", last], timeout: .seconds(30))) ?? systemLogs
    }

    // MARK: - DNS (administrator-only mutations)

    func createDNS(_ domain: String) async throws {
        try await cli.runElevated(["system", "dns", "create", domain])
        await refreshDNS()
    }

    func deleteDNS(_ domain: String) async throws {
        try await cli.runElevated(["system", "dns", "delete", domain])
        await refreshDNS()
    }
}
