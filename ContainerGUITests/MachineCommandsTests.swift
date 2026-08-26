import XCTest

/// Verifies the `container machine` argv the app builds.
///
/// Every expectation here was read off `container machine … --help` and then
/// confirmed against a live 1.3.0 machine, because several of the CLI's rules are
/// not guessable: `--` is mandatory in front of a command that carries its own
/// flags, there is no `machine start` subcommand at all, and an empty `kernel=`
/// in `machine set` is meaningful rather than omittable.
final class MachineCommandsTests: XCTestCase {

    // MARK: - Create

    func testCreateNeedsOnlyAnImage() {
        let options = MachineCommands.CreateOptions(image: "alpine:3.22")
        XCTAssertEqual(MachineCommands.create(options), ["machine", "create", "alpine:3.22"])
    }

    func testCreatePassesEveryConfiguredField() {
        var options = MachineCommands.CreateOptions(image: "alpine:3.22")
        options.name = "builder"
        options.cpus = "4"
        options.memory = "8G"
        options.homeMount = .readOnly
        options.nestedVirtualization = true
        options.kernelPath = "/Users/me/vmlinux"
        options.platform = "linux/arm64"
        options.noBoot = true
        options.setDefault = true

        let args = MachineCommands.create(options)

        XCTAssertEqual(args.prefix(3), ["machine", "create", "alpine:3.22"])
        assertPair(args, "--name", "builder")
        assertPair(args, "--cpus", "4")
        assertPair(args, "--memory", "8G")
        assertPair(args, "--home-mount", "ro")
        assertPair(args, "--kernel", "/Users/me/vmlinux")
        assertPair(args, "--platform", "linux/arm64")
        // `--virtualization` takes no value on create, unlike `virtualization=` on set.
        XCTAssertTrue(args.contains("--virtualization"))
        XCTAssertTrue(args.contains("--no-boot"))
        XCTAssertTrue(args.contains("--set-default"))
    }

    func testCreateOmitsEmptyFieldsRatherThanSendingBlanks() {
        // A blank `--memory` is an error from the CLI, not a default.
        var options = MachineCommands.CreateOptions(image: "alpine:3.22")
        options.name = ""
        options.cpus = ""
        options.memory = ""
        options.kernelPath = ""
        options.platform = ""

        let args = MachineCommands.create(options)

        XCTAssertFalse(args.contains("--name"))
        XCTAssertFalse(args.contains("--cpus"))
        XCTAssertFalse(args.contains("--memory"))
        XCTAssertFalse(args.contains("--kernel"))
        XCTAssertFalse(args.contains("--platform"))
    }

    func testCreateLeavesTheDefaultHomeMountToTheCLI() {
        // rw is the CLI's own default; spelling it out adds noise to the command.
        let options = MachineCommands.CreateOptions(image: "alpine:3.22")
        XCTAssertEqual(options.homeMount, .readWrite)
        XCTAssertFalse(MachineCommands.create(options).contains("--home-mount"))
    }

    func testCreateOmitsVirtualizationWhenOff() {
        var options = MachineCommands.CreateOptions(image: "alpine:3.22")
        options.nestedVirtualization = false
        XCTAssertFalse(MachineCommands.create(options).contains("--virtualization"))
    }

    // MARK: - Set

    func testSetJoinsEachValueWithAnEqualsSign() {
        let args = MachineCommands.set(name: "builder", settings: [.cpus("2"), .memory("2G")])
        XCTAssertEqual(args, ["machine", "set", "-n", "builder", "cpus=2", "memory=2G"])
    }

    func testSetSpellsVirtualizationAsABoolean() {
        // On create it is a bare flag; on set it needs an explicit true/false.
        XCTAssertEqual(
            MachineCommands.set(name: "builder", settings: [.virtualization(true)]).last,
            "virtualization=true"
        )
        XCTAssertEqual(
            MachineCommands.set(name: "builder", settings: [.virtualization(false)]).last,
            "virtualization=false"
        )
    }

    func testSetKeepsAnEmptyKernelBecauseThatIsHowItResets() {
        // "Empty value resets to the system default" — dropping it would silently
        // do nothing instead.
        XCTAssertEqual(
            MachineCommands.set(name: "builder", settings: [.kernel("")]).last,
            "kernel="
        )
    }

    func testSetUsesTheCLISpellingOfHomeMount() {
        XCTAssertEqual(
            MachineCommands.set(name: "builder", settings: [.homeMount(.notMounted)]).last,
            "home-mount=none"
        )
    }

    func testSetWithoutSettingsIsNotACommand() {
        // Sending `machine set -n X` with nothing to set would be a no-op round trip.
        XCTAssertTrue(MachineCommands.set(name: "builder", settings: []).isEmpty)
    }

    // MARK: - Logs

    func testLogsTakesTheMachineAsATrailingPositional() {
        XCTAssertEqual(
            MachineCommands.logs(name: "builder", boot: false, follow: false, lines: nil),
            ["machine", "logs", "builder"]
        )
    }

    func testLogsCarriesBootFollowAndLineCount() {
        XCTAssertEqual(
            MachineCommands.logs(name: "builder", boot: true, follow: true, lines: 200),
            ["machine", "logs", "--boot", "-f", "-n", "200", "builder"]
        )
    }

    // MARK: - Memory round trip

    func testMemoryRendersBackIntoWhatTheCLITakes() {
        // `machine set memory=` takes 2G; the JSON reports 2147483648. Showing the
        // raw byte count in the field would make the form un-round-trippable.
        XCTAssertEqual(MachineCommands.memoryArgument(forBytes: 2_147_483_648), "2G")
        XCTAssertEqual(MachineCommands.memoryArgument(forBytes: 25_769_803_776), "24G")
    }

    func testMemoryFallsBackToMegabytesBelowAWholeGigabyte() {
        XCTAssertEqual(MachineCommands.memoryArgument(forBytes: 536_870_912), "512M")
    }

    func testMemoryKeepsAnAwkwardSizeExact() {
        // 1.5 GiB is neither a whole G nor a lie worth rounding — 1536M is both.
        XCTAssertEqual(MachineCommands.memoryArgument(forBytes: 1_610_612_736), "1536M")
    }

    func testMemoryHasNoValueWhenThereIsNothingToShow() {
        XCTAssertEqual(MachineCommands.memoryArgument(forBytes: nil), "")
        XCTAssertEqual(MachineCommands.memoryArgument(forBytes: 0), "")
    }

    // MARK: - Boot

    func testBootingAStoppedMachineGoesThroughRun() {
        // There is no `machine start`. `machine run` boots the machine if needed,
        // so a detached no-op command is what starts one without opening a shell.
        XCTAssertEqual(
            MachineCommands.boot(name: "builder"),
            ["machine", "run", "-n", "builder", "-d", "--", "/bin/true"]
        )
    }

    func testBootSeparatesTheCommandWithADoubleDash() {
        // Without `--`, `container machine run -n X uname -a` fails outright: the
        // command's own flags are eaten by the CLI's parser.
        let args = MachineCommands.boot(name: "builder")
        let separator = args.firstIndex(of: "--")
        XCTAssertNotNil(separator)
        if let separator {
            XCTAssertEqual(Array(args[(separator + 1)...]), ["/bin/true"])
        }
    }

    // MARK: - Helpers

    private func assertPair(
        _ args: [String],
        _ flag: String,
        _ value: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let index = args.firstIndex(of: flag) else {
            return XCTFail("brak flagi \(flag) w \(args)", file: file, line: line)
        }
        XCTAssertEqual(args[safe: index + 1], value, "\(flag)", file: file, line: line)
    }
}

private extension Array where Element == String {
    subscript(safe index: Int) -> String? {
        indices.contains(index) ? self[index] : nil
    }
}
