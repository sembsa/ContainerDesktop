import XCTest

/// Verifies the machine templates, the live field validation and the argv that
/// provisions a machine or brings its desktop up.
///
/// The desktop side was established against a live 1.3.0 machine before any of
/// this was written: a port listening inside a machine is reachable from the host
/// at the machine's own address with nothing published, `apk add` persists, and
/// `x11vnc` on `:1` answered the host with `RFB 003.008`.
final class MachineTemplateTests: XCTestCase {

    // MARK: - Templates

    func testEveryTemplateHasItsOwnIdentity() {
        let ids = MachineTemplate.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "powtórzone id szablonu")
        XCTAssertFalse(MachineTemplate.all.isEmpty)
    }

    func testTemplatesCanBeCreatedWithoutTypingAnything() {
        // The whole point: picking a template fills the form in.
        for template in MachineTemplate.all where template.id != MachineTemplate.custom.id {
            XCTAssertFalse(template.image.isEmpty, "\(template.id) bez obrazu")
            XCTAssertFalse(template.suggestedName.isEmpty, "\(template.id) bez proponowanej nazwy")
        }
    }

    func testTheCustomTemplateFillsInNothing() {
        XCTAssertTrue(MachineTemplate.custom.image.isEmpty)
        XCTAssertTrue(MachineTemplate.custom.packages.isEmpty)
        XCTAssertFalse(MachineTemplate.custom.providesDesktop)
    }

    func testTheDotnetTemplateInstallsTheSDK() {
        guard let template = MachineTemplate.all.first(where: { $0.id == "dotnet" }) else {
            return XCTFail("brak szablonu dotnet")
        }
        XCTAssertEqual(template.packages, ["dotnet10-sdk"])
        XCTAssertFalse(template.providesDesktop)
    }

    func testTheDesktopTemplateInstallsAnXServerAVNCServerAndAWindowManager() {
        guard let template = MachineTemplate.all.first(where: { $0.id == "desktop" }) else {
            return XCTFail("brak szablonu pulpitu")
        }
        XCTAssertTrue(template.providesDesktop)
        for package in ["x11vnc", "xvfb", "fluxbox", "xterm"] {
            XCTAssertTrue(template.packages.contains(package), "brak \(package)")
        }
    }

    // MARK: - Provisioning argv

    func testInstallingPackagesRunsApkAsRootBehindTheSeparator() {
        // apk carries its own flags, so `--` is mandatory — without it the CLI
        // eats them.
        let args = MachineCommands.install(packages: ["x11vnc", "xvfb"], on: "gui")
        XCTAssertEqual(
            args,
            ["machine", "run", "-n", "gui", "--root", "--",
             "apk", "add", "--no-progress", "x11vnc", "xvfb"]
        )
    }

    func testInstallingNothingIsNotACommand() {
        XCTAssertTrue(MachineCommands.install(packages: [], on: "gui").isEmpty)
    }

    func testAReadinessProbeIsThePlainestCommandThereIs() {
        // A machine reports created before `machine run` works on it: running
        // anything two seconds after `machine create` fails with "Operation not
        // supported by device". Provisioning therefore waits on this first.
        XCTAssertEqual(
            MachineCommands.readinessProbe(name: "gui"),
            ["machine", "run", "-n", "gui", "--", "/bin/true"]
        )
    }

    // MARK: - Desktop argv

    func testTheWholeDesktopRunsAsOneUser() {
        // All three as root, and that is not tidiness. With Xvfb owned by the host
        // user and x11vnc as root, x11vnc attaches to the display and then dies on
        // "X11 MIT Shared Memory Attach failed" — seen on a live machine, where
        // the port then refused connections while every command had reported
        // success.
        for args in [
            MachineCommands.desktopDisplayServer(name: "gui"),
            MachineCommands.desktopWindowManager(name: "gui"),
            MachineCommands.desktopVNCServer(name: "gui"),
        ] {
            XCTAssertTrue(args.contains("--root"), "brak --root w \(args)")
        }
    }

    func testTheDisplayServerStartsDetached() {
        let args = MachineCommands.desktopDisplayServer(name: "gui")
        XCTAssertEqual(
            args,
            ["machine", "run", "-n", "gui", "-d", "--root", "--",
             "Xvfb", ":1", "-screen", "0", "1440x900x24"]
        )
    }

    func testTheWindowManagerGetsItsDisplayThroughTheEnvironment() {
        // `-e DISPLAY=:1` rather than a shell assignment: `machine run -- sh -c`
        // swallows stdout, so shell wrapping is avoided throughout.
        let args = MachineCommands.desktopWindowManager(name: "gui")
        XCTAssertEqual(
            args,
            ["machine", "run", "-n", "gui", "-d", "--root", "-e", "DISPLAY=:1", "--", "fluxbox"]
        )
    }

    func testTheVNCServerReadsItsPasswordFromAFileInsideTheMachine() {
        let args = MachineCommands.desktopVNCServer(name: "gui")
        XCTAssertEqual(
            args,
            ["machine", "run", "-n", "gui", "-d", "--root", "--",
             "x11vnc", "-display", ":1", "-forever",
             "-rfbauth", MachineCommands.vncPasswordPath,
             "-rfbport", "5900", "-quiet"]
        )
    }

    func testThePasswordFileLivesInsideTheMachineNotInTheMountedHome() {
        // The host home is mounted rw by default, so anything under ~ would land
        // on the user's real disk.
        XCTAssertTrue(MachineCommands.vncPasswordPath.hasPrefix("/etc/"))
        XCTAssertFalse(MachineCommands.vncPasswordPath.contains("/Users/"))
    }

    func testStoringThePasswordGoesThroughX11vncItself() {
        let args = MachineCommands.desktopStorePassword(name: "gui", password: "abcd1234")
        XCTAssertEqual(
            args,
            ["machine", "run", "-n", "gui", "--root", "--",
             "x11vnc", "-storepasswd", "abcd1234", MachineCommands.vncPasswordPath]
        )
    }

    // MARK: - Password

    func testTheGeneratedPasswordIsExactlyEightCharacters() {
        // Classic VNC authentication is DES with an eight-byte key; x11vnc
        // silently truncates anything longer, so a longer password would read as
        // stronger while not being it.
        for _ in 0..<20 {
            XCTAssertEqual(MachineDesktop.generatePassword().count, 8)
        }
    }

    func testTheGeneratedPasswordAvoidsCharactersThatConfuseAShellOrAReader() {
        let allowed = Set("abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        for _ in 0..<20 {
            XCTAssertTrue(
                MachineDesktop.generatePassword().allSatisfy { allowed.contains($0) },
                "hasło zawiera znak spoza dozwolonego zbioru"
            )
        }
    }

    func testTwoPasswordsDiffer() {
        let passwords = Set((0..<20).map { _ in MachineDesktop.generatePassword() })
        XCTAssertGreaterThan(passwords.count, 1)
    }

    func testTheDesktopURLPointsAtTheMachinesOwnAddress() {
        // No port is published: the machine's address is reachable from the host
        // directly, which is what makes one click enough.
        XCTAssertEqual(
            MachineDesktop.screenSharingURL(host: "192.168.66.14")?.absoluteString,
            "vnc://192.168.66.14:5900"
        )
        XCTAssertNil(MachineDesktop.screenSharingURL(host: ""))
    }

    // MARK: - Live validation

    func testEmptyResourceFieldsAreValidBecauseTheCLIHasItsOwnDefaults() {
        XCTAssertNil(MachineFieldValidation.cpus(""))
        XCTAssertNil(MachineFieldValidation.memory(""))
        XCTAssertNil(MachineFieldValidation.kernelPath(""))
    }

    func testCPUsMustBeAWholePositiveNumber() {
        XCTAssertNil(MachineFieldValidation.cpus("4"))
        XCTAssertNotNil(MachineFieldValidation.cpus("0"))
        XCTAssertNotNil(MachineFieldValidation.cpus("-2"))
        XCTAssertNotNil(MachineFieldValidation.cpus("4.5"))
        XCTAssertNotNil(MachineFieldValidation.cpus("cztery"))
    }

    func testMemoryTakesTheSuffixesTheCLIDocuments() {
        for good in ["4G", "512M", "2048", "1T", "16G"] {
            XCTAssertNil(MachineFieldValidation.memory(good), "\(good) powinno przejść")
        }
        // The CLI documents K, M, G, T and P — not the binary spellings.
        for bad in ["4Gi", "4 GB", "0", "-1G", "duzo", "G4"] {
            XCTAssertNotNil(MachineFieldValidation.memory(bad), "\(bad) powinno odpaść")
        }
    }

    func testAKernelPathMustBeAbsoluteAndExist() {
        XCTAssertNil(MachineFieldValidation.kernelPath("/tmp/jest", exists: { _ in true }))
        XCTAssertNotNil(MachineFieldValidation.kernelPath("wzgledna/sciezka", exists: { _ in true }))
        XCTAssertNotNil(MachineFieldValidation.kernelPath("/tmp/nie-ma", exists: { _ in false }))
    }
}
