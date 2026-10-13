import Foundation
import Network
import Observation
import UserNotifications

/// Samples the system every two seconds. CPU, GPU and memory run all the time so the
/// menu bar and the short history are always current. Detail refreshes every 30 seconds
/// in the background and more often while the popover is open.
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

    nonisolated static let historyLength = 60
    /// One sample period for CPU, GPU, memory and network throughput. Sixty samples
    /// are about two minutes of history. The timer may slip by its tolerance.
    nonisolated static let interval: TimeInterval = 2
    /// Popover closed: let the kernel group this wake with other system timers.
    nonisolated static let idleSamplingTolerance: TimeInterval = 1
    /// Popover open: the graphs should keep moving, with a little room to coalesce.
    nonisolated static let activeSamplingTolerance: TimeInterval = 0.25

    nonisolated static func samplingTolerance(popoverVisible: Bool) -> TimeInterval {
        popoverVisible ? activeSamplingTolerance : idleSamplingTolerance
    }

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
    /// True after the SMC has been asked at least once. The heat section uses this to
    /// tell "still reading" from "this Mac has no fan data".
    private(set) var hasReadFans = false
    private(set) var thermalState: ProcessInfo.ThermalState = .nominal
    private(set) var processes: [ProcessUsage] = []

    // Attention
    private(set) var insights: [Insight] = []
    private(set) var recentEvents: [Insight] = []
    var notificationsEnabled: Bool = StatMonitor.notificationPreference() {
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
    private var pathMonitor: NWPathMonitor?
    /// Called once per sample so the menu bar can skip a redraw when nothing visible changed.
    var onSample: (() -> Void)?
    private var detailTask: Task<Void, Never>?
    private var isPopoverVisible = false
    private var detailRound = 0
    private var hasBattery = true
    /// Kernel free-space figures that the disk alerts use.
    private var alertVolumes: [VolumeInfo] = []
    private var tickCount = 0
    private var quickSampler = QuickProcessSampler()
    private var detailsInterface: String?
    private(set) var vpnStatusKnown = false
    private var isPaused = false
    private var isStarted = false
    private let detailReader: DetailReader

    typealias DetailReader = @Sendable (Bool, Bool, QuickProcessSampler) async -> DetailSnapshot?

    struct DetailSnapshot: Sendable {
        var volumes: [VolumeInfo] = []
        var alertVolumes: [VolumeInfo] = []
        var totals: (read: UInt64, write: UInt64) = (0, 0)
        var totalsAt = Date()
        var blockers: [SleepBlocker] = []
        var processes: [ProcessUsage]?
        var sampler: QuickProcessSampler?
    }

    init(detailReader: @escaping DetailReader = StatMonitor.readDetail) {
        self.detailReader = detailReader
    }

    isolated deinit {
        samplingTask?.cancel()
        pathMonitor?.cancel()
        detailTask?.cancel()
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        isPaused = false
        resetSamplingBaselines()
        startPathMonitoring()
        if notificationsEnabled { Self.requestNotificationPermission() }
        tick(refreshDetail: true)
        startSampling()
    }

    private func startPathMonitoring() {
        stopPathMonitoring()
        guard !isPaused else { return }
        let monitor = NWPathMonitor()
        pathMonitor = monitor
        // One evaluator for the life of a wake. The handler only publishes when the
        // up/down bit changes, so a repeated path callback does not wake the UI.
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in
                guard let self, !self.isPaused, self.internetReachable != online else { return }
                self.internetReachable = online
            }
        }
        monitor.start(queue: DispatchQueue.global(qos: .utility))
    }

    private func stopPathMonitoring() {
        pathMonitor?.cancel()
        pathMonitor = nil
    }

    func setPopoverVisible(_ visible: Bool) {
        isPopoverVisible = visible
        if visible && !isPaused {
            lastIO = nil
            sampleDetail()
        }
    }

    private func tick(refreshDetail: Bool = false) {
        // The sample runs inside a Swift task, which does not drain an autorelease
        // pool each iteration. IOKit and Foundation temporaries would otherwise sit
        // in the idle footprint.
        autoreleasepool {
            sampleFast()
            thermalState = ProcessInfo.processInfo.thermalState
            // Detail every tick while you're looking, otherwise every 30 s so StatBar can
            // still notice a runaway app, a full disk or a mounted drive on its own.
            if refreshDetail || isPopoverVisible || tickCount % 15 == 0 { sampleDetail() }
            evaluateInsights()
        }
        onSample?()
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
        signals.vpnConnected = vpnStatusKnown ? network.vpnTunnel != nil : nil
        if hasDetail {
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

    static func notificationPreference(in defaults: UserDefaults = .standard) -> Bool {
        // Command-line overrides live in NSArgumentDomain as strings. bool(forKey:)
        // interprets those as well as persisted Bool values without changing either.
        defaults.object(forKey: "notificationsEnabled") == nil || defaults.bool(forKey: "notificationsEnabled")
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
        let routeChanged = route.interfaceName != network.interfaceName
        let identity = route.interfaceName.flatMap { name in
            name != detailsInterface ? networkReader.identity(forBSDName: name) : nil
        }
        let counters = route.interfaceName.flatMap { networkReader.counters(for: $0) }
        applyNetworkSample(route: route, identity: identity, counters: counters, at: Date())
        if routeChanged { sampleNetworkDetails() }
    }

    /// Applies one route/counter sample, also used by deterministic disconnect tests.
    func applyNetworkSample(route: ActiveRoute, identity: InterfaceIdentity?, counters: InterfaceCounters?, at now: Date) {
        if route.interfaceName != network.interfaceName || route.interfaceName == nil {
            network = NetworkState()
            // A new physical route says nothing about whether the VPN survived it.
            // Wait for a fresh VPN read before emitting connection events.
            vpnStatusKnown = route.interfaceName == nil
            detailsInterface = nil
            lastCounters = nil
            downloadRate = 0
            uploadRate = 0
        }
        network.interfaceName = route.interfaceName
        network.routerAddress = route.routerAddress
        if route.interfaceName != nil, network.transport == .none { network.transport = .other }
        // Keep the connection kind in step with the route right away, not on the next
        // 30 s detail round, so events and labels name the right connection.
        if let name = route.interfaceName, let identity {
            detailsInterface = name
            network.transport = identity.transport
            network.displayName = identity.displayName
        }
        guard let name = route.interfaceName else {
            Self.append(0, to: &downloadHistory)
            Self.append(0, to: &uploadHistory)
            return
        }
        if let counters {
            if let last = lastCounters, last.interface == name {
                let elapsed = max(now.timeIntervalSince(last.at), 0.5)
                downloadRate = counterRate(from: last.counters.receivedBytes, to: counters.receivedBytes, over: elapsed)
                uploadRate = counterRate(from: last.counters.sentBytes, to: counters.sentBytes, over: elapsed)
                Self.append(downloadRate, to: &downloadHistory)
                Self.append(uploadRate, to: &uploadHistory)
            }
            lastCounters = (name, counters, now)
        } else {
            downloadRate = 0
            uploadRate = 0
            lastCounters = nil
            Self.append(0, to: &downloadHistory)
            Self.append(0, to: &uploadHistory)
        }
    }

    /// Fan RPM only appears in the popover. Polling the SMC on the background detail
    /// round would wake it every half minute for a number nobody is looking at.
    private func readFansIfNeeded() {
        guard Self.shouldReadFans(popoverVisible: isPopoverVisible, hasReadFans: hasReadFans) else { return }
        fanSpeeds = fans?.speeds() ?? []
        hasReadFans = true
    }

    /// The idle detail round must not touch the SMC. The first read still runs so a
    /// fanless Mac is not stuck on "Reading fans…", and an open popover keeps RPM live.
    nonisolated static func shouldReadFans(popoverVisible: Bool, hasReadFans: Bool) -> Bool {
        popoverVisible || !hasReadFans
    }

    /// Interface names, addresses, link speed and VPN change rarely; read them with the popover open.
    private func sampleNetworkDetails() {
        guard let name = network.interfaceName else { return }
        // The interface's kind and display name only change when the interface does, and
        // looking them up walks every network interface (~4 ms), so cache them per name.
        if detailsInterface != name { refreshInterfaceIdentity(name) }
        let localAddress = networkReader.localIPv4Address(for: name)
        let linkSpeed = network.transport == .ethernet && isPopoverVisible
            ? networkReader.activeEthernetConnections().first { $0.interfaceName == name }?.linkSpeedBitsPerSecond
            : (network.transport == .ethernet ? network.linkSpeedBitsPerSecond : nil)
        let vpn = networkReader.globalProtectStatus()
        applyNetworkDetails(localAddress: localAddress, linkSpeed: linkSpeed, vpn: vpn)
    }

    func applyNetworkDetails(localAddress: String?, linkSpeed: UInt64?, vpn: (known: Bool, tunnel: String?)) {
        network.localAddress = localAddress
        network.linkSpeedBitsPerSecond = linkSpeed
        if vpn.known {
            network.vpnTunnel = vpn.tunnel
            vpnStatusKnown = true
        }
    }

    private func refreshInterfaceIdentity(_ name: String) {
        guard let identity = networkReader.identity(forBSDName: name) else { return }
        detailsInterface = name
        network.transport = identity.transport
        network.displayName = identity.displayName
        network.linkSpeedBitsPerSecond = nil
    }

    private func sampleDetail() {
        // Synchronous OS reads cannot be forcibly cancelled. Keep their slot until they
        // return, even across pause/resume, so a stalled drive cannot accumulate tasks.
        guard !isPaused else { return }
        readFansIfNeeded()
        sampleNetworkDetails()
        guard detailTask == nil else { return }
        // Volumes, disk counters, sleep assertions and `ps` can each block for a while
        // (a waking external drive, a busy system), so they run off the main thread and
        // a slow round is skipped rather than piled up.
        detailRound &+= 1
        let round = detailRound
        // With the popover open: Finder-accurate free space and the full `ps` list.
        // In the background: the cheaper kernel mount table and libproc.
        let thorough = isPopoverVisible
        // `ps` costs ~55 ms, so even with the popover open the app list refreshes every 10 s.
        let refreshProcesses = !thorough || !hasDetail || processes.isEmpty || tickCount % 5 == 0
        let sampler = quickSampler
        let reader = detailReader
        detailTask = Task.detached(priority: .utility) { [weak self] in
            let snapshot = await reader(thorough, refreshProcesses, sampler)
            let cancelled = Task.isCancelled
            await self?.completeDetail(round: round, snapshot: cancelled ? nil : snapshot)
        }
    }

    nonisolated private static func readDetail(thorough: Bool, refreshProcesses: Bool, sampler: QuickProcessSampler) async -> DetailSnapshot? {
        guard !Task.isCancelled else { return nil }
        return autoreleasepool {
            var sampler = sampler
            guard !Task.isCancelled else { return nil }
            // Alerts always judge free space from the kernel figure, so opening the popover
            // (which shows Finder's figure, including purgeable space) can't flip them.
            let quick = DiskReader.quickVolumes()
            guard !Task.isCancelled else { return nil }
            let volumes = thorough ? DiskReader.volumes() : quick
            guard !Task.isCancelled else { return nil }
            let totals = DiskReader.ioTotals()
            let totalsAt = Date()
            let blockers = PowerReader.sleepBlockers()
            guard !Task.isCancelled else { return nil }
            var processes: [ProcessUsage]?
            if refreshProcesses {
                processes = thorough ? ProcessReader.sample() : sampler.sample()
            }
            return DetailSnapshot(volumes: volumes, alertVolumes: quick, totals: totals, totalsAt: totalsAt,
                                  blockers: blockers, processes: processes, sampler: thorough ? nil : sampler)
        }
    }

    private func completeDetail(round: Int, snapshot: DetailSnapshot?) {
        detailTask = nil
        guard round == detailRound, !isPaused else {
            if isStarted && !isPaused { sampleDetail() }
            return
        }
        guard let snapshot else { return }
        applyDetail(round: round, volumes: snapshot.volumes, alertVolumes: snapshot.alertVolumes,
                    totals: snapshot.totals, totalsAt: snapshot.totalsAt, blockers: snapshot.blockers,
                    processes: snapshot.processes, sampler: snapshot.sampler)
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
        // Pausing invalidates the round even if an OS call ignores cancellation.
        guard round == detailRound else { return }
        if let sampler { quickSampler = sampler }
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
            stopPathMonitoring()
            detailTask?.cancel()
            detailRound &+= 1
        } else {
            resetSamplingBaselines()
            if isStarted {
                startPathMonitoring()
                tick(refreshDetail: true)
                startSampling()
            }
        }
    }

    func stop() {
        setPaused(true)
        isStarted = false
    }

    private func resetSamplingBaselines() {
        lastIO = nil
        lastCounters = nil
        readRate = 0
        writeRate = 0
        downloadRate = 0
        uploadRate = 0
        cpuReader.reset()
        quickSampler = QuickProcessSampler()
        hasDetail = false
        engine.resetPending()
    }

    /// One sleep for every reading. Tolerance lets the kernel coalesce the wake;
    /// it is larger while the popover is closed.
    private func startSampling() {
        samplingTask?.cancel()
        samplingTask = Task { [weak self] in
            while !Task.isCancelled {
                let tolerance = Self.samplingTolerance(popoverVisible: self?.isPopoverVisible == true)
                try? await Task.sleep(for: .seconds(Self.interval), tolerance: .seconds(tolerance))
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

    /// What the status item actually draws. Equal values must not touch the button:
    /// assigning an image or title marks the menu bar dirty in WindowServer.
    var menuBarPresentation: MenuBarPresentation {
        MenuBarPresentation.make(cpu: cpu, attention: attentionLevel)
    }

    var accessibilitySummary: String {
        var parts = ["CPU \(Format.percentValue(cpu).map(String.init) ?? "unavailable") percent"]
        if let gpu, let value = Format.percentValue(gpu) {
            parts.append("GPU \(value) percent")
        }
        if let memory { parts.append("memory pressure \(memory.pressure.label.lowercased())") }
        return "StatBar: " + parts.joined(separator: ", ")
    }

    var thermalLabel: String { Format.thermal(thermalState) }
}

enum MenuBarAttention: Hashable {
    case none, warning, critical

    var symbolName: String {
        switch self {
        case .none: "gauge.with.dots.needle.33percent"
        case .warning, .critical: "exclamationmark.triangle"
        }
    }
}

struct MenuBarPresentation: Equatable {
    var title: String
    var attention: MenuBarAttention

    static func make(cpu: Double, attention: Insight.Severity?) -> MenuBarPresentation {
        let level: MenuBarAttention = switch attention {
        case .critical: .critical
        case .warning: .warning
        default: .none
        }
        return MenuBarPresentation(title: Format.percent(cpu), attention: level)
    }
}
