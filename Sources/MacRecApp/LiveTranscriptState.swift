import Combine

/// Publishes caption changes only to transcript views, independently of the controls.
@MainActor
final class LiveTranscriptState: ObservableObject {
    @Published private(set) var entries: [LiveTranscriptEntry] = []
    private(set) var revision: UInt64 = 0

    func publish(_ sourceEntries: [LiveTranscriptEntry]) {
        let visibleEntries = Array(sourceEntries.suffix(180))
        guard entries != visibleEntries else { return }
        revision &+= 1
        entries = visibleEntries
    }
}
