import XCTest

/// Decodes the captured real-CLI fixtures into the app's models, guarding against
/// schema drift in `container`'s JSON output.
final class JSONDecodingTests: XCTestCase {
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private func fixture(_ name: String) throws -> Data {
        let bundle = Bundle(for: type(of: self))
        let url = bundle.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")
            ?? bundle.url(forResource: name, withExtension: "json")
        let resolved = try XCTUnwrap(url, "Brak fixtury \(name).json w bundlu testowym")
        return try Data(contentsOf: resolved)
    }

    func testDecodeContainers() throws {
        let containers = try decoder.decode([ContainerInfo].self, from: fixture("container-inspect"))
        let container = try XCTUnwrap(containers.first)
        XCTAssertEqual(container.id, "demo2")
        XCTAssertEqual(container.state, "running")
        XCTAssertEqual(container.configuration.publishedPorts?.first?.hostPort, 8080)
        XCTAssertEqual(container.configuration.publishedPorts?.first?.containerPort, 80)
        XCTAssertEqual(container.configuration.mounts?.first?.destination, "/data")
        XCTAssertEqual(container.configuration.labels?["team"], "dev")
    }

    func testDecodeImages() throws {
        let images = try decoder.decode([ImageInfo].self, from: fixture("images-list"))
        XCTAssertFalse(images.isEmpty)
        XCTAssertTrue(images.contains { $0.reference.contains("alpine") })
        XCTAssertTrue(images.allSatisfy { $0.totalSize >= 0 })
    }

    func testDecodeVolumes() throws {
        let volumes = try decoder.decode([VolumeInfo].self, from: fixture("volumes-list"))
        let volume = try XCTUnwrap(volumes.first)
        XCTAssertEqual(volume.name, "demovol")
        XCTAssertEqual(volume.configuration.format, "ext4")
    }

    func testDecodeNetworks() throws {
        let networks = try decoder.decode([NetworkInfo].self, from: fixture("networks-list"))
        let network = try XCTUnwrap(networks.first)
        XCTAssertEqual(network.name, "default")
        XCTAssertNotNil(network.status?.ipv4Subnet)
    }

    func testDecodeStats() throws {
        let stats = try decoder.decode([StatsSample].self, from: fixture("stats"))
        let sample = try XCTUnwrap(stats.first)
        XCTAssertEqual(sample.id, "demo1")
        XCTAssertNotNil(sample.memoryUsageBytes)
    }

    // MARK: - MachineInfo decoding

    func testDecodeMachines() throws {
        let machines = try decoder.decode([MachineInfo].self, from: fixture("machines-list"))
        XCTAssertEqual(machines.count, 1)
        let machine = try XCTUnwrap(machines.first)
        XCTAssertEqual(machine.id, "demo-machine")
        XCTAssertEqual(machine.name, "demo-machine")
        XCTAssertEqual(machine.status, "running")
        XCTAssertTrue(machine.isRunning)
        XCTAssertEqual(machine.cpus, 4)
        XCTAssertEqual(machine.memoryBytes, 12884901888)
        XCTAssertEqual(machine.diskSizeBytes, 78647296)
        XCTAssertEqual(machine.ipAddress, "192.168.64.22")
        XCTAssertEqual(machine.isDefault, true)
        XCTAssertNotNil(machine.createdDate)
    }

    // MARK: - SystemStatus decoding

    func testSystemStatusRunning() throws {
        let json = #"{"status":"running","appRoot":"/x"}"#.data(using: .utf8)!
        let status = try decoder.decode(SystemStatus.self, from: json)
        XCTAssertEqual(status.serviceState, .running)
    }

    func testSystemStatusUnregistered() throws {
        let json = #"{"status":"unregistered"}"#.data(using: .utf8)!
        let status = try decoder.decode(SystemStatus.self, from: json)
        XCTAssertEqual(status.serviceState, .stopped)
    }

    func testSystemStatusNotRunning() throws {
        let json = #"{"status":"not running"}"#.data(using: .utf8)!
        let status = try decoder.decode(SystemStatus.self, from: json)
        XCTAssertEqual(status.serviceState, .stopped)
    }

    func testSystemStatusCaseInsensitive() throws {
        let json = #"{"status":"RUNNING"}"#.data(using: .utf8)!
        let status = try decoder.decode(SystemStatus.self, from: json)
        XCTAssertEqual(status.serviceState, .running)
    }

    func testSystemStatusIgnoresUnknownFields() throws {
        let json = #"{"status":"running","unknownField":true,"extra":42}"#.data(using: .utf8)!
        let status = try decoder.decode(SystemStatus.self, from: json)
        XCTAssertEqual(status.serviceState, .running)
    }
}
