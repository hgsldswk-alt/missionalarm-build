import XCTest

final class CalendarAndEntitlementTests: XCTestCase {
    func testCrossMidnightAndWorkdayRollover() throws {
        let calendar = makeCalendar("Asia/Tokyo")
        let friday = date("2026-11-20T14:59:30Z")
        let next = try XCTUnwrap(AlarmRule().next(after: friday, calendar: calendar))
        XCTAssertEqual(next, date("2026-11-22T22:00:00Z"))
        let midnight = AlarmRule(hour: 0, minute: 0, days: [.saturday])
        XCTAssertEqual(midnight.next(after: friday, calendar: calendar), date("2026-11-20T15:00:00Z"))
        let once = AlarmRule(hour: 23, minute: 58, days: [], oneShot: date("2026-11-20T14:58:00Z"))
        XCTAssertNil(once.next(after: friday, calendar: calendar))
        let backups = ChainPlan.backupDates(after: try XCTUnwrap(once.oneShot), count: 10, interval: 60)
        XCTAssertEqual(calendar.component(.day, from: backups[1]), 21)
        XCTAssertEqual(calendar.component(.hour, from: backups[1]), 0)
        XCTAssertEqual(backups.last, date("2026-11-20T15:08:00Z"))
    }

    func testSpringForwardUsesFirstExistingTimeAndAbsoluteBackupMinutes() throws {
        let calendar = makeCalendar("America/New_York")
        let before = date("2026-03-08T06:58:00Z")
        let missingWallTime = AlarmRule(hour: 2, minute: 30, days: [.sunday])
        let adjusted = try XCTUnwrap(missingWallTime.next(after: before, calendar: calendar))
        XCTAssertEqual(adjusted, date("2026-03-08T07:00:00Z"))
        let backups = ChainPlan.backupDates(after: before, count: 3, interval: 60)
        XCTAssertEqual(backups.map { calendar.component(.hour, from: $0) }, [1, 3, 3])
        XCTAssertEqual(backups.map { $0.timeIntervalSince(before) }, [60, 120, 180])
    }

    func testFallBackUsesFirstOccurrenceAndDoesNotCountTheSameWallTimeTwice() throws {
        let calendar = makeCalendar("America/New_York")
        let rule = AlarmRule(hour: 1, minute: 30, days: [.sunday])
        let before = date("2026-11-01T05:15:00Z")
        let first = try XCTUnwrap(rule.next(after: before, calendar: calendar))
        XCTAssertEqual(first, date("2026-11-01T05:30:00Z"))
        let secondWallTime = date("2026-11-01T06:30:00Z")
        XCTAssertEqual(rule.mostRecent(at: secondWallTime, calendar: calendar), first)
        XCTAssertEqual(rule.next(after: first, calendar: calendar), date("2026-11-08T06:30:00Z"))
    }

    func testTrialStartsOnFirstPaidLaunchAndExpiresAtThirtyDays() {
        let start = date("2026-11-17T01:00:00Z")
        var entitlement = Entitlement()
        XCTAssertTrue(entitlement.hasPro(at: start, freePeriod: true))
        XCTAssertNil(entitlement.trialStart)
        entitlement.startPaidPeriod(at: start)
        entitlement.startPaidPeriod(at: start.addingTimeInterval(5 * 86_400))
        let expiry = start.addingTimeInterval(30 * 86_400)
        XCTAssertEqual(entitlement.trialEnd, expiry)
        XCTAssertEqual(entitlement.remainingDays(at: start), 30)
        XCTAssertTrue(entitlement.hasPro(at: expiry.addingTimeInterval(-1), freePeriod: false))
        XCTAssertFalse(entitlement.hasPro(at: expiry, freePeriod: false))
        XCTAssertEqual(entitlement.remainingDays(at: expiry), 0)
    }

    func testVerifiedTrialDoesNotExtendAccessAndBuyoutWorksAfterExpiry() {
        let start = date("2026-11-17T01:00:00Z")
        var entitlement = Entitlement(proStartedAt: start)
        entitlement.recordTrialClaim(at: start.addingTimeInterval(86_400))
        XCTAssertEqual(entitlement.trialStart, start)
        let original = start.addingTimeInterval(-40 * 86_400)
        entitlement.recordTrialClaim(at: original)
        entitlement.recordTrialClaim(at: start)
        XCTAssertEqual(entitlement.trialStart, original)
        XCTAssertFalse(entitlement.hasPro(at: start, freePeriod: false))
        entitlement.purchasedPro = true
        XCTAssertTrue(entitlement.hasPro(at: start, freePeriod: false))
    }

    func testWakeHistoryCountsAStreakByLocalDayAndRequestsReviewOnceOnThirdSuccess() {
        var history = WakeHistory()
        let timeZone = makeCalendar("Asia/Tokyo").timeZone
        let first = UUID()
        let start = date("2026-11-17T14:59:00Z")
        _ = history.record(runID: first, at: start, timeZone: timeZone)
        _ = history.record(runID: first, at: start, timeZone: timeZone)
        _ = history.record(runID: UUID(), at: date("2026-11-17T15:01:00Z"), timeZone: timeZone)
        XCTAssertEqual(history.streak, 2)
        XCTAssertFalse(history.takeReviewRequest())
        _ = history.record(runID: UUID(), at: date("2026-11-18T15:01:00Z"), timeZone: timeZone)
        XCTAssertEqual(history.streak, 3)
        XCTAssertTrue(history.takeReviewRequest())
        XCTAssertFalse(history.takeReviewRequest())
        XCTAssertEqual(history.currentStreak(at: date("2026-11-21T15:00:00Z"), timeZone: timeZone), 0)
    }

    private func makeCalendar(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
}
