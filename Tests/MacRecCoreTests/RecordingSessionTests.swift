import Foundation
import Testing
@testable import MacRecCore

@Test func recordingSessionCreatesExpectedFileLayout() {
    let root = URL(fileURLWithPath: "/tmp/macrec-tests", isDirectory: true)
    let session = RecordingSession(
        directory: root,
        title: "Yaz Follow Up",
        startedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )

    #expect(session.directory.deletingLastPathComponent() == root)
    #expect(session.directory.lastPathComponent.hasPrefix("macrec-"))
    #expect(session.directory.lastPathComponent.hasSuffix("-yaz-follow-up"))
    #expect(session.micFile.lastPathComponent == "\(session.fileStem)-me.m4a")
    #expect(session.systemFile.lastPathComponent == "\(session.fileStem)-call.m4a")
}

@Test func recordingSessionPreviewNamesUseTitleWhenPresent() {
    let names = RecordingSession.previewFileNames(title: "Yaz Follow Up")

    #expect(names.mic == "YYYY-MM-DD_HH-mm-ss-yaz-follow-up-me.m4a")
    #expect(names.system == "YYYY-MM-DD_HH-mm-ss-yaz-follow-up-call.m4a")
}

@Test func liveTranscriptFollowPausesOnlyForUserScrolling() {
    var state = TranscriptFollowState()

    state.observe(bottom: 600, viewportHeight: 600, revision: 1)
    #expect(state.isFollowingLive)

    // A new caption can make the content taller before the viewport is pinned
    // again. A new revision must not look like manual scrolling.
    state.observe(bottom: 680, viewportHeight: 600, revision: 2)
    #expect(state.isFollowingLive)

    // With unchanged content, moving the bottom farther down in viewport
    // coordinates means the user scrolled upward to review history.
    state.observe(bottom: 760, viewportHeight: 600, revision: 2)
    #expect(!state.isFollowingLive)

    // Incoming transcript updates must not pull the user back to the tail.
    state.observe(bottom: 800, viewportHeight: 600, revision: 3)
    #expect(!state.isFollowingLive)

    // Scrolling back near the bottom resumes live following naturally.
    state.observe(bottom: 620, viewportHeight: 600, revision: 3)
    #expect(state.isFollowingLive)
}

@Test func liveTranscriptFollowCanJumpBackToLive() {
    var state = TranscriptFollowState()
    state.observe(bottom: 700, viewportHeight: 600, revision: 1)
    state.observe(bottom: 780, viewportHeight: 600, revision: 1)
    #expect(!state.isFollowingLive)

    state.jumpToLive()
    #expect(state.isFollowingLive)
}
