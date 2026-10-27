import XCTest

/// Compose against a real `container` service. Skipped unless `CD_LIVE=1`
/// (`TEST_RUNNER_CD_LIVE=1 xcodebuild test …`): it pulls an image, starts
/// containers and needs the service running, which no unit test should.
///
/// It exists because service discovery is the thing that has silently failed
/// here before — the /etc/hosts patch registered container names while compose
/// files address services by name.
@MainActor
final class ComposeLiveTests: XCTestCase {
    private let project = "cdlive"

    override func setUp() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CD_LIVE"] == "1", "set CD_LIVE=1 to run")
    }

    override func tearDown() async throws {
        for name in ["\(project)-db", "\(project)-app"] {
            _ = try? await ContainerCLI.shared.run(["rm", "--force", name])
        }
        _ = try? await ContainerCLI.shared.run(["network", "delete", project])
    }

    private func exec(_ container: String, _ command: String) async -> Bool {
        (try? await ContainerCLI.shared.run(["exec", container, "sh", "-c", command])) != nil
    }

    func testServicesReachEachOtherByServiceName() async throws {
        let yaml = """
        services:
          db:
            image: docker.io/library/alpine:latest
            command: ["sleep", "600"]
          app:
            image: docker.io/library/alpine:latest
            command: ["sleep", "600"]
            depends_on: [db]
        """
        let compose = try ComposeParser.parse(yaml, projectName: project)
        let store = ComposeStore()
        let ok = await store.up(compose, replaceExisting: true)
        XCTAssertTrue(ok, store.logLines.joined(separator: "\n"))

        // What compose files actually write…
        let byService = await exec("\(project)-app", "ping -c1 -W2 db")
        XCTAssertTrue(byService, "app → db")
        // …the container name the old patch registered, kept working…
        let byContainer = await exec("\(project)-app", "ping -c1 -W2 \(project)-db")
        XCTAssertTrue(byContainer, "app → container name")
        // …and the reverse direction, written into the older service.
        let reverse = await exec("\(project)-db", "ping -c1 -W2 app")
        XCTAssertTrue(reverse, "db → app")
    }
}
