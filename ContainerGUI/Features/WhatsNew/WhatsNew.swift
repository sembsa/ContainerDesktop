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
            version: "0.9.1",
            items: [
                Item(
                    symbol: "exclamationmark.triangle",
                    title: String(localized: "Zgodność z container 1.5.0"),
                    detail: String(localized: "To wydanie usunęło polecenie restartu klastra Kubernetes. Przycisk „Uruchom” znikał więc z błędem, który mówił o czymś zupełnie innym — teraz program tłumaczy, że zatrzymany klaster trzeba usunąć i utworzyć na nowo. Na starszym CLI przycisk działa jak dotąd.")
                ),
                Item(
                    symbol: "textformat.size",
                    title: String(localized: "Tekst znów skaluje się z systemem"),
                    detail: String(localized: "Kilkanaście napisów miało wpisany sztywny rozmiar i nie reagowało na powiększenie tekstu w ustawieniach systemowych. Teraz reagują. Najdrobniejsze plakietki urosły przy okazji o punkt — były poniżej tego, co macOS w ogóle przewiduje.")
                )
            ]
        ),
        Entry(
            version: "0.9.0",
            items: [
                Item(
                    symbol: "trash",
                    title: String(localized: "Kosz przy każdym kontenerze"),
                    detail: String(localized: "Usuwanie było schowane w menu kontekstowym, choć obok stały uruchom, zatrzymaj i terminal. Teraz to przycisk jak reszta — dla kontenerów i dla projektów compose. Potwierdzenie pojawia się jak dotąd, więc chybione kliknięcie nic nie kasuje.")
                ),
                Item(
                    symbol: "arrow.clockwise.circle",
                    title: String(localized: "Kontenery wracają same"),
                    detail: String(localized: "Zamiast zaznaczać je po jednym, program zapamiętuje, co działało, i podnosi to po zalogowaniu. Zatrzymanie kontenera jest teraz sposobem na wypisanie go. Ręczny wybór został jako drugi tryb.")
                ),
                Item(
                    symbol: "square.and.arrow.down",
                    title: String(localized: "Logi: własny pasek i zapis do pliku"),
                    detail: String(localized: "Przyciski nie pływają już na tekście — najnowsze linie przestały się chować za nimi. Doszedł zapis do pliku: albo to, co widać, albo cały log, pobierany od nowa prosto na dysk.")
                ),
                Item(
                    symbol: "accessibility",
                    title: String(localized: "Czytelniej i spójniej"),
                    detail: String(localized: "Każdy przycisk z samą ikoną ma wreszcie nazwę, którą przeczyta VoiceOver — wcześniej miał ją jeden. Przełączniki wyglądają tak samo w całym programie, a karty i okna dialogowe korzystają z jednej skali marginesów i zaokrągleń.")
                )
            ]
        ),
        Entry(
            version: "0.8.3",
            items: [
                Item(
                    symbol: "hand.raised",
                    title: String(localized: "Anonimowe statystyki instalacji"),
                    detail: String(localized: "Sprawdzając aktualizacje program wysyła losowy identyfikator instalacji, swoją wersję i wersję macOS — tyle, by dało się policzyć, ilu ludzi go używa i jakiej wersji. Bez adresu IP, bez nazwy komputera. Wyłącznik jest w Ustawieniach, w sekcji Prywatność.")
                )
            ]
        ),
        Entry(
            version: "0.8.2",
            items: [
                Item(
                    symbol: "play.circle",
                    title: String(localized: "Wybrane kontenery wstają przy logowaniu"),
                    detail: String(localized: "Zaznacz kontenery w ich menu kontekstowym albo jednym przyciskiem przejmij te, które akurat działają. Po zalogowaniu system poczeka aż usługa wstanie i uruchomi je — bez otwierania aplikacji.")
                ),
                Item(
                    symbol: "checkmark.seal",
                    title: String(localized: "Uruchamianie usługi przy logowaniu potwierdzone"),
                    detail: String(localized: "Przełącznik z poprzedniej wersji działa — usługa zostaje włączona po zamknięciu aplikacji. Dziękujemy osobom, które to sprawdziły.")
                ),
            ]
        ),
        Entry(
            version: "0.8.1",
            items: [
                Item(
                    symbol: "power",
                    title: String(localized: "Usługa może startować przy logowaniu"),
                    detail: String(localized: "Usługa uruchomiona z aplikacji gaśnie po jej zamknięciu — to zachowanie systemu, nie decyzja aplikacji. Nowy przełącznik w sekcji System pozwala oddać jej uruchamianie systemowi, dzięki czemu zostaje włączona niezależnie od aplikacji. Działa od następnego zalogowania. To rozwiązanie wymaga jeszcze sprawdzenia w praktyce — daj znać, czy u Ciebie pomaga.")
                ),
            ]
        ),
        Entry(
            version: "0.8.0",
            items: [
                Item(
                    symbol: "point.3.filled.connected.trianglepath.dotted",
                    title: String(localized: "Własna wtyczka sieciowa dla klastra"),
                    detail: String(localized: "Przy tworzeniu klastra Kubernetes można wskazać manifest CNI — na przykład Cilium — zastosowany zaraz po jego starcie. Puste pole oznacza sieć domyślną.")
                ),
                Item(
                    symbol: "sidebar.left",
                    title: String(localized: "Czytelniejsze ikony na pasku bocznym"),
                    detail: String(localized: "Symbole w kolorowych kafelkach są mniejsze i mają margines, więc kafelki czytają się jak ikony, a nie jak pełne bloki koloru.")
                ),
            ]
        ),
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
