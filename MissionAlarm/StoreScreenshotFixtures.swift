import Foundation

enum StoreScreenshotFixtures {
    static var isEnabled: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-store-screenshots")
        #else
        false
        #endif
    }

    #if DEBUG
    static let calendar = Calendar.autoupdatingCurrent
    static let date = calendar.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 6, minute: 42))!

    static var questionGenerator: (MathDifficulty) -> MathQuestion {
        var index = 0
        let questions = [
            MathQuestion(lhs: 24, rhs: 18, operation: .add),
            MathQuestion(lhs: 36, rhs: 15, operation: .subtract),
            MathQuestion(lhs: 27, rhs: 16, operation: .add)
        ]
        return { _ in
            defer { index += 1 }
            return questions[index % questions.count]
        }
    }

    @MainActor static func scheduler() -> AlarmScheduler {
        let showMission = ProcessInfo.processInfo.arguments.contains("-store-mission")
        let firstFire = date.addingTimeInterval(18 * 60)
        let now = showMission ? firstFire.addingTimeInterval(120) : date
        let morning = AlarmRule(hour: 7, minute: 0)
        let weekend = AlarmRule(hour: 8, minute: 30, days: [.saturday, .sunday],
                                mission: Mission(kind: .shake))
        var ledger = AlarmLedger()
        ledger.alarms = [morning, weekend].map {
            ScheduledAlarm(rule: $0, primaryID: UUID(), installedAt: date.addingTimeInterval(-86_400))
        }
        if showMission, let alarm = ledger.alarms.first {
            var run = AlarmRun(alarm: alarm, firstFire: firstFire)
            run.started = true
            ledger.runs = [run]
            for offset in [2, 1] {
                if let previous = calendar.date(byAdding: .day, value: -offset, to: now) {
                    _ = ledger.history.record(runID: UUID(), at: previous, timeZone: calendar.timeZone)
                }
            }
        }
        let rings = ScreenshotRings(installed: ledger.alarms.map(\.primaryID))
        return AlarmScheduler(ledger: ledger, driver: rings, clock: { now }, persist: { _ in })
    }
    #endif
}

#if DEBUG
@MainActor
private final class ScreenshotRings: RingDriver {
    private var scheduled: Set<UUID>

    init(installed: [UUID]) { scheduled = Set(installed) }

    func alarms() -> [UUID: Bool] {
        Dictionary(uniqueKeysWithValues: scheduled.map { ($0, false) })
    }

    func schedule(_ schedule: RingSchedule, id: UUID) async { scheduled.insert(id) }
    func stop(id: UUID) {}
    func cancel(id: UUID) { scheduled.remove(id) }
}
#endif
