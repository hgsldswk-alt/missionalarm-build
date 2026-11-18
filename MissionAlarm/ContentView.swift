import SwiftUI
import UIKit

struct ContentView: View {
    private enum Page {
        case home, editor(AlarmRule), settings, diagnostics, paywall, importRecipe
    }

    @EnvironmentObject private var engine: AlarmEngine
    @EnvironmentObject private var model: AppModel
    @State private var page = Page.home
    @State private var updating: Set<UUID> = []

    var body: some View {
        ZStack {
            Palette.background.ignoresSafeArea()
            if let run = engine.activeRun {
                MissionView(run: run).id(run.id)
            } else if let wake = engine.wake {
                WakeView(wake: wake).id(wake.id)
            } else {
                navigationContent
            }
        }
        .foregroundStyle(Palette.text)
        .preferredColorScheme(.dark)
        .tint(Palette.accent)
        .onChange(of: engine.activeRun?.id) { _, id in
            if id != nil { page = .home }
        }
    }

    @ViewBuilder private var navigationContent: some View {
        switch page {
        case .home:
            home
        case .editor(let alarm):
            AlarmEditor(original: alarm) { page = .home }
                .id(alarm.id)
        case .settings:
            settings
        case .diagnostics:
            DiagnosticsView { page = .settings }
        case .paywall:
            if !model.freePeriod { PaywallView { page = .settings } }
        case .importRecipe:
            AlarmRecipeImport(close: { page = .settings }, onImport: { recipe in
                page = .editor(recipe)
            })
        }
    }

    private var home: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            #if DEBUG
            let now = StoreScreenshotFixtures.isEnabled ? StoreScreenshotFixtures.date : context.date
            #else
            let now = context.date
            #endif
            let alarms = engine.ledger.alarms
            let next = alarms.compactMap { alarm -> (AlarmRule, Date)? in
                guard alarm.rule.enabled,
                      let date = alarm.rule.next(after: now, calendar: .autoupdatingCurrent) else { return nil }
                return (alarm.rule, date)
            }.min { $0.1 < $1.1 }
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    homeHeader(at: now)
                    permissionStatus
                    if let next {
                        nextAlarm(next.0, date: next.1, now: now)
                    } else {
                        emptyAlarm
                    }
                    if let message = engine.message {
                        Text(message).font(.footnote).foregroundStyle(Palette.danger).alarmCard()
                    }
                    if !alarms.isEmpty {
                        Text(L.t("全部闹钟")).font(.subheadline.weight(.semibold))
                            .foregroundStyle(Palette.secondary).accessibilityAddTraits(.isHeader)
                        VStack(spacing: 1) {
                            ForEach(alarms) { row in alarmRow(row.rule) }
                        }
                    }
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 14)
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    let new = AlarmRule()
                    if model.canSave(new, among: alarms) {
                        engine.message = nil
                        page = .editor(new)
                    } else {
                        engine.message = L.t("免费版可保留两个闹钟")
                    }
                } label: {
                    Label(L.t("闹钟"), systemImage: "plus")
                }
                .buttonStyle(PrimaryButton())
                .accessibilityLabel(L.t("新建闹钟"))
                .accessibilityIdentifier("addAlarm")
                .padding(.horizontal, 22)
                .padding(.vertical, 10)
                .background(Palette.background)
            }
        }
    }

    private func homeHeader(at date: Date) -> some View {
        let streak = engine.ledger.history.currentStreak(at: date, timeZone: .current)
        return HStack {
            Text(streak == 0 ? L.t("任务闹钟") : L.f("已连续早起 %@ 天", String(streak)))
                .font(.headline)
                .foregroundStyle(streak == 0 ? Palette.text : Palette.accent)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Button {
                page = .settings
            } label: {
                Image(systemName: "ellipsis")
                    .font(.headline)
                    .frame(width: 44, height: 44)
                    .background(Palette.card, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L.t("设置"))
            .accessibilityIdentifier("openSettings")
        }
    }

    @ViewBuilder private var permissionStatus: some View {
        if engine.authorization == .denied {
            VStack(alignment: .leading, spacing: 8) {
                Label(L.t("闹钟权限已关，现在不会响"), systemImage: "alarm")
                    .font(.subheadline.bold())
                Button(L.t("去系统设置"), action: openSystemSettings)
                    .font(.subheadline.weight(.semibold)).padding(.vertical, 8)
            }
            .foregroundStyle(Palette.danger)
            .alarmCard()
        } else if engine.systemCheckFailed || !engine.unarmed.isEmpty || !engine.incompleteBackups.isEmpty || engine.cleanupPending {
            VStack(alignment: .leading, spacing: 8) {
                Text(alarmStatus)
                Button(L.t("重试")) { Task { await engine.refresh() } }.padding(.vertical, 8)
            }
            .font(.subheadline)
            .foregroundStyle(Palette.accent)
            .alarmCard()
        }
    }

    private var alarmStatus: String {
        if engine.cleanupPending { return L.t("部分铃声还在等待关闭") }
        if engine.systemCheckFailed { return L.t("无法核对系统闹钟") }
        if !engine.unarmed.isEmpty { return L.t("部分主闹钟未排上，请重试") }
        return L.t("部分补响未排上，主闹钟仍会响")
    }

    private func nextAlarm(_ rule: AlarmRule, date: Date, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Button {
                edit(rule)
            } label: {
                VStack(alignment: .leading, spacing: 5) {
                    Text(dayLabel(date, now: now)).font(.subheadline).foregroundStyle(Palette.secondary)
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            largeTime(date)
                            Text(rule.repeatLabel).font(.subheadline).foregroundStyle(Palette.secondary)
                                .lineLimit(1)
                        }.fixedSize(horizontal: true, vertical: false)
                        VStack(alignment: .leading, spacing: 0) {
                            largeTime(date)
                            Text(rule.repeatLabel).font(.subheadline).foregroundStyle(Palette.secondary)
                        }
                    }
                    if engine.authorization == .authorized && !engine.systemCheckFailed && !engine.unarmed.contains(rule.id) {
                        Text(L.f("%@后响 · 静音也会响", duration(from: now, to: date)))
                            .font(.subheadline).foregroundStyle(Palette.accent)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(L.t("编辑闹钟"))
            Button {
                edit(rule)
            } label: {
                HStack(spacing: 13) {
                    Image(systemName: rule.mission.kind.icon)
                        .foregroundStyle(Palette.accent)
                        .frame(width: 40, height: 40)
                        .background(Palette.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(rule.mission.instruction).font(.headline)
                        if rule.mission.kind == .math {
                            Text(rule.mission.difficulty.title).font(.subheadline).foregroundStyle(Palette.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(Palette.secondary)
                }
                .alarmCard()
            }
            .buttonStyle(.plain)
        }
    }

    private func largeTime(_ date: Date) -> some View {
        Text(date.formatted(date: .omitted, time: .shortened))
            .font(.system(size: 76, weight: .ultraLight, design: .rounded))
            .monospacedDigit().lineLimit(1).minimumScaleFactor(0.45)
    }

    private var emptyAlarm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "alarm").font(.largeTitle.weight(.light)).foregroundStyle(Palette.accent)
            Text(L.t("没有开启的闹钟")).font(.title2.bold())
            Text(L.t("新闹钟默认为工作日 7:00，完成三道算术题后停止"))
                .font(.subheadline).foregroundStyle(Palette.secondary)
        }
        .padding(.vertical, 22)
        .alarmCard()
    }

    private func alarmRow(_ rule: AlarmRule) -> some View {
        HStack(spacing: 12) {
            Button {
                edit(rule)
            } label: {
                VStack(alignment: .leading, spacing: 5) {
                    Text(rule.timeLabel).font(.system(size: 31, weight: .light, design: .rounded)).monospacedDigit()
                    Text(L.f("%@ · %@", rule.repeatLabel, rule.mission.kind.title))
                        .font(.subheadline).foregroundStyle(Palette.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(L.t("编辑闹钟"))
            .accessibilityIdentifier("alarmRow")
            Toggle(isOn: Binding(get: { rule.enabled }, set: { enabled in
                guard updating.insert(rule.id).inserted else { return }
                var changed = rule
                changed.enabled = enabled
                if enabled && !changed.isRepeating { changed.oneShot = nil }
                Task {
                    engine.message = nil
                    _ = await engine.save(changed)
                    updating.remove(rule.id)
                }
            })) {
                Text(L.f("%@ 闹钟", rule.timeLabel))
            }
            .labelsHidden()
            .disabled(updating.contains(rule.id))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .opacity(rule.enabled ? 1 : 0.66)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.line).frame(height: 1) }
    }

    private var settings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(title: L.t("设置")) { page = .home }
                if !model.freePeriod {
                    settingsRow("高级版", icon: "seal") {
                        model.message = nil
                        page = .paywall
                    }
                    .accessibilityIdentifier("openPro")
                }
                settingsRow("导入同款闹钟", icon: "square.and.arrow.down") { page = .importRecipe }
                settingsRow("诊断记录", icon: "list.bullet.rectangle") { page = .diagnostics }
            }.padding(22)
        }
    }

    private func settingsRow(_ key: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Label(L.t(key), systemImage: icon)
                Spacer()
                Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(Palette.secondary)
            }.alarmCard()
        }.buttonStyle(.plain)
    }

    private func edit(_ alarm: AlarmRule) {
        engine.message = nil
        page = .editor(alarm)
    }

    private func dayLabel(_ date: Date, now: Date) -> String {
        let calendar = Calendar.autoupdatingCurrent
        if calendar.isDate(date, inSameDayAs: now) { return L.t("今天") }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(date, inSameDayAs: tomorrow) { return L.t("明天") }
        return date.formatted(.dateTime.weekday(.wide))
    }

    private func duration(from now: Date, to date: Date) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter.string(from: max(60, ceil(date.timeIntervalSince(now) / 60) * 60)) ?? ""
    }
}

private struct DiagnosticsView: View {
    @EnvironmentObject private var engine: AlarmEngine
    let close: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(title: L.t("诊断记录"), close: close)
                HStack {
                    Button(L.t("复制")) { UIPasteboard.general.string = engine.logs.joined(separator: "\n") }
                    Spacer()
                    Button(L.t("清空"), role: .destructive) { engine.clearLogs() }
                }
                .buttonStyle(.bordered)
                .disabled(engine.logs.isEmpty)
                if engine.logs.isEmpty {
                    Text(L.t("暂无记录")).foregroundStyle(Palette.secondary)
                }
                ForEach(Array(engine.logs.enumerated()), id: \.offset) { _, line in
                    Text(line).font(.caption.monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(22)
        }
    }
}
