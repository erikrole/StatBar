import XCTest
@testable import StatBar

final class ReaderTests: XCTestCase {
    func testSMCStructMatchesKernelLayout() {
        XCTAssertEqual(MemoryLayout<SMCParams>.size, 80)
        XCTAssertEqual(MemoryLayout<SMCParams>.offset(of: \SMCParams.result), 40)
        XCTAssertEqual(MemoryLayout<SMCParams>.offset(of: \SMCParams.data8), 42)
        XCTAssertEqual(MemoryLayout<SMCParams>.offset(of: \SMCParams.bytes), 48)
    }

    func testSMCDecoding() {
        let rpm: Float = 2480
        let bits = rpm.bitPattern
        let bytes = [UInt8(bits & 0xFF), UInt8(bits >> 8 & 0xFF), UInt8(bits >> 16 & 0xFF), UInt8(bits >> 24)]
        XCTAssertEqual(FanReader.decode(bytes, type: FanReader.fourCharCode("flt ")), 2480)
        XCTAssertEqual(FanReader.decode([0x26, 0xC0], type: FanReader.fourCharCode("fpe2")), 2480)
        XCTAssertEqual(FanReader.decode([2], type: FanReader.fourCharCode("ui8 ")), 2)
    }

    func testCPULoadDeltas() {
        let old = [CPUReader.Ticks(busy: 100, total: 200), CPUReader.Ticks(busy: 50, total: 100)]
        let new = [CPUReader.Ticks(busy: 150, total: 300), CPUReader.Ticks(busy: 50, total: 200)]
        XCTAssertEqual(CPUReader.loads(from: old, to: new), [0.5, 0])
        XCTAssertEqual(CPUReader.loads(from: [], to: new), [])
    }

    func testProcessParsingFoldsHelpers() {
        let output = """
          101 12.5 102400 Google Chrome
          102 30.0 204800 Google Chrome Helper (Renderer)
          103  5.0  51200 Adobe After Effects 2026
          104  1.0  10240 Browser Helper (Renderer)
        """
        let paths: [Int32: String] = [
            104: "/Applications/Dia.app/Contents/Frameworks/ArcCore.framework/Helpers/Browser Helper (Renderer).app/Contents/MacOS/Browser Helper (Renderer)",
        ]
        let processes = ProcessReader.parse(output, path: { paths[$0] }).sorted { $0.cpu > $1.cpu }
        XCTAssertTrue(processes.contains { $0.name == "Dia" })
        XCTAssertEqual(processes.first?.name, "Google Chrome")
        XCTAssertEqual(processes.first?.cpu, 42.5)
        XCTAssertEqual(processes.first?.count, 2)
        XCTAssertEqual(processes.first?.memory, 300 * 1024 * 1024)
    }

    func testLiveReadersReturnSaneValues() throws {
        let memory = try XCTUnwrap(MemoryReader.read())
        XCTAssertGreaterThan(memory.total, 0)
        XCTAssertLessThanOrEqual(memory.used, memory.total)
        XCTAssertFalse(DiskReader.volumes().isEmpty)
        XCTAssertFalse(CPUReader.readGroups().isEmpty)
    }
}

final class PowerTests: XCTestCase {
    func testBatterySnapshotFromRegistry() throws {
        let registry: [String: Any] = [
            "CurrentCapacity": 24, "MaxCapacity": 100, "IsCharging": false, "ExternalConnected": false,
            "FullyCharged": false, "AvgTimeToEmpty": 52, "Voltage": 12_200, "InstantAmperage": NSNumber(value: Int64(-3000)),
            "CycleCount": 72,
            "BatteryData": ["NominalChargeCapacity": 8487, "DesignCapacity": 8579],
        ]
        let battery = try XCTUnwrap(PowerReader.snapshot(from: registry))
        XCTAssertEqual(battery.percent, 24)
        XCTAssertEqual(battery.remainingLabel, "52 min left")
        XCTAssertEqual(battery.flowWatts ?? 0, -36.6, accuracy: 0.01)
        XCTAssertEqual(Format.percent(try XCTUnwrap(battery.health)), "99%")
        XCTAssertNil(battery.adapterWatts)
    }

    func testCalculatingTimeIsHidden() throws {
        let battery = try XCTUnwrap(PowerReader.snapshot(from: [
            "CurrentCapacity": 80, "MaxCapacity": 100, "IsCharging": true, "ExternalConnected": true, "AvgTimeToFull": 65535,
            "AdapterDetails": ["Watts": 140],
        ]))
        XCTAssertNil(battery.remainingLabel)
        XCTAssertEqual(battery.adapterWatts, 140)
        XCTAssertEqual(battery.stateLabel, "Charging")
    }
}

final class HardeningTests: XCTestCase {
    func testCounterRateNeverSpikesOnReset() {
        XCTAssertEqual(counterRate(from: 1_000, to: 3_000, over: 2), 1_000)
        XCTAssertEqual(counterRate(from: 5_000_000, to: 10, over: 2), 0)
        XCTAssertEqual(counterRate(from: 10, to: 20, over: 0), 0)
    }

    func testProcessParsingIgnoresJunkLines() {
        let output = "garbage\n  12 abc 100 Foo\n  13 1.5 2048 Bar Baz\n"
        let processes = ProcessReader.parse(output)
        XCTAssertEqual(processes.map(\.name), ["Bar Baz"])
    }

    func testBatteryWithoutCapacityIsNil() {
        XCTAssertNil(PowerReader.snapshot(from: ["CurrentCapacity": 50]))
        XCTAssertNil(PowerReader.snapshot(from: ["CurrentCapacity": 50, "MaxCapacity": 0]))
    }
}

final class QuickReaderTests: XCTestCase {
    func testQuickVolumesIncludeStartupDisk() throws {
        let startup = try XCTUnwrap(DiskReader.quickVolumes().first { $0.id == "/" })
        XCTAssertGreaterThan(startup.total, 0)
        XCTAssertGreaterThan(startup.available, 0)
        // Same id scheme as the full reader, so mount events line up.
        XCTAssertTrue(DiskReader.volumes().contains { $0.id == "/" })
    }

    func testQuickProcessSamplerSeesOwnProcesses() {
        var sampler = QuickProcessSampler()
        let first = sampler.sample()
        XCTAssertFalse(first.isEmpty)
        XCTAssertTrue(first.allSatisfy { $0.cpu == 0 }, "first sample has no CPU baseline")
        var spin = 0.0
        let end = Date().addingTimeInterval(0.3)
        while Date() < end { spin += sin(spin) }
        let second = sampler.sample()
        XCTAssertTrue(second.contains { $0.cpu > 10 }, "the busy test process shows CPU")
        XCTAssertGreaterThan(spin, -1)
    }
}
