import Foundation

enum ChainPlan {
    static let backupCount = 10
    static let interval: TimeInterval = 60

    static func backupDates(after start: Date, count: Int, interval: TimeInterval) -> [Date] {
        guard count > 0, interval > 0 else { return [] }
        return (1...count).map { start.addingTimeInterval(Double($0) * interval) }
    }

    static func nextRing(after now: Date, interval: TimeInterval) -> Date {
        now.addingTimeInterval(max(interval, 30))
    }
}
