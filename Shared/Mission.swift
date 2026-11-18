import Foundation

enum MissionKind: String, Codable, CaseIterable, Identifiable {
    case math, shake, steps, scan

    var id: String { rawValue }
    var requiresPro: Bool { self == .steps || self == .scan }
}

enum MathDifficulty: Int, Codable, CaseIterable, Identifiable {
    case easy, medium, hard

    var id: Int { rawValue }
    var easier: Self { Self(rawValue: max(Self.easy.rawValue, rawValue - 1)) ?? .easy }
}

struct ScanCode: Codable, Equatable {
    let type: String
    let value: String
}

struct Mission: Codable, Equatable {
    var kind: MissionKind = .math
    var difficulty: MathDifficulty = .medium
    var shakes = 20
    var steps = 30
    var code: ScanCode?

    var goal: Int {
        switch kind {
        case .math: return 3
        case .shake: return shakes
        case .steps: return steps
        case .scan: return 1
        }
    }

    var isValid: Bool {
        switch kind {
        case .math: return true
        case .shake: return (5...60).contains(shakes)
        case .steps: return (5...120).contains(steps)
        case .scan: return code.map { !$0.type.isEmpty && !$0.value.isEmpty } ?? false
        }
    }
}

struct MathQuestion: Equatable {
    enum Operation: String { case add = "+", subtract = "−", multiply = "×" }
    let lhs: Int
    let rhs: Int
    let operation: Operation

    var expression: String { "\(lhs) \(operation.rawValue) \(rhs)" }
    var result: Int {
        switch operation {
        case .add: return lhs + rhs
        case .subtract: return lhs - rhs
        case .multiply: return lhs * rhs
        }
    }

    static func make(_ difficulty: MathDifficulty) -> Self {
        switch difficulty {
        case .easy:
            return Self(lhs: .random(in: 1...9), rhs: .random(in: 1...9), operation: .add)
        case .medium:
            let left = Int.random(in: 24...89)
            let right = Int.random(in: 12...left)
            return Self(lhs: left, rhs: right, operation: Bool.random() ? .add : .subtract)
        case .hard:
            return Self(lhs: .random(in: 12...29), rhs: .random(in: 3...12), operation: .multiply)
        }
    }
}

struct MissionProgress {
    enum Answer: Equatable { case ignored, correct, wrong, easier }

    private(set) var mission: Mission
    private(set) var count = 0
    private(set) var question: MathQuestion
    private(set) var usedFallback = false
    private var wrongAttempts = 0
    private var shakeReady = true
    private var lastShake = -Double.infinity
    private let makeQuestion: (MathDifficulty) -> MathQuestion

    init(mission: Mission, makeQuestion: @escaping (MathDifficulty) -> MathQuestion = MathQuestion.make) {
        self.mission = mission
        self.makeQuestion = makeQuestion
        question = makeQuestion(mission.difficulty)
    }

    var isComplete: Bool { count >= mission.goal }

    mutating func answer(_ value: String) -> Answer {
        guard mission.kind == .math, !isComplete, let answer = Int(value) else { return .ignored }
        if answer == question.result {
            count += 1
            wrongAttempts = 0
            if !isComplete { question = makeQuestion(mission.difficulty) }
            return .correct
        }
        wrongAttempts += 1
        if wrongAttempts == 3, mission.difficulty != .easy {
            mission.difficulty = mission.difficulty.easier
            wrongAttempts = 0
            question = makeQuestion(mission.difficulty)
            return .easier
        }
        if wrongAttempts == 3 { wrongAttempts = 0 }
        return .wrong
    }

    mutating func observeShake(magnitude: Double, timestamp: TimeInterval) {
        guard mission.kind == .shake, !isComplete else { return }
        if magnitude < 1.2 { shakeReady = true }
        guard magnitude >= 2.2, shakeReady, timestamp - lastShake >= 0.35 else { return }
        shakeReady = false
        lastShake = timestamp
        count += 1
    }

    mutating func observeSteps(_ total: Int) {
        guard mission.kind == .steps, !isComplete else { return }
        count = max(count, min(total, mission.goal))
    }

    @discardableResult
    mutating func scan(_ code: ScanCode) -> Bool {
        guard mission.kind == .scan, !isComplete, let registered = mission.code,
              code.value.utf8.elementsEqual(registered.value.utf8), code.type == registered.type else { return false }
        count = 1
        return true
    }

    mutating func switchToMath() {
        guard mission.kind != .math, !isComplete, !usedFallback else { return }
        mission = Mission()
        count = 0
        question = makeQuestion(mission.difficulty)
        usedFallback = true
    }
}
