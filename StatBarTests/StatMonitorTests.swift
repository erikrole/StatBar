import XCTest
@testable import StatBar

@MainActor
final class StatMonitorTests: XCTestCase {
    private let ethernet = InterfaceIdentity(transport: .ethernet, displayName: "Ethernet")
    private let start = Date(timeIntervalSince1970: 1_000_000)

    func testFanReadsStayOffTheIdleDetailRound() {
        XCTAssertTrue(StatMonitor.shouldReadFans(popoverVisible: false, hasReadFans: false))
        XCTAssertFalse(StatMonitor.shouldReadFans(popoverVisible: false, hasReadFans: true))
        XCTAssertTrue(StatMonitor.shouldReadFans(popoverVisible: true, hasReadFans: true))
        XCTAssertTrue(StatMonitor.shouldReadFans(popoverVisible: true, hasReadFans: false))
    }

    func testNotificationPreferenceHonorsLaunchOnlyOverrides() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "StatBarTests.\(UUID().uuidString)"))
        defer { defaults.removeVolatileDomain(forName: UserDefaults.argumentDomain) }
        defaults.setVolatileDomain([:], forName: UserDefaults.argumentDomain)
        XCTAssertTrue(StatMonitor.notificationPreference(in: defaults))
        for (value, expected) in [("NO", false), ("YES", true)] {
            defaults.setVolatileDomain(["notificationsEnabled": value], forName: UserDefaults.argumentDomain)
            XCTAssertEqual(StatMonitor.notificationPreference(in: defaults), expected)
        }
        for value in [false, true] {
            defaults.setVolatileDomain(["notificationsEnabled": value], forName: UserDefaults.argumentDomain)
            XCTAssertEqual(StatMonitor.notificationPreference(in: defaults), value)
        }
    }

    private func networkSample(_ monitor: StatMonitor, interface: String? = "en0", bytes: UInt64?, seconds: Double) {
        monitor.applyNetworkSample(
            route: ActiveRoute(interfaceName: interface, routerAddress: interface == nil ? nil : "192.0.2.1"),
            identity: interface == nil ? nil : ethernet,
            counters: bytes.map { InterfaceCounters(receivedBytes: $0, sentBytes: $0) },
            at: start.addingTimeInterval(seconds)
        )
    }

    func testDisconnectClearsIdentityDetailsAndAdvancesHistory() {
        let monitor = StatMonitor()
        networkSample(monitor, bytes: 100, seconds: 0)
        networkSample(monitor, bytes: 500, seconds: 2)
        monitor.applyNetworkDetails(localAddress: "192.0.2.2", linkSpeed: 1_000_000_000, vpn: (true, "utun5"))
        XCTAssertEqual(monitor.downloadRate, 200)
        XCTAssertNotNil(monitor.network.vpnTunnel)
        networkSample(monitor, interface: nil, bytes: nil, seconds: 4)
        XCTAssertEqual(monitor.network, StatMonitor.NetworkState())
        XCTAssertEqual(monitor.downloadRate, 0)
        XCTAssertEqual(monitor.uploadRate, 0)
        XCTAssertEqual(monitor.downloadHistory.last, 0)
        XCTAssertEqual(monitor.uploadHistory.last, 0)
    }

    func testInterfaceSwitchAndFailedCounterReadResetRateBaseline() {
        let monitor = StatMonitor()
        networkSample(monitor, bytes: 100, seconds: 0)
        networkSample(monitor, bytes: 500, seconds: 2)
        networkSample(monitor, interface: "en1", bytes: 10_000, seconds: 4)
        XCTAssertEqual(monitor.downloadRate, 0)
        networkSample(monitor, interface: "en1", bytes: 10_200, seconds: 6)
        XCTAssertEqual(monitor.downloadRate, 100)
        networkSample(monitor, interface: "en1", bytes: nil, seconds: 8)
        XCTAssertEqual(monitor.downloadRate, 0)
        networkSample(monitor, interface: "en1", bytes: 50_000, seconds: 10)
        XCTAssertEqual(monitor.downloadRate, 0, "no average spanning an unreadable interval")
        networkSample(monitor, interface: "en1", bytes: 50_600, seconds: 12)
        XCTAssertEqual(monitor.downloadRate, 300)
    }

    func testNetworkHistoryIsBoundedThroughLongDisconnection() {
        let monitor = StatMonitor()
        for tick in 0..<200 {
            networkSample(monitor, interface: nil, bytes: nil, seconds: Double(tick * 2))
        }
        XCTAssertEqual(monitor.downloadHistory.count, StatMonitor.historyLength)
        XCTAssertTrue(monitor.downloadHistory.allSatisfy { $0 == 0 })
    }

    func testInterfaceSwitchLeavesVPNUnknownUntilFreshRead() {
        let monitor = StatMonitor()
        networkSample(monitor, bytes: 100, seconds: 0)
        monitor.applyNetworkDetails(localAddress: nil, linkSpeed: nil, vpn: (true, "utun5"))
        XCTAssertTrue(monitor.vpnStatusKnown)
        networkSample(monitor, interface: "en1", bytes: 200, seconds: 2)
        XCTAssertFalse(monitor.vpnStatusKnown, "a route change is not a confirmed VPN disconnection")
        monitor.applyNetworkDetails(localAddress: nil, linkSpeed: nil, vpn: (false, nil))
        XCTAssertFalse(monitor.vpnStatusKnown)
        monitor.applyNetworkDetails(localAddress: nil, linkSpeed: nil, vpn: (true, "utun5"))
        XCTAssertTrue(monitor.vpnStatusKnown)
        XCTAssertEqual(monitor.network.vpnTunnel, "utun5")
        networkSample(monitor, interface: nil, bytes: nil, seconds: 4)
        XCTAssertTrue(monitor.vpnStatusKnown)
        XCTAssertNil(monitor.network.vpnTunnel)
    }

    func testPausedDetailCannotPublishAndBlockedWorkStaysSingleFlight() async throws {
        let reader = SuspendedDetailReader()
        let monitor = StatMonitor { _, _, _ in await reader.read() }
        monitor.setPopoverVisible(true)
        try await waitUntil { await reader.calls == 1 }
        for _ in 0..<10 { monitor.setPopoverVisible(true) }
        monitor.setPaused(true)
        monitor.setPopoverVisible(true)
        let calls = await reader.calls
        XCTAssertEqual(calls, 1)
        await reader.finish(with: snapshot("stale"))
        try await waitUntil { await reader.finished == 1 }
        // Let completion return to the main actor before checking publication.
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(monitor.volumes.isEmpty)
        XCTAssertEqual(monitor.readRate, 0)
        monitor.setPaused(false)
        monitor.setPopoverVisible(true)
        try await waitUntil { await reader.calls == 2 }
        await reader.finish(with: snapshot("fresh"))
        try await waitUntil { monitor.volumes.first?.id == "fresh" }
        monitor.stop()
    }

    func testResumeRejectsPreSleepDetailAndStartsFreshReadAfterItReturns() async throws {
        let reader = SuspendedDetailReader()
        let monitor = StatMonitor { _, _, _ in await reader.read() }
        monitor.start()
        try await waitUntil { await reader.calls == 1 }
        let historyCount = monitor.memoryHistory.count
        monitor.start()
        XCTAssertEqual(monitor.memoryHistory.count, historyCount, "start is idempotent")
        monitor.setPaused(true)
        monitor.setPaused(false)
        let calls = await reader.calls
        XCTAssertEqual(calls, 1, "resume cannot pile work onto a blocked OS read")
        await reader.finish(with: snapshot("stale"))
        try await waitUntil { await reader.calls == 2 }
        XCTAssertTrue(monitor.volumes.isEmpty)
        await reader.finish(with: snapshot("fresh"))
        try await waitUntil { monitor.volumes.first?.id == "fresh" }
        XCTAssertEqual(monitor.readRate, 0, "first post-wake sample establishes a new baseline")
        monitor.stop()
    }

    func testBlockedDetailStaysSingleFlightPastFormerTimeout() async throws {
        let reader = SuspendedDetailReader()
        let monitor = StatMonitor { _, _, _ in await reader.read() }
        monitor.start()
        monitor.setPopoverVisible(true)
        try await waitUntil { await reader.calls == 1 }
        // The original implementation abandoned its slot at 20 seconds and launched
        // another worker. Cross that boundary while normal fast ticks keep running.
        try await Task.sleep(for: .seconds(21))
        monitor.setPopoverVisible(true)
        let calls = await reader.calls
        XCTAssertEqual(calls, 1, "a blocked OS call must retain its worker slot")
        XCTAssertGreaterThan(monitor.memoryHistory.count, 3, "fast sampling must continue")
        monitor.stop()
        await reader.finish(with: snapshot("discarded"))
        try await waitUntil { await reader.finished == calls }
    }

    private func snapshot(_ id: String) -> StatMonitor.DetailSnapshot {
        let volume = VolumeInfo(id: id, name: id, url: URL(filePath: "/"), total: 1_000, available: 500, isInternal: true)
        return StatMonitor.DetailSnapshot(volumes: [volume], alertVolumes: [volume], totals: (1_000, 2_000))
    }

    private func waitUntil(_ condition: () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<500 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("Timed out waiting for detail work", file: file, line: line)
        throw CancellationError()
    }
}

private actor SuspendedDetailReader {
    private var continuations: [CheckedContinuation<StatMonitor.DetailSnapshot?, Never>] = []
    private(set) var calls = 0
    private(set) var finished = 0

    func read() async -> StatMonitor.DetailSnapshot? {
        calls += 1
        let result = await withCheckedContinuation { continuations.append($0) }
        finished += 1
        return result
    }

    func finish(with snapshot: StatMonitor.DetailSnapshot) {
        for continuation in continuations { continuation.resume(returning: snapshot) }
        continuations = []
    }
}
