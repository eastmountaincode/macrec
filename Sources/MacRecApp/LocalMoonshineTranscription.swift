@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import MacRecCore
@preconcurrency import MoonshineVoice

private struct MoonshineLinePayload: Sendable {
    let id: String
    let text: String
    let start: Float
    let end: Float
    let isComplete: Bool
    let audioData: [Float]?
}

extension LiveTranscriptionModel {
    var moonshineModelArch: ModelArch? {
        switch self {
        case .moonshineMedium:
            return .mediumStreaming
        case .moonshineSmall:
            return .smallStreaming
        case .whisperLarge, .whisperTurbo, .whisperDistil:
            return nil
        }
    }

    var moonshineDownloadURL: URL? {
        switch self {
        case .moonshineMedium:
            return URL(string: "https://download.moonshine.ai/model/medium-streaming-en/quantized")
        case .moonshineSmall:
            return URL(string: "https://download.moonshine.ai/model/small-streaming-en/quantized")
        case .whisperLarge, .whisperTurbo, .whisperDistil:
            return nil
        }
    }

    var moonshineComponents: [String] {
        [
            "adapter.ort",
            "cross_kv.ort",
            "decoder_kv.ort",
            "decoder_kv_with_attention.ort",
            "encoder.ort",
            "frontend.ort",
            "streaming_config.json",
            "tokenizer.bin",
        ]
    }
}

actor LocalMoonshineTranscriber {
    private let sampleRate: Int32 = 16_000
    private var loadedModel: LiveTranscriptionModel?
    private var transcriber: Transcriber?
    private var streams: [LiveTranscriptEntry.Speaker: MoonshineVoice.Stream] = [:]
    private var entries: [String: LiveTranscriptEntry] = [:]
    private var fileEntries: [String: LiveTranscriptEntry] = [:]
    private var isEnabled = false
    private var isStopping = false
    private var onUpdate: (@Sendable (LiveTranscriptionUpdate) -> Void)?
    private var onFinalAudio: (@Sendable (LiveTranscriptAudioSegment) -> Void)?
    private var submittedRefinementIDs: Set<String> = []

    func prepare(
        model: LiveTranscriptionModel,
        onUpdate: @escaping @Sendable (LiveTranscriptionUpdate) -> Void
    ) {
        self.isEnabled = true
        self.isStopping = false
        self.onUpdate = onUpdate
        onUpdate(.status(.loading("Preparing model…")))
        onUpdate(.progress(0))
        Task { _ = await self.ensureModelLoaded(model: model) }
    }

    func start(
        enabled: Bool,
        model: LiveTranscriptionModel,
        onUpdate: @escaping @Sendable (LiveTranscriptionUpdate) -> Void,
        onFinalAudio: (@Sendable (LiveTranscriptAudioSegment) -> Void)? = nil
    ) {
        self.isEnabled = enabled
        self.isStopping = false
        self.onUpdate = onUpdate
        self.onFinalAudio = onFinalAudio
        self.entries = [:]
        self.submittedRefinementIDs = []
        onUpdate(.reset)
        onUpdate(.progress(nil))

        guard enabled else {
            onUpdate(.status(.disabled))
            return
        }

        guard isReady(model: model), let transcriber else {
            onUpdate(.status(.idle))
            return
        }

        do {
            try closeStreams()
            streams[LiveTranscriptEntry.Speaker.me] = try makeStream(transcriber: transcriber, speaker: .me)
            streams[LiveTranscriptEntry.Speaker.call] = try makeStream(transcriber: transcriber, speaker: .call)
            try streams[LiveTranscriptEntry.Speaker.me]?.start()
            try streams[LiveTranscriptEntry.Speaker.call]?.start()
            onUpdate(.status(.ready))
        } catch {
            onUpdate(.status(.failed(error.localizedDescription)))
        }
    }

    func appendMicSampleBuffer(_ box: UncheckedSampleBuffer) {
        guard isEnabled, !isStopping else { return }
        guard let samples = LiveAudioConverter.floatSamples16kMono(from: box.value), !samples.isEmpty else { return }
        append(samples, speaker: .me)
    }

    func appendSystemSamples(_ samples: [Float]) {
        guard isEnabled, !isStopping, !samples.isEmpty else { return }
        append(samples, speaker: .call)
    }

    func stopAndWriteTranscript(to session: RecordingSession?) async {
        guard isEnabled else { return }
        isStopping = true
        do {
            try closeStreams()
            try? await Task.sleep(nanoseconds: 200_000_000)
        } catch {
            onUpdate?(.status(.failed(error.localizedDescription)))
        }

        guard let session, !entries.isEmpty else {
            onUpdate?(.status(.finished("No speech captured")))
            return
        }

        let text = renderTranscript(Array(entries.values))
        let url = session.directory.appendingPathComponent("\(session.fileStem)-live-transcript.txt")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            onUpdate?(.status(.finished("Transcript saved")))
        } catch {
            onUpdate?(.status(.failed("Could not save transcript: \(error.localizedDescription)")))
        }
    }

    func transcribeFile(
        inputURL: URL,
        outputDirectory: URL,
        model: LiveTranscriptionModel,
        onStatus: @escaping @Sendable (String, Double?) -> Void
    ) async throws -> URL {
        guard model.isMoonshine else {
            throw NSError(domain: "macrec", code: 50, userInfo: [NSLocalizedDescriptionKey: "File transcription currently supports Moonshine models."])
        }
        try Task.checkCancellation()

        self.onUpdate = { update in
            switch update {
            case let .status(message):
                onStatus(message.message, nil)
            case let .progress(value):
                onStatus("", value)
            case .reset, .entry, .replace, .replaceRange:
                break
            }
        }

        onStatus("Loading \(model.title)...", 0)
        guard await ensureModelLoaded(model: model), let transcriber else {
            throw NSError(domain: "macrec", code: 51, userInfo: [NSLocalizedDescriptionKey: "Could not load \(model.title)."])
        }
        try Task.checkCancellation()

        onStatus("Reading audio...", nil)
        let samples = try await FileAudioExtractor.floatSamples16kMono(from: inputURL)
        try Task.checkCancellation()
        guard !samples.isEmpty else {
            throw NSError(domain: "macrec", code: 52, userInfo: [NSLocalizedDescriptionKey: "No audio samples found in \(inputURL.lastPathComponent)."])
        }

        fileEntries = [:]
        let stream = try transcriber.createStream(updateInterval: 0.25)
        stream.addListener { [weak self] event in
            let line = event.line
            let payload = MoonshineLinePayload(
                id: "File-\(line.lineId)",
                text: line.text,
                start: line.startTime,
                end: line.startTime + line.duration,
                isComplete: line.isComplete,
                audioData: line.audioData
            )
            Task { await self?.handleFileLine(payload) }
        }

        try stream.start()
        var shouldCleanUpStream = true
        defer {
            if shouldCleanUpStream {
                try? stream.stop()
                stream.close()
            }
        }
        onStatus("Transcribing…", 0)
        let chunkSamples = Int(sampleRate)
        var offset = 0
        var chunksSubmitted = 0
        var lastReportedProgress = 0.0
        while offset < samples.count {
            try Task.checkCancellation()
            let end = min(samples.count, offset + chunkSamples)
            try stream.addAudio(Array(samples[offset..<end]), sampleRate: sampleRate)
            offset = end
            chunksSubmitted += 1

            let progress = min(1, Double(offset) / Double(samples.count))
            if progress == 1 || progress - lastReportedProgress >= 0.01 {
                lastReportedProgress = progress
                onStatus("Transcribing…", progress)
            }
            if chunksSubmitted.isMultiple(of: 10) {
                await Task.yield()
            }
        }
        onStatus("Finalizing transcript...", nil)
        try stream.stop()
        stream.close()
        shouldCleanUpStream = false
        try? await Task.sleep(nanoseconds: 300_000_000)
        try Task.checkCancellation()

        let transcript = renderFileTranscript(Array(fileEntries.values))
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NSError(domain: "macrec", code: 53, userInfo: [NSLocalizedDescriptionKey: "No transcript text captured."])
        }

        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let outputURL = TranscriptOutput.uniqueURL(for: inputURL, model: model, in: outputDirectory)
        try transcript.write(to: outputURL, atomically: true, encoding: .utf8)
        onStatus("Wrote transcript.", 1)
        return outputURL
    }

    private func isReady(model: LiveTranscriptionModel) -> Bool {
        transcriber != nil && loadedModel == model
    }

    @discardableResult
    private func ensureModelLoaded(model: LiveTranscriptionModel) async -> Bool {
        if isReady(model: model) {
            onUpdate?(.status(.ready))
            onUpdate?(.progress(nil))
            return true
        }

        guard let modelArch = model.moonshineModelArch else {
            onUpdate?(.status(.failed("Unsupported transcription model.")))
            onUpdate?(.progress(nil))
            return false
        }

        do {
            onUpdate?(.status(.loading("Preparing model…")))
            onUpdate?(.progress(0))
            let modelDirectory = try Self.modelDirectory(for: model)
            try await downloadMissingFiles(for: model, to: modelDirectory)

            onUpdate?(.status(.loading("Loading model…")))
            onUpdate?(.progress(nil))
            transcriber = try Transcriber(modelPath: modelDirectory.path, modelArch: modelArch)
            loadedModel = model
            onUpdate?(.status(.ready))
            onUpdate?(.progress(nil))
            return true
        } catch {
            transcriber = nil
            loadedModel = nil
            onUpdate?(.status(.failed(error.localizedDescription)))
            onUpdate?(.progress(nil))
            return false
        }
    }

    private func downloadMissingFiles(for model: LiveTranscriptionModel, to directory: URL) async throws {
        guard let baseURL = model.moonshineDownloadURL else {
            throw NSError(domain: "macrec", code: 40, userInfo: [NSLocalizedDescriptionKey: "No Moonshine download URL for \(model.title)."])
        }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let components = model.moonshineComponents
        for (index, component) in components.enumerated() {
            let destination = directory.appendingPathComponent(component)
            if FileManager.default.fileExists(atPath: destination.path) {
                onUpdate?(.progress(Double(index + 1) / Double(components.count)))
                continue
            }

            onUpdate?(.status(.loading("Downloading model…")))
            onUpdate?(.progress(Double(index) / Double(components.count)))
            let source = baseURL.appendingPathComponent(component)
            let (temporaryURL, response) = try await URLSession.shared.download(from: source)
            if let httpResponse = response as? HTTPURLResponse, !(200..<300).contains(httpResponse.statusCode) {
                throw NSError(domain: "macrec", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "Download failed for \(component)."])
            }
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: temporaryURL, to: destination)
            onUpdate?(.progress(Double(index + 1) / Double(components.count)))
        }
    }

    private func makeStream(transcriber: Transcriber, speaker: LiveTranscriptEntry.Speaker) throws -> MoonshineVoice.Stream {
        let stream = try transcriber.createStream(updateInterval: 0.5)
        stream.addListener { [weak self] event in
            let line = event.line
            let payload = MoonshineLinePayload(
                id: "\(speaker.storageKey)-\(line.lineId)",
                text: line.text,
                start: line.startTime,
                end: line.startTime + line.duration,
                isComplete: line.isComplete,
                audioData: line.audioData
            )
            Task { await self?.handleLine(payload, speaker: speaker) }
        }
        return stream
    }

    private func append(_ samples: [Float], speaker: LiveTranscriptEntry.Speaker) {
        guard let stream = streams[speaker] else { return }
        do {
            try stream.addAudio(samples, sampleRate: sampleRate)
        } catch {
            onUpdate?(.status(.failed(error.localizedDescription)))
        }
    }

    private func handleLine(_ line: MoonshineLinePayload, speaker: LiveTranscriptEntry.Speaker) {
        let text = Self.clean(line.text)
        guard !text.isEmpty else {
            if line.isComplete {
                entries.removeValue(forKey: line.id)
            }
            return
        }

        let entry = LiveTranscriptEntry(
            id: line.id,
            speaker: speaker,
            start: line.start,
            end: line.end,
            text: text,
            isFinal: line.isComplete
        )
        if entries[entry.id] != entry {
            entries[entry.id] = entry
            onUpdate?(.entry(entry))
        }

        if line.isComplete,
           !submittedRefinementIDs.contains(line.id),
           let audioData = line.audioData,
           !audioData.isEmpty {
            submittedRefinementIDs.insert(line.id)
            onFinalAudio?(LiveTranscriptAudioSegment(entry: entry, samples: audioData))
        }
    }

    private func handleFileLine(_ line: MoonshineLinePayload) {
        let text = Self.clean(line.text)
        guard !text.isEmpty else {
            if line.isComplete {
                fileEntries.removeValue(forKey: line.id)
            }
            return
        }

        let entry = LiveTranscriptEntry(
            id: line.id,
            speaker: .call,
            start: line.start,
            end: line.end,
            text: text,
            isFinal: line.isComplete
        )
        fileEntries[entry.id] = entry
    }

    private func closeStreams() throws {
        for stream in streams.values {
            if stream.isActive() {
                try stream.stop()
            }
            stream.close()
        }
        streams = [:]
    }

    private static func modelDirectory(for model: LiveTranscriptionModel) throws -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = appSupport
            .appendingPathComponent("MacRec", isDirectory: true)
            .appendingPathComponent("Moonshine", isDirectory: true)
            .appendingPathComponent(model.rawValue, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func renderTranscript(_ entries: [LiveTranscriptEntry]) -> String {
        TranscriptRenderer.renderLive(entries)
    }

    private func renderFileTranscript(_ entries: [LiveTranscriptEntry]) -> String {
        TranscriptRenderer.renderFile(entries)
    }

    private static func clean(_ text: String) -> String {
        text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func format(_ seconds: Float) -> String {
        let total = Int(seconds)
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}

enum FileAudioExtractor {
    static func floatSamples16kMono(from url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else {
            throw NSError(domain: "macrec", code: 60, userInfo: [NSLocalizedDescriptionKey: "No audio track found in \(url.lastPathComponent)."])
        }

        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw NSError(domain: "macrec", code: 61, userInfo: [NSLocalizedDescriptionKey: "Could not read audio from \(url.lastPathComponent)."])
        }
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? NSError(domain: "macrec", code: 62, userInfo: [NSLocalizedDescriptionKey: "Could not start reading \(url.lastPathComponent)."])
        }

        var samples: [Float] = []
        while let sampleBuffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            if let chunk = LiveAudioConverter.floatSamples16kMono(from: sampleBuffer) {
                samples.append(contentsOf: chunk)
            }
        }

        if reader.status == .failed {
            throw reader.error ?? NSError(domain: "macrec", code: 63, userInfo: [NSLocalizedDescriptionKey: "Could not finish reading \(url.lastPathComponent)."])
        }
        return samples
    }
}
