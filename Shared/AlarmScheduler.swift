import Foundation

enum RingSchedule: Equatable {
    case fixed(Date)
    case weekly(hour: Int, minute: Int, days: Set<Weekday>)
}

@MainActor
protocol RingDriver {
    func alarms() throws -> [UUID: Bool]
    func schedule(_ schedule: RingSchedule, id: UUID) async throws
    func stop(id: UUID) throws
    func cancel(id: UUID) throws
}

struct ScheduledAlarm: Codable, Equatable, Identifiable {
    var rule: AlarmRule
    var primaryID: UUID
    var installedAt: Date
    var id: UUID { rule.id }
}

struct BackupRing: Codable, Equatable {
    var id = UUID()
    var date: Date
    var isFollowUp = false
}

struct AlarmRun: Codable, Equatable, Identifiable {
    var id = UUID()
    var alarmID: UUID
    var firstFire: Date
    var mission: Mission
    var started = false
    var closed = false
    var handledStops: Set<UUID> = []
    var backups: [BackupRing]

    init(alarm: ScheduledAlarm, firstFire: Date) {
        alarmID = alarm.id
        mission = alarm.rule.mission
        self.firstFire = firstFire
        backups = ChainPlan.backupDates(after: firstFire, count: ChainPlan.backupCount, interval: ChainPlan.interval)
            .map { BackupRing(date: $0) }
    }

    mutating func planFollowUp(from source: UUID, at now: Date) {
        guard !closed, handledStops.insert(source).inserted else { return }
        let target = ChainPlan.nextRing(after: now, interval: ChainPlan.interval)
        guard !backups.contains(where: { $0.date > now && $0.date <= target.addingTimeInterval(3) }) else { return }
        backups.append(BackupRing(date: target, isFollowUp: true))
    }
}

struct AlarmLedger: Codable, Equatable {
    var alarms: [ScheduledAlarm] = []
    var runs: [AlarmRun] = []
    var cancellations: Set<UUID> = []
    var primaryStops: [UUID: Date] = [:]
    var history = WakeHistory()
}

@MainActor
final class AlarmScheduler {
    enum Event { case alert, stop, open }
    enum Failure: Error { case invalidRule, noFutureDate }

    private(set) var ledger: AlarmLedger
    private(set) var unarmed: Set<UUID> = []
    private(set) var incompleteBackups: Set<UUID> = []
    private let driver: RingDriver
    private let persist: (AlarmLedger) throws -> Void
    private let clock: () -> Date
    private let calendar: () -> Calendar
    private let diagnostic: (String, Error?) -> Void
    private var tail: Task<Void, Never>?

    init(ledger: AlarmLedger = AlarmLedger(), driver: RingDriver,
         clock: @escaping () -> Date = { Date() }, calendar: @escaping () -> Calendar = { .autoupdatingCurrent },
         persist: @escaping (AlarmLedger) throws -> Void,
         diagnostic: @escaping (String, Error?) -> Void = { _, _ in }) {
        self.ledger = ledger
        self.driver = driver
        self.clock = clock
        self.calendar = calendar
        self.persist = persist
        self.diagnostic = diagnostic
    }

    private func serialize<T: Sendable>(_ operation: @escaping @MainActor () async throws -> T) async throws -> T {
        let previous = tail
        let job = Task { @MainActor in
            await previous?.value
            return try await operation()
        }
        tail = Task { _ = try? await job.value }
        return try await job.value
    }

    private func commit(_ change: (inout AlarmLedger) -> Void) throws {
        var next = ledger
        change(&next)
        guard next != ledger else { return }
        try persist(next)
        ledger = next
    }

    func configure(_ rule: AlarmRule) async throws {
        try await serialize { try await self.apply(rule) }
    }

    private func apply(_ original: AlarmRule) async throws {
        var rule = original
        let now = clock()
        let old = ledger.alarms.first { $0.id == rule.id }
        if rule == old?.rule { return }
        guard (0...23).contains(rule.hour), (0...59).contains(rule.minute), !rule.enabled || rule.mission.isValid else {
            diagnostic("闹钟时间或任务无效", nil)
            throw Failure.invalidRule
        }
        if rule.enabled && !rule.isRepeating && (rule.oneShot ?? .distantPast) <= now {
            rule.oneShot = nil
            rule.oneShot = rule.next(after: now, calendar: calendar())
        }
        let new = ScheduledAlarm(rule: rule, primaryID: UUID(), installedAt: now)
        if rule.enabled {
            let schedule = try primarySchedule(new)
            try commit { $0.cancellations.insert(new.primaryID) }
            do {
                try await driver.schedule(schedule, id: new.primaryID)
                try commit { state in
                    Self.replace(old, with: new, in: &state)
                    state.cancellations.remove(new.primaryID)
                }
            } catch {
                try? cleanup()
                throw error
            }
        } else {
            try commit { Self.replace(old, with: new, in: &$0) }
        }
        await repair()
    }

    func delete(_ id: UUID) async throws {
        try await serialize {
            guard let old = self.ledger.alarms.first(where: { $0.id == id }) else { return }
            try self.commit { Self.replace(old, with: nil, in: &$0) }
            await self.repair()
        }
    }

    private static func replace(_ old: ScheduledAlarm?, with new: ScheduledAlarm?, in state: inout AlarmLedger) {
        if let old {
            state.cancellations.insert(old.primaryID)
            state.primaryStops.removeValue(forKey: old.primaryID)
            for index in state.runs.indices where state.runs[index].alarmID == old.id {
                state.cancellations.formUnion(state.runs[index].backups.map(\.id))
            }
            state.runs.removeAll { $0.alarmID == old.id }
            if let index = state.alarms.firstIndex(where: { $0.id == old.id }) {
                if let new { state.alarms[index] = new }
                else { state.alarms.remove(at: index) }
                return
            }
        }
        if let new { state.alarms.append(new) }
    }

    private func primarySchedule(_ alarm: ScheduledAlarm) throws -> RingSchedule {
        let rule = alarm.rule
        if rule.isRepeating { return .weekly(hour: rule.hour, minute: rule.minute, days: rule.days) }
        guard let date = rule.oneShot else { throw Failure.noFutureDate }
        return .fixed(date)
    }

    func reconcile() async throws {
        try await serialize { try await self.reconcileNow() }
    }

    private func reconcileNow() async throws {
        try cleanup()
        let system = try driver.alarms()
        for (id, alerting) in system where alerting {
            _ = try register(id, event: .alert, at: clock())
        }
        try await arm()
    }

    private func repair() async {
        do { try await reconcileNow() }
        catch { diagnostic("无法核对系统闹钟", error) }
    }

    func migrateLegacy(_ ids: [UUID]) async throws {
        guard !ids.isEmpty else { return }
        try await serialize {
            try self.commit { $0.cancellations.formUnion(ids) }
            try self.cleanup()
        }
    }

    func receive(_ source: UUID, event: Event, at date: Date) async throws {
        try await serialize {
            guard let run = try self.register(source, event: event, at: date) else { return }
            if event == .open {
                let system = try self.driver.alarms()
                if system[source] == true {
                    do { try self.driver.stop(id: source) }
                    catch { self.diagnostic("打开任务时无法停止当前铃声", error) }
                }
            }
            if event != .alert {
                var system = try self.driver.alarms()
                let failed = await self.armBackups(run, system: &system)
                if failed { self.incompleteBackups.insert(run.alarmID) }
                else { self.incompleteBackups.remove(run.alarmID) }
            }
        }
    }

    private func register(_ source: UUID, event: Event, at date: Date) throws -> AlarmRun? {
        if let index = ledger.runs.firstIndex(where: { $0.backups.contains { $0.id == source } }) {
            let run = ledger.runs[index]
            guard !run.closed, !ledger.cancellations.contains(source),
                  let ring = run.backups.first(where: { $0.id == source }), ring.date <= date.addingTimeInterval(3) else { return nil }
            try commit { state in
                state.runs[index].started = true
                if event != .alert { state.runs[index].planFollowUp(from: source, at: max(date, clock())) }
            }
            return ledger.runs[index]
        }

        guard let alarm = ledger.alarms.first(where: { $0.primaryID == source && $0.rule.enabled }),
              let first = alarm.rule.mostRecent(at: date.addingTimeInterval(3), calendar: calendar()),
              first >= alarm.installedAt,
              date.timeIntervalSince(first) < 12 * 3600 else { return nil }
        var run = ledger.runs.last { $0.alarmID == alarm.id && $0.firstFire == first && (!$0.closed || $0.started) }
            ?? AlarmRun(alarm: alarm, firstFire: first)
        guard !run.closed else {
            if event != .stop, (try? driver.alarms()[source]) == true {
                try commit { $0.primaryStops[source] = date }
                try cleanup()
            }
            return nil
        }
        run.started = true
        if event != .alert { run.planFollowUp(from: source, at: max(date, clock())) }
        try commit { state in
            if let index = state.runs.firstIndex(where: { $0.id == run.id }) { state.runs[index] = run }
            else { state.runs.append(run) }
        }
        return run
    }

    func complete(_ runID: UUID, asSuccess: Bool = true) async throws -> WakeRecord? {
        try await serialize {
            guard let run = self.ledger.runs.first(where: { $0.id == runID && $0.started && !$0.closed }),
                  let alarm = self.ledger.alarms.first(where: { $0.id == run.alarmID }) else { return nil }
            let now = self.clock()
            var wake: WakeRecord?
            try self.commit { state in
                guard let index = state.runs.firstIndex(where: { $0.id == runID }) else { return }
                state.runs[index].closed = true
                state.cancellations.formUnion(run.backups.map(\.id))
                if alarm.rule.isRepeating {
                    if alarm.rule.mostRecent(at: now, calendar: self.calendar()) == run.firstFire {
                        state.primaryStops[alarm.primaryID] = now
                    }
                } else {
                    state.cancellations.insert(alarm.primaryID)
                    if let row = state.alarms.firstIndex(where: { $0.id == alarm.id }) {
                        state.alarms[row].rule.enabled = false
                    }
                }
                if asSuccess { wake = state.history.record(runID: runID, at: now, timeZone: self.calendar().timeZone) }
            }
            await self.repair()
            return wake
        }
    }

    func takeReviewRequest() async throws -> Bool {
        try await serialize {
            guard !self.ledger.runs.contains(where: { $0.started && !$0.closed }) else { return false }
            var shouldRequest = false
            try self.commit { shouldRequest = $0.history.takeReviewRequest() }
            return shouldRequest
        }
    }

    private func cleanup() throws {
        guard !ledger.cancellations.isEmpty || !ledger.primaryStops.isEmpty else { return }
        let system = try driver.alarms()
        var removed: Set<UUID> = []
        var stopped: Set<UUID> = []
        for id in ledger.cancellations {
            guard system[id] != nil else { removed.insert(id); continue }
            do { try driver.cancel(id: id); removed.insert(id) }
            catch {
                diagnostic("取消闹钟失败", error)
                if system[id] == true { try? driver.stop(id: id) }
            }
        }
        for (id, recordedAt) in ledger.primaryStops {
            guard system[id] == true, abs(clock().timeIntervalSince(recordedAt)) < 12 * 3600 else {
                stopped.insert(id)
                continue
            }
            do { try driver.stop(id: id); stopped.insert(id) }
            catch { diagnostic("停止当前重复闹钟失败", error) }
        }
        try commit { state in
            state.cancellations.subtract(removed)
            for id in stopped { state.primaryStops.removeValue(forKey: id) }
        }
    }

    private func arm() async throws {
        let now = clock()
        let currentCalendar = calendar()
        var system = try driver.alarms()
        try planRuns(at: now, calendar: currentCalendar, system: system)
        try cleanup()
        system = try driver.alarms()
        var missingPrimaries: Set<UUID> = []
        var missingBackups: Set<UUID> = []

        for alarm in ledger.alarms where alarm.rule.enabled && system[alarm.primaryID] == nil {
            guard alarm.rule.isRepeating || alarm.rule.next(after: clock(), calendar: currentCalendar) != nil else { continue }
            do {
                try await driver.schedule(primarySchedule(alarm), id: alarm.primaryID)
                system[alarm.primaryID] = false
            } catch {
                missingPrimaries.insert(alarm.id)
                diagnostic("主闹钟排程失败", error)
            }
        }
        let openRuns = ledger.runs.filter { !$0.closed }.sorted { $0.firstFire < $1.firstFire }
        for run in openRuns {
            if await armBackups(run, system: &system) { missingBackups.insert(run.alarmID) }
        }
        unarmed = missingPrimaries
        incompleteBackups = missingBackups
    }

    private func planRuns(at now: Date, calendar: Calendar, system: [UUID: Bool]) throws {
        try commit { state in
            for alarm in state.alarms where alarm.rule.enabled {
                var next = alarm.rule.next(after: now, calendar: calendar)
                if let date = next, state.runs.contains(where: {
                    $0.alarmID == alarm.id && $0.firstFire == date && $0.started && $0.closed
                }) {
                    next = alarm.rule.next(after: date, calendar: calendar)
                }
                let recent = alarm.rule.mostRecent(at: now, calendar: calendar)
                for index in state.runs.indices where state.runs[index].alarmID == alarm.id && !state.runs[index].closed {
                    let run = state.runs[index]
                    let live = run.backups.contains { (system[$0.id] == true) || $0.date > now }
                    let stillCurrent = run.firstFire == recent && (live || system[alarm.primaryID] == true)
                    let stillActive = run.started && (live || now.timeIntervalSince(run.firstFire) < 12 * 3600)
                    if run.firstFire == next || stillCurrent || stillActive { continue }
                    state.runs[index].closed = true
                    state.cancellations.formUnion(run.backups.map(\.id))
                }
                if let next, !state.runs.contains(where: { $0.alarmID == alarm.id && !$0.closed }) {
                    state.runs.append(AlarmRun(alarm: alarm, firstFire: next))
                } else if next == nil, !alarm.rule.isRepeating, system[alarm.primaryID] != true,
                          !state.runs.contains(where: { $0.alarmID == alarm.id && !$0.closed }),
                          let row = state.alarms.firstIndex(where: { $0.id == alarm.id }) {
                    state.alarms[row].rule.enabled = false
                    state.cancellations.insert(alarm.primaryID)
                }
            }
            state.runs.removeAll { $0.closed && now.timeIntervalSince($0.firstFire) > 8 * 86_400 }
        }
    }

    private func armBackups(_ run: AlarmRun, system: inout [UUID: Bool]) async -> Bool {
        for ring in run.backups.sorted(by: { $0.date < $1.date }) {
            guard ring.date > clock(), system[ring.id] == nil, !run.handledStops.contains(ring.id) else { continue }
            do {
                try await driver.schedule(.fixed(ring.date), id: ring.id)
                system[ring.id] = false
            } catch {
                if ring.date <= clock() { continue }
                diagnostic(ring.isFollowUp ? "停止后补响排程失败" : "预排补响失败", error)
                return true
            }
        }
        return false
    }
}
