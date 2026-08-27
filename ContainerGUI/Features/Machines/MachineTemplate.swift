import Foundation

/// A ready-made machine, so that creating one needs no typing.
///
/// The form used to open with two empty text fields and no idea what belongs in
/// them; a base image is not something anyone should have to remember. Picking a
/// template fills the image and proposes a name, and whatever the template needs
/// on top of the base image is installed after the machine boots.
///
/// Everything here was checked against a live 1.3.0 machine rather than assumed:
/// `apk add` works inside a machine and persists, `dotnet10-sdk` is in Alpine's
/// repositories, and so are the X server, window manager and VNC server the
/// desktop template installs.
struct MachineTemplate: Identifiable, Sendable, Hashable {
    let id: String
    let title: String
    let summary: String
    let image: String
    let suggestedName: String
    /// Installed with `apk add` once the machine is up.
    let packages: [String]
    /// Whether the machine can then be reached with Screen Sharing.
    let providesDesktop: Bool

    static let all: [MachineTemplate] = [
        MachineTemplate(
            id: "alpine",
            title: String(localized: "Alpine (minimalna)"),
            summary: String(localized: "Najmniejsza sensowna maszyna — kilka megabajtów, shell i menedżer paczek apk."),
            image: "alpine:latest",
            suggestedName: "alpine",
            packages: [],
            providesDesktop: false
        ),
        MachineTemplate(
            id: "debian",
            title: String(localized: "Debian"),
            summary: String(localized: "Większa baza z apt, kiedy potrzebujesz paczek, których Alpine nie ma."),
            image: "debian:bookworm-slim",
            suggestedName: "debian",
            packages: [],
            providesDesktop: false
        ),
        MachineTemplate(
            id: "dotnet",
            title: String(localized: "Dev .NET"),
            summary: String(localized: "Alpine z pakietem dotnet10-sdk — po utworzeniu w terminalu maszyny działa polecenie dotnet."),
            image: "alpine:latest",
            suggestedName: "dotnet-dev",
            packages: ["dotnet10-sdk"],
            providesDesktop: false
        ),
        MachineTemplate(
            id: "desktop",
            title: String(localized: "Pulpit z VNC"),
            summary: String(localized: "Alpine z serwerem X, menedżerem okien i serwerem VNC. Po utworzeniu podłączysz się jednym kliknięciem przez systemowe Udostępnianie ekranu. Doinstalowanie zajmuje około 260 MB."),
            image: "alpine:latest",
            suggestedName: "pulpit",
            packages: ["x11vnc", "xvfb", "fluxbox", "xterm"],
            providesDesktop: true
        ),
        custom,
    ]

    static let custom = MachineTemplate(
        id: "custom",
        title: String(localized: "Własna"),
        summary: String(localized: "Wpisz obraz bazowy sam."),
        image: "",
        suggestedName: "",
        packages: [],
        providesDesktop: false
    )
}

/// Field checks that run while typing, so the CLI is not the first thing to say
/// a value is wrong.
enum MachineFieldValidation {

    /// An empty field is valid everywhere here: the CLI has its own defaults and
    /// the flag is simply omitted.
    static func cpus(_ text: String) -> String? {
        guard !text.isEmpty else { return nil }
        guard text.allSatisfy(\.isNumber), let value = Int(text), value > 0 else {
            return String(localized: "Podaj liczbę całkowitą większą od zera.")
        }
        return nil
    }

    static func memory(_ text: String) -> String? {
        guard !text.isEmpty else { return nil }
        // The CLI documents K, M, G, T and P — not the binary spellings, and not
        // a space before the unit.
        let digits = text.prefix(while: \.isNumber)
        let suffix = text.dropFirst(digits.count)
        guard let value = Int(digits), value > 0,
              suffix.isEmpty || (suffix.count == 1 && "KMGTP".contains(suffix))
        else {
            return String(localized: "Podaj rozmiar, np. 4G, 512M albo 2048 (bez jednostki = MB).")
        }
        return nil
    }

    static func kernelPath(
        _ text: String,
        exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> String? {
        guard !text.isEmpty else { return nil }
        guard text.hasPrefix("/") else {
            return String(localized: "Podaj pełną ścieżkę, zaczynającą się od /.")
        }
        guard exists(text) else {
            return String(localized: "Nie ma pliku pod tą ścieżką.")
        }
        return nil
    }
}
