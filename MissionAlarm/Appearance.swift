import SwiftUI

enum L {
    static func t(_ key: String) -> String { NSLocalizedString(key, comment: "") }

    static func f(_ key: String, _ values: String...) -> String {
        String(format: t(key), locale: Locale.current, arguments: values)
    }
}

enum Palette {
    static let background = Color(red: 14 / 255, green: 14 / 255, blue: 16 / 255)
    static let card = Color(red: 26 / 255, green: 26 / 255, blue: 29 / 255)
    static let raised = Color(red: 35 / 255, green: 35 / 255, blue: 39 / 255)
    static let line = Color(red: 44 / 255, green: 44 / 255, blue: 49 / 255)
    static let text = Color(red: 244 / 255, green: 242 / 255, blue: 238 / 255)
    static let secondary = Color(red: 154 / 255, green: 151 / 255, blue: 143 / 255)
    static let accent = Color(red: 242 / 255, green: 169 / 255, blue: 59 / 255)
    static let danger = Color(red: 229 / 255, green: 103 / 255, blue: 90 / 255)
}

struct PrimaryButton: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, minHeight: 54)
            .padding(.horizontal, 12)
            .foregroundStyle(Palette.background)
            .background(Palette.accent, in: Capsule())
            .opacity(enabled ? (configuration.isPressed ? 0.76 : 1) : 0.44)
    }
}

struct SecondaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, minHeight: 48)
            .padding(.horizontal, 12)
            .foregroundStyle(Palette.text)
            .background(Palette.raised.opacity(configuration.isPressed ? 0.7 : 1),
                        in: RoundedRectangle(cornerRadius: 14))
    }
}

struct PageHeader: View {
    let title: String
    let close: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: close) {
                Image(systemName: "chevron.left")
                    .font(.headline)
                    .foregroundStyle(Palette.text)
                    .frame(width: 44, height: 44)
                    .background(Palette.card, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L.t("返回"))
            .accessibilityIdentifier("pageBack")
            Text(title).font(.title2.bold()).accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
        }
    }
}

extension View {
    func alarmCard() -> some View {
        padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Palette.line, lineWidth: 1))
    }
}

extension MissionKind {
    var title: String {
        switch self {
        case .math: return L.t("算术")
        case .shake: return L.t("摇手机")
        case .steps: return L.t("走步")
        case .scan: return L.t("扫码")
        }
    }

    var icon: String {
        switch self {
        case .math: return "plus.forwardslash.minus"
        case .shake: return "iphone.radiowaves.left.and.right"
        case .steps: return "figure.walk"
        case .scan: return "qrcode.viewfinder"
        }
    }
}

extension Mission {
    var instruction: String {
        switch kind {
        case .math: return L.f("算 %@ 道题才能停", String(goal))
        case .shake: return L.f("摇手机 %@ 次", String(goal))
        case .steps: return L.f("走 %@ 步", String(goal))
        case .scan: return L.t("扫描已登记的码")
        }
    }
}

extension MathDifficulty {
    var title: String {
        switch self {
        case .easy: return L.t("简单")
        case .medium: return L.t("中等")
        case .hard: return L.t("困难")
        }
    }
}

extension AlarmRule {
    var timeLabel: String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let formatter = DateFormatter()
        formatter.timeZone = calendar.timeZone
        formatter.timeStyle = .short
        guard let date = calendar.date(from: DateComponents(year: 2001, month: 1, day: 1, hour: hour, minute: minute)) else {
            return String(format: "%d:%02d", hour, minute)
        }
        return formatter.string(from: date)
    }

    var repeatLabel: String {
        if days.isEmpty { return L.t("仅一次") }
        if days == Weekday.workdays { return L.t("工作日") }
        if days.count == Weekday.allCases.count { return L.t("每天") }
        return Weekday.allCases.filter { days.contains($0) }.map(\.title).joined(separator: " ")
    }
}

extension Weekday {
    var title: String {
        Calendar.autoupdatingCurrent.shortWeekdaySymbols[rawValue - 1]
    }
}

func openSystemSettings() {
    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
    UIApplication.shared.open(url)
}
