import XCTest

/// Docker output -> the app's neutral models. The fixtures are real output from
/// Docker Desktop 27.5.1 (`docker ps -a`, `docker inspect`, `docker stats`).
final class DockerRuntimeTests: XCTestCase {
    private func fixtureText(_ name: String, ext: String) throws -> String {
        let bundle = Bundle(for: type(of: self))
        let url = bundle.url(forResource: name, withExtension: ext, subdirectory: "Fixtures")
            ?? bundle.url(forResource: name, withExtension: ext)
        return try String(contentsOf: XCTUnwrap(url, "missing fixture \(name).\(ext)"), encoding: .utf8)
    }

    // MARK: - ps

    func testDecodePSRow() throws {
        let rows = try DockerPSRow.decodeLines(fixtureText("docker-ps", ext: "ndjson"))
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.Names, "test-nginx")
        XCTAssertEqual(row.Image, "nginx:alpine")
        XCTAssertEqual(row.State, "running")
        XCTAssertEqual(row.Ports, "0.0.0.0:8088->80/tcp")
    }

    func testPSRowMapsToNeutralModel() throws {
        let row = try XCTUnwrap(DockerPSRow.decodeLines(fixtureText("docker-ps", ext: "ndjson")).first)
        let container = DockerContainerMapper.map(row)
        XCTAssertEqual(container.id, "test-nginx")
        XCTAssertEqual(container.reference, "test-nginx")
        XCTAssertEqual(container.runtime, .docker)
        XCTAssertEqual(container.imageReference, "nginx:alpine")
        XCTAssertTrue(container.isRunning)
        XCTAssertEqual(container.configuration.publishedPorts?.first?.hostPort, 8088)
        XCTAssertEqual(container.configuration.publishedPorts?.first?.containerPort, 80)
        XCTAssertEqual(container.configuration.networks?.first?.network, "bridge")
    }

    // MARK: - inspect

    func testInspectMapsToNeutralModel() throws {
        let inspected = try DockerInspect.decodeArray(fixtureText("docker-inspect", ext: "json"))
        let raw = try XCTUnwrap(inspected.first)
        let container = DockerContainerMapper.map(raw, architectures: [raw.Image ?? "": "arm64"])

        XCTAssertEqual(container.id, "test-nginx")
        XCTAssertEqual(container.configuration.id, "test-nginx")
        XCTAssertEqual(container.runtime, .docker)
        XCTAssertEqual(container.state, "running")
        XCTAssertEqual(container.imageReference, "nginx:alpine")
        XCTAssertEqual(container.architecture, "arm64")
        XCTAssertEqual(container.configuration.platform?.os, "linux")
        XCTAssertEqual(container.primaryIPv4, "172.17.0.2/16")
        XCTAssertEqual(container.primaryIPv4Address, "172.17.0.2")
        XCTAssertEqual(container.configuration.publishedPorts?.count, 1)
        XCTAssertEqual(container.configuration.publishedPorts?.first?.display, "8088 → 80/tcp")
        XCTAssertEqual(container.configuration.initProcess?.executable, "/docker-entrypoint.sh")
        XCTAssertEqual(container.configuration.initProcess?.arguments, ["nginx", "-g", "daemon off;"])
        XCTAssertEqual(container.configuration.initProcess?.workingDirectory, "/")
        XCTAssertTrue(container.configuration.initProcess?.environment?.contains("NGINX_VERSION=1.31.6") == true)
        XCTAssertEqual(container.configuration.runtimeHandler, "runc")
        XCTAssertEqual(container.configuration.readOnly, false)
        XCTAssertNil(container.configuration.resources, "no limits set, so no resources")
        XCTAssertNotNil(container.configuration.creationDate)
        XCTAssertNotNil(container.status?.startedDate)
        XCTAssertEqual(container.configuration.labels?["maintainer"], "NGINX Docker Maintainers <docker-maint@nginx.com>")
        XCTAssertEqual(container.configuration.networks?.first?.network, "bridge")
    }

    func testComposeLabelsAreAliasedForGrouping() {
        let json = """
        [{"Id":"abc","Name":"/web-1","State":{"Status":"exited"},
          "Config":{"Image":"nginx","Labels":{"com.docker.compose.project":"shop","com.docker.compose.service":"web"}}}]
        """
        let raw = try! DockerInspect.decodeArray(json).first!
        let container = DockerContainerMapper.map(raw)
        XCTAssertEqual(container.composeProject, "shop")
        XCTAssertEqual(container.composeService, "web")
        XCTAssertEqual(container.state, "stopped")
        XCTAssertFalse(container.isRunning)
    }

    func testStoppedContainerUsesConfiguredPortBindings() throws {
        let json = """
        [{"Id":"abc","Name":"/db","State":{"Status":"exited"},"Config":{"Image":"postgres"},
          "HostConfig":{"PortBindings":{"5432/tcp":[{"HostIp":"","HostPort":"5433"}]}},
          "NetworkSettings":{"Ports":{}}}]
        """
        let container = DockerContainerMapper.map(try DockerInspect.decodeArray(json).first!)
        XCTAssertEqual(container.configuration.publishedPorts?.first?.hostPort, 5433)
        XCTAssertEqual(container.configuration.publishedPorts?.first?.containerPort, 5432)
    }

    func testStateNormalisation() {
        XCTAssertEqual(DockerContainerMapper.normalizedState("running"), "running")
        XCTAssertEqual(DockerContainerMapper.normalizedState("exited"), "stopped")
        XCTAssertEqual(DockerContainerMapper.normalizedState("created"), "stopped")
        XCTAssertEqual(DockerContainerMapper.normalizedState("Paused"), "paused")
    }

    func testNanosecondTimestampsParse() throws {
        let date = try XCTUnwrap(DockerContainerMapper.parseDate("2026-10-04T07:23:29.018136046Z"))
        XCTAssertEqual(date.timeIntervalSince1970, 1_791_098_609.018, accuracy: 0.01)
        XCTAssertNotNil(DockerContainerMapper.parseDate("2026-10-04T07:23:29Z"))
    }

    // MARK: - stats

    func testStatsRowMapsToCounterSample() throws {
        let row = try XCTUnwrap(DockerStatsRow.decodeLines(fixtureText("docker-stats", ext: "ndjson")).first)
        let sample = DockerContainerMapper.map(row, cpuMicroseconds: 1234)
        XCTAssertEqual(sample.id, "test-nginx")
        XCTAssertEqual(sample.cpuUsageUsec, 1234)
        XCTAssertEqual(sample.memoryUsageBytes, Int64(9.035 * 1_048_576))
        XCTAssertEqual(sample.memoryLimitBytes, Int64(15.6 * 1_073_741_824))
        XCTAssertEqual(sample.blockReadBytes, 143_000)
        XCTAssertEqual(sample.blockWriteBytes, 12_300)
        XCTAssertEqual(sample.networkRxBytes, 2_200)
        XCTAssertEqual(sample.networkTxBytes, 1_560)
        XCTAssertEqual(sample.numProcesses, 11)
    }

    func testByteAndPercentParsing() {
        XCTAssertEqual(DockerContainerMapper.parseBytes("0B"), 0)
        XCTAssertEqual(DockerContainerMapper.parseBytes("1.5kB"), 1500)
        XCTAssertEqual(DockerContainerMapper.parseBytes("2MiB"), 2_097_152)
        XCTAssertNil(DockerContainerMapper.parseBytes("lots"))
        XCTAssertEqual(DockerContainerMapper.parsePercent("12.50%"), 12.5)
        XCTAssertNil(DockerContainerMapper.parsePercent(nil))
    }

    func testPortStringParsing() {
        let ports = DockerContainerMapper.parsePorts("0.0.0.0:8088->80/tcp, :::8088->80/tcp, 443/tcp")
        XCTAssertEqual(ports.count, 1, "IPv6 duplicate and unpublished ports are dropped")
        XCTAssertEqual(ports.first?.hostPort, 8088)
    }

    func testAppleContainersKeepApplesIdentity() throws {
        let data = try XCTUnwrap(fixtureText("container-inspect", ext: "json").data(using: .utf8))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let container = try XCTUnwrap(decoder.decode([ContainerInfo].self, from: data).first)
        XCTAssertEqual(container.runtime, .apple)
        XCTAssertEqual(container.reference, container.id)
        XCTAssertEqual(container.sourceTags.map(\.text), [ContainerLocation.local.title, "Apple"])
        XCTAssertEqual(container.location, .local)
        XCTAssertNil(container.machineLabel)
        XCTAssertTrue(container.capabilities.contains(.recreate))
        let row = try XCTUnwrap(DockerPSRow.decodeLines(fixtureText("docker-ps", ext: "ndjson")).first)
        let docker = DockerContainerMapper.map(row)
        XCTAssertFalse(docker.capabilities.contains(.recreate))
        XCTAssertEqual(docker.sourceTags.map(\.text), [ContainerLocation.local.title, "Docker"])
    }

    // MARK: - Live (skipped when Docker or test-nginx is not there)

    func testLiveListAndInspectSeeTestNginx() async throws {
        let runtime = DockerRuntime()
        try XCTSkipUnless(runtime.isInstalled, "docker CLI not installed")
        let containers: [ContainerInfo]
        do { containers = try await runtime.list(includeStopped: true) }
        catch { throw XCTSkip("docker daemon unavailable: \(error)") }
        guard let nginx = containers.first(where: { $0.id == "test-nginx" }) else {
            throw XCTSkip("test-nginx container not present")
        }
        XCTAssertEqual(nginx.runtime, .docker)
        XCTAssertEqual(nginx.imageReference, "nginx:alpine")
        XCTAssertEqual(nginx.configuration.publishedPorts?.first?.hostPort, 8088)

        let raw = try await runtime.inspect(nginx.reference)
        XCTAssertTrue(raw.contains("\"Name\": \"/test-nginx\""))

        if nginx.isRunning {
            let samples = try await runtime.stats(references: [nginx.reference])
            XCTAssertEqual(samples.first?.id, "test-nginx")
            XCTAssertNotNil(samples.first?.memoryUsageBytes)
            let files = try await runtime.listFiles(nginx.reference, path: "/")
            XCTAssertTrue(files.contains { $0.name == "etc" && $0.isDirectory })
        }
    }
}
