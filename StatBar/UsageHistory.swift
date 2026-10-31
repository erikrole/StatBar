import Foundation

/// One hour of readings, summed so an hour is a few numbers no matter how many samples it saw.
struct HourSample: Codable, Equatable, Sendable {
    var hour: Date
    var samples = 0
    var cpuSum = 0.0
    var cpuMax = 0.0
    var memorySum = 0.0
    var downloadBytes = 0.0
    var uploadBytes = 0.0
    /// Free space on the startup disk at the hour's last reading.
    var startupFree: Int64?

    var cpuAverage: Double { samples > 0 ? cpuSum / Double(samples) : 0 }
    var memoryAverage: Double { samples > 0 ? memorySum / Double(samples) : 0 }
}

/// A day's totals for the history chart.
struct DaySummary: Equatable, Identifiable, Sendable {
    let day: Date
    let cpuAverage: Double
    let cpuMax: Double
    let downloadBytes: Double
    let uploadBytes: Double
    var id: Date { day }
}

/// Hourly history for the last 30 days, kept on disk so it survives restarts and updates.
/// Only system-wide numbers are stored: no process names, addresses or network identities.
struct UsageHistory: Codable, Equatable, Sendable {
    static let keepHours = 30 * 24
    static let defaultURL = URL.applicationSupportDirectory.appending(path: "StatBar/history.json")

    private(set) var hours: [HourSample] = []
    private(set) var current: HourSample?

    /// Adds one sample. Returns true when an hour closed, the moment to save.
    @discardableResult
    mutating func record(cpu: Double, memory: Double?, downloadRate: Double, uploadRate: Double, seconds: TimeInterval,
                         startupFree: Int64?, at now: Date, calendar: Calendar = .current) -> Bool {
        let hour = calendar.dateInterval(of: .hour, for: now)?.start ?? now
        var closed = false
        if let open = current, open.hour != hour {
            hours.append(open)
            if hours.count > Self.keepHours { hours.removeFirst(hours.count - Self.keepHours) }
            current = nil
            closed = true
        }
        var sample = current ?? HourSample(hour: hour)
        let clean = { (value: Double) in value.isFinite ? max(0, value) : 0 }
        sample.samples += 1
        sample.cpuSum += clean(cpu)
        sample.cpuMax = max(sample.cpuMax, clean(cpu))
        sample.memorySum += clean(memory ?? 0)
        sample.downloadBytes += clean(downloadRate) * seconds
        sample.uploadBytes += clean(uploadRate) * seconds
        if let startupFree { sample.startupFree = startupFree }
        current = sample
        return closed
    }

    /// One summary per calendar day for the last `count` days that have data, oldest first.
    func days(_ count: Int, calendar: Calendar = .current) -> [DaySummary] {
        let all = hours + (current.map { [$0] } ?? [])
        let grouped = Dictionary(grouping: all) { calendar.startOfDay(for: $0.hour) }
        return grouped.keys.sorted().suffix(count).map { day in
            let items = grouped[day] ?? []
            let samples = items.reduce(0) { $0 + $1.samples }
            return DaySummary(
                day: day,
                cpuAverage: samples > 0 ? items.reduce(0) { $0 + $1.cpuSum } / Double(samples) : 0,
                cpuMax: items.map(\.cpuMax).max() ?? 0,
                downloadBytes: items.reduce(0) { $0 + $1.downloadBytes },
                uploadBytes: items.reduce(0) { $0 + $1.uploadBytes })
        }
    }

    /// Days until the startup disk fills at the rate it shrank over the last three days, or nil
    /// when there's under a day of readings or it isn't shrinking.
    func daysUntilStartupFull(now: Date) -> Double? {
        let points = (hours + (current.map { [$0] } ?? [])).compactMap { sample -> (Double, Double)? in
            guard let free = sample.startupFree, now.timeIntervalSince(sample.hour) <= 3 * 86_400 else { return nil }
            return (sample.hour.timeIntervalSince(now) / 3600, Double(free))
        }
        guard points.count >= 24, let first = points.first, let last = points.last, last.0 - first.0 >= 24 else { return nil }
        let meanX = points.reduce(0) { $0 + $1.0 } / Double(points.count)
        let meanY = points.reduce(0) { $0 + $1.1 } / Double(points.count)
        let covariance = points.reduce(0) { $0 + ($1.0 - meanX) * ($1.1 - meanY) }
        let variance = points.reduce(0) { $0 + ($1.0 - meanX) * ($1.0 - meanX) }
        guard variance > 0 else { return nil }
        let bytesPerHour = covariance / variance
        guard bytesPerHour < 0, last.1 > 0 else { return nil }
        return last.1 / -bytesPerHour / 24
    }

    // MARK: Disk

    static func load(from url: URL = defaultURL) -> UsageHistory {
        guard let data = try? Data(contentsOf: url),
              let history = try? JSONDecoder().decode(UsageHistory.self, from: data) else { return UsageHistory() }
        return history
    }

    func save(to url: URL = defaultURL) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(self).write(to: url, options: .atomic)
        } catch {
            // History is a convenience; a failed write leaves the previous file.
        }
    }
}
