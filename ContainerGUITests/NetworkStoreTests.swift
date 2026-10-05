import XCTest
import os

/// The Networks store merging engines, machines and WireGuard — and a failing
/// source never blocking the rest.
@MainActor
final class NetworkStoreTests: XCTestCase {

    /// A runtime that answers `listNetworks` from a script and counts calls.
    final class FakeRuntime: ContainerRuntime, @unchecked Sendable {
        let id: String
        let kind: RuntimeKind
        let sourceLabel: String?
        let capabilities: RuntimeCapabilities = .none
        let isInstalled = true
        let keepsLastListOnError: Bool
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let behavior: OSAllocatedUnfairLock<Result<[NetworkEntry], CLIError>>
        let networkActions: NetworkActions

        init(id: String, kind: RuntimeKind, label: String? = nil, keepsLast: Bool = false,
             actions: NetworkActions = .none, result: Result<[NetworkEntry], CLIError>) {
            self.id = id; self.kind = kind; self.sourceLabel = label
            self.keepsLastListOnError = keepsLast
            self.networkActions = actions
            self.behavior = OSAllocatedUnfairLock(initialState: result)
        }

        func listNetworks() async throws -> [NetworkEntry] {
            calls.withLock { $0 += 1 }
            return try behavior.withLock { $0 }.get()
        }

        let removed = OSAllocatedUnfairLock<[String]>(initialState: [])
        func removeNetwork(_ reference: String) async throws { removed.withLock { $0.append(reference) } }

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

    func testMergesEnginesMachinesAndWireGuardWithTags() async throws {
        let studio = Make.endpoint("studio")
        let studioKey = ExternalMachineRuntime.runtimeKey(for: studio)
        let apple = FakeRuntime(id: "apple", kind: .apple, result: .success([Make.net("default", kind: .apple)]))
        let docker = FakeRuntime(id: "docker", kind: .docker, result: .success([Make.net("bridge")]))
        let remote = FakeRuntime(id: studioKey, kind: .docker, label: "studio", result: .success([
            Make.net("bridge").with(runtimeID: studioKey, machineLabel: "studio", engine: .colima),
        ]))
        let store = NetworkStore(
            runtimes: [apple, docker, remote], machines: [studio],
            wireGuard: WireGuardScanner(
                local: { _ in Make.scan(Make.wgInterface("utun0", address: "10.10.0.3/32")) },
                remote: { _, _ in Make.scan(Make.wgInterface("wg0", address: "10.10.0.1/24")) }
            )
        )
        await store.refresh()

        XCTAssertEqual(store.items.count, 5)
        let local = ContainerLocation.local.title, external = ContainerLocation.external.title
        let tags = store.items.map { $0.sourceTags.map(\.text) }
        XCTAssertEqual(tags, [
            [local, "Apple"], [local, "Docker"], [local, "WireGuard"],
            [external, "studio", "Colima"], [external, "studio", "WireGuard"],
        ])
        XCTAssertEqual(Set(store.items.map(\.id)).count, 5)
        XCTAssertEqual(store.machineOptions, [.local, .machine("studio")])
        XCTAssertEqual(store.runtimeOptions, [.engine(.apple), .engine(.docker), .engine(.colima), .wireGuard])
        XCTAssertEqual(store.localAppleItems.map(\.name), ["default"])
        XCTAssertTrue(store.failures.isEmpty)

        store.machineFilter = .machine("studio")
        XCTAssertEqual(store.filteredItems.count, 2)
        store.runtimeFilter = .wireGuard
        XCTAssertEqual(store.filteredItems.map(\.name), ["wg0"])
    }

    func testFailingRemoteDoesNotBlockTheListAndIsBackedOff() async throws {
        let hub = Make.endpoint("hub")
        let hubKey = ExternalMachineRuntime.runtimeKey(for: hub)
        let docker = FakeRuntime(id: "docker", kind: .docker, result: .success([Make.net("bridge")]))
        let remote = FakeRuntime(id: hubKey, kind: .docker, label: "hub",
                                 result: .failure(.command(exitCode: 255, stderr: "ssh: connect to host hub: Operation timed out")))
        let wgCalls = OSAllocatedUnfairLock(initialState: 0)
        let store = NetworkStore(
            runtimes: [docker, remote], machines: [hub],
            wireGuard: WireGuardScanner(
                local: { _ in Make.scan(nil) },
                remote: { _, _ in
                    wgCalls.withLock { $0 += 1 }
                    throw CLIError.command(exitCode: 255, stderr: "ssh: connect to host hub: Operation timed out")
                }
            )
        )
        await store.refresh()

        XCTAssertEqual(store.items.map(\.name), ["bridge"], "the reachable engine still lists")
        XCTAssertEqual(Set(store.failures.map(\.source)), ["hub", "hub · WireGuard"])
        XCTAssertNil(store.error, "a remote failure is not the primary (Apple) error")
        XCTAssertEqual(remote.calls.withLock { $0 }, 1)

        await store.refresh()
        XCTAssertEqual(remote.calls.withLock { $0 }, 1, "an unreachable machine is retried after the backoff, not every poll")
        XCTAssertEqual(wgCalls.withLock { $0 }, 1)
        XCTAssertEqual(store.items.map(\.name), ["bridge"])
        XCTAssertEqual(store.failures.count, 2)
    }

    func testRecoveryClearsTheFailure() async throws {
        let hub = Make.endpoint("hub")
        let hubKey = ExternalMachineRuntime.runtimeKey(for: hub)
        let remote = FakeRuntime(id: hubKey, kind: .docker, label: "hub", result: .failure(.command(exitCode: 1, stderr: "down")))
        let store = NetworkStore(runtimes: [remote], machines: [], wireGuard: .none)
        await store.refresh()
        XCTAssertEqual(store.failures.count, 1)

        remote.behavior.withLock { $0 = .success([Make.net("bridge").with(runtimeID: hubKey, machineLabel: "hub")]) }
        // Past the 20 s backoff the next refresh tries again; simulate by a fresh
        // store sharing the runtime (the backoff table is per store).
        let second = NetworkStore(runtimes: [remote], machines: [], wireGuard: .none)
        await second.refresh()
        XCTAssertTrue(second.failures.isEmpty)
        XCTAssertEqual(second.items.map(\.machineLabel), ["hub"])
    }

    func testAppleFailureSetsPrimaryErrorAndKeepsLastList() async throws {
        let apple = FakeRuntime(id: "apple", kind: .apple, keepsLast: true, result: .success([Make.net("default", kind: .apple)]))
        let store = NetworkStore(runtimes: [apple], wireGuard: .none)
        await store.refresh()
        XCTAssertEqual(store.items.count, 1)

        apple.behavior.withLock { $0 = .failure(.command(exitCode: 1, stderr: "xpc error")) }
        await store.refresh()
        XCTAssertNotNil(store.error)
        XCTAssertEqual(store.items.map(\.name), ["default"], "Apple keeps its last list across a hiccup")
    }

    func testAppleServiceDownStillListsDocker() async throws {
        let apple = FakeRuntime(id: "apple", kind: .apple, result: .success([Make.net("default", kind: .apple)]))
        let docker = FakeRuntime(id: "docker", kind: .docker, result: .success([Make.net("bridge")]))
        let store = NetworkStore(runtimes: [apple, docker], wireGuard: .none)
        await store.refresh(appleAvailable: false)
        XCTAssertEqual(store.items.map(\.name), ["bridge"])
        XCTAssertEqual(apple.calls.withLock { $0 }, 0)
    }

    func testDroppedMachineLeavesTheListImmediately() async throws {
        let hub = Make.endpoint("hub")
        let key = ExternalMachineRuntime.runtimeKey(for: hub)
        let remote = FakeRuntime(id: key, kind: .docker, label: "hub",
                                 result: .success([Make.net("bridge").with(runtimeID: key, machineLabel: "hub")]))
        let store = NetworkStore(runtimes: [], machines: [hub], wireGuard: .none)
        store.runtimeProvider = { [remote] in [remote] }
        await store.refresh()
        XCTAssertEqual(store.items.count, 1)

        store.runtimeProvider = { [] }
        store.machineProvider = { [] }
        await store.refresh()
        XCTAssertTrue(store.items.isEmpty)
    }

    func testRemoveIsGatedByActions() async throws {
        let docker = FakeRuntime(id: "docker", kind: .docker, actions: .docker, result: .success([Make.net("backend")]))
        let store = NetworkStore(runtimes: [docker], wireGuard: .none)
        await store.refresh()
        let backend = try XCTUnwrap(store.items.first)
        try await store.remove(backend)
        XCTAssertEqual(docker.removed.withLock { $0 }, ["backend"])

        // Built-ins and read-only sources are refused before any engine is asked.
        var builtIn = backend
        builtIn.isBuiltIn = true
        do { try await store.remove(builtIn); XCTFail("built-in network must not be removable") } catch {}
        let remote = backend.with(runtimeID: "machine:1", machineLabel: "studio")
        do { try await store.remove(remote); XCTFail("external network must not be removable") } catch {}
        XCTAssertEqual(docker.removed.withLock { $0 }, ["backend"])

        do { try await store.prune(); XCTFail("prune is Apple-only") } catch {}
    }

    func testWireGuardScanIsCachedBetweenPolls() async throws {
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let store = NetworkStore(runtimes: [], wireGuard: WireGuardScanner(
            local: { _ in calls.withLock { $0 += 1 }; return Make.scan(Make.wgInterface("utun0", address: "10.10.0.3/32")) },
            remote: { _, _ in Make.scan(nil) }
        ))
        await store.refresh()
        await store.refresh()
        XCTAssertEqual(calls.withLock { $0 }, 1, "each remote scan is an ssh login; polls within the TTL reuse the result")
        XCTAssertEqual(store.items.map(\.name), ["utun0"])
    }

    func testSudoIsNotRetriedAfterItFailed() async throws {
        let attempts = OSAllocatedUnfairLock<[Bool]>(initialState: [])
        let denied = WireGuardScan(status: .needsRoot, wgBinary: "/opt/homebrew/bin/wg", sudoAttempted: true, usedSudo: false, interfaces: [])
        let store = NetworkStore(runtimes: [], wireGuard: WireGuardScanner(
            local: { trySudo in attempts.withLock { $0.append(trySudo) }; return denied },
            remote: { _, _ in denied }
        ))
        await store.refresh()
        // Expire the result cache without touching the sudo memo.
        store.expireWireGuardCacheForTesting()
        await store.refresh()
        XCTAssertEqual(attempts.withLock { $0 }, [true, false], "sudo -n is attempted once, then left alone for a while")
    }

    func testManualRefreshBypassesTheSudoBackoffAndTheCache() async throws {
        let attempts = OSAllocatedUnfairLock<[Bool]>(initialState: [])
        let denied = WireGuardScan(status: .needsRoot, wgBinary: "/opt/homebrew/bin/wg", sudoAttempted: true, usedSudo: false, interfaces: [])
        let store = NetworkStore(runtimes: [], wireGuard: WireGuardScanner(
            local: { trySudo in attempts.withLock { $0.append(trySudo) }; return denied },
            remote: { _, _ in denied }
        ))
        await store.refresh()
        await store.refresh()   // inside the cache TTL: no scan at all
        await store.refresh(force: true)   // e.g. the user just added a sudoers rule
        XCTAssertEqual(attempts.withLock { $0 }, [true, true], "force re-scans immediately and tries sudo -n again")
        await store.refresh()
        XCTAssertEqual(attempts.withLock { $0 }.count, 2, "polling after a forced refresh stays within the cache")
    }

    func testManualRefreshRetriesAnUnreachableMachineAtOnce() async throws {
        let remote = FakeRuntime(id: "machine:hub", kind: .docker, label: "hub", result: .failure(.command(exitCode: 255, stderr: "down")))
        let store = NetworkStore(runtimes: [remote], wireGuard: .none)
        await store.refresh()
        await store.refresh()
        XCTAssertEqual(remote.calls.withLock { $0 }, 1)
        await store.refresh(force: true)
        XCTAssertEqual(remote.calls.withLock { $0 }, 2)
    }
}

/// Builders usable from `@Sendable` closures.
private enum Make {
    static func net(_ name: String, kind: NetworkEntry.Kind = .docker) -> NetworkEntry {
        NetworkEntry(id: name, reference: name, name: name, kind: kind)
    }

    static func endpoint(_ label: String) -> DockerEndpoint {
        var e = DockerEndpoint()
        e.label = label
        e.host = label
        return e
    }

    static func scan(_ interface: WireGuardInterface?) -> WireGuardScan {
        WireGuardScan(status: .ok, wgBinary: "/usr/bin/wg", sudoAttempted: false, usedSudo: false,
                      interfaces: interface.map { [$0] } ?? [])
    }

    static func wgInterface(_ name: String, address: String) -> WireGuardInterface {
        WireGuardInterface(name: name, listenPort: 51820, publicKey: "FAKE-PUBLIC-KEY-A=", addresses: [address],
                           subnets: [address], peers: [], source: .dump, peerDetailsNeedRoot: false)
    }
}
