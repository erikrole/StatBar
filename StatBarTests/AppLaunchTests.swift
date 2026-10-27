import XCTest
@testable import StatBar

final class AppLaunchTests: XCTestCase {
    func testDiagnosticModesAndDefaultsFlags() throws {
        XCTAssertEqual(try AppLaunchMode(arguments: []), .normal)
        XCTAssertEqual(try AppLaunchMode(arguments: ["--report"]), .report(seconds: 4.5))
        XCTAssertEqual(try AppLaunchMode(arguments: ["--report", "75"]), .report(seconds: 75))
        XCTAssertEqual(try AppLaunchMode(arguments: ["--report", "-notificationsEnabled", "NO"]), .report(seconds: 4.5))
        XCTAssertEqual(try AppLaunchMode(arguments: ["--snapshot", "/tmp/StatBar.png", "--snapshot-light"]), .snapshot(path: "/tmp/StatBar.png", light: true))
        XCTAssertEqual(try AppLaunchMode(arguments: ["--measure-idle"]), .measureIdle)
        XCTAssertFalse(AppLaunchMode.normal.isDiagnostic)
        XCTAssertTrue(AppLaunchMode.measureIdle.isDiagnostic)
        XCTAssertTrue(AppLaunchMode.report(seconds: 4.5).isDiagnostic)
        XCTAssertTrue(AppLaunchMode.snapshot(path: "/tmp/StatBar.png", light: false).isDiagnostic)
        XCTAssertTrue(AppLaunchMode.report(seconds: 4.5).isHeadless)
        XCTAssertTrue(AppLaunchMode.snapshot(path: "/tmp/StatBar.png", light: false).isHeadless)
        XCTAssertFalse(AppLaunchMode.normal.isHeadless)
        XCTAssertFalse(AppLaunchMode.measureIdle.isHeadless)
        XCTAssertEqual(try AppLaunchMode(arguments: ["--report", "86400"]), .report(seconds: 86_400))
    }

    func testInvalidDiagnosticsFailInsteadOfLaunchingAnOrdinaryCopy() {
        for arguments in [
            ["--report", "0"], ["--report", "-1"], ["--report", "nan"],
            ["--report", "inf"], ["--report", "later"], ["--report", "1e300"], ["--report", "86401"],
            ["--snapshot"], ["--snapshot", "--snapshot-light"],
            ["--measure-idle", "--report"], ["--report", "--snapshot", "/tmp/StatBar.png"],
        ] {
            XCTAssertThrowsError(try AppLaunchMode(arguments: arguments), "\(arguments)")
        }
    }

    func testConcurrentLaunchesElectExactlyOneCopyRegardlessOfEnumerationOrder() throws {
        let date = Date(timeIntervalSince1970: 1_000)
        // PIDs can wrap; launch date takes precedence over numeric PID order.
        let oldest = AppInstance(processIdentifier: 900, launchDate: date)
        let middle = AppInstance(processIdentifier: 100, launchDate: date.addingTimeInterval(1))
        let newest = AppInstance(processIdentifier: 200, launchDate: date.addingTimeInterval(2))
        for instances in [[oldest, middle, newest], [newest, oldest, middle], [middle, newest, oldest]] {
            let survivors = instances.filter { candidate in !instances.contains { $0.precedes(candidate) } }
            XCTAssertEqual(survivors, [oldest])
        }
        XCTAssertFalse(oldest.precedes(oldest))
    }

    func testSameOrMissingLaunchDatesHaveDeterministicTieBreaks() {
        for date in [nil, Date(timeIntervalSince1970: 1_000)] {
            let first = AppInstance(processIdentifier: 10, launchDate: date)
            let second = AppInstance(processIdentifier: 11, launchDate: date)
            XCTAssertTrue(first.precedes(second))
            XCTAssertFalse(second.precedes(first))
        }
        let unknown = AppInstance(processIdentifier: 50, launchDate: nil)
        let known = AppInstance(processIdentifier: 10, launchDate: Date())
        XCTAssertTrue(unknown.precedes(known))
        XCTAssertFalse(known.precedes(unknown))
    }
}
