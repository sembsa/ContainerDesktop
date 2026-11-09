import AppKit
import SwiftUI

/// Shows a VNC framebuffer and sends the mouse and keyboard back to it.
///
/// The image is set straight on the layer with aspect-fit, so a window of any
/// shape shows the whole screen; pointer positions are mapped back through the
/// same fitted rectangle.
@MainActor
final class RFBDisplayView: NSView {

    var client: RFBClient?
    private(set) var framebufferSize = CGSize.zero
    private var buttons: UInt8 = 0
    /// What each held key sent on the way down, so the release matches even if
    /// Shift was let go first (otherwise "A" goes down and "a" comes up).
    private var pressed: [UInt16: UInt32] = [:]
    private var heldModifiers: Set<UInt16> = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.contentsGravity = .resizeAspect
        layer?.magnificationFilter = .linear
    }

    required init?(coder: NSCoder) { fatalError("not used from a nib") }

    func show(_ image: CGImage) {
        framebufferSize = CGSize(width: image.width, height: image.height)
        layer?.contents = image
    }

    // MARK: - Mouse

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    /// Where the fitted image sits inside the view.
    private var imageRect: CGRect {
        guard framebufferSize.width > 0, framebufferSize.height > 0 else { return .zero }
        let scale = min(bounds.width / framebufferSize.width, bounds.height / framebufferSize.height)
        let size = CGSize(width: framebufferSize.width * scale, height: framebufferSize.height * scale)
        return CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    private func sendPointer(_ event: NSEvent) {
        let rect = imageRect
        guard rect.width > 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        // AppKit's y grows upwards, the framebuffer's downwards.
        let x = (point.x - rect.minX) / rect.width * framebufferSize.width
        let y = (rect.maxY - point.y) / rect.height * framebufferSize.height
        client?.sendPointer(
            buttons: buttons,
            x: Int(min(max(x, 0), framebufferSize.width - 1)),
            y: Int(min(max(y, 0), framebufferSize.height - 1))
        )
    }

    private func press(_ bit: UInt8, _ event: NSEvent, down: Bool) {
        if down { buttons |= bit } else { buttons &= ~bit }
        sendPointer(event)
    }

    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); press(1, event, down: true) }
    override func mouseUp(with event: NSEvent) { press(1, event, down: false) }
    override func rightMouseDown(with event: NSEvent) { press(4, event, down: true) }
    override func rightMouseUp(with event: NSEvent) { press(4, event, down: false) }
    override func otherMouseDown(with event: NSEvent) { press(2, event, down: true) }
    override func otherMouseUp(with event: NSEvent) { press(2, event, down: false) }
    override func mouseMoved(with event: NSEvent) { sendPointer(event) }
    override func mouseDragged(with event: NSEvent) { sendPointer(event) }
    override func rightMouseDragged(with event: NSEvent) { sendPointer(event) }
    override func otherMouseDragged(with event: NSEvent) { sendPointer(event) }

    override func scrollWheel(with event: NSEvent) {
        guard event.scrollingDeltaY != 0 else { return }
        // A wheel step is a press and release of button 4 (up) or 5 (down).
        let bit: UInt8 = event.scrollingDeltaY > 0 ? 8 : 16
        press(bit, event, down: true)
        press(bit, event, down: false)
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        guard let keysym = RFBKeys.keysym(keyCode: event.keyCode, charactersIgnoringModifiers: event.charactersIgnoringModifiers) else { return }
        pressed[event.keyCode] = keysym
        client?.sendKey(keysym, down: true)
    }

    override func keyUp(with event: NSEvent) {
        guard let keysym = pressed.removeValue(forKey: event.keyCode) else { return }
        client?.sendKey(keysym, down: false)
    }

    override func flagsChanged(with event: NSEvent) {
        guard let modifier = RFBKeys.modifiers[event.keyCode] else { return }
        let down = event.modifierFlags.contains(modifier.flag) && !heldModifiers.contains(event.keyCode)
        if down { heldModifiers.insert(event.keyCode) } else { heldModifiers.remove(event.keyCode) }
        client?.sendKey(modifier.keysym, down: down)
    }

    /// Cmd shortcuts reach this before `keyDown`, and AppKit never delivers their
    /// key-up — so they are sent as a complete press here. Cmd+W and Cmd+Q stay
    /// with the Mac so the window can still be closed and the app quit.
    /// shortcut: every other Cmd combination goes to the guest; offer a toggle if
    /// someone misses a Mac shortcut inside this window.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.type == .keyDown else { return false }
        if event.modifierFlags.contains(.command), ["w", "q"].contains(event.charactersIgnoringModifiers?.lowercased()) {
            return false
        }
        guard let keysym = RFBKeys.keysym(keyCode: event.keyCode, charactersIgnoringModifiers: event.charactersIgnoringModifiers) else { return false }
        client?.sendKey(keysym, down: true)
        client?.sendKey(keysym, down: false)
        return true
    }

    /// Leaving the window must not leave a key held down in the guest.
    override func resignFirstResponder() -> Bool {
        releaseEverything()
        return super.resignFirstResponder()
    }

    func releaseEverything() {
        for keysym in pressed.values { client?.sendKey(keysym, down: false) }
        for code in heldModifiers { if let m = RFBKeys.modifiers[code] { client?.sendKey(m.keysym, down: false) } }
        pressed.removeAll()
        heldModifiers.removeAll()
    }
}

/// Hosts the session's view; the session owns it so frames never pass through SwiftUI state.
struct RFBDisplay: NSViewRepresentable {
    let view: RFBDisplayView
    func makeNSView(context: Context) -> RFBDisplayView { view }
    func updateNSView(_ nsView: RFBDisplayView, context: Context) {}
}
