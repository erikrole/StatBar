import Foundation
import IOKit
import IOKit.pwr_mgt

/// Battery and power state from the AppleSmartBattery registry entry, plus what is
/// keeping the Mac awake. Public IOKit only.
struct BatterySnapshot: Equatable, Sendable {
    let percent: Int
    let isCharging: Bool
    let isPluggedIn: Bool
    let isFull: Bool
    /// Minutes to empty when on battery, or to full when charging; nil while macOS estimates.
    let minutesRemaining: Int?
    /// Battery flow in watts: positive while charging, negative while draining.
    let flowWatts: Double?
    let adapterWatts: Int?
    let cycleCount: Int?
    /// Maximum capacity as a fraction of design capacity.
    let health: Double?

    var stateLabel: String {
        if isFull { return "Charged" }
        if isCharging { return "Charging" }
        if isPluggedIn { return "Plugged in, not charging" }
        return "On battery"
    }

    var remainingLabel: String? {
        guard let minutesRemaining, minutesRemaining > 0, !isFull else { return nil }
        let hours = minutesRemaining / 60
        let minutes = minutesRemaining % 60
        let time = hours > 0 ? "\(hours) h \(minutes) min" : "\(minutes) min"
        return isCharging ? "\(time) to full" : "\(time) left"
    }
}

struct SleepBlocker: Identifiable, Equatable, Sendable {
    let process: String
    let reason: String
    let preventsDisplaySleep: Bool
    var id: String { "\(process)|\(reason)" }
}

enum PowerReader {
    static func battery() -> BatterySnapshot? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        // Ask for just these keys: the full property set includes large logs and is
        // the most expensive thing StatBar would otherwise read every tick.
        let keys = ["CurrentCapacity", "MaxCapacity", "IsCharging", "ExternalConnected", "FullyCharged",
                    "AvgTimeToFull", "AvgTimeToEmpty", "Voltage", "InstantAmperage", "Amperage",
                    "AdapterDetails", "CycleCount", "AppleRawMaxCapacity", "DesignCapacity", "BatteryData"]
        var dictionary: [String: Any] = [:]
        for key in keys {
            if let value = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() {
                dictionary[key] = value
            }
        }
        return snapshot(from: dictionary)
    }

    static func snapshot(from battery: [String: Any]) -> BatterySnapshot? {
        func int(_ key: String) -> Int64? { (battery[key] as? NSNumber)?.int64Value }
        func bool(_ key: String) -> Bool { (battery[key] as? NSNumber)?.boolValue ?? false }

        guard let current = int("CurrentCapacity"), let max = int("MaxCapacity"), max > 0 else { return nil }
        let percent = Int((Double(current) / Double(max) * 100).rounded())
        let isCharging = bool("IsCharging")
        let timeKey = isCharging ? "AvgTimeToFull" : "AvgTimeToEmpty"
        // 65535 means "still calculating".
        let minutes = int(timeKey).flatMap { $0 > 0 && $0 < 65535 ? Int($0) : nil }

        let millivolts = int("Voltage")
        let milliamps = int("InstantAmperage") ?? int("Amperage")
        let flow = millivolts.flatMap { mv in milliamps.map { Double(mv) * Double($0) / 1_000_000 } }

        let adapter = (battery["AdapterDetails"] as? [String: Any])?["Watts"] as? NSNumber
        // Recent macOS keeps the mAh figures inside BatteryData; System Settings' Maximum
        // Capacity is nominal charge capacity over design capacity.
        let data = battery["BatteryData"] as? [String: Any] ?? [:]
        func dataInt(_ key: String) -> Int64? { (data[key] as? NSNumber)?.int64Value ?? int(key) }
        let rawMax = dataInt("NominalChargeCapacity") ?? dataInt("AppleRawMaxCapacity")
        let design = dataInt("DesignCapacity")
        let health = rawMax.flatMap { raw in design.flatMap { $0 > 0 ? Double(raw) / Double($0) : nil } }

        return BatterySnapshot(
            percent: min(100, Swift.max(0, percent)),
            isCharging: isCharging,
            isPluggedIn: bool("ExternalConnected"),
            isFull: bool("FullyCharged"),
            minutesRemaining: minutes,
            flowWatts: flow,
            adapterWatts: bool("ExternalConnected") ? adapter?.intValue : nil,
            cycleCount: int("CycleCount").map(Int.init),
            health: health.map { Swift.min($0, 1) }
        )
    }

    /// Processes holding an assertion that stops the Mac or its display from sleeping.
    static func sleepBlockers() -> [SleepBlocker] {
        var byProcess: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&byProcess) == kIOReturnSuccess,
              let dictionary = byProcess?.takeRetainedValue() as? [NSNumber: [[String: Any]]]
        else { return [] }

        let systemTypes: Set<String> = ["PreventUserIdleSystemSleep", "PreventSystemSleep", "NoIdleSleepAssertion"]
        let displayTypes: Set<String> = ["PreventUserIdleDisplaySleep", "NoDisplaySleepAssertion"]
        var blockers: [SleepBlocker] = []
        for (pid, assertions) in dictionary {
            for assertion in assertions {
                guard let type = assertion["AssertType"] as? String,
                      systemTypes.contains(type) || displayTypes.contains(type),
                      (assertion["AssertLevel"] as? NSNumber)?.intValue ?? 255 > 0
                else { continue }
                let process = assertion["Process Name"] as? String ?? processName(pid.int32Value) ?? "PID \(pid)"
                let reason = (assertion["AssertName"] as? String) ?? type
                blockers.append(SleepBlocker(process: process, reason: reason, preventsDisplaySleep: displayTypes.contains(type)))
            }
        }
        // Drop macOS's own housekeeping so the list shows what you started.
        let ignored: Set<String> = ["powerd", "coreaudiod", "WindowServer", "sharingd", "useractivityd", "bluetoothd"]
        return Array(Set(blockers.filter { !ignored.contains($0.process) }))
            .sorted { $0.process.localizedStandardCompare($1.process) == .orderedAscending }
    }

    private static func processName(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return URL(filePath: String(cString: buffer)).lastPathComponent
    }
}

extension SleepBlocker: Hashable {}
