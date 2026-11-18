import XCTest

final class AlarmSchedulerTests: XCTestCase {
    @MainActor
    func testStopReusesPrearmedBackupsAndCompletionCancelsEntireOneShot() async throws {
        let fixture = AlarmFixture()
        let scheduler = fixture.makeScheduler()
        try await scheduler.configure(AlarmRule(days: []))
        let alarm = try XCTUnwrap(scheduler.ledger.alarms.first)
        let run = try XCTUnwrap(scheduler.ledger.runs.first)
        XCTAssertEqual(fixture.driver.registered.count, 11)

        fixture.now = run.firstFire.addingTimeInterval(2)
        fixture.driver.registered.removeValue(forKey: alarm.primaryID)
        try await scheduler.receive(alarm.primaryID, event: .stop, at: fixture.now)
        try await scheduler.receive(alarm.primaryID, event: .stop, at: fixture.now)
        XCTAssertEqual(fixture.driver.scheduled.count, 11)
        XCTAssertEqual(scheduler.ledger.runs.first?.handledStops, [alarm.primaryID])

        let wake = try await scheduler.complete(run.id)
        XCTAssertNotNil(wake)
        XCTAssertTrue(fixture.driver.registered.isEmpty)
        XCTAssertEqual(fixture.driver.cancelled, Set(run.backups.map(\.id)))
        XCTAssertTrue(scheduler.ledger.runs.first?.closed == true)
        XCTAssertFalse(try XCTUnwrap(scheduler.ledger.alarms.first).rule.enabled)

        let reloaded = fixture.makeScheduler()
        fixture.now = run.backups[0].date
        try await reloaded.receive(run.backups[0].id, event: .stop, at: fixture.now)
        try await reloaded.receive(alarm.primaryID, event: .stop, at: fixture.now)
        let duplicateWake = try await reloaded.complete(run.id)
        XCTAssertNil(duplicateWake)
        XCTAssertEqual(fixture.driver.scheduled.count, 11)
        XCTAssertEqual(reloaded.ledger.history.records.count, 1)
    }

    @MainActor
    func testLateStopExtendsChainOnceAndCompletionWinsDuringAnInFlightSchedule() async throws {
        let fixture = AlarmFixture()
        let scheduler = fixture.makeScheduler()
        try await scheduler.configure(AlarmRule(days: []))
        let run = try XCTUnwrap(scheduler.ledger.runs.first)
        let last = try XCTUnwrap(run.backups.last)
        fixture.now = last.date.addingTimeInterval(1)
        fixture.driver.registered.removeAll()
        let gate = ScheduleGate()
        let suspended = expectation(description: "The follow-up schedule is in flight")
        fixture.driver.beforeNextSchedule = { await gate.suspend { suspended.fulfill() } }
        let pendingStop = Task { try await scheduler.receive(last.id, event: .stop, at: fixture.now) }
        await fulfillment(of: [suspended], timeout: 3)
        let completion = Task { try await scheduler.complete(run.id) }
        gate.resume()
        try await pendingStop.value
        let wake = try await completion.value
        XCTAssertNotNil(wake)
        let extended = try XCTUnwrap(scheduler.ledger.runs.first?.backups.last)
        XCTAssertTrue(extended.isFollowUp)
        XCTAssertEqual(extended.date, fixture.now.addingTimeInterval(60))
        XCTAssertTrue(fixture.driver.cancelled.contains(extended.id))
        XCTAssertTrue(fixture.driver.registered.isEmpty)

        try await scheduler.receive(last.id, event: .stop, at: fixture.now)
        XCTAssertEqual(fixture.driver.scheduled.count, 12)
    }

    @MainActor
    func testRepeatingPrimaryStaysArmedAndNextWindowReplacesOnlyCurrentBackups() async throws {
        let fixture = AlarmFixture()
        let scheduler = fixture.makeScheduler()
        try await scheduler.configure(AlarmRule())
        let row = try XCTUnwrap(scheduler.ledger.alarms.first)
        let current = try XCTUnwrap(scheduler.ledger.runs.first)
        XCTAssertEqual(fixture.driver.registered[row.primaryID], .weekly(hour: 7, minute: 0, days: Weekday.workdays))

        fixture.now = current.firstFire
        fixture.driver.alerting = [row.primaryID]
        try await scheduler.receive(row.primaryID, event: .alert, at: fixture.now)
        _ = try await scheduler.complete(current.id)
        let next = try XCTUnwrap(scheduler.ledger.runs.first { !$0.closed })
        XCTAssertGreaterThan(next.firstFire, current.firstFire)
        XCTAssertTrue(fixture.driver.stopped.contains(row.primaryID))
        XCTAssertFalse(fixture.driver.cancelled.contains(row.primaryID))
        XCTAssertEqual(fixture.driver.registered.count, 11)
        XCTAssertTrue(Set(current.backups.map(\.id)).isDisjoint(with: fixture.driver.registered.keys))
        try await scheduler.receive(row.primaryID, event: .stop, at: fixture.now)
        XCTAssertEqual(fixture.driver.scheduled.count, 21)
    }

    @MainActor
    func testFreshClockZoneReplansBackupsAndKeepsWeeklyPrimary() async throws {
        let fixture = AlarmFixture()
        let scheduler = fixture.makeScheduler()
        try await scheduler.configure(AlarmRule(days: Set(Weekday.allCases)))
        let old = try XCTUnwrap(scheduler.ledger.runs.first)
        let primary = try XCTUnwrap(scheduler.ledger.alarms.first?.primaryID)
        fixture.calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        try await scheduler.reconcile()
        let rewritten = try XCTUnwrap(scheduler.ledger.runs.first { !$0.closed })
        XCTAssertNotEqual(old.firstFire, rewritten.firstFire)
        XCTAssertEqual(fixture.calendar.component(.hour, from: rewritten.firstFire), 7)
        XCTAssertFalse(fixture.driver.cancelled.contains(primary))
        XCTAssertEqual(fixture.driver.cancelled, Set(old.backups.map(\.id)))

        fixture.calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        try await scheduler.reconcile()
        let restored = try XCTUnwrap(scheduler.ledger.runs.first { !$0.closed })
        XCTAssertEqual(restored.firstFire, old.firstFire)
        fixture.now = restored.firstFire
        try await scheduler.receive(primary, event: .alert, at: fixture.now)
        XCTAssertTrue(scheduler.ledger.runs.first(where: { $0.id == restored.id })?.started == true)
    }

    @MainActor
    func testFailedReplacementKeepsOldAlarmAndPartialBackupsAreRetried() async throws {
        let fixture = AlarmFixture()
        let scheduler = fixture.makeScheduler()
        fixture.driver.limit = 4
        let original = AlarmRule()
        try await scheduler.configure(original)
        let primary = try XCTUnwrap(scheduler.ledger.alarms.first?.primaryID)
        XCTAssertTrue(scheduler.incompleteBackups.contains(original.id))

        var edited = original
        edited.hour = 9
        do {
            try await scheduler.configure(edited)
            XCTFail("Replacement should fail at the system limit.")
        } catch {
            XCTAssertEqual(scheduler.ledger.alarms.first?.rule, original)
            XCTAssertNotNil(fixture.driver.registered[primary])
        }
        fixture.driver.limit = 20
        try await scheduler.reconcile()
        XCTAssertEqual(fixture.driver.registered.count, 11)
        XCTAssertTrue(scheduler.incompleteBackups.isEmpty)
    }

    @MainActor
    func testConcurrentAlarmsStayIndependentAndFailedCancellationsCanResume() async throws {
        let fixture = AlarmFixture()
        let scheduler = fixture.makeScheduler()
        let first = AlarmRule(days: [])
        let second = AlarmRule(hour: 9, days: [])
        try await scheduler.configure(first)
        try await scheduler.configure(second)
        let primary = try XCTUnwrap(scheduler.ledger.alarms.first { $0.id == first.id }?.primaryID)
        let latest = try XCTUnwrap(scheduler.ledger.runs.first { $0.alarmID == first.id })
        let backup = try XCTUnwrap(latest.backups.first?.id)
        fixture.driver.cancelFailures = [backup]
        fixture.now = latest.firstFire
        try await scheduler.receive(primary, event: .alert, at: fixture.now)
        _ = try await scheduler.complete(latest.id)
        XCTAssertEqual(scheduler.ledger.cancellations, [backup])
        XCTAssertEqual(fixture.driver.registered.count, 12)

        let reloaded = fixture.makeScheduler()
        fixture.driver.cancelFailures = []
        try await reloaded.reconcile()
        let ringIDs = Set(fixture.driver.registered.keys)
        let otherRun = try XCTUnwrap(reloaded.ledger.runs.first { $0.alarmID == second.id })
        XCTAssertTrue(ringIDs.isSuperset(of: otherRun.backups.map(\.id)))
        XCTAssertEqual(ringIDs.count, 11)
        XCTAssertTrue(reloaded.ledger.cancellations.isEmpty)
    }
}

@MainActor
private final class AlarmFixture {
    let driver = FakeRings()
    var now = ISO8601DateFormatter().date(from: "2026-11-17T06:00:00Z")!
    var calendar = Calendar(identifier: .gregorian)
    private var stored: Data?

    init() { calendar.timeZone = TimeZone(secondsFromGMT: 0)! }

    func makeScheduler() -> AlarmScheduler {
        let ledger = stored.flatMap { try? JSONDecoder().decode(AlarmLedger.self, from: $0) } ?? AlarmLedger()
        return AlarmScheduler(ledger: ledger, driver: driver, clock: { self.now }, calendar: { self.calendar },
                              persist: { self.stored = try JSONEncoder().encode($0) })
    }
}

@MainActor
private final class FakeRings: RingDriver {
    enum TestError: Error { case rejected }
    var registered: [UUID: RingSchedule] = [:]
    var scheduled: [UUID] = []
    var alerting: Set<UUID> = []
    var cancelled: Set<UUID> = []
    var stopped: Set<UUID> = []
    var cancelFailures: Set<UUID> = []
    var limit = 100
    var beforeNextSchedule: (() async -> Void)?

    func alarms() throws -> [UUID: Bool] {
        Dictionary(uniqueKeysWithValues: registered.keys.map { ($0, alerting.contains($0)) })
    }

    func schedule(_ schedule: RingSchedule, id: UUID) async throws {
        if let beforeNextSchedule {
            self.beforeNextSchedule = nil
            await beforeNextSchedule()
        }
        guard registered.count < limit, registered[id] == nil else { throw TestError.rejected }
        scheduled.append(id)
        registered[id] = schedule
    }

    func stop(id: UUID) throws {
        stopped.insert(id)
        alerting.remove(id)
        if case .fixed? = registered[id] { registered.removeValue(forKey: id) }
    }

    func cancel(id: UUID) throws {
        guard !cancelFailures.contains(id) else { throw TestError.rejected }
        cancelled.insert(id)
        registered.removeValue(forKey: id)
        alerting.remove(id)
    }
}

@MainActor
private final class ScheduleGate {
    private var pending: CheckedContinuation<Void, Never>?
    private var released = false

    func suspend(entered: () -> Void) async {
        guard !released else { return }
        await withCheckedContinuation {
            pending = $0
            entered()
        }
    }

    func resume() {
        released = true
        pending?.resume()
        pending = nil
    }
}
