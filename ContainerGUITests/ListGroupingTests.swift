import XCTest

/// The pure logic behind the toolbar's "Group by".
final class ListGroupingTests: XCTestCase {
    private func container(
        _ name: String, running: Bool = true, image: String = "img", project: String? = nil,
        machine: String? = nil, engine: ContainerEngine? = nil, runtime: RuntimeKind = .apple
    ) -> ContainerInfo {
        let configuration = ContainerInfo.Configuration(
            id: name, image: .init(reference: image, descriptor: nil),
            creationDate: nil, labels: project.map { ["compose.project": $0] }, resources: nil, platform: nil, initProcess: nil,
            publishedPorts: nil, mounts: nil, rosetta: nil, runtimeHandler: nil, readOnly: nil,
            ssh: nil, virtualization: nil, networks: nil, readonlyPaths: nil, maskedPaths: nil
        )
        let status = ContainerInfo.Status(state: running ? "running" : "stopped", startedDate: nil, networks: nil)
        let base = ContainerInfo(id: name, configuration: configuration, status: status, runtime: runtime)
        guard let machine else { return base }
        return base.with(runtimeID: "machine:\(machine)", machineLabel: machine, engine: engine)
    }

    private func names(_ groups: [ListGroup<ContainerInfo>]) -> [[String]] { groups.map { $0.items.map(\.id) } }

    func testNoneIsOneFlatUntitledSection() {
        let groups = ListGrouper.group([container("a"), container("b")], by: .none)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].title, "")
        XCTAssertEqual(names(groups), [["a", "b"]])
        XCTAssertTrue(ListGrouper.group([ContainerInfo](), by: .none).isEmpty)
    }

    func testMachineThisMacFirstThenExternalByLabel() {
        let list = [
            container("z1", machine: "zeta", engine: .docker, runtime: .docker),
            container("a1", machine: "alpha", engine: .colima, runtime: .docker),
            container("m1"),
            container("z2", machine: "zeta", engine: .docker, runtime: .docker),
            container("m2"),
        ]
        let groups = ListGrouper.group(list, by: .machine)
        XCTAssertEqual(Array(groups.map(\.title).dropFirst()), ["alpha", "zeta"])
        XCTAssertEqual(groups[0].id, "machine:local")
        XCTAssertEqual(names(groups), [["m1", "m2"], ["a1"], ["z1", "z2"]], "input order kept inside a section")
        XCTAssertEqual(groups.map(\.count), [2, 1, 2])
    }

    func testRuntimeFollowsEngineOrder() {
        let list = [
            container("c", machine: "s", engine: .colima, runtime: .docker),
            container("d", runtime: .docker),
            container("a"),
        ]
        XCTAssertEqual(ListGrouper.group(list, by: .runtime).map(\.title), ["Apple", "Docker", "Colima"])
    }

    func testStatusRunningBeforeStopped() {
        let list = [container("s1", running: false), container("r1"), container("s2", running: false)]
        let groups = ListGrouper.group(list, by: .status)
        XCTAssertEqual(groups.map(\.id), ["status:running", "status:stopped"])
        XCTAssertEqual(names(groups), [["r1"], ["s1", "s2"]])
    }

    func testComposeProjectsAlphabeticalWithoutProjectLast() {
        let list = [container("x"), container("b1", project: "beta"), container("a1", project: "alpha"), container("b2", project: "beta")]
        let groups = ListGrouper.group(list, by: .compose)
        XCTAssertEqual(groups.map(\.id), ["compose:alpha", "compose:beta", "compose:"])
        XCTAssertEqual(names(groups), [["a1"], ["b1", "b2"], ["x"]])
    }

    func testImageGroupsByReference() {
        let list = [container("a", image: "nginx:alpine"), container("b", image: "redis"), container("c", image: "nginx:alpine")]
        let groups = ListGrouper.group(list, by: .image)
        XCTAssertEqual(groups.map(\.title), ["nginx:alpine", "redis"])
        XCTAssertEqual(names(groups), [["a", "c"], ["b"]])
    }

    func testNetworksAndVolumesGroupByMachineAndRuntimeOnly() {
        let nets = [
            NetworkEntry(id: "1", reference: "wg0", name: "wg0", kind: .wireguard),
            NetworkEntry(id: "2", reference: "bridge", name: "bridge", kind: .docker),
            NetworkEntry(id: "3", reference: "default", name: "default", kind: .apple),
        ]
        XCTAssertEqual(ListGrouper.group(nets, by: .runtime).map(\.title), ["Apple", "Docker", "WireGuard"])
        XCTAssertEqual(ListGrouper.group(nets, by: .machine).count, 1)
        XCTAssertNil(nets[0].groupKey(for: .status), "no status for a network")

        let vols = [
            VolumeEntry(id: "a", reference: "a", name: "a", kind: .docker).with(runtimeID: "machine:s", machineLabel: "studio", engine: .colima),
            VolumeEntry(id: "b", reference: "b", name: "b", kind: .apple),
        ]
        XCTAssertEqual(ListGrouper.group(vols, by: .machine).map(\.title).last, "studio")
        XCTAssertEqual(ListGrouper.group(vols, by: .runtime).map(\.title), ["Apple", "Colima"])
    }

    func testSearchAndFiltersComposeBeforeGrouping() {
        let list = [container("web", machine: "studio", engine: .colima, runtime: .docker), container("db"), container("web2")]
        let filtered = ContainerSourceFilter.apply(machine: .machine("studio"), engine: nil, to: list)
            + list.filter { $0.matchesSearch("web2") }
        let groups = ListGrouper.group(filtered, by: .machine)
        XCTAssertEqual(groups.map(\.count), [1, 1])
    }

    func testRestrictedFallsBackToNone() {
        XCTAssertEqual(ListGrouping.status.restricted(to: ListGrouping.simple), .none)
        XCTAssertEqual(ListGrouping.runtime.restricted(to: ListGrouping.simple), .runtime)
        XCTAssertEqual(ListGrouping(rawValue: "machine"), .machine)
    }

    func testCollapsedGroupsRoundTrip() {
        var stored = ""
        stored = CollapsedGroups.toggled("containers|machine:studio", in: stored)
        stored = CollapsedGroups.toggled("networks|runtime:docker", in: stored)
        XCTAssertTrue(CollapsedGroups.isCollapsed("containers|machine:studio", in: stored))
        XCTAssertFalse(CollapsedGroups.isCollapsed("containers|machine:local", in: stored))
        stored = CollapsedGroups.toggled("containers|machine:studio", in: stored)
        XCTAssertFalse(CollapsedGroups.isCollapsed("containers|machine:studio", in: stored))
        XCTAssertTrue(CollapsedGroups.isCollapsed("networks|runtime:docker", in: stored))
    }
}
