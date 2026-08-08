import Foundation
import Observation

/// Helm releases, repositories and chart search for one selected cluster.
///
/// Everything cluster-scoped goes through a `HelmCLI.ClusterTarget` built by
/// `KubeconfigManager`, so no command can reach the user's own kubectl context.
/// Repository and chart-metadata commands need no cluster and are available even
/// before one is selected.
@MainActor @Observable
final class HelmStore {
    var releases: [HelmRelease] = []
    var repositories: [HelmRepository] = []
    var searchResults: [HelmChart] = []
    var error: String?
    var isLoadingReleases = false
    var isSearching = false
    /// Release ids with an action in flight.
    var pendingIDs: Set<String> = []

    /// The cluster all release operations act on. Nil until one is picked.
    private(set) var target: HelmCLI.ClusterTarget?
    private(set) var targetCluster: String?

    private let helm = HelmCLI.shared

    var isHelmInstalled: Bool { HelmCLI.isInstalled }

    // MARK: - Target selection

    /// Points the store at a cluster, writing a fresh app-managed kubeconfig.
    func select(cluster: String) async {
        guard targetCluster != cluster || target == nil else { return }
        do {
            target = try await KubeconfigManager.target(for: cluster)
            targetCluster = cluster
            error = nil
            await refreshReleases()
        } catch {
            target = nil
            targetCluster = nil
            releases = []
            present(error)
        }
    }

    func clearTarget() {
        target = nil
        targetCluster = nil
        releases = []
    }

    // MARK: - Releases

    func refreshReleases() async {
        guard isHelmInstalled, let target else { return }
        // The 3s poll calls this too — only show the spinner on a cold load, or
        // it blinks forever in the cluster bar.
        if releases.isEmpty { isLoadingReleases = true }
        defer { isLoadingReleases = false }
        do {
            releases = try await helm.json(["list", "--all-namespaces"], on: target, as: [HelmRelease].self)
            error = nil
        } catch {
            releases = []
            present(error)
        }
    }

    func uninstall(_ release: HelmRelease) async throws {
        guard let target else { return }
        pendingIDs.insert(release.id)
        defer { pendingIDs.remove(release.id) }
        try await helm.run(
            ["uninstall", release.name, "--namespace", release.namespace],
            on: target
        )
        await refreshReleases()
    }

    func history(of release: HelmRelease) async throws -> [HelmRevision] {
        guard let target else { return [] }
        return try await helm.json(
            ["history", release.name, "--namespace", release.namespace],
            on: target,
            as: [HelmRevision].self
        )
    }

    func rollback(_ release: HelmRelease, to revision: Int) async throws {
        guard let target else { return }
        pendingIDs.insert(release.id)
        defer { pendingIDs.remove(release.id) }
        try await helm.run(
            ["rollback", release.name, String(revision), "--namespace", release.namespace, "--wait"],
            on: target
        )
        await refreshReleases()
    }

    /// Values the user supplied for a release (not the chart defaults).
    func userValues(of release: HelmRelease) async throws -> String {
        guard let target else { return "" }
        let output = try await helm.run(
            ["get", "values", release.name, "--namespace", release.namespace, "-o", "yaml"],
            on: target
        )
        // With no overrides helm prints the literal "null".
        return output == "null" ? "" : output
    }

    // MARK: - Repositories

    func refreshRepositories() async {
        guard isHelmInstalled else { return }
        do {
            repositories = try await helm.jsonRepo(["repo", "list"], as: [HelmRepository].self)
            error = nil
        } catch {
            // An empty repo list exits non-zero with "no repositories to show".
            if case CLIError.command(_, let stderr) = error,
               stderr.lowercased().contains("no repositories") {
                repositories = []
                self.error = nil
            } else {
                present(error)
            }
        }
    }

    func addRepository(name: String, url: String) async throws {
        try await helm.runRepo(["repo", "add", name, url, "--force-update"])
        await refreshRepositories()
    }

    func removeRepository(_ repository: HelmRepository) async throws {
        try await helm.runRepo(["repo", "remove", repository.name])
        await refreshRepositories()
    }

    func updateRepositories() async throws {
        try await helm.runRepo(["repo", "update"])
    }

    // MARK: - Charts

    func search(_ query: String) async {
        guard isHelmInstalled else { return }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            searchResults = []
            return
        }
        isSearching = true
        defer { isSearching = false }
        do {
            searchResults = try await helm.jsonRepo(
                ["search", "repo", trimmed],
                as: [HelmChart].self,
                timeout: .seconds(60)
            )
            error = nil
        } catch {
            // "No results found" is an ordinary outcome, not a failure.
            if case CLIError.command(_, let stderr) = error,
               stderr.lowercased().contains("no results") {
                searchResults = []
                self.error = nil
            } else {
                searchResults = []
                present(error)
            }
        }
    }

    /// All published versions of one chart, newest first.
    func versions(of chart: String) async -> [HelmChart] {
        (try? await helm.jsonRepo(
            ["search", "repo", chart, "--versions"],
            as: [HelmChart].self,
            timeout: .seconds(60)
        )) ?? []
    }

    /// The chart's default `values.yaml` — the basis for the values editor.
    func defaultValues(of chart: String, version: String?) async throws -> String {
        var args = ["show", "values", chart]
        if let version, !version.isEmpty { args.append(contentsOf: ["--version", version]) }
        return try await helm.runRepo(args)
    }

    // MARK: - Install / upgrade

    /// Renders the release without touching the cluster, so schema violations
    /// and template errors surface before anything is applied. helm validates
    /// against the chart's `values.schema.json` here and reports the offending
    /// path (e.g. `at '/replicaCount': got string, want number`).
    func dryRun(
        release: String,
        chart: String,
        version: String?,
        namespace: String,
        valuesFile: String?
    ) async throws -> String {
        guard let target else { throw CLIError.command(exitCode: -1, stderr: String(localized: "Nie wybrano klastra.")) }
        var args = ["install", release, chart, "--namespace", namespace, "--dry-run=server"]
        if let version, !version.isEmpty { args.append(contentsOf: ["--version", version]) }
        if let valuesFile { args.append(contentsOf: ["--values", valuesFile]) }
        return try await helm.run(args, on: target, timeout: .seconds(120))
    }

    nonisolated func installStream(
        release: String,
        chart: String,
        version: String?,
        namespace: String,
        valuesFile: String?,
        createNamespace: Bool,
        wait: Bool,
        upgrade: Bool,
        on target: HelmCLI.ClusterTarget
    ) -> AsyncThrowingStream<String, Error> {
        var args = upgrade
            ? ["upgrade", release, chart, "--install"]
            : ["install", release, chart]
        args.append(contentsOf: ["--namespace", namespace])
        if createNamespace { args.append("--create-namespace") }
        if let version, !version.isEmpty { args.append(contentsOf: ["--version", version]) }
        if let valuesFile { args.append(contentsOf: ["--values", valuesFile]) }
        if wait { args.append(contentsOf: ["--wait", "--timeout", "10m"]) }
        return HelmCLI.shared.stream(args, on: target)
    }

    // MARK: - Errors

    private func present(_ error: Error) {
        self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
