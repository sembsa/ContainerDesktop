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

    func testSetupScriptInstallsTheDisplayHelperFromTheCD() {
        XCTAssertTrue(WindowsSetupMedia.setupScript().contains(
            #"-File "%~dp0display-helper-install.ps1""#))
    }

    /// The helper reads what the host writes, and the installer copies the
    /// file the host checks for — three files that have to agree.
    func testDisplayHelperAgreesWithTheHost() throws {
        let tools = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "ContainerGUI/Resources/GuestTools")
        let helper = try String(contentsOf: tools.appending(path: WindowsDisplayHelper.helperFile), encoding: .utf8)
        let installer = try String(contentsOf: tools.appending(path: WindowsDisplayHelper.installerFile), encoding: .utf8)
        XCTAssertTrue(WindowsDisplayHelper.requestPath.hasSuffix(#"\display-request.txt"#))
        XCTAssertTrue(helper.contains(#"Path.Combine(dir, "display-request.txt")"#))
        XCTAssertTrue(helper.contains(#"Regex.Match(text, @"^(\d+)x(\d+)")"#))
        // Add-Type -OutputType WindowsApplication needs an entry point.
        XCTAssertTrue(helper.contains("public static void Main()"))
        XCTAssertEqual(WindowsDisplayHelper.requestText(width: 1600, height: 1000, id: "a1"), "1600x1000 a1")
        XCTAssertTrue(installer.contains("$dst = '\(WindowsDisplayHelper.guestDirectory)'"))
        XCTAssertTrue(installer.contains("'\(WindowsDisplayHelper.helperFile)'"))
        // The installer prints this last; install(on:) treats its absence as failure.
        XCTAssertTrue(installer.hasSuffix("\"installed\"\n"))
        XCTAssertEqual(WindowsDisplayHelper.installCommand,
                       #"powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File C:\Windows\Temp\display-helper-install.ps1"#)
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
        var vm = VirtualMachine(name: "w", extraDrives: drives)
        let paths = QEMULauncher.paths(for: URL(fileURLWithPath: "/v/w"))
        let install = QEMULauncher.arguments(for: vm, paths: paths, vncDisplay: 1)
        XCTAssertTrue(install.contains("nvme,drive=d0,serial=cd0,bootindex=1"))
        XCTAssertTrue(install.contains("usb-storage,drive=x0,removable=on,bootindex=2"))
        XCTAssertTrue(install.contains("usb-storage,drive=x1,removable=on"))
        XCTAssertTrue(install.contains("ramfb"))
        // Never both: Windows would get two screens and VNC shows the first.
        vm.display = .virtioGPU
        let normal = QEMULauncher.arguments(for: vm, paths: paths, vncDisplay: 1)
        XCTAssertTrue(normal.contains("virtio-gpu-pci,xres=1280,yres=800"))
        XCTAssertFalse(normal.contains("ramfb"))
    }
}
