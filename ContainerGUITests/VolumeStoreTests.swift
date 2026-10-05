import XCTest
import os

/// The Volumes store merging engines and machines — and a failing source never
/// blocking the rest.
@MainActor
final class VolumeStoreTests: XCTestCase {

    final class FakeRuntime: ContainerRuntime, @unchecked Sendable {
        let id: String
        let kind: RuntimeKind
        let sourceLabel: String?
        let capabilities: RuntimeCapabilities = .none
        let isInstalled = true
        let keepsLastListOnError: Bool
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let behavior: OSAllocatedUnfairLock<Result<[VolumeEntry], CLIError>>
        let volumeActions: VolumeActions
        let removed = OSAllocatedUnfairLock<[String]>(initialState: [])
        let pruned = OSAllocatedUnfairLock(initialState: 0)

        init(id: String, kind: RuntimeKind, label: String? = nil, keepsLast: Bool = false,
             actions: VolumeActions = .none, result: Result<[VolumeEntry], CLIError>) {
            self.id = id; self.kind = kind; self.sourceLabel = label
            self.keepsLastListOnError = keepsLast
            self.volumeActions = actions
            self.behavior = OSAllocatedUnfairLock(initialState: result)
        }

        func listVolumes() async throws -> [VolumeEntry] {
            calls.withLock { $0 += 1 }
            return try behavior.withLock { $0 }.get()
        }
        func removeVolume(_ reference: String) async throws { removed.withLock { $0.append(reference) } }
        func pruneVolumes() async throws { pruned.withLock { $0 += 1 } }

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

    private func vol(_ name: String, kind: VolumeEntry.Kind = .docker) -> VolumeEntry {
        VolumeEntry(id: name, reference: name, name: name, kind: kind)
    }

    func testMergesEnginesAndMachinesWithTags() async throws {
        let apple = FakeRuntime(id: "apple", kind: .apple, result: .success([vol("models", kind: .apple)]))
        let docker = FakeRuntime(id: "docker", kind: .docker, result: .success([vol("pgdata")]))
        let key = "machine:studio"
        let remote = FakeRuntime(id: key, kind: .docker, label: "studio", result: .success([
            vol("pgdata").with(runtimeID: key, machineLabel: "studio", engine: .colima),
            VolumeEntry(id: "bind:/srv/x", reference: "/srv/x", name: "/srv/x", kind: .docker, storage: .bind)
                .with(runtimeID: key, machineLabel: "studio", engine: .colima),
        ]))
        let store = VolumeStore(runtimes: [apple, docker, remote])
        await store.refresh()

        XCTAssertEqual(store.items.count, 4)
        let local = ContainerLocation.local.title, external = ContainerLocation.external.title
        XCTAssertEqual(store.items.map { $0.sourceTags.map(\.text) }, [
            [local, "Apple"], [local, "Docker"],
            [external, "studio", "Colima"], [external, "studio", "Colima"],
        ])
        XCTAssertEqual(store.items.map(\.name), ["models", "pgdata", "pgdata", "/srv/x"], "named volumes before bind mounts")
        XCTAssertEqual(Set(store.items.map(\.id)).count, 4)
        XCTAssertEqual(store.machineOptions, [.local, .machine("studio")])
        XCTAssertEqual(store.engineOptions, [.apple, .docker, .colima])
        XCTAssertEqual(store.localAppleItems.map(\.name), ["models"])
        XCTAssertTrue(store.failures.isEmpty)

        store.machineFilter = .machine("studio")
        XCTAssertEqual(store.filteredItems().count, 2)
        XCTAssertEqual(store.filteredItems(showBindMounts: false).count, 1)
        store.engineFilter = .docker
        XCTAssertTrue(store.filteredItems().isEmpty)
    }

    func testFailingRemoteDoesNotBlockTheListAndIsBackedOff() async throws {
        let docker = FakeRuntime(id: "docker", kind: .docker, result: .success([vol("pgdata")]))
        let remote = FakeRuntime(id: "machine:hub", kind: .docker, label: "hub",
                                 result: .failure(.command(exitCode: 255, stderr: "ssh: connect to host hub: Operation timed out")))
        let store = VolumeStore(runtimes: [docker, remote])
        await store.refresh()

        XCTAssertEqual(store.items.map(\.name), ["pgdata"])
        XCTAssertEqual(store.failures.map(\.source), ["hub"])
        XCTAssertNil(store.error, "a remote failure is not the primary (Apple) error")
        XCTAssertEqual(remote.calls.withLock { $0 }, 1)

        await store.refresh()
        XCTAssertEqual(remote.calls.withLock { $0 }, 1, "an unreachable machine is retried after the backoff, not every poll")
        XCTAssertEqual(store.failures.count, 1)

        await store.refresh(force: true)
        XCTAssertEqual(remote.calls.withLock { $0 }, 2, "a manual refresh bypasses the backoff")
    }

    func testAppleFailureSetsPrimaryErrorAndKeepsLastList() async throws {
        let apple = FakeRuntime(id: "apple", kind: .apple, keepsLast: true, result: .success([vol("models", kind: .apple)]))
        let store = VolumeStore(runtimes: [apple])
        await store.refresh()
        apple.behavior.withLock { $0 = .failure(.command(exitCode: 1, stderr: "xpc error")) }
        await store.refresh()
        XCTAssertNotNil(store.error)
        XCTAssertEqual(store.items.map(\.name), ["models"])
        XCTAssertEqual(store.failures.map(\.source), ["Apple"])
    }

    func testAppleServiceDownStillListsDocker() async throws {
        let apple = FakeRuntime(id: "apple", kind: .apple, result: .success([vol("models", kind: .apple)]))
        let docker = FakeRuntime(id: "docker", kind: .docker, result: .success([vol("pgdata")]))
        let store = VolumeStore(runtimes: [apple, docker])
        await store.refresh(appleAvailable: false)
        XCTAssertEqual(store.items.map(\.name), ["pgdata"])
        XCTAssertEqual(apple.calls.withLock { $0 }, 0)
    }

    func testDroppedMachineLeavesTheListImmediately() async throws {
        let remote = FakeRuntime(id: "machine:hub", kind: .docker, label: "hub",
                                 result: .success([vol("pgdata").with(runtimeID: "machine:hub", machineLabel: "hub")]))
        let store = VolumeStore(runtimes: [remote])
        await store.refresh()
        XCTAssertEqual(store.items.count, 1)
        store.runtimeProvider = { [] }
        await store.refresh()
        XCTAssertTrue(store.items.isEmpty)
    }

    func testRemoveAndPruneAreGated() async throws {
        let docker = FakeRuntime(id: "docker", kind: .docker, actions: .docker, result: .success([vol("pgdata")]))
        let store = VolumeStore(runtimes: [docker])
        await store.refresh()
        let pgdata = try XCTUnwrap(store.items.first)
        try await store.remove(pgdata)
        XCTAssertEqual(docker.removed.withLock { $0 }, ["pgdata"])

        var bind = pgdata; bind.storage = .bind
        do { try await store.remove(bind); XCTFail("bind mount must not be removable") } catch {}
        let remote = pgdata.with(runtimeID: "machine:1", machineLabel: "studio")
        do { try await store.remove(remote); XCTFail("external volume must not be removable") } catch {}
        XCTAssertEqual(docker.removed.withLock { $0 }, ["pgdata"])

        do { try await store.prune(); XCTFail("prune is Apple-only") } catch {}
        XCTAssertEqual(docker.pruned.withLock { $0 }, 0)
    }
}
