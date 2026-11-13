import SwiftUI
import AppKit
import MacRecCore

struct LiveCompanionView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("MacRecCompanionIsDocked") private var companionIsDocked = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            companionControls
            Divider()
            LiveTranscriptPanel(state: model.liveTranscript, liveTranscriptionEnabled: model.liveTranscriptionEnabled, isRecording: model.isRecording)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            WindowConfiguration(
                autosaveName: "MacRecLiveCompanionWindow",
                minSize: NSSize(width: 360, height: 420),
                maxSize: NSSize(width: 760, height: 1000),
                supportsFullScreenOverlay: true
            )
        )
        .task {
            if companionIsDocked {
                DispatchQueue.main.async {
                    MacRecWindowCoordinator.shared.closeCompanion()
                }
            }
        }
    }

    private var companionControls: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(model.isRecording ? Color.green : Color.secondary)
                .frame(width: 9, height: 9)
            Group {
                if let startedAt = model.recordingStartedAt {
                    RecordingDuration(startedAt: startedAt)
                } else {
                    Text("Live transcript")
                }
            }
            .font(.callout.weight(.medium))

            Spacer(minLength: 8)

            Button(action: dockCompanion) {
                Label("Dock transcript", systemImage: "rectangle.leadinghalf.inset.filled")
            }
            .help("Move the live transcript back into the MacRec control window.")
        }
    }

    private func dockCompanion() {
        MacRecWindowFrames.rememberUndockedControlFrame()
        companionIsDocked = true
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            MacRecWindowFrames.controlWindow?.makeKeyAndOrderFront(nil)
            MacRecWindowCoordinator.shared.closeCompanion()
        }
    }

}

struct DockedCompanionPanel: View {
    @EnvironmentObject var model: AppModel
    let onPopOut: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Circle()
                    .fill(model.isRecording ? Color.green : Color.secondary)
                    .frame(width: 9, height: 9)
                Group {
                    if let startedAt = model.recordingStartedAt {
                        RecordingDuration(startedAt: startedAt)
                    } else {
                        Text("Live transcript")
                    }
                }
                .font(.callout.weight(.medium))
                Spacer(minLength: 8)
                Button(action: onPopOut) {
                    Label("Pop Out", systemImage: "rectangle.on.rectangle")
                }
            }

            Divider()
            LiveTranscriptPanel(state: model.liveTranscript, liveTranscriptionEnabled: model.liveTranscriptionEnabled, isRecording: model.isRecording)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

}

private struct LiveTranscriptPanel: View {
    @ObservedObject var state: LiveTranscriptState
    let liveTranscriptionEnabled: Bool
    let isRecording: Bool

    var body: some View {
        LiveTranscriptViewport(
            entries: state.entries,
            revision: state.revision,
            liveTranscriptionEnabled: liveTranscriptionEnabled,
            isRecording: isRecording
        )
        .equatable()
    }
}

private struct LiveTranscriptViewport: View, Equatable {
    let entries: [LiveTranscriptEntry]
    let revision: UInt64
    let liveTranscriptionEnabled: Bool
    let isRecording: Bool

    @State private var followState = TranscriptFollowState()

    private static let bottomID = "macrec-live-transcript-bottom"
    private static let scrollSpace = "macrec-live-transcript-scroll-space"

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.revision == rhs.revision
            && lhs.liveTranscriptionEnabled == rhs.liveTranscriptionEnabled
            && lhs.isRecording == rhs.isRecording
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if entries.isEmpty {
                Text(emptyMessage)
                    .foregroundStyle(.secondary)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            } else {
                ScrollViewReader { proxy in
                    GeometryReader { viewport in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 6) {
                                ForEach(entries) { entry in
                                    LiveTranscriptRow(entry: entry)
                                        .equatable()
                                }

                                Color.clear
                                    .frame(height: 1)
                                    .id(Self.bottomID)
                                    .background {
                                        GeometryReader { bottom in
                                            Color.clear.preference(
                                                key: TranscriptBottomPreferenceKey.self,
                                                value: bottom.frame(in: .named(Self.scrollSpace)).maxY
                                            )
                                        }
                                    }
                            }
                        }
                        .coordinateSpace(name: Self.scrollSpace)
                        .onAppear {
                            scrollToLive(using: proxy)
                        }
                        .onChange(of: revision) { _ in
                            guard followState.isFollowingLive else { return }
                            // Frequent partial-caption updates made overlapping
                            // animations feel jerky. Keeping the tail pinned is
                            // smoother and preserves direct manual scrolling.
                            DispatchQueue.main.async {
                                guard followState.isFollowingLive else { return }
                                scrollToLive(using: proxy)
                            }
                        }
                        .onPreferenceChange(TranscriptBottomPreferenceKey.self) { bottom in
                            updateFollowState(
                                bottom: bottom,
                                viewportHeight: viewport.size.height
                            )
                        }
                        .overlay(alignment: .bottomTrailing) {
                            if !followState.isFollowingLive {
                                Button {
                                    followState.jumpToLive()
                                    scrollToLive(using: proxy)
                                } label: {
                                    Label("Jump to live", systemImage: "arrow.down.to.line")
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                                .padding(8)
                            }
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var emptyMessage: String {
        guard liveTranscriptionEnabled else { return "Live transcription is off in the control window." }
        return isRecording
            ? "Listening for speech..."
            : "Start recording to see the transcript here."
    }

    private func scrollToLive(using proxy: ScrollViewProxy) {
        proxy.scrollTo(Self.bottomID, anchor: .bottom)
    }

    private func updateFollowState(bottom: CGFloat, viewportHeight: CGFloat) {
        followState.observe(
            bottom: Double(bottom),
            viewportHeight: Double(viewportHeight),
            revision: revision
        )
    }
}

private struct LiveTranscriptRow: View, Equatable {
    let entry: LiveTranscriptEntry

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.entry.id == rhs.entry.id
            && lhs.entry.speaker == rhs.entry.speaker
            && lhs.entry.text == rhs.entry.text
            && lhs.entry.isFinal == rhs.entry.isFinal
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Text(entry.speaker.displayName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(entry.speaker == .me ? .blue : .green)
                .frame(width: 66, alignment: .leading)
            Text(entry.text)
                .font(.body)
                .foregroundStyle(entry.isFinal ? .primary : .secondary)
                .italic(!entry.isFinal)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .opacity(entry.isFinal ? 1 : 0.78)
        .id(entry.id)
    }
}

private struct TranscriptBottomPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
