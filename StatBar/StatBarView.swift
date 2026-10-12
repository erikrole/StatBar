import AppKit
import SwiftUI

enum Format {
    static func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .memory)
    }

    static func diskBytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(max(0, bytesPerSecond)), countStyle: .file) + "/s"
    }

    static func linkSpeed(_ bitsPerSecond: UInt64) -> String {
        bitsPerSecond >= 1_000_000_000
            ? String(format: "%g Gb/s", Double(bitsPerSecond) / 1_000_000_000)
            : "\(bitsPerSecond / 1_000_000) Mb/s"
    }

    static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }
}

struct StatBarView: View {
    @Bindable var monitor: StatMonitor
    @Bindable var launchAtLogin: LaunchAtLoginController
    @State private var processSort: ProcessSort = .cpu
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

    /// Every card, without the scroll view, so `--snapshot` can render it too.
    var cards: some View {
        VStack(spacing: 10) {
            nowCard
            cpuCard
            gpuCard
            memoryCard
            powerCard
            networkCard
            disksCard
            heatCard
            processesCard
        }
        .padding(12)
    }

    /// What needs attention right now, most serious first, plus what just happened.
    private var nowCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            if monitor.insights.isEmpty {
                Label("All quiet", systemImage: "checkmark.circle")
                    .font(.subheadline.weight(.semibold))
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
                            HStack(spacing: 6) {
                                Image(systemName: event.symbol).frame(width: 16)
                                Text(event.title)
                                if let detail = event.detail { Text("· \(detail)").foregroundStyle(.tertiary) }
                                Spacer()
                                Text(event.since.formatted(date: .omitted, time: .shortened))
                                    .foregroundStyle(.tertiary)
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
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(nowBackground, in: RoundedRectangle(cornerRadius: 10))
        .animation(.easeOut(duration: 0.25), value: monitor.insights.map(\.id))
    }

    private var nowBackground: Color {
        switch monitor.attentionLevel {
        case .critical: .red.opacity(0.15)
        case .warning: .yellow.opacity(0.13)
        default: Color.secondary.opacity(0.08)
        }
    }

    private var cpuCard: some View {
        Card(title: "CPU", value: Format.percent(monitor.cpu), symbol: "cpu") {
            Sparkline(values: monitor.cpuHistory, tint: .blue)
            ForEach(monitor.coreGroups) { group in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("\(group.name) · \(group.coreCount) cores")
                        Spacer()
                        Text(Format.percent(group.load)).monospacedDigit()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    CoreBars(loads: group.coreLoads)
                }
            }
        }
    }

    private var gpuCard: some View {
        Card(title: "GPU", value: monitor.gpu.map(Format.percent) ?? "–", symbol: "square.stack.3d.up") {
            Sparkline(values: monitor.gpuHistory, tint: .purple)
        }
    }

    @ViewBuilder
    private var memoryCard: some View {
        if let memory = monitor.memory {
            Card(title: "Memory", value: memory.pressure.label, valueColor: pressureColor(memory.pressure), symbol: "memorychip") {
                UsageBar(fraction: memory.usedFraction, tint: pressureColor(memory.pressure))
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                    StatRow("Used", "\(Format.bytes(memory.used)) of \(Format.bytes(memory.total))")
                    StatRow("Compressed", Format.bytes(memory.compressed))
                    StatRow("Cached files", Format.bytes(memory.cached))
                    StatRow("Swap", memory.swapTotal == 0 ? "None" : "\(Format.bytes(memory.swapUsed)) of \(Format.bytes(memory.swapTotal))")
                }
                .font(.caption)
            }
        }
    }

    @ViewBuilder
    private var powerCard: some View {
        if let battery = monitor.battery {
            Card(title: "Power", value: "\(battery.percent)%", valueColor: battery.percent <= 15 && !battery.isPluggedIn ? .red : .primary,
                 symbol: battery.isCharging ? "battery.100percent.bolt" : "battery.75percent") {
                UsageBar(fraction: Double(battery.percent) / 100, tint: battery.isPluggedIn ? .green : (battery.percent <= 20 ? .orange : .green))
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                    StatRow("State", [battery.stateLabel, battery.remainingLabel].compactMap { $0 }.joined(separator: " · "))
                    if let flow = battery.flowWatts, abs(flow) >= 0.1 {
                        StatRow(flow > 0 ? "Into battery" : "Drawing", String(format: "%.1f W", abs(flow)))
                    }
                    if let adapter = battery.adapterWatts {
                        StatRow("Charger", "\(adapter) W")
                    }
                    if let health = battery.health {
                        StatRow("Health", "\(Format.percent(health))\(battery.cycleCount.map { " · \($0) cycles" } ?? "")")
                    }
                }
                .font(.caption)
                if !monitor.sleepBlockers.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Keeping your Mac awake")
                            .font(.caption.weight(.medium))
                        ForEach(monitor.sleepBlockers) { blocker in
                            Label("\(blocker.process): \(blocker.reason)", systemImage: blocker.preventsDisplaySleep ? "display" : "moon.zzz")
                                .lineLimit(1)
                                .help(blocker.reason)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
        return Card(title: "Network", value: status.0, valueColor: status.1, symbol: network.transport.symbolName) {
            HStack(spacing: 12) {
                RateGraph(label: "Down", rate: monitor.downloadRate, values: monitor.downloadHistory, tint: .blue, symbol: "arrow.down")
                RateGraph(label: "Up", rate: monitor.uploadRate, values: monitor.uploadHistory, tint: .orange, symbol: "arrow.up")
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                StatRow("Using", [
                    network.displayName ?? network.transport.rawValue,
                    network.linkSpeedBitsPerSecond.map(Format.linkSpeed),
                ].compactMap { $0 }.joined(separator: " · "))
                if let address = network.localAddress { StatRow("IP address", address) }
                if let router = network.routerAddress { StatRow("Router", router) }
                if SystemNetworkReader.isGlobalProtectInstalled {
                    StatRow("VPN", network.vpnTunnel == nil ? "GlobalProtect off" : "GlobalProtect connected")
                }
            }
            .font(.caption)
        }
    }

    private var disksCard: some View {
        Card(title: "Disks", value: nil, symbol: "internaldrive") {
            ForEach(monitor.volumes) { volume in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Image(systemName: volume.isInternal ? "internaldrive" : "externaldrive")
                            .foregroundStyle(.secondary)
                        Text(volume.name).lineLimit(1)
                        Spacer()
                        Text("\(Format.diskBytes(volume.available)) free")
                            .monospacedDigit()
                            .foregroundStyle(volume.usedFraction > 0.9 ? .orange : .secondary)
                    }
                    .font(.caption)
                    UsageBar(fraction: volume.usedFraction, tint: volume.usedFraction > 0.9 ? .orange : .teal)
                }
                .contentShape(Rectangle())
                .onTapGesture { NSWorkspace.shared.open(volume.url) }
                .help("Open \(volume.name)")
            }
            HStack(spacing: 16) {
                Label(Format.rate(monitor.readRate), systemImage: "arrow.down")
                Label(Format.rate(monitor.writeRate), systemImage: "arrow.up")
                Spacer()
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private var heatCard: some View {
        Card(title: "Heat", value: monitor.thermalLabel, valueColor: thermalColor, symbol: "thermometer.medium") {
            if monitor.fanSpeeds.isEmpty {
                Text("No fan readings").font(.caption).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 16) {
                    ForEach(Array(monitor.fanSpeeds.enumerated()), id: \.offset) { index, rpm in
                        Label("\(monitor.fanSpeeds.count > 1 ? "Fan \(index + 1): " : "Fan: ")\(rpm < 1 ? "Off" : "\(Int(rpm)) rpm")",
                              systemImage: "fan")
                    }
                    Spacer()
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
    }

    private var processesCard: some View {
        Card(title: "Top apps", value: nil, symbol: "list.bullet") {
            if !isSnapshot {
            Picker("Sort", selection: $processSort) {
                ForEach(ProcessSort.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            }
            ForEach(topProcesses) { process in
                HStack {
                    Text(process.name).lineLimit(1)
                    if process.count > 1 {
                        Text("×\(process.count)").foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Text(processSort == .cpu ? String(format: "%.0f%%", process.cpu) : Format.bytes(process.memory))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
            }
            if monitor.processes.isEmpty {
                Text("Reading…").font(.caption).foregroundStyle(.secondary)
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
            Toggle("Alerts", isOn: $monitor.notificationsEnabled)
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .help("Notify me about serious things: offline, low battery, a charger that can't keep up, a nearly full disk, critical memory, throttling.")
            Toggle("Launch at login", isOn: Binding(
                get: { launchAtLogin.isEnabled },
                set: { launchAtLogin.setEnabled($0) }
            ))
            .toggleStyle(.checkbox)
            .controlSize(.small)
            Spacer()
            Button("Activity Monitor") {
                NSWorkspace.shared.open(URL(filePath: "/System/Applications/Utilities/Activity Monitor.app"))
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.borderless)
                .controlSize(.small)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func pressureColor(_ pressure: MemorySnapshot.Pressure) -> Color {
        switch pressure {
        case .normal: .green
        case .warning: .yellow
        case .critical: .red
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

private struct Card<Content: View>: View {
    let title: String
    let value: String?
    var valueColor: Color = .primary
    let symbol: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(title, systemImage: symbol)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if let value {
                    Text(value)
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(valueColor)
                }
            }
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct InsightRow: View {
    let insight: Insight

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: insight.symbol)
                .foregroundStyle(color)
                .frame(width: 18)
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
        case .info: .blue
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
            Text(value).monospacedDigit()
        }
    }
}

/// A filled line of recent samples, drawn with one Canvas pass. Swift Charts looked the
/// same but cost several times more to redraw every two seconds.
private struct Sparkline: View {
    let values: [Double]
    let tint: Color

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
                index == 0 ? line.move(to: point) : line.addLine(to: point)
            }
            var area = line
            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.addLine(to: CGPoint(x: startX, y: size.height))
            area.closeSubpath()
            context.fill(area, with: .color(tint.opacity(0.18)))
            context.stroke(line, with: .color(tint), lineWidth: 1.2)
        }
        .frame(height: 36)
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
        VStack(alignment: .leading, spacing: 2) {
            Label(Format.rate(rate), systemImage: symbol)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityLabel("\(label) \(Format.rate(rate))")
            let peak = max(values.max() ?? 0, 1)
            Sparkline(values: values.map { $0 / peak }, tint: tint)
                .frame(height: 28)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CoreBars: View {
    let loads: [Double]

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(Array(loads.enumerated()), id: \.offset) { _, load in
                GeometryReader { proxy in
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(load > 0.85 ? Color.orange : Color.blue)
                            .frame(height: max(1.5, proxy.size.height * load))
                    }
                }
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 1.5))
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
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(tint).frame(width: proxy.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: 6)
    }
}
