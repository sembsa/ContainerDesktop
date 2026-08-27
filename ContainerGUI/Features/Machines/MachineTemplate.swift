import Foundation

/// Which package manager a machine's distribution uses.
///
/// This matters because provisioning is a list of direct commands: `machine run
/// -- sh -c "…"` executes but swallows stdout and loses exit codes, so
/// `apt-get update && apt-get install` cannot be one shell line.
enum MachinePackageManager: String, Sendable, Hashable {
    case apk
    case apt

    /// The commands to run, in order, to install packages inside the machine.
    func installCommands(packages: [String], on name: String) -> [[String]] {
        guard !packages.isEmpty else { return [] }
        switch self {
        case .apk:
            return [["machine", "run", "-n", name, "--root", "--",
                     "apk", "add", "--no-progress"] + packages]
        case .apt:
            return [
                ["machine", "run", "-n", name, "--root", "--", "apt-get", "update"],
                // DEBIAN_FRONTEND is not optional: without it the install can stop
                // on a configuration prompt nobody is there to answer.
                ["machine", "run", "-n", name, "--root",
                 "-e", "DEBIAN_FRONTEND=noninteractive", "--",
                 "apt-get", "install", "-y", "--no-install-recommends"] + packages,
            ]
        }
    }
}

/// A ready-made machine, so that creating one needs no typing.
///
/// The form used to open with two empty text fields and no idea what belongs in
/// them; a base image is not something anyone should have to remember. Picking a
/// template fills the image and proposes a name, and whatever the template needs
/// on top of the base image is installed after the machine boots.
///
/// Everything here was checked against a live 1.3.0 machine rather than assumed —
/// including the fact that decides which distributions can appear at all: **a
/// machine will not boot from an image without `/sbin/init`.** Alpine's is a
/// busybox symlink and works. `ubuntu:24.04` and `debian:bookworm-slim` carry no
/// init whatsoever — no systemd, no busybox — and `machine create` fails on them
/// with "container must be running". Ubuntu therefore arrives as a base image the
/// app builds itself: Ubuntu plus `busybox-static`, linked as `/sbin/init`. That
/// image boots and reports Ubuntu 24.04.4 LTS.
struct MachineTemplate: Identifiable, Sendable, Hashable {
    let id: String
    let title: String
    let summary: String
    /// The image a machine is created from. For templates that build their own
    /// base, this is the tag the build produces.
    let image: String
    let suggestedName: String
    /// Installed after the machine boots.
    let packages: [String]
    /// Whether this is a graphical machine; the chosen environment decides what
    /// gets installed.
    let providesDesktop: Bool
    let packageManager: MachinePackageManager
    /// Set when the base image has to be built before a machine can be made.
    let baseImageDockerfile: String?

    var needsBaseImageBuild: Bool { baseImageDockerfile != nil }

    /// Ubuntu with an init, which the official image lacks. busybox rather than
    /// systemd: it is the same mechanism Alpine boots with here, and a fraction
    /// of the size.
    private static let ubuntuDockerfile = """
        FROM ubuntu:24.04
        RUN apt-get update \\
         && apt-get install -y --no-install-recommends busybox-static \\
         && ln -sf /bin/busybox /sbin/init \\
         && rm -rf /var/lib/apt/lists/*
        """

    private static let ubuntuImage = "containerdesktop/ubuntu-machine:24.04"

    static let all: [MachineTemplate] = [
        MachineTemplate(
            id: "alpine",
            title: String(localized: "Alpine (minimalna)"),
            summary: String(localized: "Najmniejsza sensowna maszyna — kilka megabajtów, shell i menedżer paczek apk."),
            image: "alpine:latest",
            suggestedName: "alpine",
            packages: [],
            providesDesktop: false,
            packageManager: .apk,
            baseImageDockerfile: nil
        ),
        MachineTemplate(
            id: "ubuntu",
            title: String(localized: "Ubuntu 24.04"),
            summary: String(localized: "Pełne Ubuntu z apt. Obraz bazowy aplikacja zbuduje sama — oficjalny nie zawiera inita, bez którego maszyna nie wstaje."),
            image: ubuntuImage,
            suggestedName: "ubuntu",
            packages: [],
            providesDesktop: false,
            packageManager: .apt,
            baseImageDockerfile: ubuntuDockerfile
        ),
        MachineTemplate(
            id: "dotnet",
            title: String(localized: "Dev .NET"),
            summary: String(localized: "Alpine z pakietem dotnet10-sdk — po utworzeniu w terminalu maszyny działa polecenie dotnet."),
            image: "alpine:latest",
            suggestedName: "dotnet-dev",
            packages: ["dotnet10-sdk"],
            providesDesktop: false,
            packageManager: .apk,
            baseImageDockerfile: nil
        ),
        MachineTemplate(
            id: "desktop",
            title: String(localized: "Alpine z pulpitem VNC"),
            summary: String(localized: "Alpine z pulpitem graficznym i serwerem VNC — środowisko wybierasz niżej. Po utworzeniu podłączysz się jednym kliknięciem przez systemowe Udostępnianie ekranu."),
            image: "alpine:latest",
            suggestedName: "pulpit",
            packages: [],
            providesDesktop: true,
            packageManager: .apk,
            baseImageDockerfile: nil
        ),
        MachineTemplate(
            id: "ubuntu-desktop",
            title: String(localized: "Ubuntu z pulpitem VNC"),
            summary: String(localized: "Ubuntu z pulpitem graficznym i serwerem VNC. Cięższe od Alpine, ale z apt i pełnym userlandem. Obraz bazowy aplikacja zbuduje sama."),
            image: ubuntuImage,
            suggestedName: "ubuntu-pulpit",
            packages: [],
            providesDesktop: true,
            packageManager: .apt,
            baseImageDockerfile: ubuntuDockerfile
        ),
        custom,
    ]

    static let custom = MachineTemplate(
        id: "custom",
        title: String(localized: "Własna"),
        summary: String(localized: "Wpisz obraz bazowy sam. Obraz musi zawierać /sbin/init — bez niego maszyna nie wstanie."),
        image: "",
        suggestedName: "",
        packages: [],
        providesDesktop: false,
        packageManager: .apk,
        baseImageDockerfile: nil
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
