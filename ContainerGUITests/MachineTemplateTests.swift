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

    func testTheDesktopTemplateLeavesThePackagesToTheChosenEnvironment() {
        guard let template = MachineTemplate.all.first(where: { $0.id == "desktop" }) else {
            return XCTFail("brak szablonu pulpitu")
        }
        XCTAssertTrue(template.providesDesktop)
        // The environment decides what gets installed, so the template itself
        // names nothing.
        XCTAssertTrue(template.packages.isEmpty)
    }

    // MARK: - Graphical environments

    func testBothEnvironmentsBringAnXServerAndAVNCServer() {
        for environment in MachineDesktopEnvironment.allCases {
            for manager in [MachinePackageManager.apk, .apt] {
                XCTAssertTrue(environment.packages(for: manager).contains("xvfb"),
                              "\(environment)/\(manager) bez xvfb")
                XCTAssertTrue(environment.packages(for: manager).contains("x11vnc"),
                              "\(environment)/\(manager) bez x11vnc")
            }
            XCTAssertFalse(environment.startExecutable.isEmpty)
            XCTAssertFalse(environment.probeProcess.isEmpty)
        }
    }

    func testNoEnvironmentUsesFluxbox() {
        // fluxbox segfaults on Alpine aarch64 inside a machine: it reads its
        // config, prints the usual "Setting default value" lines and exits 139,
        // which left the VNC session showing a black screen — an X server with
        // nothing drawing on it.
        for environment in MachineDesktopEnvironment.allCases {
            for manager in [MachinePackageManager.apk, .apt] {
                XCTAssertFalse(environment.packages(for: manager).contains("fluxbox"))
            }
            XCTAssertNotEqual(environment.startExecutable, "fluxbox")
        }
    }

    func testIceWMIsTheLightOneAndNeedsATerminalOpeningForIt() {
        let ice = MachineDesktopEnvironment.iceWM
        XCTAssertEqual(ice.startExecutable, "icewm")
        XCTAssertEqual(ice.probeProcess, "icewm")
        XCTAssertTrue(ice.packages(for: .apk).contains("xterm"))
        // A window manager alone is a taskbar over an empty root window.
        XCTAssertFalse(ice.providesTerminal)
    }

    func testXfceStartsASessionAndBringsItsOwnTerminal() {
        let xfce = MachineDesktopEnvironment.xfce
        // `startxfce4`, not a bare window manager: it brings up the session,
        // the panel, the desktop and dbus. Verified on a live machine — xfwm4 is
        // what appears in the process list, which is why that is the probe.
        XCTAssertEqual(xfce.startExecutable, "startxfce4")
        XCTAssertEqual(xfce.probeProcess, "xfwm4")
        XCTAssertTrue(xfce.packages(for: .apk).contains("dbus"))
        XCTAssertTrue(xfce.providesTerminal)
    }

    func testTheDefaultEnvironmentIsTheSmallOne() {
        // 300 MB against 650 MB of packages.
        XCTAssertEqual(MachineDesktopEnvironment.default, .iceWM)
    }

    func testTheSessionCommandCarriesTheDisplayAndRunsAsRoot() {
        XCTAssertEqual(
            MachineCommands.desktopSession(name: "gui", environment: .xfce),
            ["machine", "run", "-n", "gui", "-d", "--root", "-e", "DISPLAY=:1", "--", "startxfce4"]
        )
    }

    func testAnEnvironmentIsRecognisedByItsOwnBinary() {
        XCTAssertEqual(
            MachineCommands.whichProbe(name: "gui", binary: "startxfce4"),
            ["machine", "run", "-n", "gui", "--", "which", "startxfce4"]
        )
        for environment in MachineDesktopEnvironment.allCases {
            XCTAssertFalse(environment.marker.isEmpty)
        }
    }

    // MARK: - Distributions

    func testUbuntuIsOfferedPlainAndWithADesktop() {
        let ubuntu = MachineTemplate.all.filter { $0.packageManager == .apt }
        XCTAssertEqual(ubuntu.count, 2, "Ubuntu zwykłe i z pulpitem")
        XCTAssertTrue(ubuntu.contains { !$0.providesDesktop })
        XCTAssertTrue(ubuntu.contains { $0.providesDesktop })
    }

    func testUbuntuNeedsItsBaseImageBuiltBecauseTheOfficialOneHasNoInit() {
        // A machine will not boot from an image without /sbin/init. Alpine's is a
        // busybox symlink; ubuntu:24.04 has no init at all — no systemd, no
        // busybox — and `machine create` fails with "container must be running".
        // So the base is built: ubuntu plus busybox-static linked as /sbin/init.
        // Verified: the built image boots and reports Ubuntu 24.04.4 LTS.
        for template in MachineTemplate.all where template.packageManager == .apt {
            guard let dockerfile = template.baseImageDockerfile else {
                return XCTFail("\(template.id) bez Dockerfile")
            }
            XCTAssertTrue(dockerfile.contains("FROM ubuntu:"))
            XCTAssertTrue(dockerfile.contains("/sbin/init"))
            XCTAssertTrue(dockerfile.contains("busybox"))
            XCTAssertFalse(template.image.isEmpty, "brak tagu budowanego obrazu")
        }
    }

    func testDebianIsNotOfferedAnyMore() {
        // It never worked: debian:bookworm-slim has no /sbin/init either, so the
        // template shipped broken. Ubuntu covers the apt world instead.
        XCTAssertFalse(MachineTemplate.all.contains { $0.id == "debian" })
    }

    func testAlpineTemplatesUseApk() {
        for template in MachineTemplate.all
        where template.image.hasPrefix("alpine") {
            XCTAssertEqual(template.packageManager, .apk)
        }
    }

    // MARK: - Package managers

    func testApkInstallsInOneCommand() {
        let commands = MachinePackageManager.apk.installCommands(
            packages: ["icewm", "xterm"], on: "gui"
        )
        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(
            commands[0],
            ["machine", "run", "-n", "gui", "--root", "--",
             "apk", "add", "--no-progress", "icewm", "xterm"]
        )
    }

    func testAptNeedsAnUpdateFirstAndMustNotAskQuestions() {
        let commands = MachinePackageManager.apt.installCommands(
            packages: ["icewm", "xterm"], on: "gui"
        )
        XCTAssertEqual(commands.count, 2, "update i install")
        XCTAssertEqual(
            commands[0],
            ["machine", "run", "-n", "gui", "--root", "--", "apt-get", "update"]
        )
        // Without DEBIAN_FRONTEND the install can stop on a prompt nobody can answer.
        XCTAssertTrue(commands[1].contains("DEBIAN_FRONTEND=noninteractive"))
        XCTAssertTrue(commands[1].contains("--no-install-recommends"))
        XCTAssertEqual(commands[1].suffix(2), ["icewm", "xterm"])
    }

    func testNeitherManagerInstallsNothing() {
        XCTAssertTrue(MachinePackageManager.apk.installCommands(packages: [], on: "gui").isEmpty)
        XCTAssertTrue(MachinePackageManager.apt.installCommands(packages: [], on: "gui").isEmpty)
    }

    func testXfceNeedsADifferentDbusPackageOnUbuntu() {
        // dbus-launch lives in dbus-x11 on Debian and Ubuntu; the Alpine package
        // is simply dbus. Verified: startxfce4 brought the session up on both.
        XCTAssertTrue(MachineDesktopEnvironment.xfce.packages(for: .apk).contains("dbus"))
        XCTAssertTrue(MachineDesktopEnvironment.xfce.packages(for: .apt).contains("dbus-x11"))
    }

    func testIceWMNeedsTheSamePackagesEverywhere() {
        XCTAssertEqual(
            MachineDesktopEnvironment.iceWM.packages(for: .apk),
            MachineDesktopEnvironment.iceWM.packages(for: .apt)
        )
    }

    // MARK: - Building a base image

    func testBuildingTheBaseImageTagsItAndPointsAtAContext() {
        let args = MachineCommands.buildBaseImage(
            tag: "containerdesktop/ubuntu-machine:24.04",
            contextDirectory: "/tmp/ctx"
        )
        XCTAssertEqual(args.first, "build")
        XCTAssertTrue(args.contains("--tag"))
        XCTAssertTrue(args.contains("containerdesktop/ubuntu-machine:24.04"))
        XCTAssertEqual(args.last, "/tmp/ctx")
    }

    // MARK: - Provisioning argv

    func testInstallingPackagesKeepsThemBehindTheSeparator() {
        // The package manager carries its own flags, so `--` is mandatory —
        // without it the CLI eats them.
        for manager in [MachinePackageManager.apk, .apt] {
            for command in manager.installCommands(packages: ["x11vnc"], on: "gui") {
                guard let separator = command.firstIndex(of: "--") else {
                    return XCTFail("brak separatora w \(command)")
                }
                XCTAssertLessThan(separator, command.count - 1)
            }
        }
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
            MachineCommands.desktopSession(name: "gui", environment: .iceWM),
            MachineCommands.desktopTerminal(name: "gui"),
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

    func testTheSessionGetsItsDisplayThroughTheEnvironmentVariable() {
        // `-e DISPLAY=:1` rather than a shell assignment: `machine run -- sh -c`
        // swallows stdout and loses exit codes, so shell wrapping is avoided.
        let args = MachineCommands.desktopSession(name: "gui", environment: .iceWM)
        XCTAssertEqual(
            args,
            ["machine", "run", "-n", "gui", "-d", "--root", "-e", "DISPLAY=:1", "--", "icewm"]
        )
    }

    func testTheDesktopOpensATerminalSoTheScreenIsNotBare() {
        // A window manager alone is a taskbar over an empty root window. The
        // first thing anyone connecting wants is a prompt.
        XCTAssertEqual(
            MachineCommands.desktopTerminal(name: "gui"),
            ["machine", "run", "-n", "gui", "-d", "--root", "-e", "DISPLAY=:1", "--", "xterm"]
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

    func testAProcessProbeIsADirectCommandNotAShellOne() {
        // Exit codes do not survive `/bin/sh -c` in a machine: `sh -c 'exit 3'`
        // reports 0, while a direct `/bin/false` reports 1. Any probe whose answer
        // is its exit code therefore has to be a plain executable.
        let args = MachineCommands.processProbe(name: "gui", process: "icewm")
        XCTAssertEqual(args, ["machine", "run", "-n", "gui", "--", "pgrep", "icewm"])
        XCTAssertFalse(args.contains("/bin/sh"))
        XCTAssertFalse(args.contains("-c"))
    }

    func testNoDesktopCommandGoesThroughAShell() {
        // Same reason, plus stdout is swallowed through `sh -c`.
        for args in [
            MachineCommands.desktopDisplayServer(name: "gui"),
            MachineCommands.desktopSession(name: "gui", environment: .iceWM),
            MachineCommands.desktopTerminal(name: "gui"),
            MachineCommands.desktopVNCServer(name: "gui"),
            MachineCommands.readinessProbe(name: "gui"),
        ] {
            XCTAssertFalse(args.contains("/bin/sh"), "shell w \(args)")
        }
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
