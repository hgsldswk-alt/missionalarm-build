import SwiftUI

struct AlarmEditor: View {
    private enum Repeat: CaseIterable, Identifiable {
        case once, workdays, daily, custom

        var id: Self { self }
        var title: String {
            switch self {
            case .once: return L.t("仅一次")
            case .workdays: return L.t("工作日")
            case .daily: return L.t("每天")
            case .custom: return L.t("自定义星期")
            }
        }

        init(_ days: Set<Weekday>) {
            if days.isEmpty { self = .once }
            else if days == Weekday.workdays { self = .workdays }
            else if days.count == Weekday.allCases.count { self = .daily }
            else { self = .custom }
        }
    }

    @EnvironmentObject private var engine: AlarmEngine
    @EnvironmentObject private var model: AppModel
    @State private var draft: AlarmRule
    @State private var repetition: Repeat
    @State private var showingScanner = false
    @State private var saving = false
    let close: () -> Void

    init(original: AlarmRule, close: @escaping () -> Void) {
        _draft = State(initialValue: original)
        _repetition = State(initialValue: Repeat(original.days))
        self.close = close
    }

    private var original: AlarmRule? { engine.ledger.alarms.first { $0.id == draft.id }?.rule }
    private var saveAllowed: Bool {
        draft.mission.isValid && (repetition != .custom || !draft.days.isEmpty)
            && model.canSave(draft, among: engine.ledger.alarms)
    }

    var body: some View {
        if showingScanner {
            VStack(spacing: 16) {
                PageHeader(title: L.t("登记起床码")) { showingScanner = false }
                Text(L.t("把你要用来起床的二维码或条码放进取景框"))
                    .font(.subheadline).foregroundStyle(Palette.secondary)
                CodeCapture { code in
                    draft.mission.code = code
                    showingScanner = false
                }
                .frame(maxHeight: 460)
            }
            .padding(22)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    PageHeader(title: L.t(original == nil ? "新建闹钟" : "编辑闹钟"), close: close)
                    DatePicker(L.t("响铃时间"), selection: timeBinding, displayedComponents: .hourAndMinute)
                        .datePickerStyle(.wheel)
                        .labelsHidden()
                        .frame(maxWidth: .infinity)
                    repeatOptions
                    missionOptions
                    if let message = engine.message {
                        Text(message).font(.footnote).foregroundStyle(Palette.danger)
                        if engine.authorization == .denied {
                            Button(L.t("去系统设置"), action: openSystemSettings).font(.subheadline)
                        }
                    }
                    if original != nil {
                        Button(role: .destructive) {
                            saving = true
                            Task {
                                if await engine.delete(draft) { close() }
                                saving = false
                            }
                        } label: {
                            Text(L.t("删除闹钟")).frame(minHeight: 44).contentShape(Rectangle())
                        }
                        .disabled(saving)
                    }
                }
                .padding(22)
            }
            .safeAreaInset(edge: .bottom) {
                Button(action: save) {
                    if saving { ProgressView().tint(Palette.background) }
                    else { Text(L.t("设好")) }
                }
                .buttonStyle(PrimaryButton())
                .disabled(!saveAllowed || saving)
                .accessibilityIdentifier("saveAlarm")
                .padding(.horizontal, 22)
                .padding(.vertical, 10)
                .background(Palette.background)
            }
        }
    }

    private var repeatOptions: some View {
        VStack(alignment: .leading, spacing: 13) {
            Picker(L.t("重复"), selection: $repetition) {
                ForEach(Repeat.allCases) { Text($0.title).tag($0) }
            }
            .onChange(of: repetition) { _, value in
                switch value {
                case .once: draft.days = []
                case .workdays: draft.days = Weekday.workdays
                case .daily: draft.days = Set(Weekday.allCases)
                case .custom:
                    if draft.days.isEmpty { draft.days = Weekday.workdays }
                }
            }
            if repetition == .custom {
                ForEach(Weekday.allCases) { day in
                    Toggle(day.title, isOn: Binding(get: { draft.days.contains(day) }, set: { selected in
                        if selected { draft.days.insert(day) }
                        else { draft.days.remove(day) }
                    }))
                }
            }
        }
        .alarmCard()
    }

    private var missionOptions: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker(L.t("起床任务"), selection: $draft.mission.kind) {
                ForEach(MissionKind.allCases) { kind in
                    if !kind.requiresPro || model.hasPro || kind == draft.mission.kind || kind == original?.mission.kind {
                        Text(kind.title).tag(kind)
                    }
                }
            }
            switch draft.mission.kind {
            case .math:
                Picker(L.t("难度"), selection: $draft.mission.difficulty) {
                    ForEach(MathDifficulty.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            case .shake:
                Stepper(draft.mission.instruction, value: $draft.mission.shakes, in: 5...60, step: 5)
            case .steps:
                Stepper(draft.mission.instruction, value: $draft.mission.steps, in: 5...120, step: 5)
                    .disabled(!model.hasPro)
            case .scan:
                Button(L.t(draft.mission.code == nil ? "登记一个码" : "已登记 · 重新登记")) {
                    showingScanner = true
                }
                .buttonStyle(SecondaryButton())
                .disabled(!model.hasPro)
            }
            if !model.hasPro && !model.canSave(draft, among: engine.ledger.alarms) {
                Text(L.t(draft.mission.kind.requiresPro ? "请选择算术或摇手机，已设的闹钟照常响" : "免费版可保留两个闹钟"))
                    .font(.footnote).foregroundStyle(Palette.secondary)
            }
        }
        .alarmCard()
    }

    private var timeBinding: Binding<Date> {
        let calendar = Calendar(identifier: .gregorian)
        let day = calendar.date(from: DateComponents(year: 2001, month: 2, day: 1)) ?? Date()
        return Binding(get: {
            calendar.date(bySettingHour: draft.hour, minute: draft.minute, second: 0, of: day) ?? day
        }, set: { date in
            draft.hour = calendar.component(.hour, from: date)
            draft.minute = calendar.component(.minute, from: date)
        })
    }

    private func save() {
        guard !saving, saveAllowed else { return }
        var rule = draft
        if let original, original.hour != rule.hour || original.minute != rule.minute || original.days != rule.days {
            rule.oneShot = nil
        }
        if rule.isRepeating { rule.oneShot = nil }
        engine.message = nil
        saving = true
        Task {
            if await engine.save(rule) { close() }
            saving = false
        }
    }
}

struct AlarmRecipeImport: View {
    @State private var text = ""
    @State private var invalid = false
    let close: () -> Void
    let onImport: (AlarmRule) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(title: L.t("导入同款闹钟"), close: close)
                TextField(L.t("粘贴闹钟口令"), text: $text, axis: .vertical)
                    .lineLimit(3...6).autocorrectionDisabled().textInputAutocapitalization(.never)
                    .alarmCard()
                if invalid {
                    Text(L.t("未识别到完整的闹钟口令")).foregroundStyle(Palette.danger)
                }
                Button(L.t("打开闹钟设置")) {
                    if let rule = AlarmRecipe.decode(text) { onImport(rule) }
                    else { invalid = true }
                }
                .buttonStyle(PrimaryButton())
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.padding(22)
        }
    }
}
