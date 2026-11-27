import AlarmKit
import Foundation
import SwiftUI
import UIKit

@MainActor
final class AlarmEngine: ObservableObject {
    static let shared = AlarmEngine()

    @Published private(set) var ledger = AlarmLedger()
    @Published private(set) var activeRun: AlarmRun?
    @Published private(set) var wake: WakeRecord?
    @Published private(set) var authorization: AlarmManager.AuthorizationState = .notDetermined
    @Published private(set) var incompleteBackups: Set<UUID> = []
    @Published private(set) var unarmed: Set<UUID> = []
    @Published private(set) var systemCheckFailed = false
    @Published private(set) var cleanupPending = false
    @Published private(set) var logs: [String] = []
    @Published var message: String?

    private lazy var manager = AlarmManager.shared
    private let defaults = UserDefaults.standard
    private var scheduler: AlarmScheduler?
    private var listener: Task<Void, Never>?
    private var debounce: Task<Void, Never>?
    private var refreshing = false
    private var refreshAgain = false
    private var lastSystemSummary: [Int]?

    private init() {
        #if DEBUG
        if StoreScreenshotFixtures.isEnabled {
            scheduler = StoreScreenshotFixtures.scheduler()
            authorization = .authorized
            publishState()
            return
        }
        #endif
        logs = defaults.stringArray(forKey: "logs") ?? []
        loadScheduler()
        authorization = manager.authorizationState
    }

    private func loadScheduler() {
        guard scheduler == nil else { return }
        do {
            let folder = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                     appropriateFor: nil, create: true)
            let url = folder.appendingPathComponent("alarm-ledger-v1.json")
            let state: AlarmLedger
            do { state = try JSONDecoder().decode(AlarmLedger.self, from: Data(contentsOf: url)) }
            catch let error as CocoaError where error.code == .fileReadNoSuchFile { state = AlarmLedger() }
            scheduler = AlarmScheduler(ledger: state, driver: SystemRings(manager: manager), persist: { state in
                try JSONEncoder().encode(state).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            }, diagnostic: { [weak self] key, error in
                self?.log(key, error: error)
            })
            publishState()
        } catch {
            log("无法读取闹钟记录", error: error)
            message = L.t("无法读取闹钟记录")
        }
    }

    func start() async {
        guard !StoreScreenshotFixtures.isEnabled else { return }
        if listener == nil {
            listener = Task { [weak self] in
                guard let self else { return }
                for await alarms in manager.alarmUpdates {
                    let counts = [alarms.count, alarms.filter { $0.state == .alerting }.count]
                    if lastSystemSummary != counts {
                        lastSystemSummary = counts
                        log(L.f("系统闹钟 %@ 个，正在响 %@ 个", String(counts[0]), String(counts[1])))
                    }
                    debounce?.cancel()
                    debounce = Task { [weak self] in
                        try? await Task.sleep(for: .milliseconds(250))
                        guard !Task.isCancelled else { return }
                        await self?.refresh()
                    }
                }
            }
        }
        await refresh()
    }

    func refresh() async {
        guard !StoreScreenshotFixtures.isEnabled else { return }
        guard !refreshing else { refreshAgain = true; return }
        refreshing = true
        defer { refreshing = false }
        repeat {
            refreshAgain = false
            loadScheduler()
            authorization = manager.authorizationState
            guard let scheduler, authorization == .authorized else { return }
            do {
                if let old = defaults.data(forKey: "chain"),
                   let legacy = try? JSONDecoder().decode(LegacyChain.self, from: old) {
                    try await scheduler.migrateLegacy(legacy.ids)
                    defaults.removeObject(forKey: "chain")
                }
                try await scheduler.reconcile()
                systemCheckFailed = false
            } catch {
                systemCheckFailed = true
                log("无法核对系统闹钟", error: error)
            }
            publishState()
        } while refreshAgain
    }

    func save(_ rule: AlarmRule) async -> Bool {
        guard let scheduler else { message = L.t("无法读取闹钟记录"); return false }
        if !StoreScreenshotFixtures.isEnabled {
            if rule.enabled, manager.authorizationState == .notDetermined {
                do { _ = try await manager.requestAuthorization() }
                catch { log("闹钟授权失败", error: error) }
            }
            authorization = manager.authorizationState
        }
        guard !rule.enabled || authorization == .authorized else {
            message = L.t("请在系统设置中允许闹钟")
            return false
        }
        do {
            try await scheduler.configure(rule)
            log(rule.enabled ? "已保存闹钟" : "已关闭闹钟")
            publishState()
            return true
        } catch {
            log("保存闹钟失败", error: error)
            message = L.t("保存闹钟失败，请检查权限或尝试关闭其他闹钟")
            publishState()
            return false
        }
    }

    func delete(_ rule: AlarmRule) async -> Bool {
        guard let scheduler else { return false }
        do {
            try await scheduler.delete(rule.id)
            publishState()
            return true
        } catch {
            log("无法删除闹钟", error: error)
            message = L.t("无法删除闹钟")
            return false
        }
    }

    func handleStop(alarmID: String) async {
        await receive(alarmID, event: .stop)
    }

    func handleOpen(alarmID: String) async {
        await receive(alarmID, event: .open)
    }

    private func receive(_ value: String, event: AlarmScheduler.Event) async {
        guard !StoreScreenshotFixtures.isEnabled else { return }
        let date = Date()
        loadScheduler()
        guard let id = UUID(uuidString: value), let scheduler else { return }
        do {
            try await scheduler.receive(id, event: event, at: date)
            log(event == .stop ? "系统停止按钮" : "系统去做任务按钮")
        } catch {
            log("无法处理响铃操作", error: error)
        }
        publishState()
    }

    func complete(_ id: UUID, asSuccess: Bool = true) async -> Bool {
        guard let scheduler else { return false }
        do {
            if let recorded = try await scheduler.complete(id, asSuccess: asSuccess) { wake = recorded }
            log(asSuccess ? "已完成起床任务" : "已紧急关闭闹钟")
            publishState()
            return true
        } catch {
            log("无法关闭本次闹钟", error: error)
            message = L.t("无法关闭本次闹钟")
            return false
        }
    }

    func dismissWake() { wake = nil }

    func takeReviewRequest() async -> Bool {
        guard !StoreScreenshotFixtures.isEnabled, let scheduler else { return false }
        return (try? await scheduler.takeReviewRequest()) == true
    }

    func clearLogs() {
        logs = []
        lastSystemSummary = nil
        if !StoreScreenshotFixtures.isEnabled { defaults.removeObject(forKey: "logs") }
    }

    private func publishState() {
        guard let scheduler else { return }
        let state = scheduler.ledger
        let active = state.runs.filter { $0.started && !$0.closed }.min { $0.firstFire < $1.firstFire }
        if active?.id != activeRun?.id { activeRun = active }
        if ledger != state { ledger = state }
        if unarmed != scheduler.unarmed { unarmed = scheduler.unarmed }
        if incompleteBackups != scheduler.incompleteBackups { incompleteBackups = scheduler.incompleteBackups }
        let pending = !state.cancellations.isEmpty || !state.primaryStops.isEmpty
        if cleanupPending != pending { cleanupPending = pending }
    }

    private func log(_ key: String, error: Error? = nil) {
        let detail = error.map { " · \($0.localizedDescription)" } ?? ""
        let entry = Date().formatted(date: .numeric, time: .standard) + "  " + L.t(key) + detail
        logs.insert(entry, at: 0)
        if logs.count > 300 { logs.removeLast(logs.count - 300) }
        if !StoreScreenshotFixtures.isEnabled { defaults.set(logs, forKey: "logs") }
    }

    private struct LegacyChain: Decodable { var ids: [UUID] }
}

@MainActor
private struct SystemRings: RingDriver {
    let manager: AlarmManager

    func alarms() throws -> [UUID: Bool] {
        Dictionary(uniqueKeysWithValues: try manager.alarms.map { ($0.id, $0.state == .alerting) })
    }

    func schedule(_ schedule: RingSchedule, id: UUID) async throws {
        let alarmSchedule: Alarm.Schedule
        switch schedule {
        case .fixed(let date):
            alarmSchedule = .fixed(date)
        case let .weekly(hour, minute, days):
            let weekdays = Weekday.allCases.filter { days.contains($0) }.map(\.localeWeekday)
            alarmSchedule = .relative(.init(time: .init(hour: hour, minute: minute), repeats: .weekly(weekdays)))
        }
        let alert = AlarmPresentation.Alert(
            title: "起床任务",
            stopButton: AlarmButton(text: "停止", textColor: .white, systemImageName: "stop.fill"),
            secondaryButton: AlarmButton(text: "去做任务", textColor: .white, systemImageName: "alarm"),
            secondaryButtonBehavior: .custom
        )
        let attributes = AlarmAttributes<WakeMeta>(presentation: AlarmPresentation(alert: alert),
                                                   metadata: WakeMeta(), tintColor: Palette.accent)
        let configuration = AlarmManager.AlarmConfiguration<WakeMeta>(
            countdownDuration: nil,
            schedule: alarmSchedule,
            attributes: attributes,
            stopIntent: StopAlarmIntent(alarmID: id.uuidString),
            secondaryIntent: OpenTaskIntent(alarmID: id.uuidString)
        )
        _ = try await manager.schedule(id: id, configuration: configuration)
    }

    func stop(id: UUID) throws { try manager.stop(id: id) }
    func cancel(id: UUID) throws { try manager.cancel(id: id) }
}

private extension Weekday {
    var localeWeekday: Locale.Weekday {
        switch self {
        case .monday: return .monday
        case .tuesday: return .tuesday
        case .wednesday: return .wednesday
        case .thursday: return .thursday
        case .friday: return .friday
        case .saturday: return .saturday
        case .sunday: return .sunday
        }
    }
}
