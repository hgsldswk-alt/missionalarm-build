import AlarmKit
import AppIntents

struct StopAlarmIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "停止闹钟"
    static var isDiscoverable: Bool = false

    @Parameter(title: "Alarm ID")
    var alarmID: String

    init() {}

    init(alarmID: String) {
        self.alarmID = alarmID
    }

    func perform() async throws -> some IntentResult {
        await AlarmEngine.shared.handleStop(alarmID: alarmID)
        return .result()
    }
}

struct OpenTaskIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "去做任务"
    static var isDiscoverable: Bool = false
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Alarm ID")
    var alarmID: String

    init() {}

    init(alarmID: String) {
        self.alarmID = alarmID
    }

    func perform() async throws -> some IntentResult {
        await AlarmEngine.shared.handleOpen(alarmID: alarmID)
        return .result()
    }
}
