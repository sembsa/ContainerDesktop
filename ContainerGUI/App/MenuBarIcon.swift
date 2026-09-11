import AppKit

/// Layout for the activity bars drawn beside the status item glyph.
///
/// Separated from the drawing so the geometry can be tested: at this size an
/// off-by-one is a smudge nobody can read, and there is no way to eyeball it in
/// the menu bar.
enum MenuBarIconLayout {
    /// The menu bar grid. Anything taller is clipped and glitches when the
    /// status item highlights.
    static let height: CGFloat = 17
    static let glyphWidth: CGFloat = 17
    static let barCount = 6
    static let barWidth: CGFloat = 1.5
    static let barSpacing: CGFloat = 1
    static let gap: CGFloat = 3

    /// So a container sitting at zero still reads as "present and idle" rather
    /// than as a gap in the graph.
    static let minimumBarHeight: CGFloat = 1.5

    static var barsWidth: CGFloat {
        CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * barSpacing
    }

    static var totalWidth: CGFloat { glyphWidth + gap + barsWidth }

    /// Bars for the most recent samples, newest on the right, growing upwards.
    ///
    /// `samples` are normalised `0...1`. Fewer than `barCount` are right-aligned,
    /// so a freshly started app fills in from the right rather than stretching
    /// two samples across the whole strip.
    static func bars(for samples: [Double], origin: CGPoint, maxHeight: CGFloat) -> [CGRect] {
        guard !samples.isEmpty else { return [] }
        let recent = Array(samples.suffix(barCount))
        let leadingSlots = barCount - recent.count

        return recent.enumerated().map { index, value in
            let slot = leadingSlots + index
            let x = origin.x + CGFloat(slot) * (barWidth + barSpacing)
            let clamped = min(max(value, 0), 1)
            let height = max(clamped * maxHeight, minimumBarHeight)
            return CGRect(x: x, y: origin.y, width: barWidth, height: height)
        }
    }
}

/// Builds the status item image.
enum MenuBarIcon {
    /// The app's glyph, plus a live activity strip when containers are running.
    ///
    /// Returned as a template image so macOS tints it for the menu bar's
    /// appearance — drawing our own colours here would look wrong in half the
    /// system's states.
    static func image(symbolName: String, activity: [Double]) -> NSImage {
        let glyph = symbol(symbolName)
        guard !activity.isEmpty else { return glyph }

        let size = NSSize(width: MenuBarIconLayout.totalWidth, height: MenuBarIconLayout.height)
        let image = NSImage(size: size, flipped: false) { _ in
            glyph.draw(
                in: NSRect(
                    x: 0,
                    y: (MenuBarIconLayout.height - glyph.size.height) / 2,
                    width: glyph.size.width,
                    height: glyph.size.height
                )
            )

            NSColor.black.setFill()
            let bars = MenuBarIconLayout.bars(
                for: activity,
                origin: CGPoint(x: MenuBarIconLayout.glyphWidth + MenuBarIconLayout.gap, y: 2),
                maxHeight: MenuBarIconLayout.height - 5
            )
            for bar in bars {
                NSBezierPath(roundedRect: bar, xRadius: 0.75, yRadius: 0.75).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    /// The bare glyph, sized to the menu bar grid.
    static func symbol(_ name: String) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Container Desktop")?
            .withSymbolConfiguration(config) ?? NSImage()
        if image.size.height > MenuBarIconLayout.height, image.size.height > 0 {
            let ratio = MenuBarIconLayout.height / image.size.height
            image.size = NSSize(width: image.size.width * ratio, height: MenuBarIconLayout.height)
        }
        image.isTemplate = true
        return image
    }
}
