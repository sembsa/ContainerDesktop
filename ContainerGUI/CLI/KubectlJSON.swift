import Foundation

/// The decoder for `kubectl -o json`, deliberately its own rather than shared
/// with `ContainerCLI`.
///
/// `container` emits timestamps without fractional seconds, so the strict
/// `.iso8601` strategy is fine there. Kubernetes emits both forms in the same
/// document — `creationTimestamp: 2026-08-27T05:45:06Z` alongside nine-digit
/// nanosecond fractions elsewhere — and strict `.iso8601` throws on the second.
/// `ISO8601DateFormatter` will not take nine digits either, so an over-long
/// fraction is trimmed rather than refused.
enum KubectlJSON {

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = date(from: text) else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath,
                          debugDescription: "nierozpoznany znacznik czasu: \(text)")
                )
            }
            return date
        }
        return decoder
    }()

    static func date(from text: String) -> Date? {
        if let date = try? fractional.parse(text) { return date }
        if let date = try? plain.parse(text) { return date }
        if let trimmed = trimmingFraction(text), let date = try? fractional.parse(trimmed) {
            return date
        }
        return nil
    }

    /// Cuts a fractional part down to the three digits the formatter accepts.
    /// Kubernetes prints nanoseconds; nobody displays them.
    private static func trimmingFraction(_ text: String) -> String? {
        guard let dot = text.firstIndex(of: ".") else { return nil }
        let afterDot = text.index(after: dot)
        let digits = text[afterDot...].prefix(while: \.isNumber)
        guard digits.count > 3 else { return nil }
        let suffix = text[text.index(afterDot, offsetBy: digits.count)...]
        return String(text[..<afterDot]) + digits.prefix(3) + suffix
    }

    // `ISO8601DateFormatter` is a class and not Sendable, so it cannot be a
    // static under strict concurrency. These format styles are structs.
    private static let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let plain = Date.ISO8601FormatStyle()
}
