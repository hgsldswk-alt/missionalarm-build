import Combine
import SwiftUI
import UIKit

@main
struct MissionAlarmApp: App {
    @StateObject private var engine = AlarmEngine.shared
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(engine)
                .environmentObject(model)
                .task { await engine.start() }
                .task { await model.start() }
                .onChange(of: phase) { _, newPhase in
                    if newPhase == .active {
                        Task { await engine.refresh() }
                        Task { await model.start() }
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
                    Task { await engine.refresh() }
                }
                .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in
                    Task { await engine.refresh() }
                }
        }
    }
}
