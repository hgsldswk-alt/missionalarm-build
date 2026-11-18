import Foundation

enum Weekday: Int, Codable, CaseIterable, Identifiable {
    case monday = 2, tuesday, wednesday, thursday, friday, saturday, sunday = 1

    static let workdays: Set<Self> = [.monday, .tuesday, .wednesday, .thursday, .friday]
    var id: Int { rawValue }
}

struct AlarmRule: Codable, Equatable, Identifiable {
    var id = UUID()
    var hour = 7
    var minute = 0
    var days = Weekday.workdays
    var mission = Mission()
    var enabled = true
    var oneShot: Date?

    var isRepeating: Bool { !days.isEmpty }

    func next(after date: Date, calendar: Calendar) -> Date? {
        if !isRepeating, let oneShot { return oneShot > date ? oneShot : nil }
        return matchingDate(near: date, calendar: calendar, forward: true)
    }

    func mostRecent(at date: Date, calendar: Calendar) -> Date? {
        guard isRepeating else { return oneShot.flatMap { $0 <= date ? $0 : nil } }
        return matchingDate(near: date, calendar: calendar, forward: false)
    }

    private func matchingDate(near date: Date, calendar: Calendar, forward: Bool) -> Date? {
        let start = calendar.startOfDay(for: date)
        for offset in 0...7 {
            guard let day = calendar.date(byAdding: .day, value: forward ? offset : -offset, to: start),
                  days.isEmpty || days.contains(where: { $0.rawValue == calendar.component(.weekday, from: day) }),
                  let fire = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day,
                                           matchingPolicy: .nextTime, repeatedTimePolicy: .first),
                  calendar.isDate(fire, inSameDayAs: day) else { continue }
            if forward ? fire > date : fire <= date { return fire }
        }
        return nil
    }
}

struct AlarmRecipe: Codable {
    private static let prefix = "WAKE1-"
    private let hour: Int
    private let minute: Int
    private let days: [Weekday]
    private let mission: Mission

    static func encode(_ rule: AlarmRule) -> String? {
        var mission = rule.mission
        mission.code = nil
        let recipe = Self(hour: rule.hour, minute: rule.minute, days: rule.days.sorted { $0.rawValue < $1.rawValue },
                          mission: mission)
        guard let data = try? JSONEncoder().encode(recipe) else { return nil }
        return prefix + data.base64EncodedString()
    }

    static func decode(_ text: String) -> AlarmRule? {
        guard text.utf8.count <= 12_000,
              let token = text.split(whereSeparator: \.isWhitespace).first(where: { $0.hasPrefix(prefix) }),
              let data = Data(base64Encoded: String(token.dropFirst(prefix.count))),
              let recipe = try? JSONDecoder().decode(Self.self, from: data),
              (0...23).contains(recipe.hour), (0...59).contains(recipe.minute),
              recipe.mission.code == nil, recipe.mission.kind == .scan || recipe.mission.isValid else { return nil }
        return AlarmRule(hour: recipe.hour, minute: recipe.minute, days: Set(recipe.days), mission: recipe.mission)
    }
}

struct WakeRecord: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var time: Date
    var day: Date
    var timeZoneID: String
}

struct WakeHistory: Codable, Equatable {
    var records: [WakeRecord] = []
    var reviewRequested = false

    static func localDay(_ date: Date, timeZone: TimeZone) -> Date {
        var local = Calendar(identifier: .gregorian)
        local.timeZone = timeZone
        return utc.date(from: local.dateComponents([.year, .month, .day], from: date)) ?? date
    }

    var streak: Int {
        guard let latest = records.last else { return 0 }
        return streak(endingOn: latest.day)
    }

    func currentStreak(at now: Date, timeZone: TimeZone) -> Int {
        let today = Self.localDay(now, timeZone: timeZone)
        guard let latest = records.last, (0...86_400).contains(today.timeIntervalSince(latest.day)) else { return 0 }
        return streak
    }

    func streak(endingOn day: Date) -> Int {
        let days = Set(records.map(\.day))
        var count = 0
        var cursor = day
        while days.contains(cursor) {
            count += 1
            cursor = cursor.addingTimeInterval(-86_400)
        }
        return count
    }

    mutating func record(runID: UUID, at time: Date, timeZone: TimeZone) -> WakeRecord {
        if let previous = records.first(where: { $0.id == runID }) { return previous }
        let wake = WakeRecord(id: runID, time: time, day: Self.localDay(time, timeZone: timeZone),
                              timeZoneID: timeZone.identifier)
        records.append(wake)
        return wake
    }

    mutating func takeReviewRequest() -> Bool {
        guard records.count >= 3, !reviewRequested else { return false }
        reviewRequested = true
        return true
    }

    private static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
}
