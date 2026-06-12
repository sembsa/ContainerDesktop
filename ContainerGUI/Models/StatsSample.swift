import Foundation

/// A single resource-usage sample from `container stats --format json`.
struct StatsSample: Codable, Identifiable, Sendable, Hashable {
    let id: String
    let cpuUsageUsec: Int64?
    let memoryUsageBytes: Int64?
    let memoryLimitBytes: Int64?
    let blockReadBytes: Int64?
    let blockWriteBytes: Int64?
    let networkRxBytes: Int64?
    let networkTxBytes: Int64?
    let numProcesses: Int?

    var memoryFraction: Double? {
        guard let used = memoryUsageBytes, let limit = memoryLimitBytes, limit > 0 else { return nil }
        return Double(used) / Double(limit)
    }
}
