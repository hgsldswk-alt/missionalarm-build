import XCTest

final class MissionTests: XCTestCase {
    func testCorrectMathAnswersAndThreeWrongAnswersLowerDifficulty() {
        var progress = MissionProgress(mission: Mission(difficulty: .hard)) { difficulty in
            MathQuestion(lhs: difficulty.rawValue + 2, rhs: 1, operation: .add)
        }
        XCTAssertEqual(progress.answer(""), .ignored)
        XCTAssertEqual(progress.answer("99"), .wrong)
        XCTAssertEqual(progress.answer("99"), .wrong)
        XCTAssertEqual(progress.answer("99"), .easier)
        XCTAssertEqual(progress.mission.difficulty, .medium)
        XCTAssertEqual(progress.count, 0)
        XCTAssertEqual(progress.answer("4"), .correct)
        XCTAssertEqual(progress.answer("4"), .correct)
        XCTAssertFalse(progress.isComplete)
        XCTAssertEqual(progress.answer("4"), .correct)
        XCTAssertTrue(progress.isComplete)
        XCTAssertEqual(progress.answer("4"), .ignored)
    }

    func testAllMathLevelsHaveValidResults() {
        for _ in 0..<50 {
            XCTAssertEqual(MathQuestion.make(.easy).operation, .add)
            XCTAssertGreaterThanOrEqual(MathQuestion.make(.medium).result, 0)
            XCTAssertEqual(MathQuestion.make(.hard).operation, .multiply)
        }
    }

    func testShakesNeedAReleaseAndCooldownAndStopCountingAtTarget() {
        var progress = MissionProgress(mission: Mission(kind: .shake, shakes: 5))
        progress.observeShake(magnitude: 3, timestamp: 1)
        progress.observeShake(magnitude: 3, timestamp: 1.5)
        XCTAssertEqual(progress.count, 1)
        progress.observeShake(magnitude: 0.4, timestamp: 1.6)
        progress.observeShake(magnitude: 3, timestamp: 1.7)
        for offset in 2...6 {
            progress.observeShake(magnitude: 0.4, timestamp: Double(offset))
            progress.observeShake(magnitude: 3, timestamp: Double(offset) + 0.1)
        }
        XCTAssertEqual(progress.count, 5)
        XCTAssertTrue(progress.isComplete)

        var debounce = MissionProgress(mission: Mission(kind: .shake))
        debounce.observeShake(magnitude: 3, timestamp: 1)
        debounce.observeShake(magnitude: 0.2, timestamp: 1.1)
        debounce.observeShake(magnitude: 3, timestamp: 1.2)
        XCTAssertEqual(debounce.count, 1)
    }

    func testStepsAreCumulativeAndSaturateAtGoal() {
        var progress = MissionProgress(mission: Mission(kind: .steps, steps: 30))
        progress.observeSteps(16)
        progress.observeSteps(16)
        progress.observeSteps(2)
        XCTAssertEqual(progress.count, 16)
        progress.observeSteps(29)
        XCTAssertFalse(progress.isComplete)
        progress.observeSteps(40)
        XCTAssertEqual(progress.count, 30)
        XCTAssertTrue(progress.isComplete)
    }

    func testScanRequiresTheExactValueAndTypeAndCanSwitchToMathOnce() {
        let target = ScanCode(type: "QR", value: "café-A")
        let mission = Mission(kind: .scan, code: target)
        var progress = MissionProgress(mission: mission)
        XCTAssertFalse(progress.scan(ScanCode(type: "EAN", value: target.value)))
        XCTAssertFalse(progress.scan(ScanCode(type: "QR", value: "cafe\u{0301}-A")))
        XCTAssertFalse(progress.scan(ScanCode(type: "QR", value: "café-a")))
        XCTAssertTrue(progress.scan(target))
        XCTAssertTrue(progress.isComplete)
        progress.switchToMath()
        XCTAssertEqual(progress.mission.kind, .scan)

        var fallback = MissionProgress(mission: mission)
        fallback.switchToMath()
        XCTAssertEqual(fallback.mission.kind, .math)
        XCTAssertEqual(fallback.mission.difficulty, .medium)
        XCTAssertTrue(fallback.usedFallback)
        fallback.switchToMath()
        XCTAssertFalse(fallback.scan(target))
    }

    func testShareRecipeNeverContainsRegisteredCodeAndImportsAsANewAlarm() throws {
        let rule = AlarmRule(hour: 6, minute: 35, days: [.monday, .wednesday],
                             mission: Mission(kind: .scan, code: ScanCode(type: "QR", value: "private-data")))
        let encoded = try XCTUnwrap(AlarmRecipe.encode(rule))
        let imported = try XCTUnwrap(AlarmRecipe.decode("A shared alarm\n" + encoded))
        XCTAssertNotEqual(imported.id, rule.id)
        XCTAssertEqual(imported.hour, 6)
        XCTAssertEqual(imported.minute, 35)
        XCTAssertEqual(imported.days, rule.days)
        XCTAssertEqual(imported.mission.kind, .scan)
        XCTAssertNil(imported.mission.code)
        XCTAssertFalse(imported.mission.isValid)
        XCTAssertNil(AlarmRecipe.decode("WAKE1-__"))
    }
}
