import AppKit

/// Mac key events → X11 keysyms, which is what RFB speaks.
///
/// QEMU turns each keysym back into a PC scancode, so modifiers have to arrive
/// as key presses of their own: a ":" is Shift held plus the ";" key, and the
/// guest only sees the Shift if it was sent. Modifiers therefore come from
/// `flagsChanged`, and printable keys send the character without modifiers.
enum RFBKeys {

    /// Non-printing keys, by Mac virtual key code.
    static let special: [UInt16: UInt32] = [
        36: 0xff0d, 76: 0xff0d,         // Return, keypad Enter
        48: 0xff09,                     // Tab
        51: 0xff08,                     // Backspace
        53: 0xff1b,                     // Escape
        117: 0xffff,                    // Forward delete
        115: 0xff50, 119: 0xff57,       // Home, End
        116: 0xff55, 121: 0xff56,       // Page up, Page down
        123: 0xff51, 124: 0xff53,       // Left, Right
        125: 0xff54, 126: 0xff52,       // Down, Up
        122: 0xffbe, 120: 0xffbf, 99: 0xffc0, 118: 0xffc1,   // F1–F4
        96: 0xffc2, 97: 0xffc3, 98: 0xffc4, 100: 0xffc5,     // F5–F8
        101: 0xffc6, 109: 0xffc7, 103: 0xffc8, 111: 0xffc9,  // F9–F12
    ]

    /// Modifier keys, by key code. Cmd is the Windows key, which is what a Mac
    /// keyboard's Cmd sits where. The right Option is AltGr, so a Polish layout
    /// in the guest types ą, ę, ł with it the way it would on a PC.
    static let modifiers: [UInt16: (keysym: UInt32, flag: NSEvent.ModifierFlags)] = [
        56: (0xffe1, .shift), 60: (0xffe2, .shift),
        59: (0xffe3, .control), 62: (0xffe4, .control),
        58: (0xffe9, .option), 61: (0xfe03, .option),   // Alt_L, ISO_Level3_Shift (AltGr)
        55: (0xffeb, .command), 54: (0xffec, .command), // Super_L, Super_R
    ]

    /// Combinations a Mac keyboard cannot send, or that macOS would take for itself.
    enum Combo: CaseIterable {
        case ctrlAltDelete, windows, run, altTab, altF4, taskManager, escape

        var keysyms: [UInt32] {
            switch self {
            case .ctrlAltDelete: [0xffe3, 0xffe9, 0xffff]
            case .windows: [0xffeb]
            case .run: [0xffeb, 0x72]               // Win+R
            case .altTab: [0xffe9, 0xff09]
            case .altF4: [0xffe9, 0xffc1]
            case .taskManager: [0xffe3, 0xffe1, 0xff1b] // Ctrl+Shift+Esc
            case .escape: [0xff1b]
            }
        }
    }

    /// The keysym for a key press, or nil for keys this viewer does not map.
    static func keysym(keyCode: UInt16, charactersIgnoringModifiers: String?) -> UInt32? {
        if let special = special[keyCode] { return special }
        guard let scalar = charactersIgnoringModifiers?.unicodeScalars.first else { return nil }
        // Latin-1 keysyms equal their code points; past that X11 offsets by 0x01000000.
        return scalar.value < 0x100 ? scalar.value : 0x0100_0000 | scalar.value
    }
}
