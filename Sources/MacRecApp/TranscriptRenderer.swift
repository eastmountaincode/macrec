import Foundation

enum TranscriptRenderer {
    static func renderLive(_ entries: [LiveTranscriptEntry]) -> String {
        render(entries: entries) { $0.speaker.displayName }
    }

    static func renderFile(_ entries: [LiveTranscriptEntry]) -> String {
        render(entries: entries, groupConsecutiveSpeakers: false) { _ in "Audio" }
    }

    private static func render(
        entries: [LiveTranscriptEntry],
        groupConsecutiveSpeakers: Bool = true,
        speakerName: (LiveTranscriptEntry) -> String
    ) -> String {
        var lines: [String] = []
        var lastSpeaker: String?

        for entry in entries.sorted(by: { $0.start < $1.start }) {
            let speaker = speakerName(entry)
            if !groupConsecutiveSpeakers || speaker != lastSpeaker {
                if !lines.isEmpty {
                    lines.append("")
                }
                lines.append("[\(format(entry.start))] \(speaker):")
                lastSpeaker = speaker
            }

            for line in entry.text.split(whereSeparator: \.isNewline) {
                let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    lines.append("  \(text)")
                }
            }
        }

        return lines.joined(separator: "\n") + "\n"
    }

    private static func format(_ seconds: Float) -> String {
        let total = Int(seconds)
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}
