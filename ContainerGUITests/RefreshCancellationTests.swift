import XCTest
import os

/// A cancelled refresh is not a failed one: no error banner, last good data kept,
/// and a poll that arrives while a refresh runs does not start (or cancel) another.
@MainActor
final class RefreshCancellationTests: XCTestCase {
    /// Answers networks and volumes from a script that may throw any error.
    final class ScriptedRuntime: ContainerRuntime, @unchecked Sendable {
        let id: String
        let kind: RuntimeKind
        let sourceLabel: String?
        let capabilities: RuntimeCapabilities = .none
        let isInstalled = true
        let keepsLastListOnError = false
        let networkActions: NetworkActions = .none
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let networkScript: OSAllocatedUnfairLock<@Sendable () async throws -> [NetworkEntry]>
        let volumeScript: OSAllocatedUnfairLock<@Sendable () async throws -> [VolumeEntry]>

        init(id: String = "docker", kind: RuntimeKind = .docker, label: String? = nil,
             networks: @escaping @Sendable () async throws -> [NetworkEntry] = { [] },
             volumes: @escaping @Sendable () async throws -> [VolumeEntry] = { [] }) {
            self.id = id; self.kind = kind; self.sourceLabel = label
            self.networkScript = OSAllocatedUnfairLock(initialState: networks)
            self.volumeScript = OSAllocatedUnfairLock(initialState: volumes)
        }

        func listNetworks() async throws -> [NetworkEntry] {
            calls.withLock { $0 += 1 }
            return try await networkScript.withLock { $0 }()
        }
        func listVolumes() async throws -> [VolumeEntry] {
            calls.withLock { $0 += 1 }
            return try await volumeScript.withLock { $0 }()
        }

        func list(includeStopped: Bool) async throws -> [ContainerInfo] { [] }
        func inspect(_ reference: String) async throws -> String { "" }
        func start(_ reference: String) async throws {}
        func stop(_ reference: String) async throws {}
        func kill(_ reference: String) async throws {}
        func restart(_ reference: String, wasRunning: Bool) async throws {}
        func remove(_ reference: String, force: Bool) async throws {}
        func logs(_ reference: String, tail: LogTailLimit) -> AsyncThrowingStream<String, Error> { AsyncThrowingStream { $0.finish() } }
        func writeFullLog(_ reference: String, to path: String) async throws {}
        func stats(references: [String]?) async throws -> [StatsSample] { [] }
        func listFiles(_ reference: String, path: String) async throws -> [FileEntry] { [] }
        func copyIn(_ reference: String, localPath: String, destination: String) async throws {}
        func copyOut(_ reference: String, source: String, localPath: String) async throws {}
        func export(_ reference: String, to url: URL) async throws {}
        func terminalTarget(_ reference: String) -> TerminalTarget { .container(id: reference) }
    }

    /// A runtime whose `list` is scripted.
    final class ScriptedListRuntime: ContainerRuntime, @unchecked Sendable {
        let base: ScriptedRuntime
        let listScript: OSAllocatedUnfairLock<@Sendable () async throws -> [ContainerInfo]>
        var id: String { base.id }
        var kind: RuntimeKind { base.kind }
        var sourceLabel: String? { base.sourceLabel }
        var capabilities: RuntimeCapabilities { .none }
        var isInstalled: Bool { true }
        var keepsLastListOnError: Bool { false }
        let calls = OSAllocatedUnfairLock(initialState: 0)

        init(id: String, kind: RuntimeKind, label: String?, list: @escaping @Sendable () async throws -> [ContainerInfo]) {
            base = ScriptedRuntime(id: id, kind: kind, label: label)
            listScript = OSAllocatedUnfairLock(initialState: list)
        }
        func list(includeStopped: Bool) async throws -> [ContainerInfo] {
            calls.withLock { $0 += 1 }
            return try await listScript.withLock { $0 }()
        }
        func inspect(_ reference: String) async throws -> String { "" }
        func start(_ reference: String) async throws {}
        func stop(_ reference: String) async throws {}
        func kill(_ reference: String) async throws {}
        func restart(_ reference: String, wasRunning: Bool) async throws {}
        func remove(_ reference: String, force: Bool) async throws {}
        func logs(_ reference: String, tail: LogTailLimit) -> AsyncThrowingStream<String, Error> { AsyncThrowingStream { $0.finish() } }
        func writeFullLog(_ reference: String, to path: String) async throws {}
        func stats(references: [String]?) async throws -> [StatsSample] { [] }
        func listFiles(_ reference: String, path: String) async throws -> [FileEntry] { [] }
        func copyIn(_ reference: String, localPath: String, destination: String) async throws {}
        func copyOut(_ reference: String, source: String, localPath: String) async throws {}
        func export(_ reference: String, to url: URL) async throws {}
        func terminalTarget(_ reference: String) -> TerminalTarget { .container(id: reference) }
    }

    private func sample(_ name: String) -> ContainerInfo {
        let configuration = ContainerInfo.Configuration(
            id: name, image: .init(reference: "img", descriptor: nil), creationDate: nil, labels: nil, resources: nil,
            platform: nil, initProcess: nil, publishedPorts: nil, mounts: nil, rosetta: nil, runtimeHandler: nil,
            readOnly: nil, ssh: nil, virtualization: nil, networks: nil, readonlyPaths: nil, maskedPaths: nil
        )
        return ContainerInfo(id: name, configuration: configuration, status: .init(state: "running", startedDate: nil, networks: nil), runtime: .docker, runtimeReference: name)
    }

    func testCancelledContainerListingRecordsNoRuntimeErrorAndKeepsTheList() async {
        let cancelNext = OSAllocatedUnfairLock(initialState: false)
        let docker = ScriptedListRuntime(id: "docker", kind: .docker, label: nil) { [sample = sample("web")] in
            if cancelNext.withLock({ $0 }) { throw CancellationError() }
            return [sample]
        }
        let store = ContainerStore(runtimes: [docker])
        await store.refresh()
        XCTAssertEqual(store.items.map(\.id), ["web"])

        cancelNext.withLock { $0 = true }
        await store.refresh()
        XCTAssertEqual(store.items.map(\.id), ["web"], "the last good list stays")
        XCTAssertTrue(store.runtimeErrors.isEmpty)
        XCTAssertNil(store.error)

        // A genuine failure is still recorded.
        let broken = ScriptedListRuntime(id: "docker", kind: .docker, label: nil) { throw CLIError.command(exitCode: 1, stderr: "daemon is down") }
        let other = ContainerStore(runtimes: [broken])
        await other.refresh()
        XCTAssertEqual(other.runtimeErrors.count, 1)
    }

    func testCancellingTheCallerDoesNotCancelAContainerRefresh() async {
        let docker = ScriptedListRuntime(id: "docker", kind: .docker, label: nil) { [sample = sample("web")] in
            try await Task.sleep(for: .milliseconds(150))
            return [sample]
        }
        let store = ContainerStore(runtimes: [docker])
        let caller = Task { await store.refresh() }
        try? await Task.sleep(for: .milliseconds(30))
        caller.cancel()
        await caller.value
        XCTAssertEqual(store.items.map(\.id), ["web"])
        XCTAssertTrue(store.runtimeErrors.isEmpty)

        // And a poll that arrives during a refresh waits for it.
        let polled = ScriptedListRuntime(id: "docker", kind: .docker, label: nil) { [sample = sample("web")] in
            try await Task.sleep(for: .milliseconds(150))
            return [sample]
        }
        let second = ContainerStore(runtimes: [polled])
        async let one: Void = second.refresh()
        try? await Task.sleep(for: .milliseconds(30))
        async let two: Void = second.refresh()
        _ = await (one, two)
        XCTAssertEqual(polled.calls.withLock { $0 }, 1)
    }

    func testRecognisesCancellationInItsUsualDisguises() {
        XCTAssertTrue(RefreshCancellation.isCancellation(CancellationError()))
        XCTAssertTrue(RefreshCancellation.isCancellation(URLError(.cancelled)))
        XCTAssertTrue(RefreshCancellation.isCancellation(NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)))
        XCTAssertTrue(RefreshCancellation.isCancellation(
            CLIError.command(exitCode: -1, stderr: CancellationError().localizedDescription + " Swift.CancellationError")))
        XCTAssertFalse(RefreshCancellation.isCancellation(URLError(.timedOut)))
        XCTAssertFalse(RefreshCancellation.isCancellation(CLIError.command(exitCode: 1, stderr: "no such network")))
        XCTAssertFalse(RefreshCancellation.isCancellation(CLIError.timeout(seconds: 25, command: "docker")))
    }

    func testCancelledNetworkListingKeepsLastDataAndRecordsNoError() async {
        let cancelNext = OSAllocatedUnfairLock(initialState: false)
        let runtime = ScriptedRuntime(label: "Cloudlab Two", networks: {
            if cancelNext.withLock({ $0 }) { throw CancellationError() }
            return [net("bridge")]
        })
        let store = NetworkStore(runtimes: [runtime], wireGuard: .none)
        await store.refresh()
        XCTAssertEqual(store.items.map(\.name), ["bridge"])

        cancelNext.withLock { $0 = true }
        await store.refresh(force: true)
        XCTAssertEqual(store.items.map(\.name), ["bridge"], "the last good list stays, even for an engine that does not keep it on errors")
        XCTAssertTrue(store.failures.isEmpty)
        XCTAssertNil(store.error)
    }

    func testCancelledWireGuardScanRecordsNoError() async {
        let scanner = WireGuardScanner(local: { _ in throw CancellationError() }, remote: { _, _ in throw URLError(.cancelled) })
        let store = NetworkStore(runtimes: [ScriptedRuntime(networks: { [] })], wireGuard: scanner)
        await store.refresh(force: true)
        XCTAssertTrue(store.failures.isEmpty)
    }

    func testRealFailuresAreStillReported() async {
        let runtime = ScriptedRuntime(label: "studio", networks: { throw CLIError.command(exitCode: 1, stderr: "daemon is down") })
        let store = NetworkStore(runtimes: [runtime], wireGuard: .none)
        await store.refresh()
        XCTAssertEqual(store.failures.map(\.source), ["studio"])
    }

    func testCancelledVolumeListingKeepsLastDataAndRecordsNoError() async {
        let cancelNext = OSAllocatedUnfairLock(initialState: false)
        let runtime = ScriptedRuntime(label: "Mac Studio", volumes: {
            if cancelNext.withLock({ $0 }) { throw CancellationError() }
            return [vol("data")]
        })
        let store = VolumeStore(runtimes: [runtime])
        await store.refresh()
        XCTAssertEqual(store.items.map(\.name), ["data"])

        cancelNext.withLock { $0 = true }
        await store.refresh(force: true)
        XCTAssertEqual(store.items.map(\.name), ["data"])
        XCTAssertTrue(store.failures.isEmpty)
        XCTAssertNil(store.error)
    }

    /// The view that started the refresh going away (its `.task` is cancelled)
    /// must not turn the in-flight listing into a "CancellationError" banner.
    func testCancellingTheCallerDoesNotCancelTheRefresh() async {
        let runtime = ScriptedRuntime(label: "Docker", networks: {
            try await Task.sleep(for: .milliseconds(150))
            return [net("bridge")]
        })
        let store = NetworkStore(runtimes: [runtime], wireGuard: .none)
        let caller = Task { await store.refresh() }
        try? await Task.sleep(for: .milliseconds(30))
        caller.cancel()
        await caller.value
        XCTAssertEqual(store.items.map(\.name), ["bridge"])
        XCTAssertTrue(store.failures.isEmpty)
    }

    func testAPollDuringARefreshWaitsInsteadOfStartingAnother() async {
        let runtime = ScriptedRuntime(networks: {
            try await Task.sleep(for: .milliseconds(150))
            return [net("bridge")]
        })
        let store = NetworkStore(runtimes: [runtime], wireGuard: .none)
        async let first: Void = store.refresh()
        try? await Task.sleep(for: .milliseconds(30))
        async let second: Void = store.refresh()
        _ = await (first, second)
        XCTAssertEqual(runtime.calls.withLock { $0 }, 1)
        XCTAssertEqual(store.items.map(\.name), ["bridge"])
    }
}

private func net(_ name: String) -> NetworkEntry { NetworkEntry(id: name, reference: name, name: name, kind: .docker) }
private func vol(_ name: String) -> VolumeEntry { VolumeEntry(id: name, reference: name, name: name, kind: .docker) }
