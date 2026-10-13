import Foundation

/// Display strings shared by the menu bar, popover, insights and `--report`.
/// Load fractions are 0...1. Process CPU from `ps` is already a percentage.
enum Format {
    static func percent(_ fraction: Double) -> String {
        guard let value = percentValue(fraction) else { return "–" }
        return "\(value)%"
    }

    /// Rounded percentage in 0...100, or nil when the sample is not a real number.
    static func percentValue(_ fraction: Double) -> Int? {
        guard fraction.isFinite else { return nil }
        let clamped = min(max(fraction, 0), 1)
        return Int((clamped * 100).rounded())
    }

    static func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .memory)
    }

    static func diskBytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(value, 0), countStyle: .file)
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        ByteCountFormatter.string(fromByteCount: clampedByteCount(bytesPerSecond), countStyle: .file) + "/s"
    }

    static func linkSpeed(_ bitsPerSecond: UInt64) -> String {
        if bitsPerSecond >= 1_000_000_000 {
            let gbps = Double(bitsPerSecond) / 1_000_000_000
            let number = abs(gbps.rounded() - gbps) < 0.05 ? posix("%.0f", gbps) : posix("%.1f", gbps)
            return "\(number) Gb/s"
        }
        if bitsPerSecond >= 1_000_000 {
            return "\(bitsPerSecond / 1_000_000) Mb/s"
        }
        if bitsPerSecond >= 1_000 {
            return "\(bitsPerSecond / 1_000) Kb/s"
        }
        return "\(bitsPerSecond) b/s"
    }

    /// Absolute watts for a row that already says whether power is entering or leaving.
    static func watts(_ value: Double) -> String {
        guard value.isFinite else { return "–" }
        return "\(posix("%.1f", abs(value))) W"
    }

    /// Signed watts for the text report, where there is no separate direction label.
    static func signedWatts(_ value: Double) -> String {
        guard value.isFinite else { return "–" }
        let number = posix("%.1f", abs(value))
        return value < 0 ? "-\(number) W" : "\(number) W"
    }

    static func wholeWatts(_ value: Double) -> String {
        guard value.isFinite else { return "–" }
        return "\(posix("%.0f", abs(value))) W"
    }

    static func rpm(_ value: Double) -> String {
        guard value.isFinite, value >= 0, value <= FanReader.maxPlausibleRPM else { return "–" }
        if value < 1 { return "Off" }
        return "\(Int(value.rounded())) rpm"
    }

    static func fanReading(_ rpm: Double, index: Int, count: Int) -> String {
        let prefix = count > 1 ? "Fan \(index + 1): " : "Fan: "
        return prefix + self.rpm(rpm)
    }

    static func thermal(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "Cool"
        case .fair: "Warm"
        case .serious: "Hot, throttling"
        case .critical: "Critical, throttling hard"
        @unknown default: "Unknown"
        }
    }

    /// `ps` %CPU, which can exceed 100 when an app occupies more than one core.
    static func processPercent(_ cpuPercent: Double) -> String {
        guard cpuPercent.isFinite else { return "–" }
        return "\(posix("%.0f", min(max(cpuPercent, 0), 9_999)))%"
    }

    static func cores(_ cpuPercent: Double) -> String {
        guard cpuPercent.isFinite else { return "–" }
        let cores = max(cpuPercent, 0) / 100
        return cpuPercent >= 1_000 ? posix("%.0f", cores) : posix("%.1f", cores)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "under a minute" }
        let minutesDouble = seconds / 60
        let minutes = minutesDouble >= 1_000_000_000 ? 1_000_000_000 : Int(minutesDouble)
        if minutes < 1 { return "under a minute" }
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0 ? "\(hours) h" : "\(hours) h \(remainder) min"
    }

    private static func clampedByteCount(_ value: Double) -> Int64 {
        guard value.isFinite, value > 0 else { return 0 }
        // Stay under the integer boundary. `Double(Int64.max)` rounds up and
        // `Int64` of that value traps.
        if value >= 9.22e18 { return Int64.max }
        return Int64(value.rounded())
    }

    private static func posix(_ format: String, _ value: Double) -> String {
        String(format: format, locale: Locale(identifier: "en_US_POSIX"), value)
    }
}
