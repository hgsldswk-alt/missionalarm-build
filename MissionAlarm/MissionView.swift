import CoreMotion
import SwiftUI

struct MissionView: View {
    @EnvironmentObject private var engine: AlarmEngine
    @Environment(\.scenePhase) private var phase
    @StateObject private var sensors = MissionSensors()
    @State private var progress: MissionProgress
    @State private var answer = ""
    @State private var feedback: String?
    @State private var closing = false
    @State private var emergencyCode: String?
    @State private var emergencyEntry = ""
    @State private var startedAt = Date()
    let run: AlarmRun

    init(run: AlarmRun) {
        self.run = run
        #if DEBUG
        let makeQuestion = StoreScreenshotFixtures.isEnabled ? StoreScreenshotFixtures.questionGenerator : MathQuestion.make
        _progress = State(initialValue: MissionProgress(mission: run.mission, makeQuestion: makeQuestion))
        #else
        _progress = State(initialValue: MissionProgress(mission: run.mission))
        #endif
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 18) {
                    if let emergencyCode {
                        emergency(emergencyCode)
                    } else {
                        statusHeader
                        Spacer(minLength: 4)
                        switch progress.mission.kind {
                        case .math: math
                        case .shake, .steps: motion
                        case .scan: scanner
                        }
                        Spacer(minLength: 4)
                        footer
                    }
                }
                .frame(minHeight: max(0, geometry.size.height - 34))
                .padding(.horizontal, 22)
                .padding(.vertical, 17)
            }
        }
        .onAppear { startSensors() }
        .onDisappear { sensors.stop() }
        .onChange(of: phase) { _, current in
            if current == .background { sensors.stop() }
            if current == .active { startSensors() }
        }
    }

    private var statusHeader: some View {
        HStack {
            Label(L.t("做完任务才会停"), systemImage: "alarm")
                .font(.subheadline.weight(.semibold)).foregroundStyle(Palette.accent)
            Spacer()
            if progress.mission.kind == .math {
                HStack(spacing: 5) {
                    ForEach(0..<progress.mission.goal, id: \.self) { index in
                        Capsule().fill(index < progress.count ? Palette.accent : Palette.line)
                            .frame(width: 16, height: 4)
                    }
                }
                .accessibilityHidden(true)
            }
        }
    }

    private var math: some View {
        VStack(spacing: 15) {
            Text(progress.question.expression)
                .font(.system(size: 62, weight: .light, design: .rounded)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.55)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("mathQuestion")
            Text(answer.isEmpty ? "–" : answer)
                .font(.system(size: 39, weight: .light, design: .rounded)).monospacedDigit()
                .frame(maxWidth: 205, minHeight: 66)
                .background(Palette.card, in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Palette.accent, lineWidth: 1))
                .accessibilityLabel(L.t("答案"))
                .accessibilityValue(answer)
            Text(L.f("第 %@ / %@ 题", String(min(progress.count + 1, progress.mission.goal)), String(progress.mission.goal)))
                .font(.subheadline).foregroundStyle(Palette.secondary)
            VStack(spacing: 7) {
                ForEach(0..<3, id: \.self) { row in
                    HStack(spacing: 7) {
                        ForEach(1...3, id: \.self) { column in
                            let digit = String(row * 3 + column)
                            key(digit) { append(digit) }
                        }
                    }
                }
                HStack(spacing: 7) {
                    key(L.t("删除")) { if !answer.isEmpty { answer.removeLast() } }
                    key("0") { append("0") }
                    key(L.t("确定"), confirm: true, action: submit)
                        .disabled(answer.isEmpty)
                        .accessibilityIdentifier("submitAnswer")
                }
            }
            .disabled(closing || progress.isComplete)
        }
    }

    private func key(_ title: String, confirm: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(.title3, design: .rounded, weight: .semibold))
                .lineLimit(1).minimumScaleFactor(0.6)
                .frame(maxWidth: .infinity, minHeight: 51)
                .foregroundStyle(confirm ? Palette.background : Palette.text)
                .background(confirm ? Palette.accent : Palette.card, in: RoundedRectangle(cornerRadius: 13))
        }
        .buttonStyle(.plain)
    }

    private var motion: some View {
        VStack(spacing: 16) {
            Image(systemName: progress.mission.kind.icon)
                .font(.system(size: 48, weight: .light)).foregroundStyle(Palette.accent)
                .accessibilityHidden(true)
            Text(progress.mission.instruction).font(.title2.bold()).accessibilityAddTraits(.isHeader)
            Text(L.f("%@ / %@", String(progress.count), String(progress.mission.goal)))
                .font(.system(size: 58, weight: .light, design: .rounded)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.6)
            ProgressView(value: Double(progress.count), total: Double(progress.mission.goal))
                .accessibilityLabel(progress.mission.kind.title)
        }
        .frame(maxWidth: .infinity)
    }

    private var scanner: some View {
        VStack(spacing: 14) {
            Text(L.t("扫描已登记的码")).font(.title2.bold()).accessibilityAddTraits(.isHeader)
            if !progress.isComplete {
                CodeCapture { code in
                    guard !closing else { return }
                    if progress.scan(code) { finishIfReady() }
                    else { feedback = L.t("这个码和登记的不一样") }
                }
                .frame(height: 280)
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 9) {
            if let feedback {
                Text(feedback).font(.footnote).foregroundStyle(Palette.danger)
                    .multilineTextAlignment(.center)
            }
            if progress.isComplete && !closing {
                Button(L.t("重试关闭"), action: finishIfReady).buttonStyle(PrimaryButton())
            }
            if progress.mission.kind != .math && !progress.isComplete {
                Button(L.t("改做算术")) {
                    sensors.stop()
                    progress.switchToMath()
                    feedback = nil
                }
                .buttonStyle(SecondaryButton())
            }
            Button(L.t("紧急关闭")) {
                sensors.stop()
                emergencyEntry = ""
                emergencyCode = String((0..<20).compactMap { _ in "ABCDEFGHJKLMNPQRSTUVWXYZ23456789".randomElement() })
                feedback = nil
            }
            .foregroundStyle(Palette.secondary)
            .font(.footnote)
            .frame(minHeight: 44)
            .disabled(closing)
        }
    }

    private func emergency(_ code: String) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(title: L.t("紧急关闭")) {
                emergencyCode = nil
                feedback = nil
                startSensors()
            }
            Text(L.t("输入下方字符即可关闭本次闹钟，本次不计入早起打卡"))
                .font(.subheadline).foregroundStyle(Palette.secondary)
            Text(code).font(.title3.monospaced()).minimumScaleFactor(0.6).lineLimit(1)
            TextField(L.t("输入字符"), text: $emergencyEntry)
                .textInputAutocapitalization(.characters).autocorrectionDisabled()
                .font(.body.monospaced())
                .alarmCard()
            Button(L.t("关闭本次闹钟")) { finish(asSuccess: false) }
                .buttonStyle(SecondaryButton())
                .disabled(emergencyEntry.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() != code || closing)
            if let feedback { Text(feedback).foregroundStyle(Palette.danger).font(.footnote) }
            Spacer(minLength: 0)
        }
    }

    private func append(_ digit: String) {
        guard answer.count < 6 else { return }
        answer += digit
    }

    private func submit() {
        switch progress.answer(answer) {
        case .ignored: return
        case .correct: feedback = nil
        case .wrong: feedback = L.t("不对，再算一次")
        case .easier: feedback = L.t("换一道简单些的题")
        }
        answer = ""
        finishIfReady()
    }

    private func startSensors() {
        guard emergencyCode == nil, !progress.isComplete, phase != .background else { return }
        sensors.start(progress.mission.kind, since: startedAt) { sample in
            switch sample {
            case let .shake(magnitude, timestamp):
                progress.observeShake(magnitude: magnitude, timestamp: timestamp)
            case .steps(let count):
                progress.observeSteps(count)
            case .unavailable:
                feedback = L.t("动作或步数不可用，可以改做算术")
            }
            finishIfReady()
        }
    }

    private func finishIfReady() {
        if progress.isComplete { finish(asSuccess: true) }
    }

    private func finish(asSuccess: Bool) {
        guard !closing else { return }
        closing = true
        sensors.stop()
        Task {
            if !(await engine.complete(run.id, asSuccess: asSuccess)) {
                feedback = L.t("无法关闭本次闹钟")
                closing = false
            }
        }
    }
}

@MainActor
private final class MissionSensors: ObservableObject {
    enum Sample {
        case shake(Double, TimeInterval)
        case steps(Int)
        case unavailable
    }

    private let motion = CMMotionManager()
    private let pedometer = CMPedometer()
    private let queue = OperationQueue()
    private var active: UUID?

    func start(_ kind: MissionKind, since date: Date, observe: @escaping @MainActor (Sample) -> Void) {
        guard active == nil else { return }
        let token = UUID()
        switch kind {
        case .shake:
            guard motion.isDeviceMotionAvailable else { observe(.unavailable); return }
            active = token
            motion.deviceMotionUpdateInterval = 0.04
            motion.startDeviceMotionUpdates(to: queue) { [weak self] sample, error in
                if let sample {
                    let a = sample.userAcceleration
                    let magnitude = sqrt(a.x * a.x + a.y * a.y + a.z * a.z)
                    let time = sample.timestamp
                    Task { @MainActor [weak self] in
                        guard self?.active == token else { return }
                        observe(.shake(magnitude, time))
                    }
                } else if error != nil {
                    Task { @MainActor [weak self] in
                        guard self?.active == token else { return }
                        self?.stop()
                        observe(.unavailable)
                    }
                }
            }
        case .steps:
            guard CMPedometer.isStepCountingAvailable(), CMPedometer.authorizationStatus() != .denied,
                  CMPedometer.authorizationStatus() != .restricted else { observe(.unavailable); return }
            active = token
            pedometer.startUpdates(from: date) { [weak self] data, error in
                let count = data?.numberOfSteps.intValue
                let failed = error != nil
                Task { @MainActor [weak self] in
                    guard self?.active == token else { return }
                    if let count { observe(.steps(count)) }
                    else if failed { self?.stop(); observe(.unavailable) }
                }
            }
        case .math, .scan:
            break
        }
    }

    func stop() {
        active = nil
        motion.stopDeviceMotionUpdates()
        pedometer.stopUpdates()
    }
}
