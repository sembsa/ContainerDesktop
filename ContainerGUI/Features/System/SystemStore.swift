import Foundation
import Observation

/// Owns the state of the `container` background service and disk usage.
@MainActor @Observable
final class SystemStore {
    var serviceState: ServiceState = .unknown
    var diskUsage: DiskUsage?
    var properties: JSONValue?
    var dnsDomains: [String] = []
    var builderRunning = false
    var isBusy = false
    var lastActionError: CLIError?
    var transitionDetail: String?
    var systemLogs: String?
    var isLoadingLogs = false

    private let cli = ContainerCLI.shared
    private var epoch: UInt64 = 0

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
               let status = try? JSONDecoder().decode(SystemStatus.self, from: data) {
                return status.serviceState
            }
            return result.exitCode == 0 ? .running : .stopped
        } catch {
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
