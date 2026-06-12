import AppKit
import SwiftUI

/// Native, selectable log renderer. A single NSTextView gives continuous
/// multi-line selection and Cmd+C (SwiftUI `Text` rows can only select one
/// row at a time) and lets us colorize lines by detected log level.
struct LogTextView: NSViewRepresentable {
    let lines: [LogLine]
    var showTimestamps = false
    var autoscroll = true
    var colorize = true

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView,
              let storage = textView.textStorage else { return }
        let coordinator = context.coordinator

        let optionsChanged = coordinator.showTimestamps != showTimestamps
            || coordinator.colorize != colorize
        let wasReset = lines.count < coordinator.appliedCount
            || (coordinator.appliedCount > 0 && coordinator.firstID != lines.first?.id)

        if optionsChanged || wasReset {
            coordinator.appliedCount = 0
            storage.setAttributedString(NSAttributedString())
        }
        coordinator.showTimestamps = showTimestamps
        coordinator.colorize = colorize
        coordinator.firstID = lines.first?.id

        guard lines.count > coordinator.appliedCount else { return }
        let batch = NSMutableAttributedString()
        for line in lines[coordinator.appliedCount...] {
            batch.append(Self.render(line, showTimestamps: showTimestamps, colorize: colorize))
        }
        storage.append(batch)
        coordinator.appliedCount = lines.count

        if autoscroll {
            textView.scrollToEndOfDocument(nil)
        }
    }

    final class Coordinator {
        var appliedCount = 0
        var showTimestamps = false
        var colorize = true
        var firstID: UUID?
    }

    // MARK: - Rendering

    private static let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private static func render(_ line: LogLine, showTimestamps: Bool, colorize: Bool) -> NSAttributedString {
        let result = NSMutableAttributedString()
        if showTimestamps {
            result.append(NSAttributedString(
                string: "[\(timeFormatter.string(from: line.date))] ",
                attributes: [.font: font, .foregroundColor: NSColor.tertiaryLabelColor]
            ))
        }
        let color: NSColor = colorize ? LogLevel.detect(in: line.text).color : .labelColor
        result.append(NSAttributedString(
            string: line.text + "\n",
            attributes: [.font: font, .foregroundColor: color]
        ))
        return result
    }
}

/// Detected severity of a log line. The detector is deliberately tolerant:
/// different containers use different syntaxes (serilog `[11:04 ERR]`,
/// .NET `ERROR:`, logfmt `level=warn`, klog `E0612 ...`).
enum LogLevel {
    case error, warning, debug, normal

    var color: NSColor {
        switch self {
        case .error: .systemRed
        case .warning: .systemOrange
        case .debug: .secondaryLabelColor
        case .normal: .labelColor
        }
    }

    private static let errorRegex = try! NSRegularExpression(
        pattern: #"(?i)\b(err|error|fatal|ftl|crit|critical|panic|exception)\b|^[EF]\d{4}"#
    )
    private static let warningRegex = try! NSRegularExpression(
        pattern: #"(?i)\b(wrn|warn|warning)\b|^W\d{4}"#
    )
    private static let debugRegex = try! NSRegularExpression(
        pattern: #"(?i)\b(dbg|debug|trace|trc|verbose)\b|^D\d{4}"#
    )

    static func detect(in text: String) -> LogLevel {
        // Levels live near the start of a line; scanning a prefix avoids
        // false positives from message bodies (e.g. an URL mentioning "error").
        let prefix = String(text.prefix(64))
        let range = NSRange(prefix.startIndex..., in: prefix)
        if errorRegex.firstMatch(in: prefix, range: range) != nil { return .error }
        if warningRegex.firstMatch(in: prefix, range: range) != nil { return .warning }
        if debugRegex.firstMatch(in: prefix, range: range) != nil { return .debug }
        return .normal
    }
}
