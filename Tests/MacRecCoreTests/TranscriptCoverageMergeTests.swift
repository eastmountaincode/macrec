import Testing
@testable import MacRecApp

@Test
func transcriptCoverageReplacesOnlyItsCallRangeAndSuppressesLateDuplicates() {
    var entries = [
        LiveTranscriptEntry(
            id: "call-a",
            speaker: .call,
            start: 0,
            end: 8,
            text: "one two three four five six seven eight nine ten"
        ),
        LiveTranscriptEntry(
            id: "me",
            speaker: .me,
            start: 9,
            end: 12,
            text: "my microphone stays"
        ),
        LiveTranscriptEntry(
            id: "call-b",
            speaker: .call,
            start: 13,
            end: 20,
            text: "eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen"
        ),
        LiveTranscriptEntry(
            id: "outside",
            speaker: .call,
            start: 35,
            end: 40,
            text: "outside stays"
        ),
    ]
    let replacement = LiveTranscriptEntry(
        id: "coverage",
        speaker: .call,
        start: 1,
        end: 22,
        text: "recovered one two three four five six seven eight nine ten eleven"
    )
    var coveredRanges: [TranscriptCoverageRange] = []

    let didReplace = TranscriptCoverageMerge.replace(
        speaker: .call,
        start: 0,
        end: 30,
        with: [replacement],
        entries: &entries,
        coveredCallRanges: &coveredRanges
    )

    #expect(didReplace)
    #expect(entries.map(\.id) == ["coverage", "me", "outside"])
    #expect(coveredRanges == [TranscriptCoverageRange(start: 0, end: 30)])

    let lateMoonshineEntry = LiveTranscriptEntry(
        id: "late",
        speaker: .call,
        start: 20,
        end: 25,
        text: "this should not be duplicated"
    )
    #expect(TranscriptCoverageMerge.contains(lateMoonshineEntry, in: coveredRanges))
}

@Test
func transcriptCoverageRejectsAWeakerReplacementWithoutMarkingTheRangeCovered() {
    let original = LiveTranscriptEntry(
        id: "original",
        speaker: .call,
        start: 0,
        end: 20,
        text: "one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen twenty"
    )
    var entries = [original]
    var coveredRanges: [TranscriptCoverageRange] = []
    let weakReplacement = LiveTranscriptEntry(
        id: "weak",
        speaker: .call,
        start: 0,
        end: 20,
        text: "one two three four five six seven eight"
    )

    let didReplace = TranscriptCoverageMerge.replace(
        speaker: .call,
        start: 0,
        end: 30,
        with: [weakReplacement],
        entries: &entries,
        coveredCallRanges: &coveredRanges
    )

    #expect(!didReplace)
    #expect(entries == [original])
    #expect(coveredRanges.isEmpty)
}
