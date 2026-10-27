import XCTest

/// Naming and finding a container's snapshots.
final class ContainerSnapshotsTests: XCTestCase {

    private func image(_ reference: String) throws -> ImageInfo {
        let json = """
        {"id":"\(reference)","configuration":{"name":"\(reference)",
         "descriptor":{"digest":"sha256:00","size":1}}}
        """
        return try JSONDecoder().decode(ImageInfo.self, from: Data(json.utf8))
    }

    func testAContainerNameBecomesAValidRepository() {
        // Uppercase and anything but alphanumerics are not allowed in a repository.
        XCTAssertEqual(ContainerSnapshots.repository(for: "Shop_DB.main"), "localhost/snapshots/shop-db-main")
    }

    func testTheReferenceCarriesItsOwnTimestamp() {
        let date = Date(timeIntervalSince1970: 1_790_000_000)  // 2026-09-21 14:13:20 UTC
        let reference = ContainerSnapshots.reference(for: "web", at: date)
        XCTAssertEqual(reference, "localhost/snapshots/web:20260921-141320")
        XCTAssertEqual(ContainerSnapshots.date(of: reference), date)
    }

    func testOnlyThisContainersSnapshotsNewestFirst() throws {
        let images = try [
            "localhost/snapshots/web:20260921-141320",
            "localhost/snapshots/web2:20260922-090000",  // must not leak into web's history
            "docker.io/library/nginx:latest",
            "localhost/snapshots/web:20260925-080000",
        ].map(image)
        XCTAssertEqual(
            ContainerSnapshots.snapshots(for: "web", in: images).map(\.reference),
            ["localhost/snapshots/web:20260925-080000", "localhost/snapshots/web:20260921-141320"]
        )
    }

    func testANonSnapshotTagHasNoDate() {
        XCTAssertNil(ContainerSnapshots.date(of: "docker.io/library/nginx:latest"))
    }
}
