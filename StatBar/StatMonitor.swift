import Foundation
import Observation

/// Samples the system every two seconds. CPU, GPU and memory run all the time so the
/// menu bar and the short history are always current; disks, fans and the process list
/// are read only while the popover is open.
@MainActor
@Observable
final class StatMonitor {
    struct CoreGroupLoad: Identifiable, Equatable {
        let name: String
        let coreCount: Int
        let load: Double
        let coreLoads: [Double]
        var id: String { name }
    }

    static let historyLength = 60
    static let interval: TimeInterval = 2

    private(set) var cpu: Double = 0
    private(set) var coreGroups: [CoreGroupLoad] = []
    private(set) var gpu: Double?
    private(set) var memory: MemorySnapshot?
    private(set) var cpuHistory: [Double] = []
    private(set) var gpuHistory: [Double] = []
    private(set) var memoryHistory: [Double] = []

    private(set) var volumes: [VolumeInfo] = []
    private(set) var readRate: Double = 0
    private(set) var writeRate: Double = 0
    private(set) var fanSpeeds: [Double] = []
    private(set) var thermalState: ProcessInfo.ThermalState = .nominal
    private(set) var processes: [ProcessUsage] = []

    private var cpuReader = CPUReader()
    private let fans = FanReader()
    private var lastIO: (read: UInt64, write: UInt64, at: Date)?
    private var timer: Timer?
    private var isPopoverVisible = false

    func start() {
        sampleFast()
        thermalState = ProcessInfo.processInfo.thermalState
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        timer?.tolerance = 0.3
    }

    func setPopoverVisible(_ visible: Bool) {
        isPopoverVisible = visible
        if visible {
            lastIO = nil
            sampleDetail()
        }
    }

    private func tick() {
        sampleFast()
        thermalState = ProcessInfo.processInfo.thermalState
        if isPopoverVisible { sampleDetail() }
    }

    private func sampleFast() {
        let loads = cpuReader.sample()
        if !loads.isEmpty {
            cpu = loads.reduce(0, +) / Double(loads.count)
            var index = 0
            coreGroups = cpuReader.groups.map { group in
                let slice = Array(loads[min(index, loads.count)..<min(index + group.coreCount, loads.count)])
                index += group.coreCount
                let load = slice.isEmpty ? 0 : slice.reduce(0, +) / Double(slice.count)
                return CoreGroupLoad(name: group.name, coreCount: group.coreCount, load: load, coreLoads: slice)
            }
            Self.append(cpu, to: &cpuHistory)
        }
        gpu = GPUReader.utilization()
        if let gpu { Self.append(gpu, to: &gpuHistory) }
        memory = MemoryReader.read()
        if let memory { Self.append(memory.usedFraction, to: &memoryHistory) }
    }

    private func sampleDetail() {
        volumes = DiskReader.volumes()
        let totals = DiskReader.ioTotals()
        let now = Date()
        if let lastIO {
            let elapsed = max(now.timeIntervalSince(lastIO.at), 0.5)
            readRate = Double(totals.read &- lastIO.read) / elapsed
            writeRate = Double(totals.write &- lastIO.write) / elapsed
        }
        lastIO = (totals.read, totals.write, now)
        fanSpeeds = fans?.speeds() ?? []
        Task.detached(priority: .utility) {
            let processes = ProcessReader.sample()
            await MainActor.run { [weak self] in self?.processes = processes }
        }
    }

    private static func append(_ value: Double, to history: inout [Double]) {
        history.append(value)
        if history.count > historyLength { history.removeFirst(history.count - historyLength) }
    }

    // MARK: - Menu bar text

    var menuBarText: String {
        "\(Int((cpu * 100).rounded()))%"
    }

    var accessibilitySummary: String {
        var parts = ["CPU \(Int((cpu * 100).rounded())) percent"]
        if let gpu { parts.append("GPU \(Int((gpu * 100).rounded())) percent") }
        if let memory { parts.append("memory pressure \(memory.pressure.label.lowercased())") }
        return "StatBar: " + parts.joined(separator: ", ")
    }

    var thermalLabel: String {
        switch thermalState {
        case .nominal: "Cool"
        case .fair: "Warm"
        case .serious: "Hot, throttling"
        case .critical: "Critical, throttling hard"
        @unknown default: "Unknown"
        }
    }
}
