@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import MacRecCore
@preconcurrency import WhisperKit

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

    var loadPrompt: String {
        isMoonshine ? "Load Moonshine before recording." : "Load Whisper before recording."
    }

    var readyStatus: String {
        isMoonshine ? "Moonshine ready." : "Whisper ready."
    }
}

enum LiveTranscriptionUpdate: Sendable {
    case reset
    case status(String)
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

final class UncheckedSampleBuffer: @unchecked Sendable {
    let value: CMSampleBuffer

    init(_ value: CMSampleBuffer) {
        self.value = value
    }
}

private final class ConverterInputState: @unchecked Sendable {
    let input: AVAudioPCMBuffer
    var didProvideInput = false

    init(_ input: AVAudioPCMBuffer) {
        self.input = input
    }
}

actor LocalWhisperTranscriber {
    private struct SpeakerState {
        var samples: [Float] = []
        var absoluteStartSample = 0
        var nextTranscribeSample = 0
    }

    private let sampleRate = 16_000
    private let chunkSamples = 16_000 * 4
    private let minimumFinalSamples = 16_000 * 2
    private let silenceThreshold: Float = 0.004

    private var states: [LiveTranscriptEntry.Speaker: SpeakerState] = [
        .me: SpeakerState(),
        .call: SpeakerState(),
    ]
    private var pending: [LiveTranscriptEntry.Speaker] = []
    private var isProcessing = false
    private var isEnabled = false
    private var isStopping = false
    private var modelID = LiveTranscriptionModel.whisperLarge.rawValue
    private var loadedModelID: String?
    private var whisperKit: WhisperKit?
    private var entries: [LiveTranscriptEntry] = []
    private var onUpdate: (@Sendable (LiveTranscriptionUpdate) -> Void)?

    func prepare(
        modelID: String,
        onUpdate: @escaping @Sendable (LiveTranscriptionUpdate) -> Void
    ) {
        self.isEnabled = true
        self.isStopping = false
        self.modelID = modelID
        self.onUpdate = onUpdate
        onUpdate(.status("Preparing Whisper model..."))
        onUpdate(.progress(0))
        Task { _ = await self.ensureModelLoaded() }
    }

    func isReady(modelID: String) -> Bool {
        whisperKit != nil && loadedModelID == modelID
    }

    func start(
        enabled: Bool,
        modelID: String,
        onUpdate: @escaping @Sendable (LiveTranscriptionUpdate) -> Void
    ) {
        self.isEnabled = enabled
        self.isStopping = false
        self.modelID = modelID
        self.onUpdate = onUpdate
        self.states = [.me: SpeakerState(), .call: SpeakerState()]
        self.entries = []
        self.pending = []
        onUpdate(.reset)
        onUpdate(.progress(nil))

        guard enabled else {
            onUpdate(.status("Live transcript off"))
            onUpdate(.progress(nil))
            return
        }

        if isReady(modelID: modelID) {
            onUpdate(.status("Whisper ready."))
        } else {
            onUpdate(.status("Load Whisper before recording."))
        }
    }

    func appendMicSampleBuffer(_ box: UncheckedSampleBuffer) {
        guard isEnabled, !isStopping else { return }
        guard let samples = LiveAudioConverter.floatSamples16kMono(from: box.value), !samples.isEmpty else { return }
        append(samples, speaker: .me)
    }

    func appendSystemSample(_ sample: SystemAudioSample) {
        guard isEnabled, !isStopping else { return }
        guard let samples = LiveAudioConverter.floatSamples16kMono(from: sample), !samples.isEmpty else { return }
        append(samples, speaker: .call)
    }

    func stopAndWriteTranscript(to session: RecordingSession?) async {
        guard isEnabled else { return }
        isStopping = true
        queueFinalChunks()
        await processQueue()

        guard let session, !entries.isEmpty else {
            onUpdate?(.status("No transcript text captured."))
            return
        }

        let text = renderTranscript(entries)
        let url = session.directory.appendingPathComponent("\(session.fileStem)-live-transcript.txt")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            onUpdate?(.status("Wrote live transcript."))
        } catch {
            onUpdate?(.status("Could not write live transcript: \(error.localizedDescription)"))
        }
    }

    func transcribeFile(
        inputURL: URL,
        outputDirectory: URL,
        model: LiveTranscriptionModel,
        onStatus: @escaping @Sendable (String, Double?) -> Void
    ) async throws -> URL {
        guard model.isWhisper else {
            throw NSError(domain: "macrec", code: 70, userInfo: [NSLocalizedDescriptionKey: "Whisper file transcription requires a Whisper model."])
        }
        try Task.checkCancellation()

        self.modelID = model.rawValue
        self.onUpdate = { update in
            switch update {
            case let .status(message):
                onStatus(message, nil)
            case let .progress(value):
                onStatus("", value)
            case .reset, .entry, .replace, .replaceRange:
                break
            }
        }

        onStatus("Loading \(model.title)...", 0)
        guard await ensureModelLoaded(), let whisperKit else {
            throw NSError(domain: "macrec", code: 71, userInfo: [NSLocalizedDescriptionKey: "Could not load \(model.title)."])
        }
        try Task.checkCancellation()

        onStatus("Reading audio...", nil)
        let samples = try await FileAudioExtractor.floatSamples16kMono(from: inputURL)
        try Task.checkCancellation()
        guard !samples.isEmpty else {
            throw NSError(domain: "macrec", code: 72, userInfo: [NSLocalizedDescriptionKey: "No audio samples found in \(inputURL.lastPathComponent)."])
        }

        let chunkSamples = sampleRate * 30
        var offset = 0
        var fileEntries: [LiveTranscriptEntry] = []
        onStatus("Transcribing audio 0%...", 0)

        while offset < samples.count {
            try Task.checkCancellation()
            let end = min(samples.count, offset + chunkSamples)
            let chunk = Array(samples[offset..<end])
            let chunkStart = Float(offset) / Float(sampleRate)
            let chunkEnd = Float(end) / Float(sampleRate)

            if rms(chunk) >= silenceThreshold {
                let results = try await whisperKit.transcribe(
                    audioArray: chunk,
                    decodeOptions: fileDecodeOptions,
                    callback: { _ in
                        Task.isCancelled ? false : nil
                    }
                )
                try Task.checkCancellation()
                for segment in results.flatMap(\.segments) {
                    let text = Self.clean(segment.text)
                    guard !text.isEmpty else { continue }
                    fileEntries.append(
                        LiveTranscriptEntry(
                            speaker: .call,
                            start: chunkStart + segment.start,
                            end: min(chunkEnd, chunkStart + segment.end),
                            text: text
                        )
                    )
                }
            }

            offset = end
            let progress = min(1, Double(offset) / Double(samples.count))
            onStatus("Transcribing audio \(Int(progress * 100))%...", progress)
        }

        onStatus("Writing transcript...", nil)
        let transcript = renderFileTranscript(fileEntries)
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NSError(domain: "macrec", code: 73, userInfo: [NSLocalizedDescriptionKey: "No transcript text captured."])
        }

        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let outputURL = TranscriptOutput.uniqueURL(for: inputURL, model: model, in: outputDirectory)
        try transcript.write(to: outputURL, atomically: true, encoding: .utf8)
        onStatus("Wrote transcript.", 1)
        return outputURL
    }

    private func append(_ samples: [Float], speaker: LiveTranscriptEntry.Speaker) {
        var state = states[speaker] ?? SpeakerState()
        state.samples.append(contentsOf: samples)
        states[speaker] = state

        let available = state.absoluteStartSample + state.samples.count - state.nextTranscribeSample
        if available >= chunkSamples {
            enqueue(speaker)
        }
    }

    private func enqueue(_ speaker: LiveTranscriptEntry.Speaker, startProcessing: Bool = true) {
        if !pending.contains(speaker) {
            pending.append(speaker)
        }
        if startProcessing {
            Task { await self.processQueue() }
        }
    }

    private func queueFinalChunks() {
        for speaker in [LiveTranscriptEntry.Speaker.me, .call] {
            guard let state = states[speaker] else { continue }
            let available = state.absoluteStartSample + state.samples.count - state.nextTranscribeSample
            if available >= minimumFinalSamples {
                enqueue(speaker, startProcessing: false)
            }
        }
    }

    private func processQueue() async {
        guard !isProcessing else { return }
        isProcessing = true
        defer { isProcessing = false }

        guard await ensureModelLoaded() else { return }

        while !pending.isEmpty {
            let speaker = pending.removeFirst()
            guard let chunk = takeChunk(for: speaker) else { continue }
            guard rms(chunk.samples) >= silenceThreshold else { continue }
            await transcribe(chunk, speaker: speaker)
        }
    }

    @discardableResult
    private func ensureModelLoaded() async -> Bool {
        if whisperKit != nil, loadedModelID == modelID {
            onUpdate?(.status("Whisper ready."))
            onUpdate?(.progress(nil))
            return true
        }

        do {
            onUpdate?(.status("Checking Whisper model cache..."))
            onUpdate?(.progress(0))
            let cacheDirectory = try Self.modelCacheDirectory()
            onUpdate?(.status("Preparing Whisper model files..."))
            let modelFolder = try await WhisperKit.download(variant: modelID, downloadBase: cacheDirectory) { [onUpdate] progress in
                let fraction = progress.fractionCompleted
                guard fraction.isFinite else {
                    onUpdate?(.progress(nil))
                    return
                }
                onUpdate?(.progress(min(1, max(0, fraction))))
            }

            onUpdate?(.status("Warming up Whisper locally..."))
            onUpdate?(.progress(nil))
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
            loadedModelID = modelID
            onUpdate?(.status("Whisper ready."))
            onUpdate?(.progress(nil))
            return true
        } catch {
            onUpdate?(.status("Whisper failed: \(error.localizedDescription)"))
            onUpdate?(.progress(nil))
            whisperKit = nil
            loadedModelID = nil
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

    private func takeChunk(for speaker: LiveTranscriptEntry.Speaker) -> (samples: [Float], start: Float, end: Float)? {
        guard var state = states[speaker] else { return nil }

        let absoluteEnd = state.absoluteStartSample + state.samples.count
        let available = absoluteEnd - state.nextTranscribeSample
        guard available >= minimumFinalSamples else { return nil }

        let chunkEnd = isStopping ? absoluteEnd : min(absoluteEnd, state.nextTranscribeSample + chunkSamples)
        let localStart = max(0, state.nextTranscribeSample - state.absoluteStartSample)
        let localEnd = max(localStart, chunkEnd - state.absoluteStartSample)
        guard localEnd <= state.samples.count else { return nil }

        let samples = Array(state.samples[localStart..<localEnd])
        let start = Float(state.nextTranscribeSample) / Float(sampleRate)
        let end = Float(chunkEnd) / Float(sampleRate)
        state.nextTranscribeSample = chunkEnd

        if localEnd > 0 {
            state.samples.removeFirst(localEnd)
            state.absoluteStartSample = chunkEnd
        }

        states[speaker] = state
        return (samples, start, end)
    }

    private func transcribe(_ chunk: (samples: [Float], start: Float, end: Float), speaker: LiveTranscriptEntry.Speaker) async {
        guard let whisperKit else { return }

        let options = liveDecodeOptions

        do {
            let results = try await whisperKit.transcribe(audioArray: chunk.samples, decodeOptions: options)
            let text = Self.clean(results.map(\.text).joined(separator: " "))
            guard shouldAccept(text, speaker: speaker) else { return }

            let words = results
                .flatMap(\.segments)
                .flatMap { $0.words ?? [] }
                .sorted { $0.start < $1.start }
                .compactMap { word -> LiveTranscriptWord? in
                    let text = word.word.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return nil }
                    return LiveTranscriptWord(
                        text: text,
                        start: chunk.start + word.start,
                        end: chunk.start + word.end
                    )
                }

            let entry = LiveTranscriptEntry(
                speaker: speaker,
                start: chunk.start,
                end: chunk.end,
                text: text,
                words: words
            )
            entries.append(entry)
            entries.sort { $0.start < $1.start }
            onUpdate?(.entry(entry))
        } catch {
            onUpdate?(.status("Whisper transcription failed: \(error.localizedDescription)"))
        }
    }

    private var liveDecodeOptions: DecodingOptions {
        DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: "en",
            temperature: 0,
            temperatureIncrementOnFallback: 0.2,
            temperatureFallbackCount: 2,
            usePrefillPrompt: true,
            skipSpecialTokens: true,
            withoutTimestamps: false,
            wordTimestamps: true,
            compressionRatioThreshold: 1.8,
            logProbThreshold: -1.0,
            firstTokenLogProbThreshold: -1.5,
            noSpeechThreshold: 0.6,
            concurrentWorkerCount: 1
        )
    }

    private var fileDecodeOptions: DecodingOptions {
        DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: "en",
            temperature: 0,
            temperatureIncrementOnFallback: 0.2,
            temperatureFallbackCount: 2,
            usePrefillPrompt: true,
            skipSpecialTokens: true,
            withoutTimestamps: false,
            wordTimestamps: false,
            compressionRatioThreshold: 1.8,
            logProbThreshold: -1.0,
            firstTokenLogProbThreshold: -1.5,
            noSpeechThreshold: 0.6,
            concurrentWorkerCount: 1,
            chunkingStrategy: ChunkingStrategy.none
        )
    }

    private func shouldAccept(_ text: String, speaker: LiveTranscriptEntry.Speaker) -> Bool {
        guard !text.isEmpty else { return false }
        let normalized = Self.normalized(text)
        guard normalized.count >= 3 else { return false }

        if let previous = entries.last(where: { $0.speaker == speaker }),
           Self.normalized(previous.text) == normalized {
            return false
        }
        return true
    }

    private func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sum = samples.reduce(Float(0)) { partial, sample in
            partial + sample * sample
        }
        return sqrt(sum / Float(samples.count))
    }

    private func renderTranscript(_ entries: [LiveTranscriptEntry]) -> String {
        TranscriptRenderer.renderLive(entries)
    }

    private func renderFileTranscript(_ entries: [LiveTranscriptEntry]) -> String {
        TranscriptRenderer.renderFile(entries)
    }

    private static func clean(_ text: String) -> String {
        let collapsed = text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapseRepeatedPrefix(collapsed)
    }

    private static func collapseRepeatedPrefix(_ text: String) -> String {
        let words = text.split(separator: " ").map(String.init)
        guard words.count >= 8 else { return text }
        let normalizedWords = normalized(text).split(separator: " ").map(String.init)

        for size in 1...min(12, normalizedWords.count / 3) {
            let phrase = Array(normalizedWords.prefix(size))
            var index = 0
            var repeats = 0
            while index + size <= normalizedWords.count,
                  Array(normalizedWords[index..<(index + size)]) == phrase {
                repeats += 1
                index += size
            }
            if repeats >= 3, Float(index) / Float(normalizedWords.count) >= 0.8 {
                return words.prefix(size).joined(separator: " ")
            }
        }

        return text
    }

    private static func normalized(_ text: String) -> String {
        text
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9\s]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func format(_ seconds: Float) -> String {
        let total = Int(seconds)
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}

enum LiveAudioConverter {
    static func floatSamples16kMono(from sampleBuffer: CMSampleBuffer) -> [Float]? {
        guard let buffer = makePCMBuffer(from: sampleBuffer) else { return nil }
        return convert(buffer)
    }

    static func floatSamples16kMono(from sample: SystemAudioSample) -> [Float]? {
        guard let buffer = makePCMBuffer(from: sample) else { return nil }
        return convert(buffer)
    }

    private static func convert(_ input: AVAudioPCMBuffer) -> [Float]? {
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else {
            return nil
        }

        guard input.format.sampleRate != outputFormat.sampleRate
            || input.format.channelCount != outputFormat.channelCount
            || input.format.commonFormat != outputFormat.commonFormat
            || input.format.isInterleaved != outputFormat.isInterleaved else {
            return samples(from: input)
        }

        guard let converter = AVAudioConverter(from: input.format, to: outputFormat) else { return nil }
        let ratio = outputFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(max(1, ceil(Double(input.frameLength) * ratio) + 8))
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }

        let inputState = ConverterInputState(input)
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if inputState.didProvideInput {
                status.pointee = .noDataNow
                return nil
            }
            inputState.didProvideInput = true
            status.pointee = .haveData
            return inputState.input
        }
        guard error == nil else { return nil }
        return samples(from: output)
    }

    private static func samples(from buffer: AVAudioPCMBuffer) -> [Float]? {
        guard let channel = buffer.floatChannelData?[0] else { return nil }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }

    private static func makePCMBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescriptionPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return nil
        }

        var streamDescription = streamDescriptionPointer.pointee
        guard let format = AVAudioFormat(streamDescription: &streamDescription) else { return nil }
        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
        buffer.frameLength = frameCount

        var bufferListSize = 0
        var status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &bufferListSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: nil
        )
        guard status == noErr, bufferListSize > 0 else { return nil }

        let rawBufferList = UnsafeMutableRawPointer.allocate(
            byteCount: bufferListSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawBufferList.deallocate() }

        let sourceBufferList = rawBufferList.bindMemory(to: AudioBufferList.self, capacity: 1)
        var blockBuffer: CMBlockBuffer?
        status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: sourceBufferList,
            bufferListSize: bufferListSize,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else { return nil }

        copy(sourceBufferList, to: buffer.mutableAudioBufferList)
        return buffer
    }

    private static func makePCMBuffer(from sample: SystemAudioSample) -> AVAudioPCMBuffer? {
        var sourceFormat = sample.format
        guard let format = AVAudioFormat(streamDescription: &sourceFormat),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: sample.frameCount) else {
            return nil
        }
        buffer.frameLength = sample.frameCount

        let destinationBuffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        for (index, data) in sample.buffers.enumerated() where index < destinationBuffers.count {
            guard let destination = destinationBuffers[index].mData else { continue }
            data.withUnsafeBytes { rawBuffer in
                guard let source = rawBuffer.baseAddress else { return }
                memcpy(destination, source, min(Int(destinationBuffers[index].mDataByteSize), data.count))
            }
        }
        return buffer
    }

    private static func copy(_ sourceBufferList: UnsafeMutablePointer<AudioBufferList>, to destinationBufferList: UnsafeMutablePointer<AudioBufferList>) {
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(sourceBufferList)
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(destinationBufferList)
        for (index, sourceBuffer) in sourceBuffers.enumerated() where index < destinationBuffers.count {
            guard let source = sourceBuffer.mData, let destination = destinationBuffers[index].mData else { continue }
            memcpy(destination, source, min(Int(sourceBuffer.mDataByteSize), Int(destinationBuffers[index].mDataByteSize)))
        }
    }
}
