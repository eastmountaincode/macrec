import Foundation

struct TranscriptCoverageRange: Equatable {
    let start: Float
    let end: Float
}

enum TranscriptCoverageMerge {
    static func contains(
        _ entry: LiveTranscriptEntry,
        in ranges: [TranscriptCoverageRange]
    ) -> Bool {
        let midpoint = entry.start + max(0, entry.end - entry.start) / 2
        return ranges.contains { midpoint >= $0.start && midpoint < $0.end }
    }

    @discardableResult
    static func replace(
        speaker: LiveTranscriptEntry.Speaker,
        start: Float,
        end: Float,
        with replacements: [LiveTranscriptEntry],
        entries: inout [LiveTranscriptEntry],
        coveredCallRanges: inout [TranscriptCoverageRange]
    ) -> Bool {
        let originals = entries.filter { entry in
            let midpoint = entry.start + max(0, entry.end - entry.start) / 2
            return entry.speaker == speaker && midpoint >= start && midpoint < end
        }
        let originalWordCount = originals.reduce(0) {
            $0 + $1.text.split(whereSeparator: \.isWhitespace).count
        }
        let replacementWordCount = replacements.reduce(0) {
            $0 + $1.text.split(whereSeparator: \.isWhitespace).count
        }
        guard originalWordCount == 0
                || Double(replacementWordCount) >= Double(originalWordCount) * 0.45 else {
            return false
        }

        let replacementIDs = Set(replacements.map(\.id))
        entries.removeAll { entry in
            let midpoint = entry.start + max(0, entry.end - entry.start) / 2
            return replacementIDs.contains(entry.id)
                || (
                    entry.speaker == speaker
                        && midpoint >= start
                        && midpoint < end
                )
        }
        entries.append(contentsOf: replacements)
        entries.sort { $0.start < $1.start }
        if speaker == .call {
            coveredCallRanges.append(TranscriptCoverageRange(start: start, end: end))
        }
        return true
    }
}
