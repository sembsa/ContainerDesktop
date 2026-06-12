import Foundation

/// Runs a long-lived `container` subprocess (e.g. `logs --follow`, `stats`) and
/// exposes its merged stdout/stderr as an `AsyncThrowingStream` of text lines.
///
/// The class is `@unchecked Sendable`: all mutable state is guarded by `lock`,
/// and the process is owned exclusively by this reader.
final class ProcessLineReader: @unchecked Sendable {
    private let process = Process()
    private let outPipe = Pipe()
    private let lock = NSLock()
    private var buffer = Data()
    private let failOnNonZeroExit: Bool

    /// Rolling window of the most recently emitted lines, used to build a
    /// meaningful error message when the process exits non-zero. Guarded by `lock`.
    private var recentLines: [String] = []
    private static let recentLineLimit = 10

    /// Set (under `lock`) when iteration is cancelled, before `stop()` is called,
    /// so the termination handler can distinguish a user-initiated stop from a
    /// genuine non-zero exit.
    private var cancelled = false

    init(binary: String, arguments: [String], failOnNonZeroExit: Bool = false) {
        self.failOnNonZeroExit = failOnNonZeroExit
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        process.standardOutput = outPipe
        process.standardError = outPipe
    }

    /// Yields output line by line. Finishes when the process exits, throws
    /// `CLIError.notInstalled` if it cannot be launched. Cancelling iteration
    /// terminates the underlying process. When `failOnNonZeroExit` is set, a
    /// non-zero exit finishes the stream with `CLIError.command`.
    func lines() -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let handle = outPipe.fileHandleForReading

            handle.readabilityHandler = { [self] fileHandle in
                let chunk = fileHandle.availableData
                guard !chunk.isEmpty else { return }
                let drained = drain(appending: chunk)
                for line in drained { continuation.yield(line) }
            }

            process.terminationHandler = { [self] process in
                handle.readabilityHandler = nil
                for line in drainRemainder() { continuation.yield(line) }

                let status = process.terminationStatus
                let wasCancelled = lock.withLockValue { cancelled }
                if failOnNonZeroExit && status != 0 && !wasCancelled {
                    let context = lock.withLockValue { recentLines.joined(separator: "\n") }
                    continuation.finish(throwing: CLIError.command(exitCode: status, stderr: context))
                } else {
                    continuation.finish()
                }
            }

            continuation.onTermination = { [self] _ in
                lock.withLockValue { cancelled = true }
                stop()
                handle.readabilityHandler = nil
                process.terminationHandler = nil
            }

            do {
                try process.run()
            } catch {
                continuation.finish(throwing: CLIError.notInstalled)
            }
        }
    }

    func stop() {
        if process.isRunning { process.terminate() }
    }

    // MARK: - Buffer handling

    private func drain(appending chunk: Data) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(chunk)
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            var lineData = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            if lineData.last == 0x0D { lineData.removeLast() }
            let line = String(decoding: lineData, as: UTF8.self)
            lines.append(line)
            recordRecentLocked(line)
        }
        return lines
    }

    private func drainRemainder() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        guard !buffer.isEmpty else { return [] }
        var rest = buffer
        if rest.last == 0x0D { rest.removeLast() }
        buffer.removeAll()
        let line = String(decoding: rest, as: UTF8.self)
        recordRecentLocked(line)
        return [line]
    }

    /// Appends to the rolling recent-lines window. Caller must hold `lock`.
    private func recordRecentLocked(_ line: String) {
        recentLines.append(line)
        if recentLines.count > Self.recentLineLimit {
            recentLines.removeFirst(recentLines.count - Self.recentLineLimit)
        }
    }
}

private extension NSLock {
    /// Convenience to run a closure while holding the lock and return its value.
    func withLockValue<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
