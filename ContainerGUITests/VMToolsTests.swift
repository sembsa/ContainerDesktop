import XCTest

final class VMToolsTests: XCTestCase {

    private let shift: UInt32 = 0xffe1

    private func down(_ k: UInt32) -> VMInputStep { .key(k, down: true) }
    private func up(_ k: UInt32) -> VMInputStep { .key(k, down: false) }

    // MARK: - Typing

    func testLowercaseAndDigitsNeedNoShift() {
        let typing = VMInput.typing("a1")
        XCTAssertEqual(typing.steps, [down(0x61), up(0x61), down(0x31), up(0x31)])
        XCTAssertTrue(typing.nonASCII.isEmpty)
    }

    func testUppercaseAndShiftedSymbolsAreWrappedInShift() {
        for character in "AZ~!@#$%^&*()_+{}|:\"<>?" {
            let keysym = character.unicodeScalars.first!.value
            XCTAssertEqual(VMInput.typing(String(character)).steps,
                           [down(shift), down(keysym), up(keysym), up(shift)], "\(character)")
        }
        // Unshifted punctuation on a US layout stays bare.
        for character in "-=[]\\;',./` " {
            XCTAssertEqual(VMInput.typing(String(character)).steps.count, 2, "\(character)")
        }
    }

    func testNewlinesBecomeReturn() {
        XCTAssertEqual(VMInput.typing("\n").steps, [down(0xff0d), up(0xff0d)])
        XCTAssertEqual(VMInput.typing("\r\n").steps, [down(0xff0d), up(0xff0d)])
        XCTAssertEqual(VMInput.typing("\t").steps, [down(0xff09), up(0xff09)])
    }

    func testNonASCIIIsSentButReported() {
        let typing = VMInput.typing("aą")
        XCTAssertEqual(typing.nonASCII, ["ą"])
        XCTAssertEqual(typing.steps.suffix(2), [down(0x0100_0105), up(0x0100_0105)])
        XCTAssertEqual(VMInput.typing("é").steps, [down(0xe9), up(0xe9)])
    }

    // MARK: - Combos

    func testComboPressesInOrderAndReleasesInReverse() throws {
        XCTAssertEqual(try VMInput.combo("ctrl+alt+delete"),
                       [down(0xffe3), down(0xffe9), down(0xffff), up(0xffff), up(0xffe9), up(0xffe3)])
        XCTAssertEqual(try VMInput.combo("Win+R"), [down(0xffeb), down(0x72), up(0x72), up(0xffeb)])
        XCTAssertEqual(try VMInput.combo("f5"), [down(0xffc2), up(0xffc2)])
        XCTAssertEqual(try VMInput.combo("alt + f4"), [down(0xffe9), down(0xffc1), up(0xffc1), up(0xffe9)])
        XCTAssertEqual(try VMInput.combo("enter"), [down(0xff0d), up(0xff0d)])
        XCTAssertEqual(try VMInput.combo("esc"), [down(0xff1b), up(0xff1b)])
    }

    func testBadCombosAreInvalidParams() {
        for spec in ["", "ctrl+", "ctrl++", "hyper+x", "ą"] {
            XCTAssertThrowsError(try VMInput.combo(spec), spec) { XCTAssertTrue($0 is InvalidParams, spec) }
        }
    }

    // MARK: - Clicks

    func testClickMovesThenPressesAndReleases() throws {
        XCTAssertEqual(VMInput.click(x: 10, y: 20, buttons: 1, double: false), [
            .pointer(buttons: 0, x: 10, y: 20), .wait(milliseconds: 50),
            .pointer(buttons: 1, x: 10, y: 20), .wait(milliseconds: 50), .pointer(buttons: 0, x: 10, y: 20),
        ])
        let double = VMInput.click(x: 1, y: 2, buttons: try VMInput.buttonMask("right"), double: true)
        XCTAssertEqual(double.filter { $0 == .pointer(buttons: 4, x: 1, y: 2) }.count, 2)
        XCTAssertEqual(double.last, .pointer(buttons: 0, x: 1, y: 2), "ends with every button up")
        XCTAssertEqual(try VMInput.buttonMask("middle"), 2)
        XCTAssertThrowsError(try VMInput.buttonMask("fourth"))
    }

    // MARK: - Opt-in

    private func makeRoot(_ machines: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "vmtools-\(UUID().uuidString)")
        for (id, json) in machines {
            let dir = root.appending(path: id)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(json.utf8).write(to: dir.appending(path: "vm.json"))
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testAMachineWithoutAgentControlIsRefusedWithHowToEnableIt() throws {
        let root = try makeRoot([
            "old": #"{"name":"Old"}"#,
            "off": #"{"name":"Off","agentControl":false}"#,
            "on": #"{"name":"On","agentControl":true}"#,
        ])
        for id in ["old", "off", "Off"] {
            XCTAssertThrowsError(try VMTools.machine(id, in: root)) { error in
                let message = (error as? ToolFailure)?.message ?? ""
                XCTAssertTrue(message.contains("Allow the AI agent to control this machine"), message)
            }
        }
        XCTAssertEqual(try VMTools.machine("on", in: root).id, "on")
        XCTAssertEqual(try VMTools.machine("On", in: root).id, "on", "found by display name too")
        XCTAssertEqual(try VMTools.machine("old", in: root, requireControl: false).agentControl, false)
        XCTAssertThrowsError(try VMTools.machine("missing", in: root))
    }

    func testAgentControlSurvivesASaveAndDefaultsOff() throws {
        let root = try makeRoot(["m": #"{"name":"M","vncPort":5903}"#])
        let dir = root.appending(path: "m")
        var vm = try XCTUnwrap(VirtualMachineStore.load(dir))
        XCTAssertFalse(vm.agentControl)
        vm.agentControl = true
        try vm.save(to: dir)
        let reloaded = try XCTUnwrap(VirtualMachineStore.load(dir))
        XCTAssertTrue(reloaded.agentControl)
        XCTAssertEqual(reloaded.vncPort, 5903)
    }

    // MARK: - Host paths

    func testHostPathsOutsideHomeAreRefused() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        let outside = FileManager.default.temporaryDirectory.appending(path: "outside-\(UUID().uuidString).txt")
        try Data("x".utf8).write(to: outside)
        addTeardownBlock { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: home.appending(path: "link.txt"), withDestinationURL: outside)

        XCTAssertNoThrow(try VMTools.hostPath(home.appending(path: "new.txt").path, home: home.path))
        XCTAssertThrowsError(try VMTools.hostPath(outside.path, home: home.path))
        XCTAssertThrowsError(try VMTools.hostPath(home.path + "/../escape.txt", home: home.path))
        XCTAssertThrowsError(try VMTools.hostPath(home.appending(path: "link.txt").path, home: home.path), "a symlink out is followed")
        XCTAssertThrowsError(try VMTools.hostPath("relative.txt", home: home.path))
    }

    func testScriptPrologueSwitchesToUTF8() {
        XCTAssertEqual(VMTools.windowsScript("ver"), "@echo off\r\nchcp 65001 >nul\r\nver")
    }
}
