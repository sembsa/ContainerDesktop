import XCTest

/// The list shows three separate tags per container: location, machine name
/// (external only) and runtime. These cover the model fields, search, the
/// toolbar filter and the duplicate-name identities.
final class ContainerSourceTagsTests: XCTestCase {
    private func make(
        _ name: String,
        runtime: RuntimeKind = .apple,
        machine: String? = nil,
        engine: ContainerEngine? = nil
    ) -> ContainerInfo {
        let configuration = ContainerInfo.Configuration(
            id: name,
            image: .init(reference: "img:\(name)", descriptor: nil),
            creationDate: nil, labels: nil, resources: nil, platform: nil, initProcess: nil,
            publishedPorts: nil, mounts: nil, rosetta: nil, runtimeHandler: nil, readOnly: nil,
            ssh: nil, virtualization: nil, networks: nil, readonlyPaths: nil, maskedPaths: nil
        )
        let base = ContainerInfo(id: name, configuration: configuration, status: nil, runtime: runtime)
        guard let machine else { return base }
        return base.with(runtimeID: "machine:1", machineLabel: machine, engine: engine)
    }

    // The unit-test bundle carries no .strings, so the location titles come back
    // as their (Polish) keys here; the English texts are checked via the app's
    // en.lproj by LocalizationTests. Compare against the model's own strings.
    private let local = ContainerLocation.local.title
    private let external = ContainerLocation.external.title

    private func texts(_ container: ContainerInfo) -> [String] { container.sourceTags.map(\.text) }

    // MARK: - Tags

    func testLocalAppleContainer() {
        let c = make("a")
        XCTAssertEqual(texts(c), [local, "Apple"])
        XCTAssertEqual(c.sourceTags.map(\.kind), [.location, .runtime])
        XCTAssertEqual(c.location, .local)
        XCTAssertNil(c.machineLabel)
    }

    func testLocalDockerContainer() {
        let c = make("d", runtime: .docker)
        XCTAssertEqual(texts(c), [local, "Docker"])
        XCTAssertEqual(c.engine, .docker)
    }

    func testExternalColimaContainerShowsAllThreeTags() {
        let c = make("web", runtime: .docker, machine: "studio", engine: .colima)
        XCTAssertEqual(texts(c), [external, "studio", "Colima"])
        XCTAssertEqual(c.sourceTags.map(\.kind), [.location, .machine, .runtime])
        XCTAssertEqual(c.location, .external)
        XCTAssertEqual(c.machineLabel, "studio")
    }

    func testExternalAppleContainerKeepsLabelAndApple() {
        let c = make("web", runtime: .apple, machine: "studio", engine: .apple)
        XCTAssertEqual(texts(c), [external, "studio", "Apple"])
    }

    func testMachineLabelIsShownExactlyAsTyped() {
        let c = make("web", runtime: .docker, machine: "Cloud Lab 2", engine: .docker)
        XCTAssertEqual(c.sourceTags[1].text, "Cloud Lab 2")
    }

    func testEngineFromDetectedTitle() {
        XCTAssertEqual(ContainerEngine(engineTitle: "Colima"), .colima)
        XCTAssertEqual(ContainerEngine(engineTitle: "Colima (work) [bob]"), .colima)
        XCTAssertEqual(ContainerEngine(engineTitle: "Docker Desktop"), .docker)
        XCTAssertEqual(ContainerEngine(engineTitle: "Docker"), .docker)
        XCTAssertEqual(ContainerEngine(engineTitle: "OrbStack"), .docker)
        XCTAssertEqual(ContainerEngine(engineTitle: "Apple"), .apple)
    }

    func testTaggingKeepsReferenceAndRuntime() {
        let local = make("web", runtime: .docker)
        let tagged = local.with(reference: "ref", runtimeID: "machine:1", machineLabel: "m", engine: .colima)
        XCTAssertEqual(tagged.reference, "ref")
        XCTAssertEqual(tagged.runtime, .docker)
        XCTAssertEqual(tagged.runtimeKey, "machine:1")
        // Re-tagging without a label must not make it local again.
        XCTAssertEqual(tagged.with(id: "other").location, .external)
        XCTAssertEqual(tagged.with(id: "other").machineLabel, "m")
    }

    // MARK: - Search

    func testSearchMatchesLocationMachineAndRuntime() {
        let c = make("web", runtime: .docker, machine: "CloudLab", engine: .colima)
        XCTAssertTrue(c.matchesSearch(external.lowercased()))
        XCTAssertTrue(c.matchesSearch("cloudlab"))
        XCTAssertTrue(c.matchesSearch("colima"))
        XCTAssertTrue(c.matchesSearch("web"))
        XCTAssertFalse(c.matchesSearch("apple"))
        XCTAssertFalse(c.matchesSearch(local.lowercased()))
        let localOne = make("x")
        XCTAssertTrue(localOne.matchesSearch(local.lowercased()))
        XCTAssertTrue(localOne.matchesSearch("apple"))
        XCTAssertFalse(localOne.matchesSearch(external.lowercased()))
    }

    // MARK: - Filter

    func testFilterByMachineAndRuntime() {
        let list = [
            make("a"),
            make("d", runtime: .docker),
            make("c", runtime: .docker, machine: "studio", engine: .colima),
            make("s", runtime: .apple, machine: "studio", engine: .apple),
            make("o", runtime: .docker, machine: "CloudLab", engine: .docker),
        ]
        func ids(_ m: MachineFilter?, _ e: ContainerEngine?) -> [String] {
            ContainerSourceFilter.apply(machine: m, engine: e, to: list).map(\.id)
        }
        XCTAssertEqual(ids(nil, nil), ["a", "d", "c", "s", "o"])
        XCTAssertEqual(ids(.local, nil), ["a", "d"])
        XCTAssertEqual(ids(.machine("studio"), nil), ["c", "s"])
        XCTAssertEqual(ids(nil, .docker), ["d", "o"])
        XCTAssertEqual(ids(nil, .colima), ["c"])
        XCTAssertEqual(ids(.machine("studio"), .apple), ["s"])
        XCTAssertEqual(ids(.local, .colima), [])
    }

    func testMachineFilterOrdersLocalFirst() {
        let sorted = [MachineFilter.machine("studio"), .machine("CloudLab"), .local].sorted()
        XCTAssertEqual(sorted, [.local, .machine("CloudLab"), .machine("studio")])
        XCTAssertEqual(MachineFilter.local.title, local)
    }

    // MARK: - Duplicate names

    func testDuplicateNamesGetUniqueIdsFromMachineAndRuntime() {
        let list = [
            make("web"),
            make("web", runtime: .docker),
            make("web", runtime: .docker, machine: "studio", engine: .colima),
            make("web", runtime: .apple, machine: "studio", engine: .apple),
            make("web", runtime: .docker, machine: "studio", engine: .colima),
        ]
        let unique = ContainerSourceFilter.makeIdentitiesUnique(list)
        XCTAssertEqual(
            unique.map(\.id),
            ["web", "web@Docker", "web@studio · Colima", "web@studio · Apple", "web@studio · Colima-2"]
        )
        XCTAssertEqual(Set(unique.map(\.id)).count, unique.count)
        // Engine-local names are untouched, and so are the tags.
        XCTAssertEqual(unique.map(\.reference), Array(repeating: "web", count: 5))
        XCTAssertEqual(texts(unique[2]), [external, "studio", "Colima"])
    }
}
