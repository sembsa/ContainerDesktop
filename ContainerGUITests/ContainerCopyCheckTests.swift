import XCTest

/// Where an upload is expected to land, which decides what the app probes for.
///
/// This matters because `container cp` can exit 0 without copying anything, so
/// the app looks for the file afterwards — and probing the wrong path would
/// either pass every time or fail every time.
final class ContainerCopyCheckTests: XCTestCase {

    func testAFullTargetPathIsProbedAsGiven() {
        XCTAssertEqual(
            ContainerCopyCheck.expectedPath(
                localPath: "/Users/me/app.conf",
                destination: "/etc/app.conf",
                destinationIsDirectory: false
            ),
            "/etc/app.conf"
        )
    }

    func testADirectoryDestinationGetsTheFileNameAppended() {
        // `/etc` exists whether or not the copy happened, so probing it would
        // report success every single time.
        XCTAssertEqual(
            ContainerCopyCheck.expectedPath(
                localPath: "/Users/me/app.conf",
                destination: "/etc",
                destinationIsDirectory: true
            ),
            "/etc/app.conf"
        )
    }

    func testATrailingSlashDoesNotProduceADoubleSlash() {
        XCTAssertEqual(
            ContainerCopyCheck.expectedPath(
                localPath: "/Users/me/app.conf",
                destination: "/etc/",
                destinationIsDirectory: true
            ),
            "/etc/app.conf"
        )
    }

    func testTheRootDirectoryIsStillJoinedCorrectly() {
        XCTAssertEqual(
            ContainerCopyCheck.expectedPath(
                localPath: "/Users/me/app.conf",
                destination: "/",
                destinationIsDirectory: true
            ),
            "/app.conf"
        )
    }

    func testACopiedDirectoryKeepsItsOwnName() {
        // Uploading a folder is the same rule: the last component moves across.
        XCTAssertEqual(
            ContainerCopyCheck.expectedPath(
                localPath: "/Users/me/assets",
                destination: "/srv",
                destinationIsDirectory: true
            ),
            "/srv/assets"
        )
    }

    func testANameWithSpacesSurvivesUntouched() {
        // The probe runs `test` directly rather than through a shell, so a space
        // needs no escaping — and must not acquire any.
        XCTAssertEqual(
            ContainerCopyCheck.expectedPath(
                localPath: "/Users/me/moje dane.txt",
                destination: "/data",
                destinationIsDirectory: true
            ),
            "/data/moje dane.txt"
        )
    }
}
