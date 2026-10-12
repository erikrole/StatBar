import XCTest
@testable import StatBar

final class InsightEngineTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    private func signals(at seconds: TimeInterval, _ configure: (inout Signals) -> Void = { _ in }) -> Signals {
        var signals = Signals()
        signals.now = start.addingTimeInterval(seconds)
        signals.online = true
        configure(&signals)
        return signals
    }

    private func memory(_ pressure: MemorySnapshot.Pressure, swap: UInt64 = 0) -> MemorySnapshot {
        MemorySnapshot(total: 128 << 30, used: 60 << 30, compressed: 0, cached: 0, swapUsed: swap, swapTotal: 6 << 30, pressure: pressure)
    }

    private func battery(_ percent: Int, plugged: Bool, flow: Double, adapter: Int? = nil) -> BatterySnapshot {
        BatterySnapshot(percent: percent, isCharging: plugged && flow > 0, isPluggedIn: plugged, isFull: false,
                        minutesRemaining: 40, flowWatts: flow, adapterWatts: adapter, cycleCount: 72, health: 0.99)
    }

    func testQuietWhenNothingHappens() {
        var engine = InsightEngine()
        engine.update(signals(at: 0) { $0.memory = memory(.normal); $0.battery = battery(80, plugged: true, flow: 5) })
        XCTAssertTrue(engine.active.isEmpty)
    }

    func testRunawayAppNeedsToBeSustained() {
        var engine = InsightEngine()
        let hog = [ProcessUsage(name: "Grok Bot", cpu: 240, memory: 1 << 30, count: 9)]
        engine.update(signals(at: 0) { $0.processes = hog })
        XCTAssertTrue(engine.active.isEmpty, "one busy sample shouldn't show")
        engine.update(signals(at: 30) { $0.processes = hog })
        XCTAssertTrue(engine.active.isEmpty)
        let fresh = engine.update(signals(at: 61) { $0.processes = hog })
        XCTAssertEqual(fresh.first?.title, "Grok Bot is using 2.4 cores")
        XCTAssertFalse(fresh.first?.notifies ?? true, "busy apps are informational only")
        // Cooling off clears it, and the timer restarts.
        engine.update(signals(at: 70) { $0.processes = [] })
        XCTAssertTrue(engine.active.isEmpty)
        engine.update(signals(at: 80) { $0.processes = hog })
        XCTAssertTrue(engine.active.isEmpty)
    }

    func testSystemProcessesAreNotRunaways() {
        var engine = InsightEngine()
        let busy = [ProcessUsage(name: "WindowServer", cpu: 300, memory: 0, count: 1)]
        engine.update(signals(at: 0) { $0.processes = busy })
        engine.update(signals(at: 120) { $0.processes = busy })
        XCTAssertTrue(engine.active.isEmpty)
    }

    func testChargerThatCantKeepUp() {
        var engine = InsightEngine()
        let draining = battery(22, plugged: true, flow: -12, adapter: 60)
        engine.update(signals(at: 0) { $0.battery = draining })
        XCTAssertTrue(engine.active.isEmpty)
        let fresh = engine.update(signals(at: 61) { $0.battery = draining })
        XCTAssertEqual(fresh.first?.title, "The 60 W charger can't keep up")
        XCTAssertEqual(fresh.first?.severity, .warning)
        XCTAssertTrue(fresh.first?.notifies ?? false)
    }

    func testLowAndCriticalBattery() {
        var engine = InsightEngine()
        engine.update(signals(at: 0) { $0.battery = battery(18, plugged: false, flow: -20) })
        XCTAssertEqual(engine.active.first?.severity, .warning)
        engine.update(signals(at: 10) { $0.battery = battery(8, plugged: false, flow: -20) })
        XCTAssertEqual(engine.active.first?.severity, .critical)
        engine.update(signals(at: 20) { $0.battery = battery(8, plugged: true, flow: 30) })
        XCTAssertTrue(engine.active.isEmpty)
    }

    func testMemoryPressureNamesTheBiggestApp() {
        var engine = InsightEngine()
        let apps = [ProcessUsage(name: "Adobe After Effects 2026", cpu: 50, memory: 40 << 30, count: 1),
                    ProcessUsage(name: "Dia", cpu: 5, memory: 8 << 30, count: 60)]
        engine.update(signals(at: 0) { $0.memory = memory(.critical); $0.processes = apps })
        let insight = try? XCTUnwrap(engine.active.first)
        XCTAssertEqual(insight?.severity, .critical)
        XCTAssertTrue(insight?.detail?.contains("Adobe After Effects 2026") ?? false)
    }

    func testOfflineAfterGraceAndEventsLogged() {
        var engine = InsightEngine()
        engine.update(signals(at: 0) { $0.online = true })
        engine.update(signals(at: 2) { $0.online = false; $0.transport = .wifi })
        XCTAssertTrue(engine.active.isEmpty, "a brief blip isn't shown")
        engine.update(signals(at: 8) { $0.online = false; $0.transport = .wifi })
        XCTAssertEqual(engine.active.first?.title, "You're offline")
        engine.update(signals(at: 12) { $0.online = true })
        XCTAssertTrue(engine.active.isEmpty)
        XCTAssertEqual(engine.events.map(\.title), ["Back online", "Went offline"])
    }

    func testDriveMountEventsButNotOnFirstRead() {
        var engine = InsightEngine()
        let startup = VolumeInfo(id: "a", name: "Macintosh HD", url: URL(filePath: "/"), total: 2_000_000_000_000, available: 900_000_000_000, isInternal: true)
        let media = VolumeInfo(id: "b", name: "Media", url: URL(filePath: "/Volumes/Media"), total: 4_000_000_000_000, available: 1_000_000_000_000, isInternal: false)
        engine.update(signals(at: 0) { $0.volumes = [startup] })
        XCTAssertTrue(engine.events.isEmpty)
        engine.update(signals(at: 16) { $0.volumes = [startup, media] })
        XCTAssertEqual(engine.events.first?.title, "Media mounted")
        engine.update(signals(at: 32) { $0.volumes = [startup] })
        XCTAssertEqual(engine.events.first?.title, "Media ejected")
    }

    func testNearlyFullDisk() {
        var engine = InsightEngine()
        let full = VolumeInfo(id: "b", name: "Media", url: URL(filePath: "/Volumes/Media"), total: 4_000_000_000_000, available: 30_000_000_000, isInternal: false)
        engine.update(signals(at: 0) { $0.volumes = [full] })
        XCTAssertEqual(engine.active.first?.title, "Media is almost full")
        XCTAssertEqual(engine.active.first?.severity, .warning)
    }

    func testSevereThingsSortFirst() {
        var engine = InsightEngine()
        engine.update(signals(at: 0) {
            $0.memory = memory(.warning)
            $0.battery = battery(5, plugged: false, flow: -30)
        })
        engine.update(signals(at: 30) {
            $0.memory = memory(.warning)
            $0.battery = battery(5, plugged: false, flow: -30)
        })
        XCTAssertEqual(engine.active.map(\.severity), [.critical, .warning])
    }
}
