import Foundation
import Observation

/// Materializes a parsed `ComposeProject` as a group of running containers.
///
/// Creates the project network, then starts each service in dependency order
/// via `streamChecked`, surfacing progress lines and per-service status to the UI.
@MainActor @Observable
final class ComposeStore {
    enum ServicePhase: Equatable {
        case pending
        case creating
        case running
        /// One-off init task finished successfully (exit 0).
        case completed
        case failed(String)
    }

    struct ServiceStatus: Identifiable {
        let id: String // service name
        var phase: ServicePhase
    }

    var statuses: [ServiceStatus] = []
    var isRunning = false
    /// Progress stream for the UI (appended line by line).
    var logLines: [String] = []

    private let cli = ContainerCLI.shared

    /// Brings the project up: creates the `project.name` network (ignoring
    /// "already exists"), then launches services in `project.services` order.
    /// Each line of progress is appended to `logLines` prefixed with "[service] ".
    /// Returns `true` when every service started.
    ///
    /// When a target container name already exists and `replaceExisting == true`,
    /// it is removed (`rm --force`) before the service is started.
    @discardableResult
    func up(_ project: ComposeProject, replaceExisting: Bool) async -> Bool {
        statuses = project.services.map { ServiceStatus(id: $0.name, phase: .pending) }
        isRunning = true
        defer { isRunning = false }
        logLines = []

        // 1. Create the shared network. Ignore "already exists"; any other error aborts.
        do {
            _ = try await cli.run(["network", "create", project.name])
            appendLog(prefix: nil, line: String(format: String(localized: "utworzono sieć %@"), project.name))
        } catch let error as CLIError {
            if Self.isAlreadyExistsError(error) {
                appendLog(prefix: nil, line: String(format: String(localized: "sieć %@ już istnieje"), project.name))
            } else {
                let message = error.errorDescription ?? String(localized: "nieznany błąd sieci")
                appendLog(prefix: nil, line: String(format: String(localized: "nie udało się utworzyć sieci: %@"), message))
                for index in statuses.indices {
                    statuses[index].phase = .failed(
                        String(format: String(localized: "sieć %@ niedostępna"), project.name)
                    )
                }
                return false
            }
        } catch {
            appendLog(prefix: nil, line: String(format: String(localized: "nie udało się utworzyć sieci: %@"), error.localizedDescription))
            for index in statuses.indices {
                statuses[index].phase = .failed(
                    String(format: String(localized: "sieć %@ niedostępna"), project.name)
                )
            }
            return false
        }

        // Track services that failed so we can fail their (transitive) dependents.
        var failedServices: Set<String> = []
        var allSucceeded = true

        let initServices = project.services.filter { $0.isInit }
        let regularServices = project.services.filter { !$0.isInit }

        // 2. Run init tasks first, sequentially and blocking. They run the same
        // configuration as a regular service but attached (--detach=false) and
        // with --rm: the one-off container disappears once its work is done.
        for service in initServices {
            setPhase(.creating, for: service.name)
            let resolvedName = service.resolvedName(project: project.name)

            if replaceExisting {
                _ = try? await cli.run(["rm", "--force", resolvedName])
            }

            var config = makeConfiguration(for: service, project: project)
            config.removeOnExit = true
            let arguments = RunCommandBuilder.arguments(for: config, progress: "plain", detach: false)

            do {
                // End of stream without error == process exit 0 == success.
                for try await line in cli.streamChecked(arguments) {
                    appendLog(prefix: service.name, line: line)
                }
                setPhase(.completed, for: service.name)
            } catch {
                let message = (error as? CLIError)?.errorDescription ?? error.localizedDescription
                setPhase(.failed(message), for: service.name)
                appendLog(prefix: service.name, line: message)

                // An init task failed: abort everything that has not run yet.
                let abortMessage = String(
                    format: String(localized: "przerwano: zadanie init %@ nie powiodło się"),
                    service.name
                )
                for index in statuses.indices where statuses[index].phase != .completed
                    && statuses[index].id != service.name {
                    statuses[index].phase = .failed(abortMessage)
                }
                return false
            }
        }

        // 3. Run regular services in dependency order (detached).
        for service in regularServices {
            // If a dependency failed, mark this service failed without starting it.
            if let blocking = blockingDependency(for: service, among: regularServices, failed: failedServices) {
                let message = String(format: String(localized: "zależność %@ nie wystartowała"), blocking)
                setPhase(.failed(message), for: service.name)
                failedServices.insert(service.name)
                allSucceeded = false
                appendLog(prefix: service.name, line: message)
                continue
            }

            setPhase(.creating, for: service.name)
            let resolvedName = service.resolvedName(project: project.name)

            if replaceExisting {
                _ = try? await cli.run(["rm", "--force", resolvedName])
            }

            let config = makeConfiguration(for: service, project: project)
            let arguments = RunCommandBuilder.arguments(for: config, progress: "plain")

            do {
                for try await line in cli.streamChecked(arguments) {
                    appendLog(prefix: service.name, line: line)
                }
                setPhase(.running, for: service.name)
            } catch let error as CLIError {
                let message = error.errorDescription ?? String(localized: "nieznany błąd")
                setPhase(.failed(message), for: service.name)
                failedServices.insert(service.name)
                allSucceeded = false
                appendLog(prefix: service.name, line: message)
            } catch {
                let message = error.localizedDescription
                setPhase(.failed(message), for: service.name)
                failedServices.insert(service.name)
                allSucceeded = false
                appendLog(prefix: service.name, line: message)
            }
        }

        return allSucceeded
    }

    // MARK: - Configuration mapping

    private func makeConfiguration(for service: ComposeService, project: ComposeProject) -> RunConfiguration {
        var config = RunConfiguration()
        config.image = service.image
        config.name = service.resolvedName(project: project.name)
        config.command = service.command
        config.entrypoint = service.entrypoint
        config.workdir = service.workdir
        config.user = service.user
        config.network = project.name
        config.environment = service.environment.map {
            RunConfiguration.KeyValue(key: $0.key, value: $0.value)
        }
        config.ports = service.ports.compactMap(Self.parsePort)
        config.volumes = service.volumes.compactMap(Self.parseVolume)
        config.labels = [
            RunConfiguration.KeyValue(key: "compose.project", value: project.name),
            RunConfiguration.KeyValue(key: "compose.service", value: service.name),
        ]
        return config
    }

    /// Parses "host:container[/proto]" into a `PortMapping`.
    static func parsePort(_ spec: String) -> RunConfiguration.PortMapping? {
        var body = spec
        var proto = "tcp"
        if let slash = body.lastIndex(of: "/") {
            proto = String(body[body.index(after: slash)...])
            body = String(body[body.startIndex..<slash])
        }
        let parts = body.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        switch parts.count {
        case 2:
            guard !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
            return RunConfiguration.PortMapping(host: parts[0], container: parts[1], proto: proto)
        case 1:
            guard !parts[0].isEmpty else { return nil }
            return RunConfiguration.PortMapping(host: parts[0], container: parts[0], proto: proto)
        default:
            return nil
        }
    }

    /// Parses "src:dst[:ro]" into a `VolumeMount`.
    static func parseVolume(_ spec: String) -> RunConfiguration.VolumeMount? {
        let parts = spec.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        let readOnly = parts.count >= 3 && parts[2] == "ro"
        return RunConfiguration.VolumeMount(source: parts[0], destination: parts[1], readOnly: readOnly)
    }

    // MARK: - Dependency / status helpers

    /// Returns the name of a failed dependency (direct or transitive) of `service`,
    /// or `nil` if none of its dependencies failed.
    private func blockingDependency(
        for service: ComposeService,
        among services: [ComposeService],
        failed: Set<String>
    ) -> String? {
        let byName = Dictionary(uniqueKeysWithValues: services.map { ($0.name, $0) })
        var visited: Set<String> = []
        var stack = service.dependsOn
        while let dep = stack.popLast() {
            guard !visited.contains(dep) else { continue }
            visited.insert(dep)
            if failed.contains(dep) { return dep }
            if let depService = byName[dep] {
                stack.append(contentsOf: depService.dependsOn)
            }
        }
        return nil
    }

    private func setPhase(_ phase: ServicePhase, for name: String) {
        if let index = statuses.firstIndex(where: { $0.id == name }) {
            statuses[index].phase = phase
        }
    }

    private func appendLog(prefix: String?, line: String) {
        if let prefix {
            logLines.append("[\(prefix)] \(line)")
        } else {
            logLines.append(line)
        }
    }

    private static func isAlreadyExistsError(_ error: CLIError) -> Bool {
        guard case .command(_, let stderr) = error else { return false }
        let lower = stderr.lowercased()
        return lower.contains("exists") || lower.contains("already")
    }
}
