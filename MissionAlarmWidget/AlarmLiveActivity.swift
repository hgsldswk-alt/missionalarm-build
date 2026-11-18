import ActivityKit
import AlarmKit
import SwiftUI
import WidgetKit

@main
struct MissionAlarmWidgetBundle: WidgetBundle {
    var body: some Widget {
        AlarmLiveActivity()
    }
}

struct AlarmLiveActivity: Widget {
    private let accent = Color(red: 242 / 255, green: 169 / 255, blue: 59 / 255)

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AlarmAttributes<WakeMeta>.self) { _ in
            HStack(spacing: 12) {
                Image(systemName: "alarm.fill")
                    .font(.title2)
                    .foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("起床任务")
                        .font(.headline)
                    Text("做完任务才算起床")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding()
        } dynamicIsland: { _ in
            DynamicIsland {
                DynamicIslandExpandedRegion(.center) {
                    Text("起床任务")
                }
            } compactLeading: {
                Image(systemName: "alarm.fill").foregroundStyle(accent)
            } compactTrailing: {
                Text("任务")
            } minimal: {
                Image(systemName: "alarm.fill").foregroundStyle(accent)
            }
        }
    }
}
