import Foundation
import MacRecCore
import WhisperKit

actor LiveTranscriptRefiner {
    private struct BatchSlice: Sendable {
        let audioStart: Float
        let audioEnd: Float
        let meetingStart: Float
        let meetingEnd: Float
    }

    private struct Batch: Sendable {
        let originalIDs: [String]
        let speaker: LiveTranscriptEntry.Speaker
        let start: Float
        let end: Float
        let samples: [Float]
        let originalText: String
        let slices: [BatchSlice]
    }

    private struct CoverageBatch: Sendable {
        let start: Float
        let end: Float
        let samples: [Float]
    }

    private let sampleRate = 16_000
    private let coverageWindowSeconds = 30
    private let minimumCoverageSeconds: Float = 2.5
    private let modelID = LiveTranscriptionModel.whisperLarge.rawValue
    private var whisperKit: WhisperKit?
    private var isLoadingModel = false
    private var isEnabled = false
    private var isStopping = false
    private var isProcessing = false
    private var pending: [LiveTranscriptEntry.Speaker: [LiveTranscriptAudioSegment]] = [:]
    private var flushTasks: [LiveTranscriptEntry.Speaker: Task<Void, Never>] = [:]
    private var queue: [Batch] = []
    private var coverageQueue: [CoverageBatch] = []
    private var coverageSamples: [Float] = []
    private var coverageStartSample = 0
    private var onUpdate: (@Sendable (LiveTranscriptionUpdate) async -> Void)?
    private var onStatus: (@Sendable (String) -> Void)?
    private var refinedBatchCount = 0
    private var checkedBatchCount = 0
    private var checkedCoverageCount = 0
    private var quietBatchCount = 0
    private var rejectedBatchCount = 0

    func prepare(onStatus: @escaping @Sendable (String) -> Void) async {
        self.onStatus = onStatus
        guard whisperKit == nil else {
            onStatus("Accuracy refinement ready.")
            return
        }
        _ = await ensureModelLoaded()
    }

    func start(
        enabled: Bool,
        onUpdate: @escaping @Sendable (LiveTranscriptionUpdate) async -> Void,
        onStatus: @escaping @Sendable (String) -> Void
    ) {
        flushTasks.values.forEach { $0.cancel() }
        flushTasks = [:]
        pending = [:]
        queue = []
        coverageQueue = []
        coverageSamples = []
        coverageStartSample = 0
        self.onUpdate = onUpdate
        self.onStatus = onStatus
        self.isEnabled = enabled
        self.isStopping = false
        self.refinedBatchCount = 0
        self.checkedBatchCount = 0
        self.checkedCoverageCount = 0
        self.quietBatchCount = 0
        self.rejectedBatchCount = 0
        onStatus(enabled ? (whisperKit == nil ? "Accuracy refinement is warming up..." : "Accuracy refinement ready.") : "Accuracy refinement off.")
    }

    func enqueue(_ segment: LiveTranscriptAudioSegment) {
        guard isEnabled, !isStopping else { return }
        // Call audio is covered independently below, including speech Moonshine
        // never recognized. Keep line-based refinement for the microphone track.
        guard segment.entry.speaker == .me else { return }
        guard segment.samples.count >= sampleRate / 2 else { return }

        let speaker = segment.entry.speaker
        pending[speaker, default: []].append(segment)
        flushTasks[speaker]?.cancel()

        let duration = pending[speaker, default: []].reduce(0) { $0 + $1.samples.count } / sampleRate
        if duration >= 10 || pending[speaker, default: []].count >= 5 {
            flush(speaker: speaker)
        } else {
            flushTasks[speaker] = Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                await self?.flushAfterPause(speaker: speaker)
            }
        }
    }

    func appendSystemSample(_ sample: SystemAudioSample) {
        guard isEnabled, !isStopping else { return }
        guard let samples = LiveAudioConverter.floatSamples16kMono(from: sample), !samples.isEmpty else { return }
        coverageSamples.append(contentsOf: samples)

        let windowSamples = sampleRate * coverageWindowSeconds
        var didEnqueue = false
        while coverageSamples.count >= windowSamples {
            let startSample = coverageStartSample
            let endSample = startSample + windowSamples
            coverageQueue.append(
                CoverageBatch(
                    start: Float(startSample) / Float(sampleRate),
                    end: Float(endSample) / Float(sampleRate),
                    samples: Array(coverageSamples.prefix(windowSamples))
                )
            )
            coverageSamples.removeFirst(windowSamples)
            coverageStartSample = endSample
            didEnqueue = true
        }

        if didEnqueue {
            Task { await self.processQueue() }
        }
    }

    func stop() async {
        guard isEnabled else { return }
        isStopping = true
        flushTasks.values.forEach { $0.cancel() }
        flushTasks = [:]
        for speaker in Array(pending.keys) {
            flush(speaker: speaker)
        }
        flushCoverageRemainder()

        await processQueue()
        while isProcessing {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if whisperKit == nil {
            queue = []
            coverageQueue = []
            onStatus?("Accuracy refinement was not ready; saved the live transcript.")
        }
        isEnabled = false
    }

    func reset() {
        flushTasks.values.forEach { $0.cancel() }
        flushTasks = [:]
        pending = [:]
        queue = []
        coverageQueue = []
        coverageSamples = []
        coverageStartSample = 0
        isEnabled = false
        isStopping = false
        isProcessing = false
    }

    private func flushAfterPause(speaker: LiveTranscriptEntry.Speaker) async {
        flushTasks[speaker] = nil
        flush(speaker: speaker)
    }

    private func flush(speaker: LiveTranscriptEntry.Speaker) {
        flushTasks[speaker]?.cancel()
        flushTasks[speaker] = nil
        guard let segments = pending.removeValue(forKey: speaker), !segments.isEmpty else { return }

        let ordered = segments.sorted { $0.entry.start < $1.entry.start }
        var samples: [Float] = []
        var slices: [BatchSlice] = []
        var previousEnd: Float?
        for segment in ordered {
            if let previousEnd {
                let gap = max(0, min(0.75, segment.entry.start - previousEnd))
                samples.append(contentsOf: repeatElement(0, count: Int(gap * Float(sampleRate))))
            }
            let audioStart = Float(samples.count) / Float(sampleRate)
            samples.append(contentsOf: segment.samples)
            let audioEnd = Float(samples.count) / Float(sampleRate)
            slices.append(
                BatchSlice(
                    audioStart: audioStart,
                    audioEnd: audioEnd,
                    meetingStart: segment.entry.start,
                    meetingEnd: segment.entry.end
                )
            )
            previousEnd = segment.entry.end
        }

        let audioDuration = Float(samples.count) / Float(sampleRate)
        let minimumDuration: Float = isStopping ? 2.5 : 8
        guard audioDuration >= minimumDuration else {
            // During the meeting, hold short utterances until Whisper has enough
            // acoustic context to avoid trimming or inventing boundary words.
            if !isStopping {
                pending[speaker] = ordered
            }
            return
        }

        queue.append(
            Batch(
                originalIDs: ordered.map { $0.entry.id },
                speaker: speaker,
                start: ordered.first?.entry.start ?? 0,
                end: ordered.last?.entry.end ?? 0,
                samples: samples,
                originalText: ordered.map { $0.entry.text }.joined(separator: " "),
                slices: slices
            )
        )
        Task { await self.processQueue() }
    }

    private func flushCoverageRemainder() {
        let minimumSamples = Int(Float(sampleRate) * minimumCoverageSeconds)
        guard coverageSamples.count >= minimumSamples else {
            coverageSamples = []
            return
        }

        let startSample = coverageStartSample
        let endSample = startSample + coverageSamples.count
        coverageQueue.append(
            CoverageBatch(
                start: Float(startSample) / Float(sampleRate),
                end: Float(endSample) / Float(sampleRate),
                samples: coverageSamples
            )
        )
        coverageSamples = []
        coverageStartSample = endSample
    }

    private func processQueue() async {
        guard !isProcessing else { return }
        isProcessing = true
        defer { isProcessing = false }

        guard await ensureModelLoaded(), let whisperKit else { return }

        while !coverageQueue.isEmpty || !queue.isEmpty {
            if !coverageQueue.isEmpty {
                let batch = coverageQueue.removeFirst()
                await processCoverageBatch(batch, using: whisperKit)
                continue
            }

            let batch = queue.removeFirst()
            checkedBatchCount += 1
            let level = Self.rms(batch.samples)
            guard level >= 0.0005 else {
                quietBatchCount += 1
                Self.logDiagnostic(batch: batch, refined: "", level: level, decision: "quiet")
                continue
            }
            onStatus?("Refining recent speech...")

            let options = DecodingOptions(
                verbose: false,
                task: .transcribe,
                language: "en",
                temperature: 0,
                temperatureIncrementOnFallback: 0.2,
                temperatureFallbackCount: 5,
                usePrefillPrompt: true,
                skipSpecialTokens: true,
                withoutTimestamps: false,
                wordTimestamps: true,
                compressionRatioThreshold: 2.4,
                logProbThreshold: -1.0,
                firstTokenLogProbThreshold: -1.5,
                noSpeechThreshold: 0.6,
                chunkingStrategy: ChunkingStrategy.none
            )
            do {
                let results = try await whisperKit.transcribe(audioArray: batch.samples, decodeOptions: options)
                let text = Self.clean(
                    results
                        .flatMap(\.segments)
                        .sorted { $0.start < $1.start }
                        .map(\.text)
                        .joined(separator: " ")
                )
                guard Self.shouldUse(refined: text, insteadOf: batch.originalText) else {
                    rejectedBatchCount += 1
                    Self.logDiagnostic(batch: batch, refined: text, level: level, decision: "rejected")
                    continue
                }

                let changedText = Self.normalized(text) != Self.normalized(batch.originalText)

                let words = results
                    .flatMap(\.segments)
                    .flatMap { $0.words ?? [] }
                    .sorted { $0.start < $1.start }
                    .compactMap { word -> LiveTranscriptWord? in
                        guard let start = Self.meetingTime(for: word.start, slices: batch.slices),
                              let end = Self.meetingTime(for: word.end, slices: batch.slices) else {
                            return nil
                        }
                        let cleanedWord = word.word.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !cleanedWord.isEmpty else { return nil }
                        return LiveTranscriptWord(text: cleanedWord, start: start, end: max(start, end))
                    }

                let entry = LiveTranscriptEntry(
                    id: "refined-\(batch.originalIDs.first ?? UUID().uuidString)",
                    speaker: batch.speaker,
                    start: batch.start,
                    end: batch.end,
                    text: text,
                    isFinal: true,
                    isRefined: true,
                    words: words
                )
                await onUpdate?(.replace(originalIDs: batch.originalIDs, with: entry))
                if changedText {
                    refinedBatchCount += 1
                }
                Self.logDiagnostic(batch: batch, refined: text, level: level, decision: changedText ? "replaced" : "aligned")
            } catch {
                onStatus?("Accuracy refinement will continue: \(error.localizedDescription)")
            }
        }

        if isEnabled {
            if checkedCoverageCount > 0 {
                let windows = checkedCoverageCount == 1 ? "1 call window" : "\(checkedCoverageCount) call windows"
                let improved = refinedBatchCount == 1 ? "1 mic passage improved" : "\(refinedBatchCount) mic passages improved"
                onStatus?("Whisper checked \(windows); \(improved).")
            } else {
                let checked = checkedBatchCount == 1 ? "1 passage" : "\(checkedBatchCount) passages"
                let improved = refinedBatchCount == 1 ? "1 improved" : "\(refinedBatchCount) improved"
                onStatus?("Accuracy refinement checked \(checked); \(improved).")
            }
        }
    }

    private func processCoverageBatch(_ batch: CoverageBatch, using whisperKit: WhisperKit) async {
        checkedCoverageCount += 1
        let level = Self.rms(batch.samples)
        guard level >= 0.0005 else { return }
        onStatus?("Checking recent call audio for missed speech...")

        let options = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: "en",
            temperature: 0,
            temperatureIncrementOnFallback: 0.2,
            temperatureFallbackCount: 5,
            usePrefillPrompt: true,
            skipSpecialTokens: true,
            withoutTimestamps: false,
            wordTimestamps: true,
            compressionRatioThreshold: 2.4,
            logProbThreshold: -1.0,
            firstTokenLogProbThreshold: -1.5,
            noSpeechThreshold: 0.6,
            chunkingStrategy: ChunkingStrategy.none
        )

        do {
            let results = try await whisperKit.transcribe(audioArray: batch.samples, decodeOptions: options)
            let segments = results
                .flatMap(\.segments)
                .sorted { $0.start < $1.start }
            let completeText = Self.clean(segments.map(\.text).joined(separator: " "))
            guard !completeText.isEmpty, !Self.hasExcessiveRepetition(completeText) else { return }

            let duration = max(0, batch.end - batch.start)
            let entries = segments.enumerated().compactMap { index, segment -> LiveTranscriptEntry? in
                let text = Self.clean(segment.text)
                guard !text.isEmpty else { return nil }

                let relativeStart = min(duration, max(0, segment.start))
                let relativeEnd = min(duration, max(relativeStart, segment.end))
                let start = batch.start + relativeStart
                let end = batch.start + relativeEnd
                let words = (segment.words ?? []).compactMap { word -> LiveTranscriptWord? in
                    let text = word.word.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return nil }
                    let wordStart = batch.start + min(duration, max(0, word.start))
                    let wordEnd = batch.start + min(duration, max(word.start, word.end))
                    return LiveTranscriptWord(text: text, start: wordStart, end: max(wordStart, wordEnd))
                }

                return LiveTranscriptEntry(
                    id: "coverage-\(Int(batch.start * 1_000))-\(index)",
                    speaker: .call,
                    start: start,
                    end: max(start, end),
                    text: text,
                    isFinal: true,
                    isRefined: true,
                    words: words
                )
            }
            guard !entries.isEmpty else { return }
            await onUpdate?(
                .replaceRange(
                    speaker: .call,
                    start: batch.start,
                    end: batch.end,
                    with: entries
                )
            )
        } catch {
            onStatus?("Call-audio coverage will continue: \(error.localizedDescription)")
        }
    }

    private func ensureModelLoaded() async -> Bool {
        if whisperKit != nil { return true }
        if isLoadingModel {
            while isLoadingModel {
                try? await Task.sleep(for: .milliseconds(100))
            }
            return whisperKit != nil
        }

        isLoadingModel = true
        defer { isLoadingModel = false }
        do {
            onStatus?("Preparing Whisper large v3 for accuracy refinement...")
            let cacheDirectory = try Self.modelCacheDirectory()
            let modelFolder = try await WhisperKit.download(
                variant: modelID,
                downloadBase: cacheDirectory
            ) { [onStatus] progress in
                let percent = Int(min(1, max(0, progress.fractionCompleted)) * 100)
                onStatus?("Preparing accuracy refinement \(percent)%...")
            }
            let config = WhisperKitConfig(
                modelFolder: modelFolder.path,
                tokenizerFolder: cacheDirectory,
                verbose: false,
                logLevel: .error,
                prewarm: false,
                load: true,
                download: false,
                useBackgroundDownloadSession: false
            )
            whisperKit = try await WhisperKit(config)
            onStatus?("Accuracy refinement ready.")
            return true
        } catch {
            whisperKit = nil
            onStatus?("Accuracy refinement unavailable: \(error.localizedDescription)")
            return false
        }
    }

    private static func modelCacheDirectory() throws -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = appSupport
            .appendingPathComponent("MacRec", isDirectory: true)
            .appendingPathComponent("WhisperKit", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func shouldUse(refined: String, insteadOf original: String) -> Bool {
        let refinedWords = refined.split(whereSeparator: \.isWhitespace)
        let originalWords = original.split(whereSeparator: \.isWhitespace)
        guard refinedWords.count >= 2, !hasExcessiveRepetition(refined) else { return false }
        guard originalWords.isEmpty || Double(refinedWords.count) >= Double(originalWords.count) * 0.45 else { return false }
        return true
    }

    private static func hasExcessiveRepetition(_ text: String) -> Bool {
        let words = normalized(text).split(separator: " ").map(String.init)
        guard words.count >= 12 else { return false }
        for size in 2...min(10, words.count / 4) {
            for start in 0...(words.count - size * 4) {
                let phrase = Array(words[start..<(start + size)])
                var repeats = 1
                var index = start + size
                while index + size <= words.count,
                      Array(words[index..<(index + size)]) == phrase {
                    repeats += 1
                    index += size
                }
                if repeats >= 4 { return true }
            }
        }
        return false
    }

    private static func clean(_ text: String) -> String {
        text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func meetingTime(for audioTime: Float, slices: [BatchSlice]) -> Float? {
        guard !slices.isEmpty else { return nil }
        let slice = slices.first { audioTime >= $0.audioStart - 0.05 && audioTime <= $0.audioEnd + 0.05 }
            ?? slices.min { lhs, rhs in
                distance(from: audioTime, to: lhs) < distance(from: audioTime, to: rhs)
            }
        guard let slice else { return nil }
        let audioDuration = max(0.001, slice.audioEnd - slice.audioStart)
        let progress = min(1, max(0, (audioTime - slice.audioStart) / audioDuration))
        return slice.meetingStart + progress * max(0, slice.meetingEnd - slice.meetingStart)
    }

    private static func distance(from time: Float, to slice: BatchSlice) -> Float {
        if time < slice.audioStart { return slice.audioStart - time }
        if time > slice.audioEnd { return time - slice.audioEnd }
        return 0
    }

    private static func normalized(_ text: String) -> String {
        text
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9\s]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sum = samples.reduce(Float(0)) { $0 + $1 * $1 }
        return sqrt(sum / Float(samples.count))
    }

    private static func logDiagnostic(
        batch: Batch,
        refined: String,
        level: Float,
        decision: String
    ) {
        guard ProcessInfo.processInfo.environment["MACREC_REFINER_DIAGNOSTICS"] == "1" else { return }
        let originalWords = batch.originalText.split(whereSeparator: \.isWhitespace).count
        let refinedWords = refined.split(whereSeparator: \.isWhitespace).count
        let duration = Float(batch.samples.count) / 16_000
        let durationText = String(format: "%.2f", duration)
        let levelText = String(format: "%.6f", level)
        let message = "[MacRec refiner] \(decision) duration=\(durationText) rms=\(levelText) originalWords=\(originalWords) refinedWords=\(refinedWords)\nORIGINAL: \(batch.originalText)\nREFINED: \(refined)\n"
        FileHandle.standardError.write(Data(message.utf8))
    }
}
