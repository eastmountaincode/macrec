import Foundation

/// Small, UI-independent state machine for a live transcript viewport.
///
/// New transcript layout can move the bottom marker without any user input, so
/// the revision is part of the observation. Only movement with unchanged
/// content is interpreted as the user scrolling away from the live tail.
public struct TranscriptFollowState: Sendable, Equatable {
    public private(set) var isFollowingLive = true

    private var lastMeasuredBottom: Double?
    private var lastMeasuredRevision: UInt64?

    public init() {}

    public mutating func observe(
        bottom: Double,
        viewportHeight: Double,
        revision: UInt64
    ) {
        let distanceFromBottom = bottom - viewportHeight

        if distanceFromBottom <= 36 {
            isFollowingLive = true
        } else if lastMeasuredRevision == revision,
                  let previousBottom = lastMeasuredBottom,
                  bottom > previousBottom + 2 {
            isFollowingLive = false
        }

        lastMeasuredBottom = bottom
        lastMeasuredRevision = revision
    }

    public mutating func jumpToLive() {
        isFollowingLive = true
    }
}
