import XCTest
@testable import StatBar

/// Live-reader benchmarks: compare Release results on the same Mac and workload.
/// These deliberately report timings without hardware-dependent pass/fail limits.
final class PerformanceTests: XCTestCase {
    private func benchmark(_ name: String, iterations: Int = 20, _ body: () -> Void) {
        for _ in 0..<3 { body() }
        let clock = ContinuousClock()
        var milliseconds: [Double] = []
        for _ in 0..<iterations {
            let start = clock.now
            body()
            let duration = start.duration(to: clock.now).components
            milliseconds.append(Double(duration.seconds) * 1_000 + Double(duration.attoseconds) / 1e15)
        }
        milliseconds.sort()
        let median = milliseconds[milliseconds.count / 2]
        let p95 = milliseconds[Int(ceil(Double(milliseconds.count) * 0.95)) - 1]
        print(String(format: "BENCHMARK %@ n=%d median_ms=%.3f p95_ms=%.3f", name, iterations, median, p95))
    }

    func testFastReadersBenchmark() {
        var cpu = CPUReader()
        let network = SystemNetworkReader()
        benchmark("fast-readers") {
            _ = cpu.sample()
            _ = GPUReader.utilization()
            _ = MemoryReader.read()
            let route = network.activeRoute()
            if let name = route.interfaceName { _ = network.counters(for: name) }
        }
    }

    func testBatteryBenchmark() {
        benchmark("battery") { _ = PowerReader.battery() }
    }

    func testDiskReadersBenchmark() {
        benchmark("volumes-quick") { _ = DiskReader.quickVolumes() }
        benchmark("volumes-full") { _ = DiskReader.volumes() }
        benchmark("disk-io") { _ = DiskReader.ioTotals() }
    }

    func testProcessReadersBenchmark() {
        var sampler = QuickProcessSampler()
        benchmark("processes-quick") { _ = sampler.sample() }
        benchmark("processes-full", iterations: 10) { _ = ProcessReader.sample() }
    }

    func testNetworkDetailsBenchmark() {
        let reader = SystemNetworkReader()
        guard let name = reader.activeRoute().interfaceName else { return }
        benchmark("interface-identity") {
            _ = reader.identity(forBSDName: name)
        }
        benchmark("network-details") {
            _ = reader.localIPv4Address(for: name)
            _ = reader.activeEthernetConnections()
            _ = reader.globalProtectStatus()
        }
    }

    func testInsightEngineBenchmark() {
        var engine = InsightEngine()
        var signals = Signals()
        signals.online = true
        signals.processes = (0..<200).map {
            ProcessUsage(name: "App \($0)", cpu: Double($0), memory: UInt64($0) << 20, count: 3)
        }
        benchmark("insights-200-apps", iterations: 100) {
            signals.now.addTimeInterval(2)
            engine.update(signals)
        }
    }
}
