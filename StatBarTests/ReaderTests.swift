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
