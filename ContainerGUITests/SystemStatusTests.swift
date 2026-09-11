import XCTest

/// Decodes `container system status --format json`.
///
/// 1.4.1 restructured this output — a documented breaking change. The flat
/// `apiserver.version` field the app used to grep for is gone; versions now live
/// under `client` and `server`, alongside new `host`, `paths` and `resources`
/// sections. The 1.4.1 payload below is real output, with the home directory
/// redacted.
final class SystemStatusTests: XCTestCase {

    /// Captured from CLI 1.4.1 talking to an apiserver left behind at 1.3.1 by a
    /// `.pkg` upgrade — the exact state that breaks `cp`, `clean` and `k8s`.
    private let skewed = """
    {"client":{"appName":"container","build":"release",
     "commit":"9a8917ca2da5cd6ba059b9ba5ca5a74892e9bb7d","version":"1.4.1"},
     "host":{"architecture":"arm64","cpus":18,"operatingSystem":"Version 26.6.2 (Build 25G83)"},
     "paths":{"appRoot":"/Users/me/Library/Application Support/com.apple.container/",
              "installRoot":"/usr/local/"},
     "resources":{"containersRunning":2,"containersTotal":14,"images":55},
     "server":{"appName":"container-apiserver","build":"release",
      "commit":"a9a62e28f6beb88940122a3d7b286f2d5ae8053a",
      "version":"container-apiserver version 1.3.1 (build: release, commit: a9a62e2)"},
     "status":"running"}
    """.data(using: .utf8)!

    private func decode(_ json: Data) throws -> SystemStatus {
        try JSONDecoder().decode(SystemStatus.self, from: json)
    }

    // MARK: - Shape

    func testDecodesEverySectionOfThe141Payload() throws {
        let status = try decode(skewed)

        XCTAssertEqual(status.serviceState, .running)
        XCTAssertEqual(status.client?.version, "1.4.1")
        XCTAssertEqual(status.host?.architecture, "arm64")
        XCTAssertEqual(status.host?.cpus, 18)
        XCTAssertEqual(status.host?.operatingSystem, "Version 26.6.2 (Build 25G83)")
        XCTAssertEqual(status.paths?.installRoot, "/usr/local/")
        XCTAssertEqual(status.resources?.containersRunning, 2)
        XCTAssertEqual(status.resources?.containersTotal, 14)
        XCTAssertEqual(status.resources?.images, 55)
    }

    func testServerVersionIsABannerAndIsReducedToANumber() throws {
        let status = try decode(skewed)
        // The server reports a whole banner where the client reports a bare
        // number; showing the banner verbatim in the UI would be unreadable.
        XCTAssertEqual(
            status.server?.version,
            "container-apiserver version 1.3.1 (build: release, commit: a9a62e2)"
        )
        XCTAssertEqual(status.serverVersionNumber, "1.3.1")
        XCTAssertEqual(status.clientVersionNumber, "1.4.1")
    }

    // MARK: - Version skew

    func testSkewIsReportedWithBothVersionNumbers() throws {
        let skew = try XCTUnwrap(decode(skewed).versionSkew)
        XCTAssertEqual(skew.cli, "1.4.1")
        XCTAssertEqual(skew.service, "1.3.1")
    }

    func testMatchingBuildsReportNoSkew() throws {
        let json = """
        {"client":{"commit":"9a8917ca2da5cd6ba059b9ba5ca5a74892e9bb7d","version":"1.4.1"},
         "server":{"commit":"9a8917ca2da5cd6ba059b9ba5ca5a74892e9bb7d",
                   "version":"container-apiserver version 1.4.1 (build: release, commit: 9a8917c)"},
         "status":"running"}
        """.data(using: .utf8)!
        XCTAssertNil(try decode(json).versionSkew)
    }

    func testADifferentCommitIsSkewEvenWhenTheVersionsMatch() throws {
        // Same marketing version built from two different commits still means two
        // different binaries are talking to each other.
        let json = """
        {"client":{"commit":"1111111111111111111111111111111111111111","version":"1.4.1"},
         "server":{"commit":"2222222222222222222222222222222222222222",
                   "version":"container-apiserver version 1.4.1 (build: release, commit: 2222222)"},
         "status":"running"}
        """.data(using: .utf8)!
        XCTAssertNotNil(try decode(json).versionSkew)
    }

    func testAStoppedServiceIsNotReportedAsSkew() throws {
        // Nothing is running to disagree with, and the fix would be "start", not
        // "restart".
        let json = """
        {"client":{"commit":"aaaa","version":"1.4.1"},
         "server":{"commit":"bbbb","version":"1.3.1"},
         "status":"not running"}
        """.data(using: .utf8)!
        XCTAssertNil(try decode(json).versionSkew)
    }

    func testMissingVersionInformationIsNotSkew() throws {
        let json = #"{"status":"running"}"#.data(using: .utf8)!
        XCTAssertNil(try decode(json).versionSkew)
    }

    // MARK: - Backwards compatibility

    func testAPayloadWithoutTheNewSectionsStillReportsTheServiceState() throws {
        // Older CLIs carry `status` and nothing the app now reads; the sections
        // are optional so a 1.3.x user keeps a working System page.
        let status = try decode(#"{"status":"running"}"#.data(using: .utf8)!)
        XCTAssertEqual(status.serviceState, .running)
        XCTAssertNil(status.client)
        XCTAssertNil(status.host)
    }

    func testAnythingOtherThanRunningCountsAsStopped() throws {
        for raw in ["not running", "unregistered", "stopped"] {
            let json = "{\"status\":\"\(raw)\"}".data(using: .utf8)!
            XCTAssertEqual(try decode(json).serviceState, .stopped, raw)
        }
    }
}
