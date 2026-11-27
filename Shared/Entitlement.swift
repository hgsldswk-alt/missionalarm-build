import Foundation

enum Launch {
    static let freePeriod = false

    static var isFree: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains(where: { ["-paid-mode", "-paywall", "-expired"].contains($0) }) {
            return false
        }
        #endif
        return freePeriod
    }
}

struct Entitlement: Codable, Equatable {
    static let trialLength = 30 * 86_400.0

    var proStartedAt: Date?
    var trialClaimedAt: Date?
    var purchasedPro = false

    var trialStart: Date? {
        [proStartedAt, trialClaimedAt].compactMap { $0 }.min()
    }

    var trialEnd: Date? { trialStart?.addingTimeInterval(Self.trialLength) }

    mutating func startPaidPeriod(at date: Date) {
        if proStartedAt == nil { proStartedAt = date }
    }

    mutating func recordTrialClaim(at date: Date) {
        trialClaimedAt = min(trialClaimedAt ?? date, date)
    }

    func hasPro(at now: Date, freePeriod: Bool = Launch.isFree) -> Bool {
        if freePeriod || purchasedPro { return true }
        guard let start = trialStart else { return false }
        return now.addingTimeInterval(600) >= start && now < start.addingTimeInterval(Self.trialLength)
    }

    func remainingDays(at now: Date) -> Int {
        guard let trialEnd else { return 0 }
        return Int(ceil(min(Self.trialLength, max(0, trialEnd.timeIntervalSince(now))) / 86_400))
    }
}
