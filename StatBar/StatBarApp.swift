import AppKit
import SwiftUI

/// AppKit entry point. A SwiftUI `App` scene kept a render loop alive with no window,
/// which showed up as WindowServer time while StatBar itself looked idle.
@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let monitor = StatMonitor()
    private let launchAtLogin = LaunchAtLoginController()
    private var popover: NSPopover?
    private var statusItem: NSStatusItem?
    private var outsideClickMonitor: Any?
    private var sleepTask: Task<Void, Never>?
    private var wakeTask: Task<Void, Never>?
    private var appliedPresentation: MenuBarPresentation?
    private var statusImages: [MenuBarAttention: NSImage] = [:]
    /// `NSApplication.delegate` is weak, so the process has to own this.
    private static var retained: AppDelegate?

    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        retained = delegate
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        if let index = CommandLine.arguments.firstIndex(of: "--snapshot"),
           CommandLine.arguments.indices.contains(index + 1) {
            let path = CommandLine.arguments[index + 1]
            Task { await snapshotAndExit(to: path) }
            return
        }
        if CommandLine.arguments.contains("--report") {
            Task { await printReportAndExit() }
            return
        }
        configureStatusItem()
        monitor.onSample = { [weak self] in self?.updateStatusItemIfNeeded() }
        configureOutsideClickMonitor()
        observeScreenSleep()
        monitor.start()
    }

    private func configureStatusItem() {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        let textWidth = ("100%" as NSString).size(withAttributes: [.font: font]).width
        let iconWidth = max(
            symbolWidth("gauge.with.dots.needle.33percent"),
            symbolWidth("exclamationmark.triangle")
        )
        // Fixed width: a change from 9% to 10% must not reflow every other menu bar icon.
        let length = iconWidth + textWidth + 32
        let item = NSStatusBar.system.statusItem(withLength: length)
        guard let button = item.button else { return }
        button.target = self
        button.action = #selector(togglePopover(_:))
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
        button.font = font
        statusItem = item
    }

    private func symbolWidth(_ name: String) -> CGFloat {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .medium))
        return image?.size.width ?? 16
    }

    private func configureOutsideClickMonitor() {
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.popover?.isShown == true else { return }
                self.popover?.performClose(nil)
            }
        }
    }

    /// Built on first open. An unshown popover still owns a window.
    private func makePopover() -> NSPopover {
        if let popover { return popover }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        popover.contentSize = NSSize(width: 360, height: 600)
        self.popover = popover
        return popover
    }

    /// The SwiftUI popover is built when it opens and torn down when it closes; a hidden
    /// NSHostingController still re-renders on every sample, which cost ~13% CPU.
    private func makePopoverContent() {
        let popover = makePopover()
        popover.contentViewController = NSHostingController(
            rootView: StatBarView(monitor: monitor, launchAtLogin: launchAtLogin)
        )
    }

    private func observeScreenSleep() {
        let center = NSWorkspace.shared.notificationCenter
        sleepTask = Task { [weak self] in
            for await _ in center.notifications(named: NSWorkspace.screensDidSleepNotification) {
                self?.monitor.setPaused(true)
            }
        }
        wakeTask = Task { [weak self] in
            for await _ in center.notifications(named: NSWorkspace.screensDidWakeNotification) {
                self?.monitor.setPaused(false)
            }
        }
    }

    func popoverDidShow(_ notification: Notification) {
        monitor.setPopoverVisible(true)
    }

    func popoverDidClose(_ notification: Notification) {
        monitor.setPopoverVisible(false)
        popover?.contentViewController = nil
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor.stop()
        sleepTask?.cancel()
        wakeTask?.cancel()
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
        }
    }

    /// CPU percentage beside a gauge. Warnings replace the gauge with a triangle.
    /// The button is left alone when the visible reading has not changed.
    private func updateStatusItemIfNeeded() {
        guard let button = statusItem?.button else { return }
        let presentation = monitor.menuBarPresentation
        guard presentation != appliedPresentation else { return }
        let attentionChanged = appliedPresentation?.attention != presentation.attention
        appliedPresentation = presentation
        if button.title != presentation.title {
            button.title = presentation.title
        }
        if attentionChanged {
            button.image = statusImage(for: presentation.attention)
        }
        let summary = monitor.accessibilitySummary
        if button.toolTip != summary {
            button.toolTip = summary
            button.setAccessibilityLabel(summary)
        }
    }

    private func statusImage(for attention: MenuBarAttention) -> NSImage? {
        if let cached = statusImages[attention] { return cached }
        var configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        let tint: NSColor? = switch attention {
        case .critical: .systemRed
        case .warning: .systemYellow
        case .none: nil
        }
        if let tint {
            configuration = configuration.applying(NSImage.SymbolConfiguration(hierarchicalColor: tint))
        }
        let image = NSImage(systemSymbolName: attention.symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        image?.isTemplate = tint == nil
        if let image { statusImages[attention] = image }
        return image
    }

    /// `StatBar --report` samples for a few seconds, prints every reading and exits.
    private func printReportAndExit() async {
        monitor.start()
        monitor.setPopoverVisible(true)
        // `--report 75` watches longer, so sustained conditions have time to show.
        let seconds = CommandLine.arguments.firstIndex(of: "--report")
            .flatMap { CommandLine.arguments.indices.contains($0 + 1) ? Double(CommandLine.arguments[$0 + 1]) : nil } ?? 4.5
        try? await Task.sleep(for: .seconds(seconds))
        var lines: [String] = []
        for insight in monitor.insights {
            lines.append("NOW   [\(insight.severity)] \(insight.title)\(insight.detail.map { " — \($0)" } ?? "")")
        }
        lines.append("CPU   \(Format.percent(monitor.cpu))")
        for group in monitor.coreGroups {
            lines.append("  \(group.name) (\(group.coreCount) cores)  \(Format.percent(group.load))")
        }
        lines.append("GPU   " + (monitor.gpu.map(Format.percent) ?? "unavailable"))
        if let memory = monitor.memory {
            lines.append("MEM   \(Format.bytes(memory.used)) of \(Format.bytes(memory.total)), pressure \(memory.pressure.label), compressed \(Format.bytes(memory.compressed)), swap \(Format.bytes(memory.swapUsed)) of \(Format.bytes(memory.swapTotal))")
        }
        if let battery = monitor.battery {
            lines.append("POWER \(battery.percent)%, \(battery.stateLabel)\(battery.remainingLabel.map { ", \($0)" } ?? ""), flow \(battery.flowWatts.map(Format.signedWatts) ?? "n/a"), charger \(battery.adapterWatts.map { "\($0) W" } ?? "none"), health \(battery.health.map(Format.percent) ?? "n/a"), \(battery.cycleCount ?? 0) cycles")
        }
        for blocker in monitor.sleepBlockers {
            lines.append("AWAKE \(blocker.process): \(blocker.reason)")
        }
        let network = monitor.network
        lines.append("NET   \(monitor.internetReachable == true ? "online" : "offline/checking") via \(network.displayName ?? network.transport.rawValue) (\(network.interfaceName ?? "-")) \(network.localAddress ?? ""), router \(network.routerAddress ?? "-"), VPN \(network.vpnTunnel ?? "off"), down \(Format.rate(monitor.downloadRate)), up \(Format.rate(monitor.uploadRate))")
        for volume in monitor.volumes {
            lines.append("DISK  \(volume.name): \(Format.diskBytes(volume.available)) free of \(Format.diskBytes(volume.total))")
        }
        lines.append("IO    read \(Format.rate(monitor.readRate)), write \(Format.rate(monitor.writeRate))")
        lines.append("HEAT  \(monitor.thermalLabel); fans " + (monitor.fanSpeeds.isEmpty ? "none reported" : monitor.fanSpeeds.map { Format.rpm($0) }.joined(separator: ", ")))
        for process in monitor.processes.sorted(by: { $0.cpu > $1.cpu }).prefix(5) {
            lines.append("TOP   \(process.name)  \(Format.processPercent(process.cpu)) CPU, \(Format.bytes(process.memory))")
        }
        print(lines.joined(separator: "\n"))
        exit(0)
    }

    /// `StatBar --snapshot <file.png>` renders the popover after a few samples and exits,
    /// for checking the layout without clicking the menu bar.
    private func snapshotAndExit(to path: String) async {
        monitor.start()
        monitor.setPopoverVisible(true)
        try? await Task.sleep(for: .seconds(40))
        let scheme: ColorScheme = CommandLine.arguments.contains("--snapshot-light") ? .light : .dark
        // ImageRenderer can't draw scroll views or AppKit controls, so render the cards alone.
        let view = StatBarView(monitor: monitor, launchAtLogin: launchAtLogin, isSnapshot: true).cards
            .frame(width: 360)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, scheme)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        if let image = renderer.cgImage {
            let rep = NSBitmapImageRep(cgImage: image)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(filePath: path))
            print("Wrote \(path)")
        }
        exit(0)
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem?.button else { return }
        let popover = makePopover()
        if popover.isShown {
            popover.performClose(sender)
        } else {
            makePopoverContent()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.becomeKey()
        }
    }
}
