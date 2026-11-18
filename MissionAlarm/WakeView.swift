import CoreImage.CIFilterBuiltins
import StoreKit
import SwiftUI
import UIKit

struct WakeView: View {
    @EnvironmentObject private var engine: AlarmEngine
    @Environment(\.requestReview) private var requestReview
    @Environment(\.scenePhase) private var phase
    @State private var share: WakeShare?
    @State private var shareFailed = false
    let wake: WakeRecord

    private var streak: Int { engine.ledger.history.streak(endingOn: wake.day) }

    private var milestone: Int? {
        guard [7, 30].contains(streak),
              engine.ledger.history.records.first(where: { $0.day == wake.day })?.id == wake.id else { return nil }
        return streak
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 17) {
                Label(L.t(engine.cleanupPending ? "部分铃声还在等待关闭" : "本次铃声已关闭"),
                      systemImage: engine.cleanupPending ? "alarm" : "checkmark.circle")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(Palette.accent)
                if engine.cleanupPending {
                    Button(L.t("重试关闭")) { Task { await engine.refresh() } }
                        .buttonStyle(.bordered)
                }
                Text(L.t("起床成功")).font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
                GeometryReader { geometry in
                    card(milestone: milestone)
                        .scaleEffect(geometry.size.width / WakeCard.width, anchor: .topLeading)
                }
                .aspectRatio(WakeCard.width / WakeCard.height, contentMode: .fit)
                .background(Palette.card, in: RoundedRectangle(cornerRadius: 20))
                .clipShape(RoundedRectangle(cornerRadius: 20))
                if let milestone {
                    Button(L.f("分享 %@ 天里程碑", String(milestone))) { prepareShare(milestone: milestone) }
                        .buttonStyle(PrimaryButton())
                    Button(L.t("分享早起卡")) { prepareShare(milestone: nil) }
                        .buttonStyle(SecondaryButton())
                } else {
                    Button(L.t("分享早起卡")) { prepareShare(milestone: nil) }.buttonStyle(PrimaryButton())
                }
                if shareFailed {
                    Text(L.t("分享图生成失败，请重试")).font(.footnote).foregroundStyle(Palette.danger)
                }
                Button(L.t("完成")) { engine.dismissWake() }
                    .buttonStyle(SecondaryButton())
            }
            .padding(22)
        }
        .sheet(item: $share, onDismiss: { Task { await requestReviewIfReady() } }) {
            SystemShare(items: $0.items).presentationDetents([.medium, .large])
        }
        .task(id: phase) { await requestReviewIfReady() }
    }

    private func card(milestone: Int?) -> WakeCard {
        WakeCard(wake: wake, streak: streak, days: Set(engine.ledger.history.records.map(\.day)), milestone: milestone)
    }

    private func requestReviewIfReady() async {
        guard phase == .active else { return }
        try? await Task.sleep(for: .milliseconds(450))
        guard !Task.isCancelled, share == nil, engine.activeRun == nil, engine.wake?.id == wake.id else { return }
        if await engine.takeReviewRequest(), engine.activeRun == nil { requestReview() }
    }

    private func prepareShare(milestone: Int?) {
        shareFailed = false
        let renderer = ImageRenderer(content: card(milestone: milestone))
        renderer.scale = 2
        guard let image = renderer.uiImage else { shareFailed = true; return }
        var caption = L.f("已连续早起 %@ 天", String(streak)) + "\n" + L.t("#早起打卡 #自律")
        if let run = engine.ledger.runs.first(where: { $0.id == wake.id }),
           let rule = engine.ledger.alarms.first(where: { $0.id == run.alarmID })?.rule,
           let recipe = AlarmRecipe.encode(rule) {
            caption += "\n\n" + L.t("复制口令，在任务闹钟的设置里导入同款闹钟") + "\n" + recipe
        }
        share = WakeShare(items: [image, caption])
    }
}

private struct WakeCard: View {
    static let width: CGFloat = 540
    static let height: CGFloat = 675
    static let address = "https://apps.apple.com/app/id6835499119"

    let wake: WakeRecord
    let streak: Int
    let days: Set<Date>
    let milestone: Int?

    private var localTimeZone: TimeZone { TimeZone(identifier: wake.timeZoneID) ?? .current }

    private func dateString(_ template: String) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = localTimeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: wake.time)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            Label(L.t(milestone == nil ? "早起打卡" : "早起里程碑"), systemImage: milestone == nil ? "sunrise" : "medal")
                .font(.system(size: 28, weight: .semibold)).foregroundStyle(Palette.accent)
            Text(dateString("MMMMdEEEE"))
                .font(.system(size: 24)).foregroundStyle(Palette.secondary)
            Spacer(minLength: 0)
            if let milestone {
                Text(L.f("连续早起 %@ 天", String(milestone)))
                    .font(.system(size: 64, weight: .light, design: .rounded))
                    .lineLimit(2).minimumScaleFactor(0.5).foregroundStyle(Palette.accent)
                Text(L.f("%@ 起床", dateString("jm")))
                    .font(.system(size: 27, weight: .medium))
            } else {
                Text(dateString("jm"))
                    .font(.system(size: 109, weight: .ultraLight, design: .rounded)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.35)
                Text(L.f("连续早起第 %@ 天", String(streak)))
                    .font(.system(size: 32, weight: .medium)).foregroundStyle(Palette.accent)
            }
            VStack(spacing: 7) {
                ForEach(0..<2, id: \.self) { row in
                    HStack(spacing: 7) {
                        ForEach(0..<7, id: \.self) { index in
                            let day = wake.day.addingTimeInterval(Double(row * 7 + index - 13) * 86_400)
                            RoundedRectangle(cornerRadius: 5)
                                .fill(days.contains(day) ? Palette.accent : Palette.line)
                                .frame(height: 23)
                        }
                    }
                }
            }
            .accessibilityHidden(true)
            Spacer(minLength: 0)
            Rectangle().fill(Palette.line).frame(height: 1)
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L.t("任务闹钟")).font(.system(size: 25, weight: .semibold))
                    Text(L.t("#早起打卡 #自律")).font(.system(size: 20)).foregroundStyle(Palette.secondary)
                }
                Spacer(minLength: 0)
                if let image = Self.qr {
                    Image(uiImage: image).resizable().interpolation(.none).scaledToFit()
                        .frame(width: 83, height: 83)
                        .padding(10).background(Color.white)
                        .accessibilityLabel(L.t("下载二维码"))
                }
            }
        }
        .padding(36)
        .frame(width: Self.width, height: Self.height)
        .foregroundStyle(Palette.text)
        .background(Palette.card)
    }

    private static let qr: UIImage? = {
        let generator = CIFilter.qrCodeGenerator()
        generator.message = Data(address.utf8)
        generator.correctionLevel = "M"
        guard let output = generator.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cg)
    }()
}

private struct WakeShare: Identifiable {
    let id = UUID()
    let items: [Any]
}

private struct SystemShare: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
