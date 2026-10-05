import Foundation

/// A refresh that was cancelled (a view went away, a newer task replaced it) did
/// not fail: nothing is wrong with the engine, the answer just never arrived.
/// Stores keep their last good data for such a source and record no error.
enum RefreshCancellation {
    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let url = error as? URLError, url.code == .cancelled { return true }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain, ns.code == NSURLErrorCancelled { return true }
        if let cli = error as? CLIError, case .command(_, let stderr) = cli {
            // Older code paths wrapped the error's description into a CLIError.
            return stderr.contains("CancellationError")
        }
        return false
    }
}
