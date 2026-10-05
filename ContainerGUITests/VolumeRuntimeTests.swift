import XCTest

/// Docker / Apple volume output -> `VolumeEntry`, the three source tags, filters
/// and action gating. The docker fixtures are real output from Docker Desktop
/// (`docker volume ls` / `inspect`, `docker system df -v`, container mounts).
final class VolumeRuntimeTests: XCTestCase {
    private func fixtureText(_ name: String, ext: String) throws -> String {
        let bundle = Bundle(for: type(of: self))
        let url = bundle.url(forResource: name, withExtension: ext, subdirectory: "Fixtures")
            ?? bundle.url(forResource: name, withExtension: ext)
        return try String(contentsOf: XCTUnwrap(url, "missing fixture \(name).\(ext)"), encoding: .utf8)
    }

    private let local = ContainerLocation.local.title
    private let external = ContainerLocation.external.title

    private func dockerEntries(includeBind: Bool = true) throws -> [VolumeEntry] {
        let rows = try DockerVolumeRow.decodeLines(fixtureText("docker-volume-ls", ext: "ndjson"))
        let inspected = try DockerVolumeInspect.decodeArray(fixtureText("docker-volume-inspect", ext: "json"))
        let sizes = try DockerSystemDF.decode(fixtureText("docker-system-df", ext: "json")).sizes
        let mounts = DockerContainerMounts.parse(try fixtureText("docker-container-mounts", ext: "tsv"))
        return DockerVolumeMapper.entries(rows: rows, inspected: inspected, sizes: sizes, mounts: mounts, includeBindMounts: includeBind)
    }

    // MARK: - Docker parsing (real fixtures)

    func testDecodesVolumeListLines() throws {
        let rows = try DockerVolumeRow.decodeLines(fixtureText("docker-volume-ls", ext: "ndjson"))
        XCTAssertEqual(rows.map(\.Name), ["cgui-fixture-data", "cgui-fixture-unused"])
        XCTAssertEqual(rows[0].Driver, "local")
        XCTAssertEqual(rows[0].Mountpoint, "/var/lib/docker/volumes/cgui-fixture-data/_data")
    }

    func testDecodesInspectWithNullLabels() throws {
        let inspected = try DockerVolumeInspect.decodeArray(fixtureText("docker-volume-inspect", ext: "json"))
        XCTAssertEqual(inspected.count, 2)
        XCTAssertEqual(inspected[0].Labels?["purpose"], "fixture")
        XCTAssertNil(inspected[1].Labels, "Docker emits null for no labels")
        XCTAssertEqual(inspected[0].Scope, "local")
    }

    func testSizesFromSystemDF() throws {
        let df = try DockerSystemDF.decode(fixtureText("docker-system-df", ext: "json"))
        XCTAssertEqual(df.sizes["cgui-fixture-data"], 0)
        XCTAssertEqual(df.sizes.count, 2)
    }

    func testDockerHumanSizes() {
        XCTAssertEqual(DockerSize.parse("0B"), 0)
        XCTAssertEqual(DockerSize.parse("1.09kB"), 1090)
        XCTAssertEqual(DockerSize.parse("62.4MB"), 62_400_000)
        XCTAssertEqual(DockerSize.parse("1.5GB"), 1_500_000_000)
        XCTAssertEqual(DockerSize.parse("2TB"), 2_000_000_000_000)
        XCTAssertNil(DockerSize.parse("N/A"))
        XCTAssertNil(DockerSize.parse(""))
        XCTAssertNil(DockerSize.parse(nil))
        XCTAssertNil(DockerSize.parse("big"))
    }

    func testContainerMountsParse() throws {
        let mounts = DockerContainerMounts.parse(try fixtureText("docker-container-mounts", ext: "tsv"))
        XCTAssertEqual(mounts.map(\.container), ["cgui-fixture-c", "test-nginx"], "leading slash of the name is dropped")
        XCTAssertEqual(mounts[0].mounts.map(\.Type), ["volume", "bind"])
        XCTAssertTrue(mounts[1].mounts.isEmpty)
        XCTAssertTrue(DockerContainerMounts.parse("garbage line without tab").isEmpty)
    }

    // MARK: - Mapping

    func testMapsVolumesWithDetailSizeAndUsage() throws {
        let entries = try dockerEntries(includeBind: false)
        XCTAssertEqual(entries.map(\.name), ["cgui-fixture-data", "cgui-fixture-unused"])
        let data = entries[0]
        XCTAssertEqual(data.kind, .docker)
        XCTAssertEqual(data.driver, "local")
        XCTAssertEqual(data.scope, "local")
        XCTAssertEqual(data.path, "/var/lib/docker/volumes/cgui-fixture-data/_data")
        XCTAssertEqual(data.labels["com.docker.compose.project"], "demo")
        XCTAssertEqual(data.composeProject, "demo")
        XCTAssertEqual(data.sizeBytes, 0)
        XCTAssertNotNil(data.createdAt)
        XCTAssertEqual(data.usedBy, ["cgui-fixture-c"])
        XCTAssertTrue(entries[1].usedBy.isEmpty)
        XCTAssertTrue(entries[1].labels.isEmpty)
        XCTAssertEqual(data.sourceTags.map(\.text), [local, "Docker"])
    }

    func testBindMountsBecomeRowsAndDockerDesktopPrefixIsStripped() throws {
        let entries = try dockerEntries()
        let bind = try XCTUnwrap(entries.first(where: \.isBind))
        XCTAssertEqual(bind.name, "/private/tmp", "/host_mnt is Docker Desktop's view of the host")
        XCTAssertEqual(bind.usedBy, ["cgui-fixture-c"])
        XCTAssertFalse(bind.canRemove)
        XCTAssertEqual(entries.count, 3)
    }

    func testSocketBindsAreNotStorage() {
        let mounts = [DockerContainerMounts(container: "runner", mounts: [
            DockerMount(Type: "bind", Name: nil, Source: "/var/run/docker.sock", Destination: "/var/run/docker.sock", RW: true),
            DockerMount(Type: "bind", Name: nil, Source: "/srv/act_runner", Destination: "/data", RW: true),
            DockerMount(Type: "bind", Name: nil, Source: "/srv/act_runner", Destination: "/data2", RW: true),
        ])]
        let entries = DockerVolumeMapper.entries(rows: [], inspected: [], sizes: [:], mounts: mounts)
        XCTAssertEqual(entries.map(\.name), ["/srv/act_runner"])
        XCTAssertEqual(entries[0].usedBy, ["runner"], "one container mounting a path twice is listed once")
    }

    func testListFallsBackToRowsWhenInspectIsMissing() throws {
        let rows = try DockerVolumeRow.decodeLines(fixtureText("docker-volume-ls", ext: "ndjson"))
        let entries = DockerVolumeMapper.entries(rows: rows, inspected: [], sizes: [:], mounts: [])
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].labels, ["com.docker.compose.project": "demo", "purpose": "fixture"], "ls labels are `k=v,k=v`")
        XCTAssertNil(entries[0].sizeBytes, "no df -> no size, not a made-up 0")
        XCTAssertNil(entries[0].createdAt)
    }

    func testLabelParsing() {
        XCTAssertEqual(DockerVolumeMapper.parseLabels("a=b,c=d=e,f"), ["a": "b", "c": "d=e", "f": ""])
        XCTAssertTrue(DockerVolumeMapper.parseLabels("").isEmpty)
        XCTAssertTrue(DockerVolumeMapper.parseLabels("N/A").isEmpty)
    }

    // MARK: - Apple

    private func appleVolume(_ name: String) throws -> VolumeInfo {
        let data = try Data(contentsOf: XCTUnwrap(
            Bundle(for: type(of: self)).url(forResource: "volumes-list", withExtension: "json", subdirectory: "Fixtures")
                ?? Bundle(for: type(of: self)).url(forResource: "volumes-list", withExtension: "json")
        ))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let volume = try decoder.decode([VolumeInfo].self, from: data).first!
        XCTAssertEqual(volume.name, "demovol")
        return volume
    }

    private func appleContainer(_ name: String, mounts: [ContainerInfo.Configuration.Mount]) -> ContainerInfo {
        let configuration = ContainerInfo.Configuration(
            id: name, image: .init(reference: "img", descriptor: nil),
            creationDate: nil, labels: nil, resources: nil, platform: nil, initProcess: nil,
            publishedPorts: nil, mounts: mounts, rosetta: nil, runtimeHandler: nil, readOnly: nil,
            ssh: nil, virtualization: nil, networks: nil, readonlyPaths: nil, maskedPaths: nil
        )
        return ContainerInfo(id: name, configuration: configuration, status: nil, runtime: .apple)
    }

    func testAppleVolumeMapsWithUsageAndBindMounts() throws {
        let volume = try appleVolume("demovol")
        let usesVolume = appleContainer("db", mounts: [
            .init(source: nil, destination: "/data", type: .init(volume: .init(name: "demovol"))),
            .init(source: "/Users/me/src", destination: "/src", type: nil),
        ])
        let entries = AppleVolumeMapper.entries(volumes: [volume], containers: [usesVolume])
        XCTAssertEqual(entries.map(\.name), ["demovol", "/Users/me/src"])
        let demo = entries[0]
        XCTAssertEqual(demo.kind, .apple)
        XCTAssertEqual(demo.format, "ext4")
        XCTAssertEqual(demo.sizeBytes, 67_108_864)
        XCTAssertEqual(demo.usedBy, ["db"])
        XCTAssertEqual(demo.sourceTags.map(\.text), [local, "Apple"])
        XCTAssertTrue(entries[1].isBind)
        XCTAssertEqual(entries[1].usedBy, ["db"])
    }

    // MARK: - Tags, filters, identities, gating

    private func entry(_ name: String, machine: String? = nil, engine: ContainerEngine? = nil, kind: VolumeEntry.Kind = .docker) -> VolumeEntry {
        let base = VolumeEntry(id: name, reference: name, name: name, kind: kind)
        guard let machine else { return base }
        return base.with(runtimeID: "machine:1", machineLabel: machine, engine: engine)
    }

    func testExternalColimaVolumeShowsAllThreeTags() {
        let v = entry("data", machine: "studio", engine: .colima)
        XCTAssertEqual(v.sourceTags.map(\.text), [external, "studio", "Colima"])
        XCTAssertEqual(v.sourceTags.map(\.kind), [.location, .machine, .runtime])
    }

    func testFiltersCombineAndSearchSeesTagsAndUsers() {
        var a = entry("pgdata"); a.usedBy = ["postgres"]
        let b = entry("pgdata", machine: "studio", engine: .colima)
        let c = entry("models", machine: "studio", engine: .apple, kind: .apple)
        let all = [a, b, c]
        XCTAssertEqual(VolumeSourceFilter.apply(machine: .machine("studio"), engine: nil, to: all).count, 2)
        XCTAssertEqual(VolumeSourceFilter.apply(machine: nil, engine: .colima, to: all).count, 1)
        XCTAssertEqual(VolumeSourceFilter.apply(machine: .machine("studio"), engine: .apple, to: all).map(\.name), ["models"])
        XCTAssertEqual(VolumeSourceFilter.apply(machine: nil, engine: nil, search: "postgres", to: all).count, 1)
        XCTAssertEqual(VolumeSourceFilter.apply(machine: nil, engine: nil, search: "STUDIO", to: all).count, 2)
        var bind = entry("/srv/x"); bind.storage = .bind
        XCTAssertEqual(VolumeSourceFilter.apply(machine: nil, engine: nil, showBindMounts: false, to: [a, bind]).count, 1)
    }

    func testSameNameOnTwoEnginesGetsUniqueIdentities() {
        let list = VolumeSourceFilter.makeIdentitiesUnique([entry("data"), entry("data", machine: "studio", engine: .colima), entry("data")])
        XCTAssertEqual(Set(list.map(\.id)).count, 3)
        XCTAssertTrue(list.allSatisfy { $0.reference == "data" }, "commands still go out under the engine-local reference")
    }

    func testActionsAreGatedByOwner() {
        XCTAssertEqual(entry("a", kind: .apple).actions, .apple)
        XCTAssertEqual(entry("a").actions, .docker)
        XCTAssertFalse(entry("a").actions.contains(.prune), "prune is Apple-only")
        XCTAssertEqual(entry("a", machine: "studio", engine: .colima).actions, .none)
        XCTAssertTrue(entry("a").canRemove)
        XCTAssertFalse(entry("a", machine: "studio", engine: .colima).canRemove)
    }

    func testExternalReferenceEncodingKeepsEngine() {
        let encoded = ExternalMachineRuntime.encode(engine: "/run/docker.sock", name: "data")
        let decoded = ExternalMachineRuntime.decode(encoded)
        XCTAssertEqual(decoded?.engine, "/run/docker.sock")
        XCTAssertEqual(decoded?.name, "data")
    }
}
