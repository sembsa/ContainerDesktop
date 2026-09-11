import XCTest

/// How a container path is turned into the `tar -C <dir> <name>` pair.
///
/// This is the fallback used when a container's own `cp` is broken, so getting
/// the split wrong means the fallback fails exactly where it is needed.
final class ContainerFileTransferTests: XCTestCase {

    func testAFileInADirectorySplitsIntoBoth() {
        let split = ContainerFileTransfer.split("/app/keyforge3d.png")
        XCTAssertEqual(split.directory, "/app")
        XCTAssertEqual(split.name, "keyforge3d.png")
    }

    func testATopLevelEntrySplitsAgainstTheRoot() {
        let split = ContainerFileTransfer.split("/app")
        XCTAssertEqual(split.directory, "/")
        XCTAssertEqual(split.name, "app")
    }

    func testATrailingSlashIsNotMistakenForAnEmptyName() {
        // `/app/` names the same directory as `/app`; without trimming, the last
        // component comes back empty and tar is handed nothing to archive.
        let split = ContainerFileTransfer.split("/app/")
        XCTAssertEqual(split.directory, "/")
        XCTAssertEqual(split.name, "app")
    }

    func testTheRootItselfBecomesADotEntry() {
        // There is no name to pass for `/`, and `tar -C / .` is how you say it.
        let split = ContainerFileTransfer.split("/")
        XCTAssertEqual(split.directory, "/")
        XCTAssertEqual(split.name, ".")
    }

    func testADeepPathKeepsItsWholeDirectory() {
        let split = ContainerFileTransfer.split("/var/lib/app/data.db")
        XCTAssertEqual(split.directory, "/var/lib/app")
        XCTAssertEqual(split.name, "data.db")
    }

    func testANameWithSpacesIsNotEscapedOrSplit() {
        // The arguments go to `tar` as argv, never through a shell.
        let split = ContainerFileTransfer.split("/data/moje dane.txt")
        XCTAssertEqual(split.directory, "/data")
        XCTAssertEqual(split.name, "moje dane.txt")
    }

    // MARK: - Joining back

    func testJoinAddsExactlyOneSeparator() {
        XCTAssertEqual(ContainerFileTransfer.join("/tmp", "a.txt"), "/tmp/a.txt")
        XCTAssertEqual(ContainerFileTransfer.join("/tmp/", "a.txt"), "/tmp/a.txt")
        XCTAssertEqual(ContainerFileTransfer.join("/", "a.txt"), "/a.txt")
    }

    func testSplitAndJoinRoundTrip() {
        for path in ["/app/keyforge3d.png", "/var/lib/app/data.db", "/etc/hostname"] {
            let split = ContainerFileTransfer.split(path)
            XCTAssertEqual(ContainerFileTransfer.join(split.directory, split.name), path)
        }
    }
}
