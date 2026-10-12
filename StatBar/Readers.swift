import Darwin
import Foundation
import IOKit

// Every reader here uses public, unprivileged interfaces: Mach host statistics,
// sysctl, the IORegistry and FileManager. Nothing needs admin rights.

// MARK: - CPU

/// Per-core load from `host_processor_info`, grouped into the chip's core types.
struct CPUReader {
    struct Ticks: Equatable {
        var busy: UInt64
        var total: UInt64
    }

    struct CoreGroup: Equatable, Sendable {
        let name: String
        let coreCount: Int
    }

    /// Core groups in CPU-index order. Apple silicon numbers its lowest performance
    /// level first, so the last `hw.perflevel` comes first.
    let groups: [CoreGroup]
    private var previous: [Ticks] = []

    init() {
        groups = Self.readGroups()
    }

    static func readGroups() -> [CoreGroup] {
        let levels = sysctlInt("hw.nperflevels") ?? 1
        var groups: [CoreGroup] = []
        for level in stride(from: levels - 1, through: 0, by: -1) {
            let count = sysctlInt("hw.perflevel\(level).logicalcpu") ?? 0
            let name = sysctlString("hw.perflevel\(level).name") ?? "Level \(level)"
            if count > 0 { groups.append(CoreGroup(name: name, coreCount: count)) }
        }
        return groups
    }

    /// Load of each core since the previous call, 0...1. Empty on the first call.
    mutating func sample() -> [Double] {
        let current = Self.readTicks()
        defer { previous = current }
        return Self.loads(from: previous, to: current)
    }

    static func loads(from old: [Ticks], to new: [Ticks]) -> [Double] {
        guard old.count == new.count else { return [] }
        return zip(old, new).map { old, new in
            let total = new.total &- old.total
            guard total > 0 else { return 0 }
            return min(1, Double(new.busy &- old.busy) / Double(total))
        }
    }

    private static func readTicks() -> [Ticks] {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return [] }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        return (0..<Int(count)).map { core in
            let base = core * Int(CPU_STATE_MAX)
            let user = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]))
            let system = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]))
            let nice = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]))
            let idle = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]))
            return Ticks(busy: user + system + nice, total: user + system + nice + idle)
        }
    }
}

// MARK: - GPU

/// GPU load from the accelerator's own `PerformanceStatistics` in the IORegistry.
enum GPUReader {
    static func utilization() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }
        var best: Double?
        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer { IOObjectRelease(service); service = IOIteratorNext(iterator) }
            guard let stats = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any],
                let percent = (stats["Device Utilization %"] as? NSNumber)?.doubleValue
            else { continue }
            best = max(best ?? 0, percent / 100)
        }
        return best
    }
}

// MARK: - Memory

struct MemorySnapshot: Equatable, Sendable {
    enum Pressure: Int, Sendable {
        case normal = 1, warning = 2, critical = 4

        var label: String {
            switch self {
            case .normal: "Normal"
            case .warning: "Elevated"
            case .critical: "Critical"
            }
        }
    }

    let total: UInt64
    /// What Activity Monitor calls Memory Used: app memory + wired + compressed.
    let used: UInt64
    let compressed: UInt64
    let cached: UInt64
    let swapUsed: UInt64
    let swapTotal: UInt64
    let pressure: Pressure

    var usedFraction: Double { total == 0 ? 0 : Double(used) / Double(total) }
}

enum MemoryReader {
    static func read() -> MemorySnapshot? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let page = UInt64(sysctlInt64("hw.pagesize") ?? 16_384)
        // Clamped: purgeable pages can briefly outnumber internal ones, and a plain
        // UInt64 subtraction would trap.
        let internalPages = UInt64(stats.internal_page_count)
        let purgeable = UInt64(stats.purgeable_count)
        let app = internalPages > purgeable ? internalPages - purgeable : 0
        let wired = UInt64(stats.wire_count)
        let compressed = UInt64(stats.compressor_page_count)
        let cached = UInt64(stats.external_page_count) + UInt64(stats.purgeable_count)

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0)

        let level = sysctlInt("kern.memorystatus_vm_pressure_level") ?? 1
        return MemorySnapshot(
            total: UInt64(sysctlInt64("hw.memsize") ?? 0),
            used: (app + wired + compressed) * page,
            compressed: compressed * page,
            cached: cached * page,
            swapUsed: swap.xsu_used,
            swapTotal: swap.xsu_total,
            pressure: MemorySnapshot.Pressure(rawValue: level) ?? (level >= 4 ? .critical : .normal)
        )
    }
}

// MARK: - Disks

struct VolumeInfo: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let url: URL
    let total: Int64
    let available: Int64
    let isInternal: Bool

    var usedFraction: Double { total == 0 ? 0 : 1 - Double(available) / Double(total) }
}

enum DiskReader {
    /// Local, browsable volumes: the startup disk first, then media drives by name.
    /// Network shares are left out because asking them for space can stall.
    static func volumes() -> [VolumeInfo] {
        let keys: [URLResourceKey] = [
            .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey, .volumeIsInternalKey, .volumeIsBrowsableKey,
            .volumeIsLocalKey, .volumeIsRootFileSystemKey, .volumeUUIDStringKey,
        ]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        var result: [(VolumeInfo, Bool)] = []
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.volumeIsBrowsable == true, values.volumeIsLocal == true,
                  let total = values.volumeTotalCapacity, total > 0
            else { continue }
            let available = values.volumeAvailableCapacityForImportantUsage
                ?? Int64(values.volumeAvailableCapacity ?? 0)
            result.append((VolumeInfo(
                id: values.volumeUUIDString ?? url.path,
                name: values.volumeName ?? url.lastPathComponent,
                url: url,
                total: Int64(total),
                available: available,
                isInternal: values.volumeIsInternal ?? false
            ), values.volumeIsRootFileSystem ?? false))
        }
        return result
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 }
                return lhs.0.name.localizedStandardCompare(rhs.0.name) == .orderedAscending
            }
            .map(\.0)
    }

    /// Total bytes read and written by every block device since boot.
    static func ioTotals() -> (read: UInt64, write: UInt64) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS else {
            return (0, 0)
        }
        defer { IOObjectRelease(iterator) }
        var read: UInt64 = 0
        var write: UInt64 = 0
        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer { IOObjectRelease(service); service = IOIteratorNext(iterator) }
            guard let stats = IORegistryEntryCreateCFProperty(service, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any] else { continue }
            read += (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
            write += (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
        }
        return (read, write)
    }
}

// MARK: - Fans

/// Reads fan speeds from the System Management Controller. Reading is allowed
/// without privileges; StatBar never writes to the SMC.
final class FanReader {
    private var connection: io_connect_t = 0

    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS else { return nil }
    }

    deinit {
        if connection != 0 { IOServiceClose(connection) }
    }

    /// Current speed of each fan in RPM; empty on Macs without fans.
    func speeds() -> [Double] {
        guard let count = readValue("FNum").map({ Int($0) }), count > 0 else { return [] }
        return (0..<min(count, 4)).compactMap { readValue("F\($0)Ac") }
    }

    private func readValue(_ key: String) -> Double? {
        var input = SMCParams()
        input.key = Self.fourCharCode(key)
        input.data8 = 9 // read key info
        var info = SMCParams()
        guard call(&input, &info) else { return nil }

        input.keyInfo.dataSize = info.keyInfo.dataSize
        input.data8 = 5 // read bytes
        var output = SMCParams()
        guard call(&input, &output) else { return nil }

        let bytes = withUnsafeBytes(of: output.bytes) { Array($0.prefix(Int(info.keyInfo.dataSize))) }
        return Self.decode(bytes, type: info.keyInfo.dataType)
    }

    private func call(_ input: inout SMCParams, _ output: inout SMCParams) -> Bool {
        var outputSize = MemoryLayout<SMCParams>.stride
        let result = IOConnectCallStructMethod(connection, 2, &input, MemoryLayout<SMCParams>.stride, &output, &outputSize)
        return result == KERN_SUCCESS && output.result == 0
    }

    static func decode(_ bytes: [UInt8], type: UInt32) -> Double? {
        switch type {
        case fourCharCode("flt "):
            guard bytes.count >= 4 else { return nil }
            let bits = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            return Double(Float(bitPattern: bits))
        case fourCharCode("fpe2"):
            guard bytes.count >= 2 else { return nil }
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4
        case fourCharCode("ui8 "):
            return bytes.first.map(Double.init)
        case fourCharCode("ui16"):
            guard bytes.count >= 2 else { return nil }
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        default:
            return nil
        }
    }

    static func fourCharCode(_ string: String) -> UInt32 {
        string.utf8.prefix(4).reduce(0) { $0 << 8 | UInt32($1) }
    }
}

/// Mirrors the SMC kernel extension's `SMCKeyData_t` (80 bytes).
struct SMCParams {
    struct Version { var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0; var release: UInt16 = 0 }
    struct PLimit { var version: UInt16 = 0, length: UInt16 = 0; var cpu: UInt32 = 0, gpu: UInt32 = 0, memory: UInt32 = 0 }
    // Explicit padding: Swift would otherwise pack `result` into KeyInfo's tail padding,
    // which C does not, and the kernel would read the wrong command byte.
    struct KeyInfo { var dataSize: UInt32 = 0, dataType: UInt32 = 0; var attributes: UInt8 = 0; var padding: (UInt8, UInt8, UInt8) = (0, 0, 0) }

    var key: UInt32 = 0
    var version = Version()
    var pLimit = PLimit()
    var keyInfo = KeyInfo()
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: (UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0)
}

// MARK: - Processes

struct ProcessUsage: Identifiable, Equatable, Sendable {
    let name: String
    let cpu: Double
    let memory: UInt64
    let count: Int

    var id: String { name }
}

/// Top apps by CPU and memory from `ps`. Helper processes are folded into the app
/// whose bundle they live in, so Chrome's or Dia's dozens of helpers count as one app.
enum ProcessReader {
    static func sample() -> [ProcessUsage] {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/ps")
        process.arguments = ["-Aceo", "pid=,pcpu=,rss=,comm="]
        // ps formats %CPU with the locale's decimal separator; force "12.5", not "12,5".
        process.environment = ["LC_ALL": "C"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return parse(String(decoding: data, as: UTF8.self), path: executablePath)
    }

    static func parse(_ output: String, path: (Int32) -> String? = { _ in nil }) -> [ProcessUsage] {
        var groups: [String: (cpu: Double, memory: UInt64, count: Int)] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count == 4, let pid = Int32(parts[0]), let cpu = Double(parts[1]),
                  let rssKB = UInt64(parts[2]) else { continue }
            let name = path(pid).flatMap(outermostAppName) ?? appName(String(parts[3]))
            var entry = groups[name] ?? (0, 0, 0)
            entry.cpu += cpu
            entry.memory += rssKB * 1024
            entry.count += 1
            groups[name] = entry
        }
        return groups.map { ProcessUsage(name: $0.key, cpu: $0.value.cpu, memory: $0.value.memory, count: $0.value.count) }
    }

    /// "/Applications/Google Chrome.app/Contents/Frameworks/…/Google Chrome Helper.app/…" → "Google Chrome".
    static func outermostAppName(_ path: String) -> String? {
        guard let component = path.split(separator: "/").first(where: { $0.hasSuffix(".app") }) else { return nil }
        return String(component.dropLast(4))
    }

    private static func executablePath(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    static func appName(_ command: String) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        if let range = trimmed.range(of: " Helper") { return String(trimmed[..<range.lowerBound]) }
        if trimmed.hasSuffix("WebContent") || trimmed.hasSuffix("Networking") || trimmed.hasSuffix("GPU"),
           trimmed.hasPrefix("com.apple.WebKit") { return "Web content (all apps)" }
        return trimmed
    }
}

// MARK: - Rates

/// Bytes per second between two cumulative counters. Counters that went backwards
/// (a drive was ejected, an interface reset) read as zero rather than a huge spike.
func counterRate(from old: UInt64, to new: UInt64, over seconds: TimeInterval) -> Double {
    guard new >= old, seconds > 0 else { return 0 }
    return Double(new - old) / seconds
}

// MARK: - sysctl helpers

func sysctlInt(_ name: String) -> Int? {
    var value: Int32 = 0
    var size = MemoryLayout<Int32>.size
    guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
    return Int(value)
}

func sysctlInt64(_ name: String) -> Int64? {
    var value: Int64 = 0
    var size = MemoryLayout<Int64>.size
    guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
    return value
}

func sysctlString(_ name: String) -> String? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var buffer = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
    return String(cString: buffer)
}
