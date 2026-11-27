import AlarmKit

struct WakeMeta: AlarmMetadata {
    var label: String

    init(label: String = "") {
        self.label = label
    }
}
