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

    // MARK: - ImageInspect decoding

    func testDecodeImageInspect() throws {
        let json = """
        [{
          "configuration": {
            "creationDate": "2026-06-09T20:10:54Z",
            "descriptor": {"digest": "sha256:a2d4abcdef12345678", "mediaType": "application/vnd.oci.image.index.v1+json", "size": 9218},
            "name": "docker.io/library/alpine:latest"
          },
          "id": "a2d4abcdef12345678",
          "variants": [
            {
              "config": {
                "architecture": "arm64",
                "config": {
                  "Cmd": ["/bin/sh"],
                  "Entrypoint": ["dotnet", "app.dll"],
                  "Env": ["PATH=/usr/local/sbin:/usr/local/bin"],
                  "WorkingDir": "/app",
                  "Labels": {"maintainer": "test"},
                  "ExposedPorts": {"80/tcp": {}}
                },
                "created": "2026-06-09T20:11:31.67032355Z",
                "history": [
                  {"comment": "buildkit.dockerfile.v0", "created": "2026-06-09T20:11:30Z", "created_by": "ADD alpine-minirootfs-3.22.0-aarch64.tar.gz / # buildkit"},
                  {"created_by": "CMD [\\"/bin/sh\\"]", "empty_layer": true, "created": "2026-06-09T20:11:31Z"}
                ],
                "os": "linux",
                "rootfs": {"diff_ids": ["sha256:bc5a1234", "sha256:de6b5678"], "type": "layers"}
              },
              "digest": "sha256:3315abcdef",
              "platform": {"architecture": "arm64", "os": "linux"},
              "size": 3868385
            },
            {
              "digest": "sha256:attestation999",
              "platform": {"architecture": "unknown", "os": "unknown"},
              "size": 1024
            }
          ]
        }]
        """
        let data = Data(json.utf8)
        let decoder = JSONDecoder()
        let results = try decoder.decode([ImageInspect].self, from: data)
        let inspect = try XCTUnwrap(results.first)

        // Basic structure
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(inspect.id, "a2d4abcdef12345678")
        XCTAssertEqual(inspect.configuration.name, "docker.io/library/alpine:latest")
        XCTAssertEqual(inspect.configuration.descriptor.size, 9218)

        // All variants present before filter
        XCTAssertEqual(inspect.variants.count, 2)

        // Attestation filtering
        let real = inspect.variants.filter { !$0.isAttestation }
        XCTAssertEqual(real.count, 1)
        let variant = try XCTUnwrap(real.first)
        XCTAssertEqual(variant.platformLabel, "linux/arm64")
        XCTAssertEqual(variant.size, 3868385)

        // VariantConfig
        let cfg = try XCTUnwrap(variant.config)
        XCTAssertEqual(cfg.architecture, "arm64")
        XCTAssertEqual(cfg.created, "2026-06-09T20:11:31.67032355Z")
        XCTAssertEqual(cfg.created?.formattedTimestamp, "2026-06-09 20:11:31")

        // RuntimeConfig
        let rc = try XCTUnwrap(cfg.config)
        XCTAssertEqual(rc.cmd, ["/bin/sh"])
        XCTAssertEqual(rc.entrypoint, ["dotnet", "app.dll"])
        XCTAssertEqual(rc.workingDir, "/app")
        XCTAssertEqual(rc.labels?["maintainer"], "test")
        XCTAssertNotNil(rc.exposedPorts?["80/tcp"])

        // History
        let history = try XCTUnwrap(cfg.history)
        XCTAssertEqual(history.count, 2)

        // First entry: buildkit suffix stripped
        let h0 = history[0]
        XCTAssertFalse(h0.emptyLayer == true)
        XCTAssertTrue(h0.displayCommand.hasPrefix("ADD alpine-minirootfs"))
        XCTAssertFalse(h0.displayCommand.contains("# buildkit"))

        // Second entry: empty layer, CMD prefix stripped
        let h1 = history[1]
        XCTAssertEqual(h1.emptyLayer, true)
        XCTAssertTrue(h1.displayCommand.hasPrefix("CMD"))

        // RootFS
        XCTAssertEqual(cfg.rootfs?.diffIds?.count, 2)

        // Attestation variant
        let attestation = try XCTUnwrap(inspect.variants.first { $0.isAttestation })
        XCTAssertEqual(attestation.platform.os, "unknown")
        XCTAssertTrue(attestation.isAttestation)
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
