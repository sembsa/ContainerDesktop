// Prints the CGWindowID of an app's main window, for `screencapture -l<id>`.
// Usage: swift scripts/windowid.swift [ownerName] [minHeight]
// The owner name is the app's *display* name ("Container Desktop"), not the bundle name.
// Requires Screen Recording permission for the calling terminal.

import CoreGraphics
import Foundation

let owner = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Container Desktop"
let minHeight = CommandLine.arguments.count > 2 ? Double(CommandLine.arguments[2]) ?? 200 : 200

guard let windows = CGWindowListCopyWindowInfo(
    [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
) as? [[String: Any]] else {
    FileHandle.standardError.write(Data("cannot list windows\n".utf8))
    exit(1)
}

for window in windows {
    guard window[kCGWindowOwnerName as String] as? String == owner,
          window[kCGWindowLayer as String] as? Int == 0,
          let bounds = window[kCGWindowBounds as String] as? [String: Double],
          let height = bounds["Height"], height >= minHeight,
          let number = window[kCGWindowNumber as String] as? Int
    else { continue }
    print(number)
    exit(0)
}

FileHandle.standardError.write(Data("no window of \(owner) taller than \(minHeight)pt\n".utf8))
exit(2)
