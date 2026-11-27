import StoreKit
import SwiftUI

struct PaywallView: View {
    @EnvironmentObject private var model: AppModel
    let close: () -> Void

    private var proPrice: String? {
        #if DEBUG
        if StoreScreenshotFixtures.isEnabled {
            switch Locale.current.region?.identifier {
            case "US": return "$4.99"
            case "CN": return "¥30.00"
            default: return nil
            }
        }
        #endif
        return model.product(model.proID)?.displayPrice
    }

    private var trialPrice: String? {
        #if DEBUG
        if StoreScreenshotFixtures.isEnabled {
            switch Locale.current.region?.identifier {
            case "US": return "$0.00"
            case "CN": return "¥0.00"
            default: return nil
            }
        }
        #endif
        guard let trial = model.product(model.trialID), trial.price == 0 else { return nil }
        return trial.displayPrice
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(title: L.t("高级版"), close: close)
                Label(L.t("一次买断"), systemImage: "seal")
                    .font(.title2.bold()).foregroundStyle(Palette.accent)
                if model.entitlement.purchasedPro {
                    Text(L.t("已解锁高级版")).font(.headline)
                } else {
                    let remaining = model.entitlement.remainingDays(at: Date())
                    Text(remaining > 0 ? L.f("30 天试用还剩 %@ 天", String(remaining)) : L.t("30 天试用已结束"))
                        .font(.headline)
                }
                VStack(alignment: .leading, spacing: 15) {
                    Label(L.t("走步与扫码任务"), systemImage: "figure.walk")
                    Label(L.t("创建更多闹钟"), systemImage: "alarm")
                    Text(L.t("试用结束后，算术、摇手机和已设的闹钟仍可使用。买断只收一次，不会自动扣款。"))
                        .font(.footnote).foregroundStyle(Palette.secondary)
                }
                .alarmCard()
                if !model.entitlement.purchasedPro {
                    if let proPrice {
                        Button(L.f("%@ 一次买断", proPrice)) {
                            Task { await model.purchase(model.proID) }
                        }
                        .buttonStyle(PrimaryButton())
                        .disabled(model.purchasing)
                    }
                    if model.entitlement.trialClaimedAt == nil,
                       model.entitlement.remainingDays(at: Date()) > 0,
                       let trialPrice {
                        Button(L.f("领取 %@ 试用凭证", trialPrice)) {
                            Task { await model.purchase(model.trialID) }
                        }
                        .buttonStyle(SecondaryButton())
                        .disabled(model.purchasing)
                        Text(L.t("试用从收费版首次打开起算，领取或恢复凭证不会延长试用。"))
                            .font(.footnote).foregroundStyle(Palette.secondary)
                    }
                }
                Button { Task { await model.restore() } } label: {
                    Text(L.t("恢复购买")).frame(minHeight: 44).contentShape(Rectangle())
                }
                    .disabled(model.purchasing)
                    .accessibilityIdentifier("restorePurchases")
                if model.loading || model.purchasing { ProgressView() }
                if model.productLoadFailed && !model.entitlement.purchasedPro {
                    Text(L.t("部分商品暂不可用")).foregroundStyle(Palette.secondary)
                    Button(L.t("重新加载")) { Task { await model.loadProducts() } }
                }
                if let message = model.message { Text(message).font(.footnote).foregroundStyle(Palette.secondary) }
            }
            .padding(22)
        }
        .task { await model.loadProducts() }
    }
}
