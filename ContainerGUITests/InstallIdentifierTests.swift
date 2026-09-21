import XCTest

/// The identifier sent with each update check.
///
/// The parts that matter are the ones that fail quietly: an identifier that
/// changes on every launch would count one machine as many, and an opt-out that
/// is read but never honoured would be worse than none at all.
final class InstallIdentifierTests: XCTestCase {

    /// A defaults domain of its own, so the tests never touch the real one.
    private func makeDefaults(_ name: String = UUID().uuidString) -> UserDefaults {
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    // MARK: - Stability

    func testTheIdentifierSurvivesTheLaunchThatCreatedIt() {
        let defaults = makeDefaults()
        let first = InstallIdentifier.current(in: defaults)
        XCTAssertEqual(InstallIdentifier.current(in: defaults), first)
    }

    func testTwoInstallationsDoNotShareAnIdentifier() {
        XCTAssertNotEqual(
            InstallIdentifier.current(in: makeDefaults()),
            InstallIdentifier.current(in: makeDefaults())
        )
    }

    func testWhatIsGeneratedIsAUUIDBecauseTheServerDropsAnythingElse() {
        XCTAssertNotNil(UUID(uuidString: InstallIdentifier.current(in: makeDefaults())))
    }

    func testAMangledStoredValueIsReplacedRatherThanSent() {
        let defaults = makeDefaults()
        defaults.set("not-a-uuid", forKey: InstallIdentifier.defaultsKey)
        let identifier = InstallIdentifier.current(in: defaults)
        XCTAssertNotEqual(identifier, "not-a-uuid")
        XCTAssertTrue(InstallIdentifier.isValid(identifier))
    }

    // MARK: - Opting out

    func testOptingOutSendsNothingAtAll() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: InstallIdentifier.optOutKey)
        XCTAssertTrue(InstallIdentifier.feedParameters(defaults: defaults).isEmpty)
    }

    func testOptingOutDoesNotEvenMintAnIdentifier() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: InstallIdentifier.optOutKey)
        _ = InstallIdentifier.feedParameters(defaults: defaults)
        XCTAssertNil(defaults.string(forKey: InstallIdentifier.defaultsKey))
    }

    func testMetricsAreOnUntilSomebodyTurnsThemOff() {
        XCTAssertTrue(InstallIdentifier.isEnabled(in: makeDefaults()))
    }

    // MARK: - What actually goes on the wire

    func testTheParametersCarryIdentifierVersionAndSystem() {
        let defaults = makeDefaults()
        let keys = InstallIdentifier.feedParameters(defaults: defaults).compactMap { $0["key"] }
        XCTAssertEqual(Set(keys), ["id", "v", "os"])
    }

    func testNothingIdentifyingLeaksIntoTheParameters() {
        // The whole design rests on this: nothing here may describe the person
        // or the machine beyond the version of each.
        let defaults = makeDefaults()
        let values = InstallIdentifier.feedParameters(defaults: defaults).compactMap { $0["value"] }
        let forbidden = [NSUserName(), NSFullUserName(), ProcessInfo.processInfo.hostName]
        for value in values {
            for secret in forbidden where !secret.isEmpty {
                XCTAssertFalse(value.localizedCaseInsensitiveContains(secret), "\(value) ujawnia \(secret)")
            }
        }
    }

    func testTheSystemVersionIsTwoNumbersAndNotTheWholeProfile() {
        // The server only accepts digits and dots; "27.0" passes, "Version 27.0
        // (Build 27A5286g)" would be dropped on arrival.
        let version = InstallIdentifier.systemVersion()
        XCTAssertNotNil(version.range(of: #"^\d+\.\d+$"#, options: .regularExpression), version)
    }
}
