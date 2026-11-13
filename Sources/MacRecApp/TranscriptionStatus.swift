import Foundation

enum TranscriptionStatus: Sendable, Equatable {
    case idle
    case loading(String)
    case ready
    case disabled
    case failed(String)
    case finished(String)

    var message: String {
        switch self {
        case .idle:
            return "Load a model to enable live transcription."
        case let .loading(message), let .failed(message), let .finished(message):
            return message
        case .ready:
            return "Ready to transcribe"
        case .disabled:
            return "Live transcription is off"
        }
    }

    var isReady: Bool {
        switch self {
        case .ready, .finished:
            return true
        default:
            return false
        }
    }

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}

enum RefinementStatus: Sendable, Equatable {
    case preparing
    case ready
    case working
    case unavailable(String)

    var notice: String? {
        switch self {
        case .preparing:
            return "Preparing transcript improvement…"
        case let .unavailable(message):
            return "Transcript improvement unavailable. \(message)"
        case .ready, .working:
            return nil
        }
    }
}
