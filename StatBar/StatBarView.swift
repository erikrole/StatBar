import AppKit
import SwiftUI

struct StatBarView: View {
    @Bindable var monitor: StatMonitor
    @Bindable var launchAtLogin: LaunchAtLoginController
    @AppStorage("processSort") private var processSort: ProcessSort = .cpu
    @AppStorage("showCoreDetails") private var showCoreDetails = false
    @AppStorage("showMemoryDetails") private var showMemoryDetails = false
    @AppStorage("showPowerDetails") private var showPowerDetails = false
    @AppStorage("showNetworkDetails") private var showNetworkDetails = false
    /// Set by `--snapshot`, which can't draw AppKit controls such as the segmented picker.
    var isSnapshot = false

    enum ProcessSort: String, CaseIterable, Identifiable {
        case cpu = "CPU"
        case memory = "Memory"
        var id: Self { self }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                cards
            }
            Divider()
            footer
        }
        .frame(width: 360, height: 600)
    }

    // MARK: - Cards

    /// Every section, without the scroll view, so `--snapshot` can render it too.
    var cards: some View {
        VStack(spacing: 0) {
            nowCard
            VStack(spacing: 0) {
                computeCard
                memoryCard
                powerCard
                networkCard
                disksCard
                heatCard
                processesCard
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 6)
        }
    }

    /// What needs attention right now, most serious first, plus what just happened.
    private var nowCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            if monitor.insights.isEmpty {
                Text("All quiet")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(monitor.insights) { insight in
                    InsightRow(insight: insight)
                }
            }
            if !monitor.recentEvents.isEmpty {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(monitor.recentEvents) { event in
                            HStack(alignment: .center, spacing: 8) {
                                Image(systemName: event.symbol)
                                    .frame(width: 16)
                                Text(event.title)
                                if let detail = event.detail { Text("· \(detail)").foregroundStyle(.tertiary) }
                                Spacer()
                                Text(event.since.formatted(date: .omitted, time: .shortened))
                                    .foregroundStyle(.tertiary)
                                    .monospacedDigit()
                            }
                            .lineLimit(1)
                        }
                    }
                    .padding(.top, 4)
                } label: {
                    Text("Recent · \(monitor.recentEvents.count)")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, monitor.insights.isEmpty && monitor.recentEvents.isEmpty ? 10 : 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(nowBackground)
        .animation(.easeOut(duration: 0.2), value: monitor.attentionLevel)
    }

    /// A wash only when something needs a look. A quiet Mac stays on the popover's own paper.
    private var nowBackground: Color {
        switch monitor.attentionLevel {
        case .critical: Color.red.opacity(0.10)
        case .warning: Color.orange.opacity(0.12)
        default: Color.clear
        }
    }

    private var computeCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    computeMetric("CPU", value: Format.percent(monitor.cpu), history: monitor.cpuHistory, tint: .blue)
                    Divider()
                    computeMetric("GPU", value: monitor.gpu.map(Format.percent) ?? "–", history: monitor.gpuHistory, tint: .purple)
                }
                .fixedSize(horizontal: false, vertical: true)
                if !monitor.coreGroups.isEmpty {
                    Details(isExpanded: $showCoreDetails, label: "CPU cores") {
                        ForEach(monitor.coreGroups) { group in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text("\(group.name) · \(group.coreCount) cores")
                                    Spacer(minLength: 8)
                                    Text(Format.percent(group.load)).monospacedDigit()
                                }
                                CoreBars(loads: group.coreLoads)
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 10)
        }
    }

    private func computeMetric(_ title: String, value: String, history: [Double], tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                Spacer(minLength: 4)
                Text(value).monospacedDigit()
            }
            .font(.subheadline.weight(.semibold))
            Sparkline(values: history, tint: tint, height: 28)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title) \(value == "–" ? "unavailable" : value)")
    }

    @ViewBuilder
    private var memoryCard: some View {
        if let memory = monitor.memory {
            VStack(spacing: 0) {
                Divider()
                Card(title: "Memory", value: memory.pressure.label, valueColor: pressureColor(memory.pressure)) {
                    UsageBar(fraction: memory.usedFraction, tint: pressureColor(memory.pressure))
                    Details(isExpanded: $showMemoryDetails, label: "\(Format.bytes(memory.used)) of \(Format.bytes(memory.total)) used") {
                        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                            StatRow("Compressed", Format.bytes(memory.compressed))
                            StatRow("Cached files", Format.bytes(memory.cached))
                            StatRow("Swap", memory.swapTotal == 0 ? "None" : "\(Format.bytes(memory.swapUsed)) of \(Format.bytes(memory.swapTotal))")
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var powerCard: some View {
        if let battery = monitor.battery {
            VStack(spacing: 0) {
                Divider()
                Card(
                    title: "Power",
                    value: "\(battery.percent)%",
                    valueColor: batteryTint(battery),
                    symbol: batterySymbol(battery)
                ) {
                    UsageBar(fraction: Double(battery.percent) / 100, tint: batteryTint(battery))
                    Details(isExpanded: $showPowerDetails, label: [battery.stateLabel, battery.remainingLabel].compactMap { $0 }.joined(separator: " · ")) {
                        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                            if let flow = battery.flowWatts, flow.isFinite, abs(flow) >= 0.1 {
                                StatRow(flow > 0 ? "Into battery" : "Drawing", Format.watts(flow))
                            }
                            if let adapter = battery.adapterWatts {
                                StatRow("Charger", "\(adapter) W")
                            }
                            if let health = battery.health {
                                StatRow("Health", "\(Format.percent(health))\(battery.cycleCount.map { " · \($0) cycles" } ?? "")")
                            }
                        }
                        if !monitor.sleepBlockers.isEmpty {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Keeping your Mac awake")
                                    .font(.caption.weight(.medium))
                                ForEach(monitor.sleepBlockers) { blocker in
                                    let scope = blocker.preventsDisplaySleep ? "Display" : "System"
                                    Text("\(scope) · \(blocker.process): \(blocker.reason)")
                                        .fixedSize(horizontal: false, vertical: true)
                                        .help(blocker.reason)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var networkCard: some View {
        let network = monitor.network
        let status: (String, Color) = switch monitor.internetReachable {
        case .some(true): ("Online", .green)
        case .some(false): ("Offline", .red)
        case .none: ("Checking", .secondary)
        }
        return VStack(spacing: 0) {
            Divider()
            Card(title: "Network", value: status.0, valueColor: status.1, symbol: network.transport.symbolName) {
                HStack(spacing: 12) {
                    RateGraph(label: "Down", rate: monitor.downloadRate, values: monitor.downloadHistory, tint: .blue, symbol: "arrow.down")
                    RateGraph(label: "Up", rate: monitor.uploadRate, values: monitor.uploadHistory, tint: .orange, symbol: "arrow.up")
                }
                Details(isExpanded: $showNetworkDetails, label: network.displayName ?? network.transport.rawValue) {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                        if let speed = network.linkSpeedBitsPerSecond { StatRow("Link speed", Format.linkSpeed(speed)) }
                        if let address = network.localAddress { StatRow("IP address", address) }
                        if let router = network.routerAddress { StatRow("Router", router) }
                        if SystemNetworkReader.isGlobalProtectInstalled {
                            let vpnStatus = monitor.vpnStatusKnown
                                ? (network.vpnTunnel == nil ? "GlobalProtect off" : "GlobalProtect connected")
                                : "Checking GlobalProtect"
                            StatRow("VPN", vpnStatus)
                        }
                    }
                }
            }
        }
    }

    private var disksCard: some View {
        VStack(spacing: 0) {
            Divider()
            Card(title: "Disks", value: nil) {
                ForEach(monitor.volumes) { volume in
                    let status: Color = volume.usedFraction > 0.9 ? .orange : .secondary
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .center, spacing: 6) {
                            Image(systemName: volume.isInternal ? "internaldrive" : "externaldrive")
                                .foregroundStyle(.secondary)
                            Text(volume.name).lineLimit(1)
                            Spacer(minLength: 8)
                            Text("\(Format.diskBytes(volume.available)) free")
                                .monospacedDigit()
                                .foregroundStyle(status)
                        }
                        .font(.caption)
                        UsageBar(fraction: volume.usedFraction, tint: volume.usedFraction > 0.9 ? .orange : .teal)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { NSWorkspace.shared.open(volume.url) }
                    .help("Open \(volume.name)")
                    .accessibilityAddTraits(.isButton)
                }
                HStack(spacing: 16) {
                    Label(Format.rate(monitor.readRate), systemImage: "arrow.down")
                    Label(Format.rate(monitor.writeRate), systemImage: "arrow.up")
                    Spacer()
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .symbolRenderingMode(.monochrome)
            }
        }
    }

    private var heatCard: some View {
        VStack(spacing: 0) {
            Divider()
            Card(title: "Heat", value: monitor.thermalLabel, valueColor: thermalColor) {
                if monitor.fanSpeeds.isEmpty {
                    Text(monitor.hasReadFans ? "No fan readings" : "Reading fans…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 16) {
                        ForEach(Array(monitor.fanSpeeds.enumerated()), id: \.offset) { index, rpm in
                            Text(Format.fanReading(rpm, index: index, count: monitor.fanSpeeds.count))
                        }
                        Spacer()
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var processesCard: some View {
        VStack(spacing: 0) {
            Divider()
            Card(title: "Top apps", value: nil) {
                if !isSnapshot {
                    Picker("Sort", selection: $processSort) {
                        ForEach(ProcessSort.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                }
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(topProcesses) { process in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(process.name).lineLimit(1)
                            if process.count > 1 {
                                Text("×\(process.count)").foregroundStyle(.tertiary)
                            }
                            Spacer(minLength: 8)
                            Text(processSort == .cpu ? Format.processPercent(process.cpu) : Format.bytes(process.memory))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .font(.caption)
                if monitor.processes.isEmpty {
                    Text("Reading…").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var topProcesses: [ProcessUsage] {
        let sorted = processSort == .cpu
            ? monitor.processes.sorted { $0.cpu > $1.cpu }
            : monitor.processes.sorted { $0.memory > $1.memory }
        return Array(sorted.prefix(6))
    }

    private var footer: some View {
        HStack {
            Button("Activity Monitor") {
                NSWorkspace.shared.open(URL(filePath: "/System/Applications/Utilities/Activity Monitor.app"))
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            Spacer()
            Menu {
                Toggle("Alerts", isOn: $monitor.notificationsEnabled)
                Toggle("Launch at login", isOn: Binding(
                    get: { launchAtLogin.isEnabled },
                    set: { launchAtLogin.setEnabled($0) }
                ))
                if let message = launchAtLogin.errorMessage {
                    Text(message)
                }
                if launchAtLogin.requiresApproval || launchAtLogin.errorMessage != nil {
                    Button("Open Login Items Settings…") { launchAtLogin.openSettings() }
                }
                Divider()
                Button("Quit StatBar") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            } label: {
                Text("Settings")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .controlSize(.small)
            .fixedSize()
            .help("Alerts, launch at login, and quit")
            .accessibilityLabel("StatBar settings")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func pressureColor(_ pressure: MemorySnapshot.Pressure) -> Color {
        switch pressure {
        case .normal: .green
        case .warning: .yellow
        case .critical: .red
        }
    }

    /// Matches the attention list: under 20% on battery, and under 10% is critical.
    private func batteryTint(_ battery: BatterySnapshot) -> Color {
        guard !battery.isPluggedIn else { return .green }
        if battery.percent <= 10 { return .red }
        if battery.percent <= 20 { return .orange }
        return .green
    }

    private func batterySymbol(_ battery: BatterySnapshot) -> String {
        if battery.isCharging { return "battery.100percent.bolt" }
        return switch battery.percent {
        case ..<13: "battery.0percent"
        case ..<38: "battery.25percent"
        case ..<63: "battery.50percent"
        case ..<88: "battery.75percent"
        default: "battery.100percent"
        }
    }

    private var thermalColor: Color {
        switch monitor.thermalState {
        case .nominal: .secondary
        case .fair: .yellow
        case .serious: .orange
        case .critical: .red
        @unknown default: .secondary
        }
    }
}

// MARK: - Building blocks

/// One reading. Sections sit on the popover background with a hairline between them,
/// rather than a stack of filled, rounded cards.
private struct Card<Content: View>: View {
    let title: String
    let value: String?
    var valueColor: Color = .secondary
    var symbol: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 6) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                if let symbol {
                    Image(systemName: symbol)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .symbolRenderingMode(.monochrome)
                        .accessibilityHidden(true)
                }
                Spacer(minLength: 8)
                if let value {
                    Text(value)
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(valueColor)
                }
            }
            content
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct Details<Content: View>: View {
    @Binding var isExpanded: Bool
    let label: String
    @ViewBuilder let content: Content

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 6)
        } label: {
            Text(label)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

private struct InsightRow: View {
    let insight: Insight

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: insight.symbol)
                .foregroundStyle(color)
                .symbolRenderingMode(.monochrome)
                .frame(width: 16, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                Text(insight.title)
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = insight.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        switch insight.severity {
        case .critical: .red
        case .warning: .orange
        case .info: .secondary
        }
    }
}

private struct StatRow: View {
    let label: String
    let value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value)
                .monospacedDigit()
                .gridColumnAlignment(.trailing)
        }
    }
}

/// A line of recent samples, drawn with one Canvas pass. Swift Charts looked the
/// same but cost several times more to redraw every two seconds.
private struct Sparkline: View {
    let values: [Double]
    let tint: Color
    var height: CGFloat = 36

    var body: some View {
        Canvas { context, size in
            guard values.count > 1 else { return }
            // Newest sample sits at the right edge; history fills in from the right.
            let step = size.width / CGFloat(max(StatMonitor.historyLength - 1, 1))
            let startX = size.width - step * CGFloat(values.count - 1)
            var line = Path()
            for (index, value) in values.enumerated() {
                let point = CGPoint(
                    x: startX + step * CGFloat(index),
                    y: size.height * (1 - CGFloat(min(max(value, 0), 1)))
                )
                if index == 0 {
                    line.move(to: point)
                } else {
                    line.addLine(to: point)
                }
            }
            var area = line
            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.addLine(to: CGPoint(x: startX, y: size.height))
            area.closeSubpath()
            context.fill(area, with: .color(tint.opacity(0.18)))
            context.stroke(line, with: .color(tint), style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

private struct RateGraph: View {
    let label: String
    let rate: Double
    let values: [Double]
    let tint: Color
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(Format.rate(rate), systemImage: symbol)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .symbolRenderingMode(.monochrome)
                .accessibilityLabel("\(label) \(Format.rate(rate))")
            let peak = max(values.max() ?? 0, 1)
            Sparkline(values: values.map { $0 / peak }, tint: tint, height: 28)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CoreBars: View {
    let loads: [Double]

    var body: some View {
        Canvas { context, size in
            let count = loads.count
            guard count > 0 else { return }
            let gap: CGFloat = 2
            let width = max((size.width - gap * CGFloat(count - 1)) / CGFloat(count), 1)
            for (index, load) in loads.enumerated() {
                let fraction = min(max(load, 0), 1)
                let x = CGFloat(index) * (width + gap)
                let track = CGRect(x: x, y: 0, width: width, height: size.height)
                let barHeight = max(1.5, size.height * fraction)
                let bar = CGRect(x: x, y: size.height - barHeight, width: width, height: barHeight)
                context.fill(Path(roundedRect: track, cornerRadius: 1.5), with: .color(.primary.opacity(0.12)))
                let ink: Color = fraction > 0.85 ? .orange : .blue
                context.fill(Path(roundedRect: bar, cornerRadius: 1.5), with: .color(ink))
            }
        }
        .frame(height: 18)
        .accessibilityHidden(true)
    }
}

private struct UsageBar: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            let clamped = min(max(fraction, 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(tint).frame(width: proxy.size.width * clamped)
            }
        }
        .frame(height: 5)
        .accessibilityHidden(true)
    }
}
