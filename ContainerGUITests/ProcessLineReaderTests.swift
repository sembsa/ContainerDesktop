import XCTest

/// Verifies that a burst of output survives the reader intact.
///
/// Containers like SQL Server dump thousands of lines the moment they start, and
/// the log viewer showed them torn apart mid-word ("Parallel redo is shutdown for
/// / database / 'e2610" on separate lines) — while `container logs` piped to a
/// file was clean, so the damage happened on the way through here.
final class ProcessLineReaderTests: XCTestCase {

    /// One line per iteration, long enough that a burst spans many pipe reads.
    private func burstScript(lines: Int) -> String {
        "i=1; while [ $i -le \(lines) ]; do "
            + "echo \"line-$i AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
            + "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"
            + "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC\"; "
            + "i=$((i+1)); done"
    }

    func testBurstOfOutputArrivesLineByLineInOrder() async throws {
        let expected = 5000
        let reader = ProcessLineReader(
            binary: "/bin/sh",
            arguments: ["-c", burstScript(lines: expected)]
        )

        var received: [String] = []
        for try await line in reader.lines() {
            received.append(line)
        }

        XCTAssertEqual(received.count, expected, "lines were split or merged in transit")
        for (offset, line) in received.enumerated() {
            XCTAssertTrue(
                line.hasPrefix("line-\(offset + 1) "),
                "line \(offset + 1) arrived as \"\(line.prefix(40))…\""
            )
        }
    }

    func testMultiByteCharactersSurviveChunkBoundaries() async throws {
        // A chunk boundary landing inside a multi-byte character would leave
        // replacement characters behind.
        let script = "i=1; while [ $i -le 2000 ]; do echo \"$i zażółć gęślą jaźń 中文 🚀\"; i=$((i+1)); done"
        let reader = ProcessLineReader(binary: "/bin/sh", arguments: ["-c", script])

        var count = 0
        for try await line in reader.lines() {
            count += 1
            XCTAssertFalse(line.contains("\u{FFFD}"), "mangled UTF-8 in: \(line)")
            XCTAssertTrue(line.hasSuffix("zażółć gęślą jaźń 中文 🚀"), "truncated: \(line)")
        }
        XCTAssertEqual(count, 2000)
    }

    func testProcessIsGoneAfterTheConsumingTaskIsCancelled() async throws {
        // This is the path the log view actually takes: `.task(id:)` cancels the
        // previous stream when you switch containers. A survivor here is what left
        // `container logs --follow` running in the background.
        let reader = ProcessLineReader(
            binary: "/bin/sh",
            arguments: ["-c", "while true; do echo tick; sleep 0.2; done"]
        )
        let started = expectation(description: "first line arrived")

        let task = Task {
            var first = true
            for try await _ in reader.lines() {
                if first { started.fulfill(); first = false }
            }
        }
        await fulfillment(of: [started], timeout: 5)
        task.cancel()
        _ = try? await task.value

        try await Task.sleep(for: .milliseconds(700))
        XCTAssertFalse(reader.isRunning, "cancelling the consumer left the child running")
    }

    func testProcessIsGoneAfterTheStreamIsAbandoned() async throws {
        // Leaving `container logs --follow` running is what stopped later log
        // views from loading.
        let reader = ProcessLineReader(
            binary: "/bin/sh",
            arguments: ["-c", "while true; do echo tick; sleep 0.2; done"]
        )

        var seen = 0
        for try await _ in reader.lines() {
            seen += 1
            if seen == 3 { break }   // abandon the stream mid-flight
        }

        // Give termination a moment to propagate.
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertFalse(reader.isRunning, "the child process outlived its stream")
    }
}
