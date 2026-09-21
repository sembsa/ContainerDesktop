import XCTest

/// Whether the service is set to start at login.
///
/// The decision is kept separate from the filesystem so every branch can be
/// checked — including the one that must never overwrite somebody's own file.
final class ServiceAutostartTests: XCTestCase {

    private var source: String { ServiceAutostart.sourceURL.path }

    func testWithoutTheServicesOwnPlistThereIsNothingToLinkTo() {
        // `container system start` writes it; before that there is no file.
        XCTAssertEqual(
            ServiceAutostart.state(sourceExists: false, agentLinkTarget: nil, agentExists: false),
            .unavailable
        )
        XCTAssertEqual(
            ServiceAutostart.state(sourceExists: false, agentLinkTarget: source, agentExists: true),
            .unavailable
        )
    }

    func testNoAgentMeansOff() {
        XCTAssertEqual(
            ServiceAutostart.state(sourceExists: true, agentLinkTarget: nil, agentExists: false),
            .off
        )
    }

    func testALinkToTheServicesPlistMeansOn() {
        XCTAssertEqual(
            ServiceAutostart.state(sourceExists: true, agentLinkTarget: source, agentExists: true),
            .on
        )
    }

    func testAPlainFileUnderOurNameIsLeftAlone() {
        // Somebody may have copied the plist by hand; overwriting it would be
        // rude and would hide their change.
        XCTAssertEqual(
            ServiceAutostart.state(sourceExists: true, agentLinkTarget: nil, agentExists: true),
            .foreign
        )
    }

    func testALinkPointingSomewhereElseIsAlsoLeftAlone() {
        XCTAssertEqual(
            ServiceAutostart.state(sourceExists: true, agentLinkTarget: "/tmp/inny.plist", agentExists: true),
            .foreign
        )
    }

    // MARK: - Paths

    func testTheAgentGoesWhereLaunchdLooks() {
        XCTAssertTrue(
            ServiceAutostart.agentURL.path.hasSuffix("/Library/LaunchAgents/com.apple.container.apiserver.plist"),
            ServiceAutostart.agentURL.path
        )
    }

    func testTheSourceIsApplesOwnPlistAndNotOneWeWrite() {
        XCTAssertTrue(
            ServiceAutostart.sourceURL.path.hasSuffix(
                "/Library/Application Support/com.apple.container/apiserver/apiserver.plist"
            ),
            ServiceAutostart.sourceURL.path
        )
    }
}
