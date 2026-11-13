import Foundation

enum TranscriptOutput {
    static func uniqueURL(for inputURL: URL, model: LiveTranscriptionModel, in outputDirectory: URL) -> URL {
        let base = inputURL.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: #"[^\w\-. ]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let stem = base.isEmpty ? "audio" : base
        let modelStem = model.title
            .lowercased()
            .replacingOccurrences(of: #"[^\w\-. ]+"#, with: "-", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-. "))

        var candidate = outputDirectory.appendingPathComponent("\(stem)-\(modelStem)-transcript.txt")
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = outputDirectory.appendingPathComponent("\(stem)-\(modelStem)-transcript-\(index).txt")
            index += 1
        }
        return candidate
    }
}
