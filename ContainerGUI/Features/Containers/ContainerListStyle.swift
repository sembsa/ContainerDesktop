import Foundation

/// How the container list is presented. Persisted via `@AppStorage`.
///
/// Cards are the default: they show state, live meters and controls per
/// container. The table is kept for dense, sortable scanning of many columns —
/// the two answer different questions, so neither replaces the other.
enum ContainerListStyle: String, CaseIterable, Identifiable, Sendable {
    case cards
    case table

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cards: String(localized: "Karty")
        case .table: String(localized: "Tabela")
        }
    }

    var symbol: String {
        switch self {
        case .cards: "square.grid.2x2"
        case .table: "tablecells"
        }
    }
}
