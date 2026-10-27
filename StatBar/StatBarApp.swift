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
        guard ensureSoleInstance() else { return }
        configureStatusItem()
        monitor.onSample = { [weak self] in self?.updateStatusItemIfNeeded() }
        observeScreenSleep()
        monitor.start()
        AppUpdate.checkOnLaunch()
    }

    /// One menu bar icon only. Another copy (an installed app next to a build product, or the old
    /// copy still quitting during an update relaunch) gets a short grace period to exit; if it
    /// stays, this copy brings it forward and quits instead of adding a second icon.
    private func ensureSoleInstance() -> Bool {
        guard let id = Bundle.main.bundleIdentifier else { return true }
        let me = ProcessInfo.processInfo.processIdentifier
        func others() -> [NSRunningApplication] {
            NSRunningApplication.runningApplications(withBundleIdentifier: id).filter { $0.processIdentifier != me && !$0.isTerminated }
        }
        let deadline = Date().addingTimeInterval(5)
        while !others().isEmpty, Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
        guard let existing = others().first else { return true }
        existing.activate()
        NSApp.terminate(nil)
        return false
    }

    private func configureStatusItem() {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = item.button else { return }
        button.target = self
        button.action = #selector(togglePopover(_:))
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
        button.font = font
        // Measure the widest contents once. macOS supplies the status item's outer
        // padding; adding our own made the menu bar pill unnecessarily wide.
        // Keep this width fixed so changing percentages never moves nearby items.
        button.title = "100%"
        let contentWidth = [MenuBarAttention.none, .warning, .critical].map { attention in
            button.image = statusImage(for: attention)
            return button.fittingSize.width
        }.max() ?? 0
        item.length = ceil(contentWidth)
        statusItem = item
        updateStatusItemIfNeeded()
    }

    /// Clicks in other apps, and only while the popover is up. A monitor left installed
    /// for the life of the process wakes StatBar on every mouse-down in the system.
    private func beginOutsideClickMonitoring() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.closePopoverFromOutsideClick()
            }
        }
    }

    private func endOutsideClickMonitoring() {
        guard let token = outsideClickMonitor else { return }
        NSEvent.removeMonitor(token)
        outsideClickMonitor = nil
    }

    private func closePopoverFromOutsideClick() {
        guard popover?.isShown == true else { return }
        popover?.performClose(nil)
    }

    /// Built on first open. An unshown popover still owns a window.
    private func makePopover() -> NSPopover {
        if let existing = popover { return existing }
        let created = NSPopover()
        created.behavior = .transient
        created.animates = false
        created.delegate = self
        created.contentSize = NSSize(width: 360, height: 600)
        popover = created
        return created
    }

    /// The SwiftUI popover is built when it opens and torn down when it closes; a hidden
    /// NSHostingController still re-renders on every sample, which cost ~13% CPU.
    private func makePopoverContent() {
        makePopover().contentViewController = NSHostingController(
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
        beginOutsideClickMonitoring()
    }

    func popoverDidClose(_ notification: Notification) {
        monitor.setPopoverVisible(false)
        popover?.contentViewController = nil
        endOutsideClickMonitoring()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AppUpdate.isPreparing ? .terminateCancel : .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor.stop()
        sleepTask?.cancel()
        wakeTask?.cancel()
        endOutsideClickMonitoring()
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
        let panel = makePopover()
        if panel.isShown {
            panel.performClose(sender)
        } else {
            makePopoverContent()
            panel.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            panel.contentViewController?.view.window?.becomeKey()
        }
    }
}
