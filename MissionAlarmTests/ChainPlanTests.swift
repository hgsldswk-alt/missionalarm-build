import XCTest

final class ChainPlanTests: XCTestCase {
    func testBackupDatesAreEvenlySpaced() {
        let start = Date(timeIntervalSince1970: 1_000)
        let dates = ChainPlan.backupDates(after: start, count: 3, interval: 60)
        XCTAssertEqual(dates.map { $0.timeIntervalSince1970 }, [1_060, 1_120, 1_180])
    }

    func testNoBackupsWhenCountIsZero() {
        XCTAssertTrue(ChainPlan.backupDates(after: Date(), count: 0, interval: 60).isEmpty)
    }

    func testNextRingHasMinimumGap() {
        let now = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(ChainPlan.nextRing(after: now, interval: 5).timeIntervalSince1970, 30)
        XCTAssertEqual(ChainPlan.nextRing(after: now, interval: 60).timeIntervalSince1970, 60)
    }
}
