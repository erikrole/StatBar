import Foundation
import Network
import Observation
import UserNotifications

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

    // Attention
    private(set) var insights: [Insight] = []
    private(set) var recentEvents: [Insight] = []
    var notificationsEnabled: Bool = UserDefaults.standard.object(forKey: "notificationsEnabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(notificationsEnabled, forKey: "notificationsEnabled")
            if notificationsEnabled { Self.requestNotificationPermission() }
        }
    }
    private var engine = InsightEngine()
    private var hasDetail = false
    private var lastNotified: [String: Date] = [:]
    var attentionLevel: Insight.Severity? { insights.map(\.severity).max() }

    // Power (formerly PowerBar)
    private(set) var battery: BatterySnapshot?
    private(set) var sleepBlockers: [SleepBlocker] = []

    // Network (formerly NetBar)
    struct NetworkState: Equatable {
        var transport: TransportKind = .none
        var interfaceName: String?
        var displayName: String?
        var localAddress: String?
        var routerAddress: String?
        var linkSpeedBitsPerSecond: UInt64?
        var vpnTunnel: String?
    }
    private(set) var network = NetworkState()
    private(set) var internetReachable: Bool?
    private(set) var downloadRate: Double = 0
    private(set) var uploadRate: Double = 0
    private(set) var downloadHistory: [Double] = []
    private(set) var uploadHistory: [Double] = []
    private let networkReader = SystemNetworkReader()
    private var lastCounters: (interface: String, counters: InterfaceCounters, at: Date)?

    private var cpuReader = CPUReader()
    private let fans = FanReader()
    private var lastIO: (read: UInt64, write: UInt64, at: Date)?
    private var samplingTask: Task<Void, Never>?
    private var pathTask: Task<Void, Never>?
    private var isPopoverVisible = false
    private var detailStartedAt: Date?
    private var detailRound = 0
    private var hasBattery = true
    /// Kernel free-space figures that the disk alerts use.
    private var alertVolumes: [VolumeInfo] = []
    private var tickCount = 0
    private var quickSampler = QuickProcessSampler()
    private var detailsInterface: String?
    private var isPaused = false

    func start() {
        pathTask = Task { [weak self] in
            for await path in NWPathMonitor() {
                guard let self else { return }
                self.internetReachable = path.status == .satisfied
            }
        }
        if notificationsEnabled { Self.requestNotificationPermission() }
        sampleFast()
        thermalState = ProcessInfo.processInfo.thermalState
        startSampling()
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
        // Detail every tick while you're looking, otherwise every 30 s so StatBar can
        // still notice a runaway app, a full disk or a mounted drive on its own.
        if isPopoverVisible || tickCount % 15 == 0 { sampleDetail() }
        evaluateInsights()
    }

    private func evaluateInsights() {
        var signals = Signals()
        signals.cpu = cpu
        signals.gpu = gpu
        signals.memory = memory
        signals.thermal = thermalState
        signals.battery = battery
        signals.online = internetReachable
        signals.transport = network.transport
        signals.interfaceName = network.interfaceName
        if hasDetail {
            signals.vpnConnected = network.vpnTunnel != nil
            signals.processes = processes
            signals.volumes = alertVolumes
            signals.sleepBlockers = sleepBlockers
        }
        let fresh = engine.update(signals)
        insights = engine.active
        recentEvents = engine.events
        notify(fresh)
    }

    /// Notifies once per condition, and not again for the same condition within 30 min,
    /// so something that flaps doesn't nag.
    private func notify(_ fresh: [Insight]) {
        guard notificationsEnabled, !Self.isRunningTests else { return }
        let now = Date()
        for insight in fresh where insight.notifies {
            if let last = lastNotified[insight.id], now.timeIntervalSince(last) < 30 * 60 { continue }
            lastNotified[insight.id] = now
            let content = UNMutableNotificationContent()
            content.title = insight.title
            if let detail = insight.detail { content.body = detail }
            content.interruptionLevel = insight.severity == .critical ? .timeSensitive : .active
            let request = UNNotificationRequest(identifier: insight.id, content: content, trigger: nil)
            Task { try? await UNUserNotificationCenter.current().add(request) }
        }
    }

    static func requestNotificationPermission() {
        guard !isRunningTests else { return }
        Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
    }

    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
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
        // Battery state changes slowly; every fifth tick (10 s) is plenty, and always
        // while the popover is open.
        tickCount &+= 1
        if hasBattery && (battery == nil || isPopoverVisible || tickCount % 5 == 0) {
            battery = PowerReader.battery()
            // Desktops have no battery; stop asking after the first empty answer.
            if battery == nil { hasBattery = false }
        }
        sampleNetworkRates()
    }

    /// Route and throughput every tick, so the graphs have history when the popover opens.
    private func sampleNetworkRates() {
        let route = networkReader.activeRoute()
        network.interfaceName = route.interfaceName
        network.routerAddress = route.routerAddress
        // Keep the connection kind in step with the route right away, not on the next
        // 30 s detail round, so events and labels name the right connection.
        if let name = route.interfaceName, name != detailsInterface {
            refreshInterfaceIdentity(name)
        }
        guard let name = route.interfaceName else {
            network.transport = .none
            detailsInterface = nil
            downloadRate = 0
            uploadRate = 0
            lastCounters = nil
            return
        }
        let now = Date()
        if let counters = networkReader.counters(for: name) {
            if let last = lastCounters, last.interface == name {
                let elapsed = max(now.timeIntervalSince(last.at), 0.5)
                downloadRate = counterRate(from: last.counters.receivedBytes, to: counters.receivedBytes, over: elapsed)
                uploadRate = counterRate(from: last.counters.sentBytes, to: counters.sentBytes, over: elapsed)
                Self.append(downloadRate, to: &downloadHistory)
                Self.append(uploadRate, to: &uploadHistory)
            }
            lastCounters = (name, counters, now)
        }
    }

    /// Interface names, addresses, link speed and VPN change rarely; read them with the popover open.
    private func sampleNetworkDetails() {
        guard let name = network.interfaceName else { return }
        // The interface's kind and display name only change when the interface does, and
        // looking them up walks every network interface (~4 ms), so cache them per name.
        if detailsInterface != name { refreshInterfaceIdentity(name) }
        network.localAddress = networkReader.localIPv4Address(for: name)
        network.linkSpeedBitsPerSecond = network.transport == .ethernet && isPopoverVisible
            ? networkReader.activeEthernetConnections().first { $0.interfaceName == name }?.linkSpeedBitsPerSecond
            : (network.transport == .ethernet ? network.linkSpeedBitsPerSecond : nil)
        let vpn = networkReader.globalProtectStatus()
        if vpn.known { network.vpnTunnel = vpn.tunnel }
    }

    private func refreshInterfaceIdentity(_ name: String) {
        detailsInterface = name
        network.transport = networkReader.transport(forBSDName: name) ?? .other
        network.displayName = networkReader.displayName(forBSDName: name)
        network.linkSpeedBitsPerSecond = nil
    }

    private func sampleDetail() {
        fanSpeeds = fans?.speeds() ?? []
        sampleNetworkDetails()
        // Volumes, disk counters, sleep assertions and `ps` can each block for a while
        // (a waking external drive, a busy system), so they run off the main thread and
        // a slow round is skipped rather than piled up.
        // Skip while a round is in flight, but not forever: a round stuck on a dead mount
        // or a wedged daemon is abandoned after 20 s so the readings don't freeze.
        if let started = detailStartedAt, Date().timeIntervalSince(started) < 20 { return }
        detailStartedAt = Date()
        detailRound &+= 1
        let round = detailRound
        // With the popover open: Finder-accurate free space and the full `ps` list (every
        // other tick). In the background: the kernel mount table and libproc, which cost
        // a few milliseconds instead of ~140 ms per round.
        let thorough = isPopoverVisible
        // `ps` costs ~55 ms, so even with the popover open the app list refreshes every 10 s.
        let refreshProcesses = !thorough || processes.isEmpty || tickCount % 5 == 0
        var sampler = quickSampler
        Task.detached(priority: .utility) { [weak self] in
            // Alerts always judge free space from the kernel figure, so opening the popover
            // (which shows Finder's figure, including purgeable space) can't flip them.
            let quick = DiskReader.quickVolumes()
            let volumes = thorough ? DiskReader.volumes() : quick
            let totals = DiskReader.ioTotals()
            let totalsAt = Date()
            let blockers = PowerReader.sleepBlockers()
            var processes: [ProcessUsage]?
            if refreshProcesses {
                processes = thorough ? ProcessReader.sample() : sampler.sample()
            }
            await self?.applyDetail(round: round, volumes: volumes, alertVolumes: quick, totals: totals, totalsAt: totalsAt,
                                    blockers: blockers, processes: processes, sampler: thorough ? nil : sampler)
        }
    }

    private func applyDetail(
        round: Int,
        volumes: [VolumeInfo],
        alertVolumes: [VolumeInfo],
        totals: (read: UInt64, write: UInt64),
        totalsAt now: Date,
        blockers: [SleepBlocker],
        processes: [ProcessUsage]?,
        sampler: QuickProcessSampler?
    ) {
        // A round that was given up on and finished late doesn't overwrite newer data.
        guard round == detailRound else { return }
        if let sampler { quickSampler = sampler }
        detailStartedAt = nil
        hasDetail = true
        self.volumes = volumes
        self.alertVolumes = alertVolumes
        if let lastIO {
            let elapsed = max(now.timeIntervalSince(lastIO.at), 0.5)
            readRate = counterRate(from: lastIO.read, to: totals.read, over: elapsed)
            writeRate = counterRate(from: lastIO.write, to: totals.write, over: elapsed)
        }
        lastIO = (totals.read, totals.write, now)
        sleepBlockers = blockers
        if let processes { self.processes = processes }
    }

    /// Stops sampling while the displays sleep, so StatBar costs nothing overnight.
    func setPaused(_ paused: Bool) {
        guard paused != isPaused else { return }
        isPaused = paused
        if paused {
            samplingTask?.cancel()
            samplingTask = nil
        } else {
            lastIO = nil
            lastCounters = nil
            engine.resetPending()
            tick()
            startSampling()
        }
    }

    /// Ticks every `interval` on the main actor; a sleeping task keeps sampling alive
    /// while the popover scrolls, with the same tolerance the old timer had.
    private func startSampling() {
        samplingTask?.cancel()
        samplingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.interval), tolerance: .seconds(Self.interval * 0.15))
                guard !Task.isCancelled, let self else { return }
                self.tick()
            }
        }
    }

    private static func append(_ value: Double, to history: inout [Double]) {
        history.append(value.isFinite ? max(0, value) : 0)
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
