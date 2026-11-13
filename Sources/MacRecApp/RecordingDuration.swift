import SwiftUI

struct RecordingDuration: View {
    let startedAt: Date

    var body: some View {
        TimelineView(.periodic(from: startedAt, by: 1)) { context in
            Text(Self.format(context.date.timeIntervalSince(startedAt)))
                .monospacedDigit()
                .accessibilityLabel("Recording duration")
        }
    }

    static func format(_ duration: TimeInterval) -> String {
        let total = max(0, Int(duration))
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}
