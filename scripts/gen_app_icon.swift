// Renders AppIcon.appiconset for ContainerGUI: macOS squircle with a blue
// gradient and a white shippingbox glyph. Run: swift scripts/gen_app_icon.swift
import AppKit

let canvas: CGFloat = 1024
let outDir = "ContainerGUI/Resources/Assets.xcassets/AppIcon.appiconset"

func renderMaster() -> NSImage {
    let image = NSImage(size: NSSize(width: canvas, height: canvas))
    image.lockFocus()

    // macOS icon grid: 824x824 content squircle centered on 1024 canvas.
    let content = NSRect(x: 100, y: 100, width: 824, height: 824)
    let radius: CGFloat = 185
    let squircle = NSBezierPath(roundedRect: content, xRadius: radius, yRadius: radius)

    // Soft drop shadow behind the squircle.
    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowBlurRadius = 24
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    NSColor.white.setFill()
    squircle.fill()
    NSGraphicsContext.current?.restoreGraphicsState()

    // Vertical blue gradient, lighter at the top (Tahoe style).
    let gradient = NSGradient(
        starting: NSColor(calibratedRed: 0.16, green: 0.42, blue: 0.95, alpha: 1),
        ending: NSColor(calibratedRed: 0.36, green: 0.66, blue: 1.0, alpha: 1)
    )!
    gradient.draw(in: squircle, angle: 90)

    // Subtle top sheen for glassy depth.
    let sheenRect = NSRect(x: 100, y: 512, width: 824, height: 412)
    let sheenPath = NSBezierPath(roundedRect: sheenRect, xRadius: radius, yRadius: radius)
    NSGraphicsContext.current?.saveGraphicsState()
    squircle.addClip()
    NSGradient(
        starting: NSColor.white.withAlphaComponent(0.18),
        ending: NSColor.white.withAlphaComponent(0.0)
    )!.draw(in: sheenPath, angle: -90)
    NSGraphicsContext.current?.restoreGraphicsState()

    // White shippingbox glyph, centered.
    let config = NSImage.SymbolConfiguration(pointSize: 560, weight: .medium)
        .applying(.init(paletteColors: [.white]))
    guard let symbol = NSImage(systemSymbolName: "shippingbox.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) else {
        fatalError("missing SF Symbol")
    }
    let symbolSize = symbol.size
    let scale = min(620 / symbolSize.width, 620 / symbolSize.height)
    let drawSize = NSSize(width: symbolSize.width * scale, height: symbolSize.height * scale)
    let origin = NSPoint(x: (canvas - drawSize.width) / 2, y: (canvas - drawSize.height) / 2)

    NSGraphicsContext.current?.saveGraphicsState()
    let glyphShadow = NSShadow()
    glyphShadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
    glyphShadow.shadowBlurRadius = 14
    glyphShadow.shadowOffset = NSSize(width: 0, height: -6)
    glyphShadow.set()
    symbol.draw(in: NSRect(origin: origin, size: drawSize))
    NSGraphicsContext.current?.restoreGraphicsState()

    image.unlockFocus()
    return image
}

func writePNG(_ image: NSImage, pixels: Int, to path: String) {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(
        in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
        from: NSRect(x: 0, y: 0, width: canvas, height: canvas),
        operation: .copy, fraction: 1
    )
    NSGraphicsContext.restoreGraphicsState()
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: path))
    print("wrote \(path)")
}

try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
let master = renderMaster()
for pixels in [16, 32, 64, 128, 256, 512, 1024] {
    writePNG(master, pixels: pixels, to: "\(outDir)/icon_\(pixels).png")
}
print("done")
