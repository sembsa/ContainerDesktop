import XCTest

/// The unattended-install media. The XML and scripts were proven by a full
/// install (test B); these pin what that run depended on.
final class WindowsSetupMediaTests: XCTestCase {
    private let options = WindowsSetupMedia.Options(
        vmName: "Windows 11 (test B)", username: "a<g>\"ent'", password: "Tb&<7-Kx92", locale: "pl-PL")

    func testCredentialsAreEscapedAndTheXMLParses() throws {
        let xml = WindowsSetupMedia.autounattendXML(options)
        XCTAssertTrue(xml.contains("<Value>Tb&amp;&lt;7-Kx92</Value>"))
        XCTAssertFalse(xml.contains("Tb&<"))
        let doc = try XMLDocument(xmlString: xml)
        let values = try doc.nodes(forXPath: "//*[local-name()='AutoLogon']/*[local-name()='Password']/*[local-name()='Value']")
        XCTAssertEqual(values.first?.stringValue, "Tb&<7-Kx92")
        let names = try doc.nodes(forXPath: "//*[local-name()='LocalAccount']/*[local-name()='Name']")
        XCTAssertEqual(names.first?.stringValue, "a<g>\"ent'")
    }

    func testLocaleAndKeyboard() throws {
        var o = options
        XCTAssertTrue(WindowsSetupMedia.autounattendXML(o).contains("<InputLocale>pl-PL</InputLocale>"))
        o.keyboard = "0415:00000415"
        let xml = WindowsSetupMedia.autounattendXML(o)
        XCTAssertEqual(xml.components(separatedBy: "<InputLocale>0415:00000415</InputLocale>").count - 1, 2)
        XCTAssertEqual(xml.components(separatedBy: "<UILanguage>pl-PL</UILanguage>").count - 1, 3)
    }

    func testComputerName() {
        XCTAssertEqual(WindowsSetupMedia.computerName(from: "Windows 11 (test B)"), "WINDOWS-11-TEST")
        XCTAssertEqual(WindowsSetupMedia.computerName(from: "dev"), "DEV")
        XCTAssertEqual(WindowsSetupMedia.computerName(from: "1234"), "WIN-VM")
        XCTAssertEqual(WindowsSetupMedia.computerName(from: "żółć"), "WIN-VM")
        XCTAssertEqual(WindowsSetupMedia.computerName(from: "abcdefghijklmn-xyz"), "ABCDEFGHIJKLMN")
    }

    func testLanguageFromLangIni() {
        let ini = "\r\n[Available UI Languages]\r\npl-pl = 3\r\n\r\n[Fallback Languages]\r\npl-pl = en-us\r\n"
        XCTAssertEqual(WindowsSetupMedia.language(fromLangIni: ini), "pl-PL")
        XCTAssertNil(WindowsSetupMedia.language(fromLangIni: "[Fallback Languages]\nen-us = en-us\n"))
    }

    func testSetupScriptIsCRLFAndInstallsTheAgent() {
        let s = WindowsSetupMedia.setupScript()
        XCTAssertFalse(s.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
        XCTAssertTrue(s.contains(#"call "%~dp0install.cmd""#))
        XCTAssertTrue(s.contains(#"viogpudo\w11\ARM64\viogpudo.inf"#))
    }

    /// The real resources, through ditto and hdiutil.
    func testBuildISOFromTheRepoResources() async throws {
        let tools = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "ContainerGUI/Resources/GuestTools")
        let iso = FileManager.default.temporaryDirectory.appending(path: "cdsetup-test-\(UUID().uuidString).iso")
        defer { try? FileManager.default.removeItem(at: iso) }
        try await WindowsSetupMedia.buildISO(options, output: iso, guestTools: tools)
        let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: iso.path)[.size] as? Int)
        XCTAssertGreaterThan(size, 9_000_000) // the unpacked agent is ~9.6 MB
    }

    func testInstallDrivesPutTheWindowsISOFirstAndAfterTheDisk() {
        let media = WindowsQEMUArguments.Media(
            windowsISO: URL(fileURLWithPath: "/i/win.iso"), setupISO: URL(fileURLWithPath: "/i/cd.iso"),
            virtioISO: URL(fileURLWithPath: "/i/virtio.iso"))
        let drives = WindowsQEMUArguments.installDrives(media)
        XCTAssertEqual(drives.map(\.path), ["/i/win.iso", "/i/cd.iso", "/i/virtio.iso"])
        XCTAssertTrue(drives.allSatisfy { $0.cdrom && $0.readOnly })
        // The launcher's disk is bootindex=1; the ISO has to come after it.
        let disk = QEMULauncher.arguments(for: VirtualMachine(name: "w"), paths: QEMULauncher.paths(for: URL(fileURLWithPath: "/v/w")), vncDisplay: 1)
        XCTAssertTrue(disk.contains("nvme,drive=d0,serial=cd0,bootindex=\(WindowsQEMUArguments.windowsISOBootIndex - 1)"))
        XCTAssertEqual(WindowsQEMUArguments.display(.normal), ["-device", "virtio-gpu-pci,xres=1280,yres=800"])
    }
}
