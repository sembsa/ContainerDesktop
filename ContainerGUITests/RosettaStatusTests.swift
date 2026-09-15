import XCTest

/// Detecting Rosetta, and the command that installs it.
///
/// `container` enables Rosetta for any amd64 image on an arm64 host whether or
/// not `--rosetta` was passed, so "is Rosetta there" decides whether a whole
/// class of images runs at all.
final class RosettaStatusTests: XCTestCase {

    func testAppleSiliconWithTheRuntimeIsInstalled() {
        XCTAssertEqual(
            RosettaStatus.availability(architecture: "arm64", runtimeExists: true),
            .installed
        )
    }

    func testAppleSiliconWithoutTheRuntimeIsMissing() {
        XCTAssertEqual(
            RosettaStatus.availability(architecture: "arm64", runtimeExists: false),
            .missing
        )
    }

    func testIntelMacsAreNotAsked() {
        // Rosetta is meaningless there; offering to install it would be noise.
        XCTAssertEqual(
            RosettaStatus.availability(architecture: "x86_64", runtimeExists: false),
            .notApplicable
        )
        XCTAssertEqual(
            RosettaStatus.availability(architecture: "x86_64", runtimeExists: true),
            .notApplicable
        )
    }

    func testAnUnknownArchitectureIsTreatedAsNotApplicable() {
        // Better to stay quiet than to prompt on a machine we cannot classify.
        XCTAssertEqual(
            RosettaStatus.availability(architecture: "", runtimeExists: false),
            .notApplicable
        )
    }

    // MARK: - Reading the running machine

    func testCurrentUsesTheRuntimePathAndNothingElse() {
        var asked: [String] = []
        let result = RosettaStatus.current(architecture: "arm64") { path in
            asked.append(path)
            return true
        }
        XCTAssertEqual(result, .installed)
        XCTAssertEqual(asked, [RosettaStatus.runtimePath])
    }

    func testCurrentDoesNotTouchTheFilesystemOnIntel() {
        var asked: [String] = []
        let result = RosettaStatus.current(architecture: "x86_64") { path in
            asked.append(path)
            return false
        }
        XCTAssertEqual(result, .notApplicable)
        XCTAssertTrue(asked.isEmpty)
    }

    func testTheHostArchitectureIsReadable() {
        // Guards the uname bridging, which is easy to get subtly wrong.
        XCTAssertFalse(RosettaStatus.hostArchitecture().isEmpty)
    }

    // MARK: - The install command

    func testInstallAcceptsAppleLicenceExplicitly() {
        // The UI has to say so; if this flag ever disappears the installer would
        // hang waiting for a terminal answer no GUI can give.
        XCTAssertEqual(RosettaStatus.installArguments, ["--install-rosetta", "--agree-to-license"])
        XCTAssertEqual(RosettaStatus.installExecutable, "/usr/sbin/softwareupdate")
    }
}
