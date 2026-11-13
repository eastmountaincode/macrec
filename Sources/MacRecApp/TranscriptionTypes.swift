import Foundation

struct LiveTranscriptEntry: Identifiable, Sendable, Equatable {
    enum Speaker: Sendable, Hashable {
        case me
        case call

        var displayName: String {
            switch self {
            case .me:
                return "Me"
            case .call:
                return "Call"
            }
        }

        var storageKey: String {
            switch self {
            case .me:
                return "me"
            case .call:
                return "call"
            }
        }

        var isCallAudio: Bool {
            switch self {
            case .call:
                return true
            case .me:
                return false
            }
        }
    }

    let id: String
    let speaker: Speaker
    let start: Float
    let end: Float
    let text: String
    let isFinal: Bool
    let isRefined: Bool
    let words: [LiveTranscriptWord]

    init(
        id: String = UUID().uuidString,
        speaker: Speaker,
        start: Float,
        end: Float,
        text: String,
        isFinal: Bool = true,
        isRefined: Bool = false,
        words: [LiveTranscriptWord] = []
    ) {
        self.id = id
        self.speaker = speaker
        self.start = start
        self.end = end
        self.text = text
        self.isFinal = isFinal
        self.isRefined = isRefined
        self.words = words
    }
}

struct LiveTranscriptWord: Sendable, Equatable {
    let text: String
    let start: Float
    let end: Float
}

struct LiveTranscriptAudioSegment: Sendable {
    let entry: LiveTranscriptEntry
    let samples: [Float]
}

enum LiveTranscriptionModel: String, CaseIterable, Identifiable, Sendable {
    case moonshineMedium = "moonshine-medium-streaming-en"
    case moonshineSmall = "moonshine-small-streaming-en"
    case whisperLarge = "openai_whisper-large-v3-v20240930_626MB"
    case whisperTurbo = "openai_whisper-large-v3-v20240930_turbo_632MB"
    case whisperDistil = "distil-whisper_distil-large-v3_594MB"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .moonshineMedium:
            return "Moonshine medium"
        case .moonshineSmall:
            return "Moonshine small"
        case .whisperLarge:
            return "Whisper large v3"
        case .whisperTurbo:
            return "Whisper turbo"
        case .whisperDistil:
            return "Distil Whisper"
        }
    }

    var isMoonshine: Bool {
        switch self {
        case .moonshineMedium, .moonshineSmall:
            return true
        case .whisperLarge, .whisperTurbo, .whisperDistil:
            return false
        }
    }

    var isWhisper: Bool { !isMoonshine }
}

enum LiveTranscriptionUpdate: Sendable {
    case reset
    case status(TranscriptionStatus)
    case progress(Double?)
    case entry(LiveTranscriptEntry)
    case replace(originalIDs: [String], with: LiveTranscriptEntry)
    case replaceRange(
        speaker: LiveTranscriptEntry.Speaker,
        start: Float,
        end: Float,
        with: [LiveTranscriptEntry]
    )
}
