import Foundation

/// The alert levels you can choose in the Settings menu. Zero means off; each must hold for five minutes.
struct AlertPreferences: Equatable, Sendable {
    /// Notify when one app uses more than this many cores (off keeps the quiet, unnotified "busy app" line).
    var appCores: Double = 0
    /// Notify when the whole Mac's CPU stays above this percentage.
    var cpuPercent = 0
    /// Notify when uploads stay above this many megabytes per second.
    var uploadMegabytesPerSecond = 0

    static let appCoreChoices: [Double] = [1, 2, 4, 8]
    static let cpuChoices = [70, 80, 90]
    static let uploadChoices = [1, 5, 20, 50]

    private enum Key {
        static let appCores = "alertAppCores"
        static let cpu = "alertCPUPercent"
        static let upload = "alertUploadMBps"
    }

    static func load(from defaults: UserDefaults = .standard) -> AlertPreferences {
        var value = AlertPreferences()
        value.appCores = max(0, defaults.double(forKey: Key.appCores))
        value.cpuPercent = min(max(defaults.integer(forKey: Key.cpu), 0), 100)
        value.uploadMegabytesPerSecond = max(0, defaults.integer(forKey: Key.upload))
        return value
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(appCores, forKey: Key.appCores)
        defaults.set(cpuPercent, forKey: Key.cpu)
        defaults.set(uploadMegabytesPerSecond, forKey: Key.upload)
    }

    func thresholds(base: InsightEngine.Thresholds = .init()) -> InsightEngine.Thresholds {
        var result = base
        result.appAlertCores = appCores > 0 ? appCores : nil
        result.cpuAlert = cpuPercent > 0 ? Double(cpuPercent) / 100 : nil
        result.uploadAlertBytesPerSecond = uploadMegabytesPerSecond > 0 ? Double(uploadMegabytesPerSecond) * 1_000_000 : nil
        return result
    }
}
