import XCTest

/// Where a downloaded entry is written on the host, exercised against a real
/// filesystem.
///
/// This exists because an earlier version treated the destination *directory*
/// the file browser hands it as a target *path*, and cleared it before writing
/// — which deleted every file the user had in that folder. The save panel
/// yields a directory, so that is the case these tests lead with.
final class ContainerFileTransferPlacementTests: XCTestCase {

    private var root: URL!
    private var workspace: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("placement-" + UUID().uuidString)
        workspace = root.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeFile(_ url: URL, _ contents: String) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private func read(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - The regression

    func testDownloadingIntoADirectoryLeavesEverythingElseInItAlone() throws {
        // The exact shape of the bug: the destination is a folder the user
        // already keeps files in.
        let destination = root.appendingPathComponent("Biurko")
        try makeFile(destination.appendingPathComponent("umowa.pdf"), "ważne")
        try makeFile(destination.appendingPathComponent("zdjecie.png"), "też ważne")
        try makeFile(destination.appendingPathComponent("podkatalog/notatki.txt"), "i to")

        let produced = workspace.appendingPathComponent("pobrany.txt")
        try makeFile(produced, "nowy")

        try ContainerFileTransfer.place(
            produced, named: "pobrany.txt", at: destination, backupDirectory: workspace
        )

        XCTAssertEqual(try read(destination.appendingPathComponent("umowa.pdf")), "ważne")
        XCTAssertEqual(try read(destination.appendingPathComponent("zdjecie.png")), "też ważne")
        XCTAssertEqual(try read(destination.appendingPathComponent("podkatalog/notatki.txt")), "i to")
        XCTAssertEqual(try read(destination.appendingPathComponent("pobrany.txt")), "nowy")
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: destination.path).count, 4
        )
    }

    func testTheDestinationDirectoryItselfIsNeverReplaced() throws {
        let destination = root.appendingPathComponent("Biurko")
        try makeFile(destination.appendingPathComponent("plik.txt"), "zostaje")

        let produced = workspace.appendingPathComponent("pobrany.txt")
        try makeFile(produced, "nowy")

        try ContainerFileTransfer.place(
            produced, named: "pobrany.txt", at: destination, backupDirectory: workspace
        )

        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue, "katalog docelowy zamieniono w plik")
    }

    // MARK: - A full target path

    func testAFullTargetPathIsUsedVerbatim() throws {
        let target = root.appendingPathComponent("gdzies/plik.txt")
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let produced = workspace.appendingPathComponent("plik.txt")
        try makeFile(produced, "treść")

        try ContainerFileTransfer.place(
            produced, named: "plik.txt", at: target, backupDirectory: workspace
        )

        XCTAssertEqual(try read(target), "treść")
    }

    func testAnExistingFileAtTheTargetIsReplaced() throws {
        // Overwriting a same-named file is what `container cp` does too.
        let target = root.appendingPathComponent("plik.txt")
        try makeFile(target, "stare")
        let produced = workspace.appendingPathComponent("plik.txt")
        try makeFile(produced, "nowe")

        try ContainerFileTransfer.place(
            produced, named: "plik.txt", at: target, backupDirectory: workspace
        )

        XCTAssertEqual(try read(target), "nowe")
    }

    // MARK: - Refusing to destroy a directory

    func testADirectoryInTheWayIsReportedRatherThanDeleted() throws {
        let destination = root.appendingPathComponent("Biurko")
        let clash = destination.appendingPathComponent("dane")
        try makeFile(clash.appendingPathComponent("w-srodku.txt"), "nie kasuj mnie")

        let produced = workspace.appendingPathComponent("dane")
        try makeFile(produced, "pobrane")

        XCTAssertThrowsError(
            try ContainerFileTransfer.place(
                produced, named: "dane", at: destination, backupDirectory: workspace
            )
        )
        XCTAssertEqual(try read(clash.appendingPathComponent("w-srodku.txt")), "nie kasuj mnie")
    }

    // MARK: - Target resolution on its own

    func testTargetResolution() {
        let destination = URL(fileURLWithPath: "/Users/me/Desktop")
        XCTAssertEqual(
            ContainerFileTransfer.targetURL(
                for: "a.txt", requestedDestination: destination, destinationIsDirectory: true
            ).path,
            "/Users/me/Desktop/a.txt"
        )
        XCTAssertEqual(
            ContainerFileTransfer.targetURL(
                for: "a.txt", requestedDestination: destination, destinationIsDirectory: false
            ).path,
            "/Users/me/Desktop"
        )
    }
}
