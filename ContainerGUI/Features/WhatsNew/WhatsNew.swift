import Foundation

/// Release notes shown once, the first time a version runs.
///
/// Updates arrive through Sparkle and install silently, so without this the
/// only record of what changed lives on a GitHub releases page nobody opens.
/// Kept free of SwiftUI so the selection rule can be tested on its own.
enum WhatsNew {

    /// Posted by the app menu to reopen the notes on demand.
    static let reopenNotification = Notification.Name("com.containerdesktop.showWhatsNew")

    struct Item: Identifiable, Sendable, Hashable {
        let symbol: String
        let title: String
        let detail: String
        var id: String { title }
    }

    struct Entry: Identifiable, Sendable, Hashable {
        let version: String
        let items: [Item]
        var id: String { version }
    }

    /// Which notes to show, if any.
    ///
    /// Nothing is shown when the running version has no notes, or when this
    /// version's notes have already been dismissed. A `nil` `lastSeen` counts as
    /// "not yet shown": anyone upgrading into the first release that has this
    /// window has no stored value, and they are exactly the people the window is
    /// for.
    static func entry(lastSeen: String?, current: String, in entries: [Entry] = all) -> Entry? {
        guard lastSeen != current else { return nil }
        return entries.first { $0.version == current }
    }

    static let all: [Entry] = [
        Entry(
            version: "0.7.3",
            items: [
                Item(
                    symbol: "cpu",
                    title: String(localized: "Instalacja Rosetty z poziomu aplikacji"),
                    detail: String(localized: "Bez Rosetty żaden obraz amd64 nie wystartuje na Apple Silicon — container włącza ją automatycznie dla takich obrazów, niezależnie od ustawień. Po dużej aktualizacji macOS trzeba ją zainstalować od nowa. Aplikacja to wykrywa i proponuje instalację jednym kliknięciem.")
                ),
                Item(
                    symbol: "sparkles",
                    title: String(localized: "Zgodność z macOS 27"),
                    detail: String(localized: "Aplikacja korzysta z nowych API systemu tam, gdzie są dostępne, i działa tak samo na macOS 26.")
                ),
            ]
        ),
        Entry(
            version: "0.7.2",
            items: [
                Item(
                    symbol: "chart.line.uptrend.xyaxis",
                    title: String(localized: "Menu w pasku pokazuje, co się dzieje"),
                    detail: String(localized: "Zamiast listy nazw — wykres zbiorczego obciążenia CPU z ostatnich dwóch minut, a przy każdym kontenerze własny mini-wykres obok adresu, portów, pamięci i bieżącego procentu.")
                ),
                Item(
                    symbol: "menubar.rectangle",
                    title: String(localized: "Obciążenie widoczne bez otwierania menu"),
                    detail: String(localized: "Przy ikonie w pasku menu pojawił się pasek sześciu słupków. Przy bezczynności to rząd kropek, przy pracy słupki rosną — widzisz, że coś się dzieje, nie klikając niczego.")
                ),
                Item(
                    symbol: "paintpalette",
                    title: String(localized: "Kolory projektów i ikony"),
                    detail: String(localized: "Kontenery z jednego projektu compose dostały wspólny kolor, a pozycje menu ikony i podświetlenie pod kursorem na całą szerokość.")
                ),
            ]
        ),
        Entry(
            version: "0.7.1",
            items: [
                Item(
                    symbol: "exclamationmark.shield",
                    title: String(localized: "Poprawka krytyczna: pobieranie plików"),
                    detail: String(localized: "W wersji 0.7.0 pobieranie pliku z kontenera kasowało zawartość wybranego katalogu docelowego. Jeśli wskazałeś Biurko, znikały pliki z Biurka. Naprawione: aplikacja zapisuje plik wewnątrz wskazanego katalogu i nigdy nie usuwa katalogów. Jeśli używałeś 0.7.0 do pobierania plików, sprawdź iCloud i kopie zapasowe.")
                ),
            ]
        ),
        Entry(
            version: "0.7.0",
            items: [
                Item(
                    symbol: "doc.on.doc",
                    title: String(localized: "Kopiowanie plików znów działa"),
                    detail: String(localized: "container 1.4.1 nie potrafi kopiować plików do i z kontenerów utworzonych przed aktualizacją — zgłasza „path not found” dla plików, które istnieją, a wysyłkę kończy sukcesem, nie zapisując nic. Aplikacja wykrywa to i przenosi pliki inną drogą, więc po prostu działa.")
                ),
                Item(
                    symbol: "arrow.triangle.2.circlepath",
                    title: String(localized: "Ostrzeżenie o niezgodnej wersji usługi"),
                    detail: String(localized: "Po aktualizacji pakietu container usługa w tle nadal działa w starej wersji, a błędy, które to powoduje, nigdy nie wspominają o wersjach. Aplikacja rozpoznaje ten stan i proponuje restart jednym kliknięciem.")
                ),
                Item(
                    symbol: "internaldrive",
                    title: String(localized: "Zwolnij miejsce na dysku"),
                    detail: String(localized: "Nowe polecenie container clean, dostępne z menu kontenera. Zwalnia nieużywane bloki dysku działającego kontenera — nie usuwa danych.")
                ),
                Item(
                    symbol: "info.circle",
                    title: String(localized: "Sekcja Środowisko"),
                    detail: String(localized: "System pokazuje teraz to, co raportuje container 1.4.1: wersje obu stron, system, liczbę rdzeni, kontenerów i obrazów oraz katalogi danych i instalacji.")
                ),
            ]
        )
    ]
}
