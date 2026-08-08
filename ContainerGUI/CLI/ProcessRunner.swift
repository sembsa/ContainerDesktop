import Foundation
import os

/// Runs a one-shot child process and collects its output.
///
/// Extracted from `ContainerCLI` so a second binary (`helm`, for the Kubernetes
/// section) can reuse the same launch/drain/timeout handling instead of growing
/// a parallel copy of it. Holds no state, so it is safe to call from anywhere.
enum ProcessRunner {
    /// The outcome of a finished one-shot process.
    struct CommandResult: Sendable {
        let stdout: String
        let stderr: String
        let exitCode: Int32
    }

    /// Wraps a non-Sendable `Process` so it can cross concurrency domains
    /// (termination handler / watchdog) without capturing an actor.
    private final class ProcessBox: @unchecked Sendable {
        let process: Process
        init(_ process: Process) { self.process = process }
    }

    /// Bridges the one-shot termination signal to async/await. The process's
    /// `terminationHandler` (a background thread) and the awaiting task race to
    /// set/consume the continuation; the lock makes the hand-off exactly-once.
    private final class TerminationGate: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock<(continuation: CheckedContinuation<Void, Never>?, fired: Bool)>(
            initialState: (nil, false)
        )

        /// Called from the terminationHandler. Resumes the waiter if present.
        func signal() {
            let waiter = lock.withLock { state -> CheckedContinuation<Void, Never>? in
                if state.fired { return nil }
                state.fired = true
                let c = state.continuation
                state.continuation = nil
                return c
            }
            waiter?.resume()
        }

        /// Suspends until `signal()` is (or was already) called.
        func wait() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow = lock.withLock { state -> Bool in
                    if state.fired { return true }
                    state.continuation = continuation
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        }
    }

    static func run(
        executable: String,
        arguments: [String],
        input: String? = nil,
        timeout: Duration?
    ) async throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let inPipe: Pipe?
        if input != nil {
            inPipe = Pipe()
            process.standardInput = inPipe
        } else {
            // Detach stdin so the child can never block (or hang us) reading the
            // GUI's inherited standard input.
            process.standardInput = FileHandle.nullDevice
            inPipe = nil
        }

        let box = ProcessBox(process)
        let didTimeOut = OSAllocatedUnfairLock<Bool>(initialState: false)
        let gate = TerminationGate()

        // Wire the termination handler BEFORE launching. It runs on a background
        // thread and only touches the gate/box — never an actor.
        box.process.terminationHandler = { _ in gate.signal() }

        // Launch. A failure here means the binary couldn't be exec'd. The handler
        // never fires in that case, so we surface the error directly.
        do {
            try box.process.run()
        } catch {
            box.process.terminationHandler = nil
            throw CLIError.notInstalled
        }

        // Feed stdin if requested. Safe now that the process is running.
        if let input, let inPipe, let data = input.data(using: .utf8) {
            inPipe.fileHandleForWriting.write(data)
            try? inPipe.fileHandleForWriting.close()
        }

        // Watchdog: only when a timeout is requested. Captures the box + flag,
        // not an actor.
        var watchdog: Task<Void, Never>?
        if let timeout {
            watchdog = Task.detached {
                try? await Task.sleep(for: timeout)
                guard box.process.isRunning else { return }
                didTimeOut.withLock { $0 = true }
                box.process.terminate()
                try? await Task.sleep(for: .seconds(3))
                if box.process.isRunning {
                    kill(box.process.processIdentifier, SIGKILL)
                }
            }
        }

        // Start draining both pipes BEFORE awaiting termination, so a child that
        // emits more than a pipe buffer's worth of output can't block on write
        // (which would otherwise deadlock against us waiting for it to exit).
        async let outString = readAll(outPipe.fileHandleForReading)
        async let errString = readAll(errPipe.fileHandleForReading)
        let (out, err) = await (outString, errString)

        // EOF on both pipes implies the process has closed its descriptors; await
        // the actual termination signal to read a definitive exit status.
        await gate.wait()

        // Process is done — cancel the watchdog so it can't fire post-hoc.
        watchdog?.cancel()

        if didTimeOut.withLock({ $0 }) {
            throw CLIError.timeout(
                seconds: Int(timeout?.components.seconds ?? 0),
                command: arguments.joined(separator: " ")
            )
        }

        return CommandResult(
            stdout: out.trimmingCharacters(in: .whitespacesAndNewlines),
            stderr: err,
            exitCode: box.process.terminationStatus
        )
    }

    private static func readAll(_ handle: FileHandle) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let data = handle.readDataToEndOfFile()
                continuation.resume(returning: String(decoding: data, as: UTF8.self))
            }
        }
    }
}
