import XCTest

/// The widget can only ever see what the app wrote to disk, so the snapshot
/// file is the contract between them.
final class WidgetSnapshotTests: XCTestCase {
    private let sample = WidgetSnapshot(
        generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
        serviceRunning: true,
        containers: [
            .init(id: "web", image: "nginx:alpine", state: "running", ipv4: "192.168.69.15", project: "shop", cpuPercent: 12.5, memoryUsedBytes: 18_243_584),
            .init(id: "db", image: "postgres:18", state: "stopped", ipv4: nil, project: "shop", cpuPercent: nil, memoryUsedBytes: nil),
        ]
    )

    func testRoundTripsThroughJSON() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(WidgetSnapshot.self, from: encoder.encode(sample))

        XCTAssertEqual(decoded, sample)
        XCTAssertEqual(decoded.runningCount, 1)
        XCTAssertEqual(decoded.stoppedCount, 1)
    }

    /// Inside the widget's sandbox `NSHomeDirectory()` points at the extension's
    /// own container, while the entitlement grants the *real* home directory —
    /// so the path must be built from the password database, not that API.
    func testPathIsAnchoredToTheRealHomeDirectory() {
        let path = WidgetSnapshotStore.fileURL.path

        XCTAssertTrue(path.hasSuffix("/Library/Application Support/ContainerDesktop/widget-snapshot.json"))
        XCTAssertTrue(path.hasPrefix(WidgetSnapshotStore.realHomeDirectory.path))
        // The entitlement grants exactly this directory; anything above it is
        // outside the exception and would be unreadable.
        XCTAssertTrue(WidgetSnapshotStore.directory.path.hasSuffix("/Library/Application Support/ContainerDesktop"))
    }

    func testReadReturnsNilWhenNothingWasEverWritten() {
        // Reading a path that does not exist is an ordinary state, not a throw.
        let missing = WidgetSnapshotStore.realHomeDirectory
            .appending(path: "Library/Application Support/ContainerDesktop/does-not-exist.json")
        XCTAssertNil(try? Data(contentsOf: missing))
    }

    func testEmptySnapshotCountsAreZero() {
        XCTAssertEqual(WidgetSnapshot.empty.runningCount, 0)
        XCTAssertEqual(WidgetSnapshot.empty.stoppedCount, 0)
        XCTAssertFalse(WidgetSnapshot.empty.serviceRunning)
    }

    /// The CIDR suffix the CLI reports is noise on a glanceable surface.
    func testContainerInfoStripsTheCIDRSuffixFromTheAddress() throws {
        let json = """
        [{"id":"demo","configuration":{"id":"demo","image":{"reference":"nginx"}},
          "status":{"state":"running","networks":[{"ipv4Address":"192.168.69.15/24"}]}}]
        """
        let containers = try JSONDecoder().decode([ContainerInfo].self, from: Data(json.utf8))
        let container = try XCTUnwrap(containers.first)

        XCTAssertEqual(container.primaryIPv4, "192.168.69.15/24")
        XCTAssertEqual(container.primaryIPv4Address, "192.168.69.15")
    }
}
