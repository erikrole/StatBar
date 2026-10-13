import Foundation

/// Something worth your attention right now, or something that just happened.
struct Insight: Identifiable, Equatable, Sendable {
    enum Severity: Int, Comparable, Sendable {
        case info = 0, warning = 1, critical = 2
        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// Stable per condition ("runaway|Grok Bot"), so a condition is tracked, not re-announced.
    let id: String
    let severity: Severity
    let symbol: String
    let title: String
    let detail: String?
    let since: Date
    /// Whether this is worth a notification, not just a line in the popup.
    let notifies: Bool
}

/// One tick's worth of readings, gathered by `StatMonitor`.
struct Signals: Sendable {
    var now = Date()
    var cpu: Double = 0
    var gpu: Double?
    var memory: MemorySnapshot?
    var thermal: ProcessInfo.ThermalState = .nominal
    var battery: BatterySnapshot?
    var online: Bool?
    var transport: TransportKind = .none
    var interfaceName: String?
    var vpnConnected: Bool?
    /// nil when the slower readings weren't refreshed this tick.
    var processes: [ProcessUsage]?
    var volumes: [VolumeInfo]?
    var sleepBlockers: [SleepBlocker]?
}

/// Turns readings into a short, calm list of what matters. Conditions must hold for a
/// while before they show (no flicker from one busy second), and events such as a drive
/// mounting or the network dropping are logged once as they happen.
struct InsightEngine {
    struct Thresholds {
        var runawayCores = 1.5          // an app using more than 1.5 cores...
        var runawayAfter: TimeInterval = 60   // ...for a minute
        var gpuBusy = 0.9
        var gpuBusyAfter: TimeInterval = 120
        var lowBattery = 20
        var criticalBattery = 10
        var lowDiskFraction = 0.1
        var lowDiskBytes: Int64 = 50_000_000_000
        var largeVolumeBytes: Int64 = 500_000_000_000
        var swapGrowthBytes: UInt64 = 2_000_000_000
        var swapWindow: TimeInterval = 600
        var longSleepBlock: TimeInterval = 30 * 60
        var chargerDeficitAfter: TimeInterval = 60
    }

    var thresholds = Thresholds()
    private(set) var active: [Insight] = []
    private(set) var events: [Insight] = []

    // Memory between ticks.
    private var firstSeen: [String: Date] = [:]
    private var lastProcesses: [ProcessUsage] = []
    private var lastVolumes: [VolumeInfo]?
    private var lastBlockers: [SleepBlocker] = []
    private var lastOnline: Bool?
    private var lastInterface: String?
    private var lastVPN: Bool?
    private var swapSamples: [(Date, UInt64)] = []
    private var blockerSince: [String: Date] = [:]
    private var eventCounter = 0

    static let maxEvents = 12

    /// Folds in one tick and returns the insights that just became active (for notifications).
    @discardableResult
    mutating func update(_ signals: Signals) -> [Insight] {
        let now = signals.now
        if let processes = signals.processes { lastProcesses = processes }
        if let blockers = signals.sleepBlockers { trackBlockers(blockers, now: now) }
        logEvents(signals, now: now)

        var conditions: [Insight] = []
        conditions += runawayApps(now: now)
        conditions += memoryConditions(signals, now: now)
        conditions += heatConditions(signals, now: now)
        conditions += batteryConditions(signals, now: now)
        conditions += diskConditions(signals, now: now)
        conditions += networkConditions(signals, now: now)
        conditions += gpuConditions(signals, now: now)
        conditions += blockerConditions(now: now)

        let previous = Set(active.map(\.id))
        active = conditions.sorted { lhs, rhs in
            lhs.severity != rhs.severity ? lhs.severity > rhs.severity : lhs.since < rhs.since
        }
        return active.filter { !previous.contains($0.id) }
    }

    var highestSeverity: Insight.Severity? { active.map(\.severity).max() }

    // MARK: - Sustained conditions

    /// Returns the start time once `condition` has held for `duration`, else nil.
    private mutating func sustained(_ key: String, _ condition: Bool, for duration: TimeInterval, now: Date) -> Date? {
        let pendingKey = "pending|\(key)"
        guard condition else {
            firstSeen[pendingKey] = nil
            return nil
        }
        let start = firstSeen[pendingKey] ?? now
        firstSeen[pendingKey] = start
        return now.timeIntervalSince(start) >= duration ? start : nil
    }

    private mutating func runawayApps(now: Date) -> [Insight] {
        var insights: [Insight] = []
        let hot = Set(lastProcesses.filter { $0.cpu >= thresholds.runawayCores * 100 && !Self.isSystemProcess($0.name) }.map(\.name))
        // Clear pending timers for apps that cooled off.
        for key in firstSeen.keys where key.hasPrefix("pending|runaway|") {
            let name = String(key.dropFirst("pending|runaway|".count))
            if !hot.contains(name) { firstSeen[key] = nil }
        }
        for process in lastProcesses where hot.contains(process.name) {
            guard let since = sustained("runaway|\(process.name)", true, for: thresholds.runawayAfter, now: now) else { continue }
            insights.append(Insight(
                id: "runaway|\(process.name)",
                severity: .info,
                symbol: "flame",
                title: "\(process.name) is using \(Format.cores(process.cpu)) cores",
                detail: "For \(Format.duration(now.timeIntervalSince(since))). Expected during a render or export.",
                since: since,
                notifies: false
            ))
        }
        return insights
    }

    private mutating func memoryConditions(_ signals: Signals, now: Date) -> [Insight] {
        guard let memory = signals.memory else { return [] }
        var insights: [Insight] = []
        let topMemory = lastProcesses.max { $0.memory < $1.memory }

        if memory.pressure != .normal,
           let since = sustained("memory", true, for: memory.pressure == .critical ? 0 : 20, now: now) {
            let culprit = topMemory.map { "\($0.name) is using the most (\(Format.bytes($0.memory)))." } ?? ""
            insights.append(Insight(
                id: "memory|\(memory.pressure.rawValue)",
                severity: memory.pressure == .critical ? .critical : .warning,
                symbol: "memorychip",
                title: memory.pressure == .critical ? "Memory is critically low" : "Memory is under pressure",
                detail: "\(culprit) Swap is \(Format.bytes(memory.swapUsed)).".trimmingCharacters(in: .whitespaces),
                since: since,
                notifies: memory.pressure == .critical
            ))
        } else if memory.pressure == .normal {
            _ = sustained("memory", false, for: 0, now: now)
        }

        swapSamples.append((now, memory.swapUsed))
        swapSamples.removeAll { now.timeIntervalSince($0.0) > thresholds.swapWindow }
        if let oldest = swapSamples.first, memory.swapUsed > oldest.1,
           memory.swapUsed - oldest.1 >= thresholds.swapGrowthBytes {
            insights.append(Insight(
                id: "swap",
                severity: .info,
                symbol: "arrow.up.right",
                title: "Swap grew \(Format.bytes(memory.swapUsed - oldest.1)) in \(Format.duration(now.timeIntervalSince(oldest.0)))",
                detail: topMemory.map { "\($0.name) is the largest app at \(Format.bytes($0.memory))." },
                since: oldest.0,
                notifies: false
            ))
        }
        return insights
    }

    private mutating func heatConditions(_ signals: Signals, now: Date) -> [Insight] {
        let hot = signals.thermal == .serious || signals.thermal == .critical
        guard let since = sustained("heat", hot || signals.thermal == .fair, for: hot ? 0 : 60, now: now) else { return [] }
        let culprit = lastProcesses.max { $0.cpu < $1.cpu }
        return [Insight(
            // One id for both throttling levels, so serious → critical doesn't notify twice.
            id: hot ? "heat|hot" : "heat|warm",
            severity: hot ? .warning : .info,
            symbol: "thermometer.high",
            title: hot ? "Your Mac is throttling to cool down" : "Your Mac is running warm",
            detail: culprit.map { "\($0.name) is the busiest app (\(Format.cores($0.cpu)) cores)." },
            since: since,
            notifies: hot
        )]
    }

    private mutating func batteryConditions(_ signals: Signals, now: Date) -> [Insight] {
        guard let battery = signals.battery else { return [] }
        var insights: [Insight] = []
        // Hysteresis: enter at 20%, leave at 22%, so a battery hovering on the line
        // doesn't flicker in and out of the list.
        let wasLow = active.contains { $0.id.hasPrefix("battery|") }
        let limit = wasLow ? thresholds.lowBattery + 2 : thresholds.lowBattery
        if let since = sustained("battery", !battery.isPluggedIn && battery.percent <= limit, for: 0, now: now) {
            let critical = battery.percent <= thresholds.criticalBattery
            insights.append(Insight(
                id: critical ? "battery|critical" : "battery|low",
                severity: critical ? .critical : .warning,
                symbol: critical ? "battery.0percent" : "battery.25percent",
                title: "Battery at \(battery.percent)%",
                detail: battery.remainingLabel.map { "\($0) at the current draw." },
                since: since,
                notifies: true
            ))
        }
        // Plugged in but the battery is still draining: the charger can't keep up.
        let deficit = battery.isPluggedIn && !battery.isFull && (battery.flowWatts ?? 0) < -1
        if let since = sustained("charger", deficit, for: thresholds.chargerDeficitAfter, now: now) {
            let charger = battery.adapterWatts.map { "The \($0) W charger" } ?? "The charger"
            insights.append(Insight(
                id: "charger",
                severity: .warning,
                symbol: "powerplug",
                title: "\(charger) can't keep up",
                detail: "The battery is still draining \(Format.wholeWatts(battery.flowWatts ?? 0)) while plugged in. Use a stronger charger or ease the load.",
                since: since,
                notifies: true
            ))
        }
        return insights
    }

    private func diskConditions(_ signals: Signals, now: Date) -> [Insight] {
        (signals.volumes ?? lastVolumes ?? []).compactMap { volume in
            // The absolute floor only applies to big drives; otherwise every camera card
            // or USB stick would count as "almost full" the moment it mounts.
            let fraction = Double(volume.available) / Double(max(volume.total, 1))
            let isLarge = volume.total >= thresholds.largeVolumeBytes
            let low = fraction < thresholds.lowDiskFraction || (isLarge && volume.available < thresholds.lowDiskBytes)
            guard low else { return nil }
            let critical = fraction < thresholds.lowDiskFraction / 2 || (isLarge && volume.available < thresholds.lowDiskBytes / 5)
            return Insight(
                id: "disk|\(volume.id)",
                severity: critical ? .critical : .warning,
                symbol: "externaldrive.badge.exclamationmark",
                title: "\(volume.name) is almost full",
                detail: "\(Format.diskBytes(volume.available)) free of \(Format.diskBytes(volume.total)).",
                since: now,
                notifies: true
            )
        }
    }

    private mutating func networkConditions(_ signals: Signals, now: Date) -> [Insight] {
        guard let since = sustained("offline", signals.online == false, for: 5, now: now) else { return [] }
        return [Insight(
            id: "offline",
            severity: .critical,
            symbol: "wifi.exclamationmark",
            title: "You're offline",
            detail: signals.transport == .none ? "No network connection." : "Connected to \(signals.transport.rawValue), but the internet isn't reachable.",
            since: since,
            notifies: true
        )]
    }

    private mutating func gpuConditions(_ signals: Signals, now: Date) -> [Insight] {
        guard let since = sustained("gpu", (signals.gpu ?? 0) >= thresholds.gpuBusy, for: thresholds.gpuBusyAfter, now: now) else { return [] }
        return [Insight(
            id: "gpu",
            severity: .info,
            symbol: "square.stack.3d.up",
            title: "GPU fully busy",
            detail: "For \(Format.duration(now.timeIntervalSince(since))).",
            since: since,
            notifies: false
        )]
    }

    private mutating func trackBlockers(_ blockers: [SleepBlocker], now: Date) {
        lastBlockers = blockers
        let ids = Set(blockers.map(\.process))
        blockerSince = blockerSince.filter { ids.contains($0.key) }
        for blocker in blockers where blockerSince[blocker.process] == nil {
            blockerSince[blocker.process] = now
        }
    }

    private func blockerConditions(now: Date) -> [Insight] {
        blockerSince.compactMap { process, since in
            guard now.timeIntervalSince(since) >= thresholds.longSleepBlock else { return nil }
            return Insight(
                id: "awake|\(process)",
                severity: .info,
                symbol: "moon.zzz",
                title: "\(process) has kept your Mac awake for \(Format.duration(now.timeIntervalSince(since)))",
                detail: lastBlockers.first { $0.process == process }?.reason,
                since: since,
                notifies: false
            )
        }
    }

    // MARK: - Events

    private mutating func logEvents(_ signals: Signals, now: Date) {
        if let online = signals.online {
            if let lastOnline, lastOnline != online {
                log(online ? "Back online" : "Went offline", symbol: online ? "wifi" : "wifi.slash",
                    severity: online ? .info : .warning, now: now)
            }
            lastOnline = online
        }
        if let name = signals.interfaceName {
            if let lastInterface, lastInterface != name, signals.transport != .none {
                log("Switched to \(signals.transport.rawValue)", symbol: signals.transport.symbolName, severity: .info, now: now)
            }
            lastInterface = name
        }
        if let vpn = signals.vpnConnected {
            if let lastVPN, lastVPN != vpn {
                log(vpn ? "GlobalProtect connected" : "GlobalProtect disconnected", symbol: "lock.shield",
                    severity: .info, now: now)
            }
            lastVPN = vpn
        }
        if let volumes = signals.volumes {
            if let lastVolumes {
                let before = Set(lastVolumes.map(\.id))
                let after = Set(volumes.map(\.id))
                for volume in volumes where !before.contains(volume.id) {
                    log("\(volume.name) mounted", detail: "\(Format.diskBytes(volume.available)) free", symbol: "externaldrive.badge.plus",
                        severity: .info, now: now)
                }
                for volume in lastVolumes where !after.contains(volume.id) {
                    log("\(volume.name) ejected", symbol: "eject", severity: .info, now: now)
                }
            }
            lastVolumes = volumes
        }
    }

    /// Forgets half-elapsed timers, e.g. after the displays slept, so time asleep doesn't
    /// count toward "offline for 5 s" or "kept awake for 30 min".
    mutating func resetPending() {
        firstSeen = [:]
        blockerSince = [:]
        swapSamples = []
        lastProcesses = []
        lastBlockers = []
    }

    private mutating func log(_ title: String, detail: String? = nil, symbol: String, severity: Insight.Severity, now: Date) {
        eventCounter &+= 1
        events.insert(Insight(id: "event|\(eventCounter)", severity: severity, symbol: symbol,
                              title: title, detail: detail, since: now, notifies: false), at: 0)
        if events.count > Self.maxEvents { events.removeLast(events.count - Self.maxEvents) }
    }

    // MARK: - Classification

    static func isSystemProcess(_ name: String) -> Bool {
        ["kernel_task", "WindowServer", "launchd", "mds_stores", "mds", "mdworker_shared", "backupd"].contains(name)
    }
}
