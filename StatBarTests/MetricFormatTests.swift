import Darwin
import XCTest
@testable import StatBar

/// Parsing and display for every reading the popover shows. These stay off the
/// live OS readers so a formatting change fails here instead of in the menu bar.
final class MetricFormatTests: XCTestCase {
    func testCPUPercentRoundsAndCollapsesSubPercentNoise() {
        XCTAssertEqual(Format.percent(0), "0%")
        XCTAssertEqual(Format.percent(0.126), "13%")
        XCTAssertEqual(Format.percent(0.121), Format.percent(0.124))
        XCTAssertEqual(Format.percent(1), "100%")
        XCTAssertEqual(Format.percent(1.4), "100%")
        XCTAssertEqual(Format.percent(-0.2), "0%")
        XCTAssertEqual(Format.percent(.nan), "–")
        XCTAssertEqual(Format.percent(.infinity), "–")
        XCTAssertEqual(Format.cores(240), "2.4")
        XCTAssertEqual(Format.cores(1_000), "10")
        XCTAssertEqual(Format.cores(.nan), "–")
        XCTAssertEqual(Format.processPercent(240.4), "240%")
        XCTAssertEqual(Format.processPercent(.infinity), "–")
    }

    func testMenuBarRedrawKeyIgnoresUnchangedReadings() {
        let quiet = MenuBarPresentation.make(cpu: 0.121, attention: nil)
        XCTAssertEqual(quiet, MenuBarPresentation.make(cpu: 0.124, attention: nil))
        XCTAssertEqual(quiet.title, "12%")
        XCTAssertEqual(quiet.attention, .none)
        XCTAssertNotEqual(quiet, MenuBarPresentation.make(cpu: 0.121, attention: .warning))
        let critical = MenuBarPresentation.make(cpu: 0.5, attention: .critical)
        XCTAssertEqual(critical.attention.symbolName, "exclamationmark.triangle")
        XCTAssertEqual(MenuBarAttention.none.symbolName, "gauge.with.dots.needle.33percent")
    }

    func testGPUFractionClampsAndDropsGarbage() {
        XCTAssertEqual(GPUReader.fraction(fromDevicePercent: 37), 0.37)
        XCTAssertEqual(GPUReader.fraction(fromDevicePercent: 150), 1)
        XCTAssertEqual(GPUReader.fraction(fromDevicePercent: -4), 0)
        XCTAssertNil(GPUReader.fraction(fromDevicePercent: .nan))
        XCTAssertNil(GPUReader.fraction(fromDevicePercent: .infinity))
        XCTAssertEqual(Format.percent(GPUReader.fraction(fromDevicePercent: 100) ?? -1), "100%")
    }

    func testMemoryPressureAndByteFormatting() {
        XCTAssertEqual(MemorySnapshot.pressure(forLevel: 0), .normal)
        XCTAssertEqual(MemorySnapshot.pressure(forLevel: 1), .normal)
        XCTAssertEqual(MemorySnapshot.pressure(forLevel: 2), .warning)
        XCTAssertEqual(MemorySnapshot.pressure(forLevel: 3), .warning)
        XCTAssertEqual(MemorySnapshot.pressure(forLevel: 4), .critical)
        XCTAssertEqual(MemorySnapshot.pressure(forLevel: 8), .critical)
        let memory = MemorySnapshot(
            total: 100, used: 250, compressed: 0, cached: 0, swapUsed: 0, swapTotal: 0, pressure: .normal
        )
        XCTAssertEqual(memory.usedFraction, 1)
        XCTAssertEqual(MemorySnapshot(
            total: 0, used: 10, compressed: 0, cached: 0, swapUsed: 0, swapTotal: 0, pressure: .normal
        ).usedFraction, 0)
        XCTAssertFalse(Format.bytes(0).isEmpty)
        XCTAssertFalse(Format.bytes(UInt64.max).isEmpty)
        XCTAssertNotEqual(Format.bytes(1024), Format.bytes(0))
    }

    func testPowerLabelsAndUnusableSamples() throws {
        let hour = try XCTUnwrap(PowerReader.snapshot(from: [
            "CurrentCapacity": 50, "MaxCapacity": 100, "IsCharging": false, "ExternalConnected": false,
            "AvgTimeToEmpty": 60,
        ]))
        XCTAssertEqual(hour.remainingLabel, "1 h left")
        XCTAssertEqual(hour.stateLabel, "On battery")

        let hourAndHalf = try XCTUnwrap(PowerReader.snapshot(from: [
            "CurrentCapacity": 40, "MaxCapacity": 100, "IsCharging": true, "ExternalConnected": true,
            "AvgTimeToFull": 90, "AdapterDetails": ["Watts": 0],
        ]))
        XCTAssertEqual(hourAndHalf.remainingLabel, "1 h 30 min to full")
        XCTAssertNil(hourAndHalf.adapterWatts)

        let full = try XCTUnwrap(PowerReader.snapshot(from: [
            "CurrentCapacity": 140, "MaxCapacity": 100, "IsCharging": false, "ExternalConnected": true,
            "FullyCharged": true, "AvgTimeToEmpty": 30,
            "BatteryData": ["NominalChargeCapacity": -5, "DesignCapacity": 100],
        ]))
        XCTAssertEqual(full.percent, 100)
        XCTAssertEqual(full.stateLabel, "Charged")
        XCTAssertNil(full.remainingLabel)
        XCTAssertNil(full.health)

        let healthy = try XCTUnwrap(PowerReader.snapshot(from: [
            "CurrentCapacity": 10, "MaxCapacity": 10,
            "BatteryData": ["NominalChargeCapacity": 11_000, "DesignCapacity": 10_000],
        ]))
        XCTAssertEqual(Format.percent(try XCTUnwrap(healthy.health)), "100%")
        XCTAssertEqual(Format.watts(36.64), "36.6 W")
        XCTAssertEqual(Format.watts(.nan), "–")
        XCTAssertEqual(Format.signedWatts(-12.04), "-12.0 W")
        XCTAssertEqual(Format.wholeWatts(12.6), "13 W")
        XCTAssertEqual(Format.duration(59), "under a minute")
        XCTAssertEqual(Format.duration(60), "1 min")
        XCTAssertEqual(Format.duration(3_600), "1 h")
        XCTAssertEqual(Format.duration(3_660), "1 h 1 min")
        XCTAssertEqual(Format.duration(.nan), "under a minute")
    }

    func testNetworkRateAndLinkSpeed() {
        XCTAssertEqual(Format.linkSpeed(10_000_000), "10 Mb/s")
        XCTAssertEqual(Format.linkSpeed(100_000_000), "100 Mb/s")
        XCTAssertEqual(Format.linkSpeed(1_000_000_000), "1 Gb/s")
        XCTAssertEqual(Format.linkSpeed(2_500_000_000), "2.5 Gb/s")
        XCTAssertEqual(Format.linkSpeed(10_000_000_000), "10 Gb/s")
        XCTAssertEqual(Format.linkSpeed(500_000), "500 Kb/s")
        XCTAssertEqual(Format.linkSpeed(0), "0 b/s")
        XCTAssertEqual(Format.rate(0), Format.rate(-8))
        XCTAssertEqual(Format.rate(.nan), Format.rate(0))
        XCTAssertEqual(Format.rate(.infinity), Format.rate(0))
        XCTAssertEqual(Format.rate(1e30), Format.rate(Double(Int64.max)))
        XCTAssertTrue(Format.rate(1_500_000).hasSuffix("/s"))
        XCTAssertNotEqual(Format.rate(1_500_000), Format.rate(0))

        XCTAssertEqual(SystemNetworkReader.ethernetLinkSpeed(forMediaWord: IFM_10_T), 10_000_000)
        XCTAssertEqual(SystemNetworkReader.ethernetLinkSpeed(forMediaWord: IFM_100_TX), 100_000_000)
        XCTAssertEqual(SystemNetworkReader.ethernetLinkSpeed(forMediaWord: IFM_1000_T), 1_000_000_000)
        XCTAssertEqual(SystemNetworkReader.ethernetLinkSpeed(forMediaWord: IFM_2500_T), 2_500_000_000)
        XCTAssertEqual(SystemNetworkReader.ethernetLinkSpeed(forMediaWord: IFM_10G_T), 10_000_000_000)
        XCTAssertNil(SystemNetworkReader.ethernetLinkSpeed(forMediaWord: 0))
        XCTAssertEqual(
            Format.linkSpeed(SystemNetworkReader.ethernetLinkSpeed(forMediaWord: IFM_2500_T) ?? 0),
            "2.5 Gb/s"
        )
    }

    func testDiskFormattingAndProcessLines() {
        let overfull = VolumeInfo(
            id: "/Volumes/Card", name: "Card", url: URL(filePath: "/Volumes/Card"),
            total: 100, available: -5, isInternal: false
        )
        XCTAssertEqual(overfull.usedFraction, 1)
        let roomy = VolumeInfo(
            id: "/", name: "Macintosh HD", url: URL(filePath: "/"),
            total: 100, available: 180, isInternal: true
        )
        XCTAssertEqual(roomy.usedFraction, 0)
        XCTAssertEqual(Format.diskBytes(-20), Format.diskBytes(0))
        XCTAssertFalse(Format.diskBytes(50_000_000_000).isEmpty)

        let processes = ProcessReader.parse("4 nan 10 Nope\n5 inf 10 Nope\n6 2.5 \(UInt64.max) Big One\n")
        XCTAssertEqual(processes.count, 1)
        XCTAssertEqual(processes.first?.name, "Big One")
        XCTAssertEqual(processes.first?.memory, UInt64.max)
        XCTAssertEqual(processes.first?.cpu, 2.5)
    }

    func testHeatLabelsRejectUnreadableFanSamples() {
        XCTAssertEqual(Format.thermal(.nominal), "Cool")
        XCTAssertEqual(Format.thermal(.fair), "Warm")
        XCTAssertEqual(Format.thermal(.serious), "Hot, throttling")
        XCTAssertEqual(Format.thermal(.critical), "Critical, throttling hard")
        XCTAssertEqual(Format.rpm(0), "Off")
        XCTAssertEqual(Format.rpm(0.4), "Off")
        XCTAssertEqual(Format.rpm(2480.6), "2481 rpm")
        XCTAssertEqual(Format.rpm(.nan), "–")
        XCTAssertEqual(Format.rpm(80_000), "–")
        XCTAssertEqual(Format.fanReading(1200, index: 1, count: 2), "Fan 2: 1200 rpm")
        XCTAssertEqual(FanReader.plausibleRPM(1800), 1800)
        XCTAssertNil(FanReader.plausibleRPM(.nan))
        XCTAssertNil(FanReader.plausibleRPM(-1))
        XCTAssertNil(FanReader.plausibleRPM(80_000))
        XCTAssertEqual(FanReader.fanCount(2), 2)
        XCTAssertNil(FanReader.fanCount(0))
        XCTAssertNil(FanReader.fanCount(1e20))
        XCTAssertNil(FanReader.fanCount(.infinity))
    }

    func testSamplerStaysOneCoalescedTimer() {
        XCTAssertEqual(StatMonitor.interval, 2)
        XCTAssertGreaterThanOrEqual(StatMonitor.idleSamplingTolerance, 1)
        XCTAssertLessThan(StatMonitor.activeSamplingTolerance, StatMonitor.idleSamplingTolerance)
        XCTAssertEqual(StatMonitor.samplingTolerance(popoverVisible: false), StatMonitor.idleSamplingTolerance)
        XCTAssertEqual(StatMonitor.samplingTolerance(popoverVisible: true), StatMonitor.activeSamplingTolerance)
        XCTAssertEqual(StatMonitor.historyLength, 60)
    }
}
