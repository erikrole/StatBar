import AppKit
import SwiftUI

@main
struct StatBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let monitor = StatMonitor()
    private let launchAtLogin = LaunchAtLoginController()
    private let popover = NSPopover()
    private var statusItem: NSStatusItem?
    private var outsideClickMonitor: Any?

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
        configurePopover()
        configureStatusItem()
        configureOutsideClickMonitor()
        observeMonitor()
        monitor.start()
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = item.button else { return }
        button.target = self
        button.action = #selector(togglePopover(_:))
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
        button.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        statusItem = item
        updateStatusItem()
    }

    private func configureOutsideClickMonitor() {
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.popover.isShown else { return }
                self.popover.performClose(nil)
            }
        }
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentSize = NSSize(width: 360, height: 600)
        popover.contentViewController = NSHostingController(
            rootView: StatBarView(monitor: monitor, launchAtLogin: launchAtLogin)
        )
    }

    func popoverDidShow(_ notification: Notification) {
        monitor.setPopoverVisible(true)
    }

    func popoverDidClose(_ notification: Notification) {
        monitor.setPopoverVisible(false)
    }

    private func observeMonitor() {
        withObservationTracking {
            _ = monitor.cpu
            _ = monitor.memory?.pressure
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.updateStatusItem()
                self.observeMonitor()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
        }
    }

    /// CPU percentage beside a gauge; the gauge turns yellow or red with memory pressure.
    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        var configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        let pressure = monitor.memory?.pressure ?? .normal
        if pressure != .normal {
            configuration = configuration.applying(NSImage.SymbolConfiguration(
                hierarchicalColor: pressure == .critical ? .systemRed : .systemYellow
            ))
        }
        let image = NSImage(systemSymbolName: "gauge.with.dots.needle.33percent", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        image?.isTemplate = pressure == .normal
        button.image = image
        button.title = monitor.menuBarText
        button.toolTip = monitor.accessibilitySummary
        button.setAccessibilityLabel(monitor.accessibilitySummary)
    }

    /// `StatBar --report` samples for a few seconds, prints every reading and exits.
    private func printReportAndExit() async {
        monitor.start()
        monitor.setPopoverVisible(true)
        try? await Task.sleep(for: .seconds(4.5))
        var lines: [String] = []
        lines.append(String(format: "CPU   %.0f%%", monitor.cpu * 100))
        for group in monitor.coreGroups {
            lines.append(String(format: "  %@ (%d cores)  %.0f%%", group.name, group.coreCount, group.load * 100))
        }
        lines.append("GPU   " + (monitor.gpu.map { String(format: "%.0f%%", $0 * 100) } ?? "unavailable"))
        if let memory = monitor.memory {
            lines.append("MEM   \(Format.bytes(memory.used)) of \(Format.bytes(memory.total)), pressure \(memory.pressure.label), compressed \(Format.bytes(memory.compressed)), swap \(Format.bytes(memory.swapUsed)) of \(Format.bytes(memory.swapTotal))")
        }
        for volume in monitor.volumes {
            lines.append("DISK  \(volume.name): \(Format.bytes(UInt64(volume.available))) free of \(Format.bytes(UInt64(volume.total)))")
        }
        lines.append("IO    read \(Format.rate(monitor.readRate)), write \(Format.rate(monitor.writeRate))")
        lines.append("HEAT  \(monitor.thermalLabel); fans " + (monitor.fanSpeeds.isEmpty ? "none reported" : monitor.fanSpeeds.map { "\(Int($0)) rpm" }.joined(separator: ", ")))
        for process in monitor.processes.sorted(by: { $0.cpu > $1.cpu }).prefix(5) {
            lines.append(String(format: "TOP   %@  %.0f%% CPU, %@", process.name, process.cpu, Format.bytes(process.memory)))
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
        // ImageRenderer can't draw scroll views or AppKit controls, so render the cards alone.
        let view = StatBarView(monitor: monitor, launchAtLogin: launchAtLogin, isSnapshot: true).cards
            .frame(width: 360)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .dark)
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
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.becomeKey()
        }
    }
}
