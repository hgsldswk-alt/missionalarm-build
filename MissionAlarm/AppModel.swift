import Foundation
import Security
import StoreKit
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var entitlement = Entitlement()
    @Published private(set) var products: [Product] = []
    @Published private(set) var loading = false
    @Published private(set) var productLoadFailed = false
    @Published private(set) var purchasing = false
    @Published var message: String?

    let proID = "com.hgsldswk.missionalarm.pro"
    let trialID = "com.hgsldswk.missionalarm.trial"
    let freePeriod = !StoreScreenshotFixtures.isEnabled && Launch.isFree

    private let defaults = UserDefaults.standard
    private let entitlementKey = "paid-entitlement-v1"
    private var updates: Task<Void, Never>?
    private var refreshGeneration = 0
    private let fixtures: Bool

    var hasPro: Bool { entitlement.hasPro(at: Date(), freePeriod: freePeriod) }

    init() {
        #if DEBUG
        fixtures = ProcessInfo.processInfo.arguments.contains("-expired")
        #else
        fixtures = false
        #endif
        if StoreScreenshotFixtures.isEnabled {
            entitlement.startPaidPeriod(at: Date())
            return
        }
        if fixtures {
            entitlement.startPaidPeriod(at: Date().addingTimeInterval(-31 * 86_400))
        } else if !freePeriod {
            if let data = defaults.data(forKey: entitlementKey),
               let saved = try? JSONDecoder().decode(Entitlement.self, from: data) { entitlement = saved }
            let savedStarts = [entitlement.proStartedAt, PaidStartKeychain.read()].compactMap { $0 }
            entitlement.proStartedAt = savedStarts.min()
            entitlement.startPaidPeriod(at: Date())
            if let start = entitlement.proStartedAt { PaidStartKeychain.store(start) }
            persist()
        }
    }

    func start() async {
        guard !freePeriod, !fixtures, !StoreScreenshotFixtures.isEnabled else { return }
        if updates == nil {
            updates = Task { [weak self] in
                for await verification in StoreKit.Transaction.updates {
                    guard let self, !Task.isCancelled else { return }
                    guard case .verified(let transaction) = verification, isOurs(transaction) else { continue }
                    apply(transaction)
                    await transaction.finish()
                    await refreshEntitlements()
                }
            }
        }
        await refreshEntitlements()
    }

    func canSave(_ rule: AlarmRule, among existing: [ScheduledAlarm]) -> Bool {
        if hasPro { return true }
        let old = existing.first(where: { $0.id == rule.id })?.rule
        guard old != nil || existing.count < 2 else { return false }
        return !rule.mission.kind.requiresPro || old?.mission == rule.mission
    }

    func product(_ id: String) -> Product? { products.first { $0.id == id } }

    func loadProducts() async {
        guard !freePeriod, !loading, !StoreScreenshotFixtures.isEnabled else { return }
        loading = true
        defer { loading = false }
        do {
            products = try await Product.products(for: [proID, trialID])
                .filter { $0.type == .nonConsumable }
            productLoadFailed = products.count < 2
        } catch {
            productLoadFailed = true
        }
    }

    func purchase(_ id: String) async {
        guard !freePeriod, !purchasing, !StoreScreenshotFixtures.isEnabled, let product = product(id) else { return }
        if id == trialID {
            guard product.price == 0, entitlement.trialClaimedAt == nil,
                  entitlement.remainingDays(at: Date()) > 0 else { return }
        }
        purchasing = true
        defer { purchasing = false }
        do {
            switch try await product.purchase() {
            case .success(let verification):
                guard case .verified(let transaction) = verification, isOurs(transaction) else {
                    message = L.t("无法验证购买，请尝试恢复购买")
                    return
                }
                apply(transaction)
                await transaction.finish()
                await refreshEntitlements()
            case .pending: message = L.t("购买正在等待批准，批准后会自动解锁")
            case .userCancelled: break
            @unknown default: break
            }
        } catch {
            message = L.t("购买未完成，请稍后重试")
        }
    }

    func restore() async {
        guard !freePeriod, !purchasing, !StoreScreenshotFixtures.isEnabled else { return }
        purchasing = true
        defer { purchasing = false }
        do {
            try await AppStore.sync()
            await refreshEntitlements()
            message = entitlement.purchasedPro || entitlement.trialClaimedAt != nil
                ? L.t("已恢复购买记录") : L.t("未找到可恢复的购买")
        } catch {
            message = L.t("恢复购买失败，请稍后重试")
        }
    }

    private func refreshEntitlements() async {
        refreshGeneration += 1
        let generation = refreshGeneration
        var boughtPro = false
        var trialDate: Date?
        for await verification in StoreKit.Transaction.currentEntitlements {
            guard case .verified(let transaction) = verification,
                  isOurs(transaction), transaction.revocationDate == nil else { continue }
            if transaction.productID == proID { boughtPro = true }
            if transaction.productID == trialID {
                let original = transaction.originalPurchaseDate
                trialDate = min(trialDate ?? original, original)
            }
        }
        guard generation == refreshGeneration, !Task.isCancelled else { return }
        entitlement.purchasedPro = boughtPro
        if let trialDate { entitlement.recordTrialClaim(at: trialDate) }
        persist()
    }

    private func apply(_ transaction: StoreKit.Transaction) {
        refreshGeneration += 1
        if transaction.productID == proID { entitlement.purchasedPro = transaction.revocationDate == nil }
        if transaction.productID == trialID, transaction.revocationDate == nil {
            entitlement.recordTrialClaim(at: transaction.originalPurchaseDate)
        }
        persist()
    }

    private func isOurs(_ transaction: StoreKit.Transaction) -> Bool {
        transaction.productType == .nonConsumable && [proID, trialID].contains(transaction.productID)
    }

    private func persist() {
        guard !fixtures, !freePeriod, let data = try? JSONEncoder().encode(entitlement) else { return }
        defaults.set(data, forKey: entitlementKey)
    }
}

private enum PaidStartKeychain {
    static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.hgsldswk.missionalarm",
        kSecAttrAccount as String: "paid-trial-start"
    ]

    static func read() -> Date? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(Date.self, from: data)
    }

    static func store(_ start: Date) {
        if let old = read(), old <= start { return }
        guard let data = try? JSONEncoder().encode(start) else { return }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        if SecItemAdd(item as CFDictionary, nil) == errSecDuplicateItem,
           let old = read(), start < old {
            SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        }
    }
}
