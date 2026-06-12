import Foundation

/// Locale-aware links to the project documentation site.
enum AppDocs {
    static func url(anchor: String? = nil) -> URL {
        let isPolish = Locale.preferredLanguages.first?.hasPrefix("pl") ?? false
        let page = isPolish ? "docs.pl.html" : "docs.html"
        let suffix = anchor.map { "#" + $0 } ?? ""
        return URL(string: "https://sembsa.github.io/ContainerDesktop/" + page + suffix)!
    }
}
