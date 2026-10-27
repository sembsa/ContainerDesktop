import XCTest

/// Snapshots against a real `container` service (1.6.0+). Skipped unless
/// `CD_LIVE=1`. Drives the same `ContainerSnapshots` calls the app makes and
/// checks the filesystem actually goes back in time — and forward again.
final class ContainerSnapshotsLiveTests: XCTestCase {
    private let id = "cdlive-snap"
    private let cli = ContainerCLI.shared
    private var references: [String] = []

    override func setUp() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CD_LIVE"] == "1", "set CD_LIVE=1 to run")
        _ = try? await cli.run(["rm", "--force", id])
        try await cli.run(["run", "-d", "--name", id, "docker.io/library/alpine:latest", "sleep", "600"])
    }

    override func tearDown() async throws {
        _ = try? await cli.run(["rm", "--force", id])
        for reference in references { _ = try? await cli.run(["image", "rm", reference]) }
    }

    private func marker(in container: String) async -> String? {
        try? await cli.run(["exec", container, "cat", "/marker"]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func write(_ value: String) async throws {
        try await cli.run(["exec", id, "sh", "-c", "echo \(value) > /marker"])
    }

    private func isRunning() async -> Bool {
        (try? await cli.run(["exec", id, "true"])) != nil
    }

    /// The stamp has one-second resolution; two snapshots in one second share a name.
    private func nextSecond() async { try? await Task.sleep(for: .milliseconds(1100)) }

    func testRestoreGoesBackAndTheSafetySnapshotGoesForward() async throws {
        try await write("v1")
        let v1 = try await ContainerSnapshots.take(id, isRunning: true, stopFirst: true)
        references.append(v1)
        let runningAfterStopFirst = await isRunning()
        XCTAssertTrue(runningAfterStopFirst, "stopFirst must start the container again")

        try await write("v2")
        await nextSecond()
        let v2 = try await ContainerSnapshots.take(id, isRunning: true, stopFirst: false)
        references.append(v2)

        // The app finds both under this container, newest first, as the CLI lists them.
        let images = try await cli.json(["image", "ls"], as: [ImageInfo].self)
        XCTAssertEqual(ContainerSnapshots.snapshots(for: id, in: images).map(\.reference).prefix(2), [v2, v1])

        // Restore v1 the way the sheet does: preserve, remove, run the snapshot.
        try await write("v3")
        await nextSecond()
        let safety = try await ContainerSnapshots.preserveBeforeReplacing(id)
        references.append(safety)
        try await cli.run(["rm", "--force", id])
        // The configuration the recreate sheet holds — the original command
        // included — passed through `restoring`, exactly as the sheet does.
        var original = RunConfiguration()
        original.image = "docker.io/library/alpine:latest"
        original.name = id
        original.command = "sleep 600"
        try await cli.run(RunCommandBuilder.arguments(for: original.restoring(v1)))
        let restored = await marker(in: id)
        XCTAssertEqual(restored, "v1", "restore must bring back the snapshot's filesystem")

        // The state that was replaced is not lost.
        // `--entrypoint`, because the snapshot's own entrypoint is `sleep`.
        let replaced = try? await cli.run(["run", "--rm", "--entrypoint", "cat", safety, "/marker"])
        XCTAssertEqual(replaced?.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").last, "v3")
    }
}
