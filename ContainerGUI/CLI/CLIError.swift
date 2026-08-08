import Foundation

/// Errors surfaced by the `container` CLI integration layer.
enum CLIError: Error, LocalizedError, Sendable, Equatable {
    /// The `container` binary could not be located on disk.
    case notInstalled
    /// The background system service (`container system start`) is not running.
    case serviceNotRunning
    /// The command ran but exited with a non-zero status.
    case command(exitCode: Int32, stderr: String)
    /// The command did not finish within the allotted time and was terminated.
    case timeout(seconds: Int, command: String)
    /// The command output could not be decoded into the expected model.
    case decoding(String)
    /// The `helm` binary could not be located on disk (Kubernetes section).
    case helmNotInstalled

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return String(localized: "Nie znaleziono narzędzia container. Zainstaluj je lub wskaż ścieżkę w Ustawieniach.")
        case .helmNotInstalled:
            return String(localized: "Nie znaleziono narzędzia helm. Zainstaluj je poleceniem „brew install helm” lub wskaż ścieżkę w Ustawieniach.")
        case .serviceNotRunning:
            return String(localized: "Usługa systemowa container nie jest uruchomiona. Uruchom ją, aby kontynuować.")
        case .command(let exitCode, let stderr):
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty
                ? String(format: String(localized: "Polecenie zakończyło się błędem (kod %d)."), exitCode)
                : trimmed
        case .timeout(let seconds, let command):
            return String(format: String(localized: "Polecenie „container %@” nie odpowiedziało w ciągu %d s i zostało przerwane."), command, seconds)
        case .decoding(let message):
            return String(format: String(localized: "Nie udało się odczytać odpowiedzi narzędzia: %@"), message)
        }
    }

    /// Builds the most appropriate error from a finished process result.
    ///
    /// Scans the combined stderr/stdout for known "service not running" signatures
    /// and otherwise wraps the exit code and stderr. When stderr is empty after
    /// trimming but stdout carries text, the trimmed stdout is used as the message.
    static func from(exitCode: Int32, stderr: String, stdout: String = "") -> CLIError {
        let haystack = (stderr + " " + stdout).lowercased()
        if haystack.contains("xpc connection error")
            || haystack.contains("system service has been started")
            || haystack.contains("not running and not registered") {
            return .serviceNotRunning
        }
        let trimmedStderr = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedStdout = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedStderr.isEmpty, !trimmedStdout.isEmpty {
            return .command(exitCode: exitCode, stderr: trimmedStdout)
        }
        return .command(exitCode: exitCode, stderr: stderr)
    }
}
