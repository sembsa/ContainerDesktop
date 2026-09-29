import XCTest

/// The three `.strings` files, checked against each other.
///
/// Keys are the Polish source strings, so a missing translation is not a build
/// error and not a crash — the app simply shows Polish to an English speaker.
/// Nothing catches that but a person noticing, which is how a UI drifts out of
/// step one string at a time.
///
/// Reads the files from the source tree rather than a bundle: they belong to the
/// app target, and the point is to check the files a commit would carry.
final class LocalizationTests: XCTestCase {

    private static let languages = ["pl", "en", "zh-Hans"]

    private var resourcesDirectory: URL {
        URL(fileURLWithPath: #filePath)          // …/ContainerGUITests/LocalizationTests.swift
            .deletingLastPathComponent()          // …/ContainerGUITests
            .deletingLastPathComponent()          // repo root
            .appendingPathComponent("ContainerGUI/Resources")
    }

    /// `"key" = "value";`, allowing either side to contain escaped quotes.
    private static let entry = try! NSRegularExpression(
        pattern: #"^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)";\s*$"#
    )

    /// Every entry in order, so duplicates survive to be inspected.
    private func entries(_ language: String) throws -> [(key: String, value: String)] {
        let url = resourcesDirectory
            .appendingPathComponent("\(language).lproj/Localizable.strings")
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: false).compactMap { line in
            let line = String(line)
            let range = NSRange(line.startIndex..., in: line)
            guard let match = Self.entry.firstMatch(in: line, range: range),
                  let key = Range(match.range(at: 1), in: line),
                  let value = Range(match.range(at: 2), in: line)
            else { return nil }
            return (String(line[key]), String(line[value]))
        }
    }

    func testEveryFileParsesAndIsNotEmpty() throws {
        for language in Self.languages {
            XCTAssertGreaterThan(try entries(language).count, 500, language)
        }
    }

    func testTheThreeFilesDescribeTheSameKeys() throws {
        let polish = Set(try entries("pl").map(\.key))
        for language in Self.languages.dropFirst() {
            let other = Set(try entries(language).map(\.key))
            XCTAssertEqual(
                polish.subtracting(other), [],
                "brak w \(language)"
            )
            XCTAssertEqual(
                other.subtracting(polish), [],
                "w \(language) jest klucz, którego nie ma w pl"
            )
        }
    }

    func testPolishMapsToItself() throws {
        // The convention the whole scheme rests on: the key *is* the Polish text,
        // so a pl file that translates anything has a typo in either side.
        for (key, value) in try entries("pl") where key != value {
            XCTFail("pl nie jest tożsamością: \"\(key)\" = \"\(value)\"")
        }
    }

    func testNoKeyIsDefinedTwiceWithDifferentText() throws {
        // A repeated key silently takes its last definition. Identical repeats
        // are only untidy; conflicting ones show the wrong string somewhere, and
        // nothing points at which screen.
        for language in Self.languages {
            var seen: [String: String] = [:]
            for (key, value) in try entries(language) {
                if let first = seen[key], first != value {
                    XCTFail("\(language): \"\(key)\" raz \"\(first)\", raz \"\(value)\"")
                }
                seen[key] = value
            }
        }
    }

    func testPlaceholdersSurviveTranslation() throws {
        // "%@" dropped from a translation is a crash or a blank, not a typo.
        let polish = Dictionary(try entries("pl"), uniquingKeysWith: { a, _ in a })
        for language in Self.languages.dropFirst() {
            for (key, value) in try entries(language) {
                guard let source = polish[key] else { continue }
                XCTAssertEqual(
                    source.ranges(of: "%").count, value.ranges(of: "%").count,
                    "\(language): \"\(key)\" ma inną liczbę podstawień niż źródło"
                )
            }
        }
    }
}
