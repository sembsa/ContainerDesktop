import Foundation

/// A release as reported by `helm list -A -o json`.
struct HelmRelease: Codable, Identifiable, Hashable, Sendable {
    let name: String
    let namespace: String
    let revision: String
    let updated: String
    let status: String
    let chart: String
    let appVersion: String?

    enum CodingKeys: String, CodingKey {
        case name, namespace, revision, updated, status, chart
        case appVersion = "app_version"
    }

    var id: String { "\(namespace)/\(name)" }
    var isDeployed: Bool { status.lowercased() == "deployed" }

    /// `helm` reports the chart as `name-version`; split off the trailing
    /// semver so the two can be shown separately.
    var chartName: String {
        guard let separator = chart.range(of: "-", options: .backwards),
              chart[separator.upperBound...].first?.isNumber == true
        else { return chart }
        return String(chart[..<separator.lowerBound])
    }

    var chartVersion: String? {
        guard let separator = chart.range(of: "-", options: .backwards),
              chart[separator.upperBound...].first?.isNumber == true
        else { return nil }
        return String(chart[separator.upperBound...])
    }
}

/// A chart repository from `helm repo list -o json`.
struct HelmRepository: Codable, Identifiable, Hashable, Sendable {
    let name: String
    let url: String

    var id: String { name }
}

/// A chart hit from `helm search repo -o json`.
struct HelmChart: Codable, Identifiable, Hashable, Sendable {
    let name: String
    let version: String
    let appVersion: String?
    let description: String?

    enum CodingKeys: String, CodingKey {
        case name, version, description
        case appVersion = "app_version"
    }

    var id: String { "\(name)@\(version)" }

    /// `grafana/grafana` → `grafana`.
    var repository: String {
        String(name.split(separator: "/").first ?? "")
    }

    var chartName: String {
        String(name.split(separator: "/").last ?? "")
    }
}

/// One entry of `helm history <release> -o json`.
struct HelmRevision: Codable, Identifiable, Hashable, Sendable {
    let revision: Int
    let updated: String
    let status: String
    let chart: String
    let appVersion: String?
    let description: String?

    enum CodingKeys: String, CodingKey {
        case revision, updated, status, chart, description
        case appVersion = "app_version"
    }

    var id: Int { revision }
}
