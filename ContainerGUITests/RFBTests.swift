import XCTest
import AppKit

/// The VNC client's pure parts: authentication, pixel placement and key mapping.
/// The network half was verified live against QEMU's VNC server.
final class RFBTests: XCTestCase {

    /// Reference computed independently with
    /// `openssl enc -des-ecb -K 8646c6264ccc2cac -nopad` (the password's bytes
    /// bit-reversed), so this does not check the implementation against itself.
    func testVNCAuthMatchesDESWithBitReversedKey() {
        let challenge = (0..<16).map { UInt8($0) }
        let response = RFB.vncAuthResponse(challenge: challenge, password: "abcd2345")
        XCTAssertEqual(hex(response), "46b126b200bdf046948993ef0d81c52b")
    }

    func testOnlyTheFirstEightPasswordCharactersCount() {
        let challenge = [UInt8](repeating: 7, count: 16)
        XCTAssertEqual(
            RFB.vncAuthResponse(challenge: challenge, password: "abcd2345"),
            RFB.vncAuthResponse(challenge: challenge, password: "abcd2345-ignored")
        )
    }

    func testRawRectangleLandsAtItsPosition() {
        var fb = RFBFramebuffer(width: 4, height: 3)
        fb.applyRaw(x: 1, y: 1, w: 2, h: 1, data: [1, 1, 1, 1, 2, 2, 2, 2])
        XCTAssertEqual(pixel(fb, 1, 1), 1)
        XCTAssertEqual(pixel(fb, 2, 1), 2)
        XCTAssertEqual(pixel(fb, 0, 1), 0)
        XCTAssertEqual(pixel(fb, 3, 1), 0)
    }

    func testRectangleReachingPastTheEdgeIsClippedNotFatal() {
        var fb = RFBFramebuffer(width: 2, height: 2)
        fb.applyRaw(x: 1, y: 1, w: 3, h: 3, data: [UInt8](repeating: 9, count: 3 * 3 * 4))
        XCTAssertEqual(pixel(fb, 1, 1), 9)
        XCTAssertEqual(pixel(fb, 0, 0), 0)
        XCTAssertEqual(fb.pixels.count, 2 * 2 * 4)
    }

    func testCopyRectHandlesOverlap() {
        var fb = RFBFramebuffer(width: 3, height: 1)
        fb.applyRaw(x: 0, y: 0, w: 3, h: 1, data: [1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3])
        fb.copyRect(fromX: 0, fromY: 0, x: 1, y: 0, w: 2, h: 1)
        XCTAssertEqual([pixel(fb, 0, 0), pixel(fb, 1, 0), pixel(fb, 2, 0)], [1, 1, 2])
    }

    func testFramebufferBecomesAnImageOfTheSameSize() {
        let image = RFBFramebuffer(width: 5, height: 3).makeImage()
        XCTAssertEqual(image?.width, 5)
        XCTAssertEqual(image?.height, 3)
    }

    func testKeysymsForPrintableAndSpecialKeys() {
        XCTAssertEqual(RFBKeys.keysym(keyCode: 0, charactersIgnoringModifiers: "a"), 0x61)
        XCTAssertEqual(RFBKeys.keysym(keyCode: 41, charactersIgnoringModifiers: ";"), 0x3b)
        XCTAssertEqual(RFBKeys.keysym(keyCode: 36, charactersIgnoringModifiers: "\r"), 0xff0d)
        XCTAssertEqual(RFBKeys.keysym(keyCode: 53, charactersIgnoringModifiers: "\u{1b}"), 0xff1b)
        // Past Latin-1, X11 keysyms are the code point plus 0x01000000.
        XCTAssertEqual(RFBKeys.keysym(keyCode: 0, charactersIgnoringModifiers: "ą"), 0x0100_0105)
    }

    func testCommandIsTheWindowsKeyAndRightOptionIsAltGr() {
        XCTAssertEqual(RFBKeys.modifiers[55]?.keysym, 0xffeb)
        XCTAssertEqual(RFBKeys.modifiers[61]?.keysym, 0xfe03)
    }

    func testPointerEventEncodesButtonsAndBigEndianCoordinates() {
        XCTAssertEqual(RFB.pointerEvent(buttons: 1, x: 298, y: 447), [5, 1, 0x01, 0x2a, 0x01, 0xbf])
    }

    /// RFC 6143 §7.5.7 + the community ExtendedDesktopSize spec: type 251,
    /// padding, size, one screen (id 0 at 0,0 covering everything, flags 0).
    func testSetDesktopSizeMessage() {
        XCTAssertEqual(RFB.setDesktopSize(width: 1600, height: 1000), [
            251, 0, 0x06, 0x40, 0x03, 0xe8, 1, 0,
            0, 0, 0, 0, 0, 0, 0, 0, 0x06, 0x40, 0x03, 0xe8, 0, 0, 0, 0,
        ])
    }

    func testExtendedDesktopSizeIsAnnouncedAndItsScreenListConsumed() {
        // -308 big-endian, or QEMU never accepts SetDesktopSize.
        XCTAssertTrue(hex(RFB.setEncodings).contains("fffffecc"))
        XCTAssertEqual(RFB.extendedDesktopSizeTrailer([2, 0, 0, 0]), 32)
        XCTAssertEqual(RFB.extendedDesktopSizeTrailer([0, 0, 0, 0]), 0)
    }

    func testDesktopSizeFittingAWindow() {
        XCTAssertTrue(RFB.desktopSize(fitting: CGSize(width: 1601.7, height: 1003)) == (1600, 1000))
        // Width to 16: viogpudo turns a 1720-wide mode into a 1728-wide framebuffer.
        XCTAssertTrue(RFB.desktopSize(fitting: CGSize(width: 1723, height: 970)) == (1712, 968))
        XCTAssertTrue(RFB.desktopSize(fitting: CGSize(width: 640, height: 400)) == (800, 600))
        XCTAssertTrue(RFB.desktopSize(fitting: CGSize(width: 5120, height: 2880)) == (3840, 2400))
    }

    func testVirtualMachineDirectoryScanSkipsFoldersWithoutDescription() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appending(path: "win/"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appending(path: "_tools/"), withIntermediateDirectories: true)
        try Data(#"{"name":"Win","os":"windows","vncPort":5907,"vncPassword":"x"}"#.utf8)
            .write(to: root.appending(path: "win/vm.json"))
        // A pidfile naming a process that cannot exist must not read as running.
        try Data("999999".utf8).write(to: root.appending(path: "win/qemu.pid"))

        let vms = VirtualMachineStore.scan(root)
        XCTAssertEqual(vms.map(\.id), ["win"])
        XCTAssertEqual(vms.first?.vncPort, 5907)
        XCTAssertEqual(vms.first?.isRunning, false)
    }

    private func pixel(_ fb: RFBFramebuffer, _ x: Int, _ y: Int) -> UInt8 { fb.pixels[(y * fb.width + x) * 4] }
    private func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }
}
