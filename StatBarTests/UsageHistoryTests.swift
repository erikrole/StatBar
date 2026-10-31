import XCTest
@testable import StatBar

final class UsageHistoryTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    func testHoursCloseAndDaysSummarize() throws {
        var history = UsageHistory()
        XCTAssertFalse(history.record(cpu: 0.2, memory: 0.5, downloadRate: 1_000, uploadRate: 10, seconds: 2,
                                      startupFree: nil, at: start, calendar: calendar))
        XCTAssertFalse(history.record(cpu: 0.6, memory: 0.5, downloadRate: 1_000, uploadRate: 10, seconds: 2,
                                      startupFree: nil, at: start.addingTimeInterval(60), calendar: calendar))
        XCTAssertTrue(history.record(cpu: .nan, memory: nil, downloadRate: -5, uploadRate: 0, seconds: 2,
                                     startupFree: nil, at: start.addingTimeInterval(3600), calendar: calendar))
        XCTAssertEqual(history.hours.count, 1)
        XCTAssertEqual(history.hours[0].cpuAverage, 0.4, accuracy: 0.0001)
        XCTAssertEqual(history.hours[0].downloadBytes, 4_000)
        let days = history.days(7, calendar: calendar)
        XCTAssertEqual(days.count, 1)
        XCTAssertEqual(days[0].cpuMax, 0.6)
        XCTAssertEqual(days[0].downloadBytes, 4_000, "bad readings add nothing")
    }

    func testKeepsThirtyDaysAndRoundTripsThroughDisk() throws {
        var history = UsageHistory()
        for hour in 0...(UsageHistory.keepHours + 5) {
            history.record(cpu: 0.1, memory: 0.1, downloadRate: 0, uploadRate: 0, seconds: 2, startupFree: 1,
                           at: start.addingTimeInterval(Double(hour) * 3600), calendar: calendar)
        }
        XCTAssertEqual(history.hours.count, UsageHistory.keepHours)
        let url = FileManager.default.temporaryDirectory.appending(path: "history-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        history.save(to: url)
        XCTAssertEqual(UsageHistory.load(from: url), history)
        try Data("not json".utf8).write(to: url)
        XCTAssertEqual(UsageHistory.load(from: url), UsageHistory(), "a damaged file starts over")
    }

    func testStartupDiskTrend() {
        var shrinking = UsageHistory(), steady = UsageHistory()
        let gigabyte: Int64 = 1_000_000_000
        for hour in 0..<48 {
            let at = start.addingTimeInterval(Double(hour) * 3600)
            // Loses 1 GB an hour from 100 GB: about 52 GB left, ~2.2 days to go.
            shrinking.record(cpu: 0, memory: 0, downloadRate: 0, uploadRate: 0, seconds: 2,
                             startupFree: 100 * gigabyte - Int64(hour) * gigabyte, at: at, calendar: calendar)
            steady.record(cpu: 0, memory: 0, downloadRate: 0, uploadRate: 0, seconds: 2,
                          startupFree: 100 * gigabyte, at: at, calendar: calendar)
        }
        let now = start.addingTimeInterval(47 * 3600)
        XCTAssertEqual(shrinking.daysUntilStartupFull(now: now) ?? 0, 53.0 / 24, accuracy: 0.05)
        XCTAssertNil(steady.daysUntilStartupFull(now: now))
        XCTAssertNil(UsageHistory().daysUntilStartupFull(now: now))
    }

    func testTrendAndBatteryHealthInsights() {
        var engine = InsightEngine()
        var signals = Signals()
        signals.online = true
        signals.startupDiskFull = ("Macintosh HD", 2.2)
        signals.battery = BatterySnapshot(percent: 80, isCharging: false, isPluggedIn: true, isFull: false, minutesRemaining: nil,
                                          flowWatts: 0, adapterWatts: 96, cycleCount: 900, health: 0.76)
        let fresh = engine.update(signals)
        XCTAssertEqual(fresh.first { $0.id == "diskTrend" }?.title, "Macintosh HD fills in about 2 days")
        XCTAssertEqual(fresh.first { $0.id == "diskTrend" }?.severity, .critical)
        XCTAssertEqual(fresh.first { $0.id == "batteryHealth" }?.notifies, false)
    }
}
