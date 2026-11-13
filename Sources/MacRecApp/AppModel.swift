import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MacRecCore

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var isRecording = false
    @Published var isStartingRecording = false
    @Published var isStoppingRecording = false
    @Published private(set) var recordingStartedAt: Date?
    @Published var currentSessionDir: URL?
    @Published var lastError: String?
    @Published private(set) var monitoringError: String?
    @Published var title: String = ""
    @Published var outputDir: URL = AppModel.defaultOutputDir()
    @Published var selectedMicID: String?
    @Published var inputs: [AudioInputDevice] = []
    @Published var recents: [URL] = []
    @Published var micGainDecibels: Double = 0
    @Published var systemGainDecibels: Double = 0
    @Published var liveTranscriptionEnabled = true
    @Published var transcriptionModel: LiveTranscriptionModel = .moonshineMedium
    @Published private(set) var transcriptStatus: TranscriptionStatus = .idle
    @Published var transcriptProgress: Double?
    let liveTranscript = LiveTranscriptState()
    @Published private(set) var refinementStatus: RefinementStatus = .preparing

    var isTranscriberReady: Bool { transcriptStatus.isReady }
    var isTranscriberLoading: Bool { transcriptStatus.isLoading }
    var isSessionActive: Bool { isRecording || isStartingRecording || isStoppingRecording }
    var canTranscribeFile: Bool { !isSessionActive && !isTranscriberLoading && !isFileTranscribing }
    @Published var fileInputURL: URL?
    @Published var fileTranscriptionModel: LiveTranscriptionModel = .moonshineMedium
    @Published var fileTranscriptionStatus: String = "Drop an audio or video file."
    @Published var fileTranscriptionProgress: Double?
    @Published var fileTranscriptionElapsed: TimeInterval = 0
    @Published var fileTranscriptionRemaining: TimeInterval?
    @Published var isFileTranscribing = false
    @Published var fileTranscriptURL: URL?

    private let recorder = Recorder()
    private let monitor = AudioMonitor()
    let audioMeters = AudioMeterState()
    private let audioMeterThrottle = AudioMeterThrottle(updatesPerSecond: 30)
    private let whisperTranscriber = LocalWhisperTranscriber()
    private let moonshineTranscriber = LocalMoonshineTranscriber()
    private let transcriptRefiner = LiveTranscriptRefiner()
    private var sourceTranscriptEntries: [LiveTranscriptEntry] = []
    private var coveredCallRanges: [TranscriptCoverageRange] = []
    private var transcriptPublishTask: Task<Void, Never>?
    private var micTranscriptionContinuation: AsyncStream<UncheckedSampleBuffer>.Continuation?
    private var micTranscriptionTask: Task<Void, Never>?
    private var systemTranscriptionContinuation: AsyncStream<SystemAudioSample>.Continuation?
    private var systemTranscriptionTask: Task<Void, Never>?
    private var transcriberLoadID: UUID?
    private var fileTranscriptionTask: Task<Void, Never>?
    private var fileTranscriptionID: UUID?
    private var fileTranscriptionStartedAt: Date?
    private var fileTranscriptionTimer: Timer?

    init(startServices: Bool = true) {
        guard startServices else { return }
        refreshInputs()
        refreshRecents()
        Task {
            await startMonitoring()
            prepareTranscriber()
        }
    }

    static func defaultOutputDir() -> URL {
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!
        return desktop.appendingPathComponent("macrec", isDirectory: true)
    }

    func refreshInputs() {
        inputs = AudioDevices.availableInputs()
        if selectedMicID == nil { selectedMicID = inputs.first?.id }
    }

    func selectMic(_ id: String?) {
        guard !isSessionActive else { return }
        selectedMicID = id
        Task { await startMonitoring() }
    }

    func setMicGainDecibels(_ value: Double) {
        micGainDecibels = value
        updateRecorderGains()
    }

    func setSystemGainDecibels(_ value: Double) {
        systemGainDecibels = value
        updateRecorderGains()
    }

    private func updateRecorderGains() {
        guard isRecording else { return }
        let micGainDecibels = micGainDecibels
        let systemGainDecibels = systemGainDecibels
        Task {
            await recorder.setGains(
                micGainDecibels: micGainDecibels,
                systemGainDecibels: systemGainDecibels
            )
        }
    }

    func refreshRecents() {
        let directory = outputDir
        Task { [weak self] in
            let urls = await Task.detached(priority: .utility) {
                let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isDirectoryKey]
                let contents = (try? FileManager.default.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: Array(keys),
                    options: [.skipsHiddenFiles]
                )) ?? []
                return contents
                    .filter { url in
                        let values = try? url.resourceValues(forKeys: keys)
                        return values?.isDirectory == true && url.lastPathComponent.hasPrefix("macrec-")
                    }
                    .sorted { first, second in
                        let firstDate = (try? first.resourceValues(forKeys: keys).contentModificationDate) ?? .distantPast
                        let secondDate = (try? second.resourceValues(forKeys: keys).contentModificationDate) ?? .distantPast
                        return firstDate > secondDate
                    }
            }.value
            guard let self, self.outputDir == directory else { return }
            self.recents = urls
        }
    }

    func toggleRecording() {
        guard !isStartingRecording, !isStoppingRecording else { return }
        if isRecording {
            isStoppingRecording = true
            Task {
                await stop()
                isStoppingRecording = false
            }
        } else {
            guard canRecord else { return }
            isStartingRecording = true
            Task {
                await start()
                isStartingRecording = false
                if !isRecording {
                    await startMonitoring()
                }
            }
        }
    }

    var canRecord: Bool {
        !isSessionActive && !isFileTranscribing && !isTranscriberLoading && (!liveTranscriptionEnabled || isTranscriberReady)
    }

    func prepareTranscriber() {
        guard liveTranscriptionEnabled, !isSessionActive, !isFileTranscribing, !isTranscriberLoading else { return }
        let model = transcriptionModel
        let loadID = UUID()
        transcriberLoadID = loadID
        transcriptStatus = .loading("Preparing model…")
        Task {
            if model.isMoonshine {
                await moonshineTranscriber.prepare(
                    model: model,
                    onUpdate: transcriptUpdateHandler(for: model, loadID: loadID)
                )
                await transcriptRefiner.prepare(onStatus: refinementStatusHandler)
            } else {
                await whisperTranscriber.prepare(
                    modelID: model.rawValue,
                    onUpdate: transcriptUpdateHandler(for: model, loadID: loadID)
                )
            }
        }
    }

    func selectTranscriptionModel(_ model: LiveTranscriptionModel) {
        guard !isSessionActive, !isFileTranscribing, !isTranscriberLoading else { return }
        transcriberLoadID = nil
        transcriptionModel = model
        transcriptProgress = nil
        transcriptStatus = liveTranscriptionEnabled ? .idle : .disabled
        prepareTranscriber()
    }

    func setLiveTranscriptionEnabled(_ enabled: Bool) {
        guard !isSessionActive, !isFileTranscribing, !isTranscriberLoading else { return }
        liveTranscriptionEnabled = enabled
        transcriptProgress = nil
        transcriptStatus = enabled ? .idle : .disabled
        prepareTranscriber()
    }

    func retryMonitoring() {
        guard !isSessionActive else { return }
        monitoringError = nil
        Task { await startMonitoring() }
    }

    func clearMeetingState() {
        guard !isRecording, !isStartingRecording, !isStoppingRecording else { return }
        title = ""
        sourceTranscriptEntries = []
        coveredCallRanges = []
        publishTranscript()
        currentSessionDir = nil
        recordingStartedAt = nil
        lastError = nil
        Task {
            await transcriptRefiner.reset()
        }

        guard !isTranscriberLoading else { return }
        transcriptProgress = nil
        if liveTranscriptionEnabled {
            transcriptStatus = isTranscriberReady ? .ready : .idle
        } else {
            transcriptStatus = .disabled
        }
    }

    private func start() async {
        do {
            guard !liveTranscriptionEnabled || isTranscriberReady else {
                lastError = "Wait for the transcription model to finish loading."
                return
            }
            await monitor.stop()
            resetLevels()
            sourceTranscriptEntries = []
            coveredCallRanges = []
            publishTranscript()
            let selectedTranscriptionModel = transcriptionModel
            await transcriptRefiner.start(
                enabled: liveTranscriptionEnabled && selectedTranscriptionModel.isMoonshine,
                onUpdate: transcriptRefinementUpdateHandler,
                onStatus: refinementStatusHandler
            )
            if selectedTranscriptionModel.isMoonshine {
                await moonshineTranscriber.start(
                    enabled: liveTranscriptionEnabled,
                    model: selectedTranscriptionModel,
                    onUpdate: transcriptUpdateHandler,
                    onFinalAudio: transcriptAudioHandler
                )
            } else {
                await whisperTranscriber.start(
                    enabled: liveTranscriptionEnabled,
                    modelID: selectedTranscriptionModel.rawValue,
                    onUpdate: transcriptUpdateHandler
                )
            }
            startTranscriptionInputPipelines(for: selectedTranscriptionModel)
            let micTranscriptionContinuation = micTranscriptionContinuation
            let systemTranscriptionContinuation = systemTranscriptionContinuation
            let session = try await recorder.start(
                outputDirectory: outputDir,
                title: title,
                micDeviceID: selectedMicID,
                micGainDecibels: micGainDecibels,
                systemGainDecibels: systemGainDecibels,
                onMicLevel: micLevelHandler,
                onSystemLevel: systemLevelHandler,
                onMicSampleBuffer: { sampleBuffer in
                    micTranscriptionContinuation?.yield(UncheckedSampleBuffer(sampleBuffer))
                },
                onSystemSample: { sample in
                    systemTranscriptionContinuation?.yield(sample)
                }
            )
            recordingStartedAt = Date()
            currentSessionDir = session.directory
            isRecording = true
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            await finishTranscriptionInputPipelines()
            await stopTranscriberAndWriteTranscript(to: nil)
            await transcriptRefiner.reset()
        }
    }

    private func stop() async {
        var finishedSession: RecordingSession?
        do {
            finishedSession = try await recorder.stop()
        } catch {
            lastError = error.localizedDescription
        }
        await finishTranscriptionInputPipelines()
        await stopTranscriberAndWriteTranscript(to: finishedSession)
        await transcriptRefiner.stop()
        publishTranscript()
        await writeTranscriptOutput(to: finishedSession)
        isRecording = false
        recordingStartedAt = nil
        refreshRecents()
        await startMonitoring()
    }

    private func startTranscriptionInputPipelines(for model: LiveTranscriptionModel) {
        guard liveTranscriptionEnabled else { return }
        let micPipe = AsyncStream<UncheckedSampleBuffer>.makeStream()
        let systemPipe = AsyncStream<SystemAudioSample>.makeStream()
        micTranscriptionContinuation = micPipe.continuation
        systemTranscriptionContinuation = systemPipe.continuation

        let moonshineTranscriber = moonshineTranscriber
        let whisperTranscriber = whisperTranscriber
        let transcriptRefiner = transcriptRefiner
        micTranscriptionTask = Task.detached(priority: .userInitiated) {
            for await sample in micPipe.stream {
                if model.isMoonshine {
                    await moonshineTranscriber.appendMicSampleBuffer(sample)
                } else {
                    await whisperTranscriber.appendMicSampleBuffer(sample)
                }
            }
        }
        systemTranscriptionTask = Task.detached(priority: .userInitiated) {
            for await sample in systemPipe.stream {
                if model.isMoonshine {
                    guard let samples = LiveAudioConverter.floatSamples16kMono(from: sample), !samples.isEmpty else { continue }
                    await moonshineTranscriber.appendSystemSamples(samples)
                    await transcriptRefiner.appendSystemSamples(samples)
                } else {
                    await whisperTranscriber.appendSystemSample(sample)
                }
            }
        }
    }

    private func finishTranscriptionInputPipelines() async {
        micTranscriptionContinuation?.finish()
        systemTranscriptionContinuation?.finish()
        micTranscriptionContinuation = nil
        systemTranscriptionContinuation = nil

        let micTask = micTranscriptionTask
        let systemTask = systemTranscriptionTask
        micTranscriptionTask = nil
        systemTranscriptionTask = nil
        await micTask?.value
        await systemTask?.value
    }

    func chooseOutputDir() {
        guard !isSessionActive, !isFileTranscribing else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use as output folder"
        if panel.runModal() == .OK, let url = panel.url {
            outputDir = url
            refreshRecents()
        }
    }

    func chooseInputFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.audio, .movie, .mpeg4Movie, .quickTimeMovie]
        panel.prompt = "Use audio"
        if panel.runModal() == .OK, let url = panel.url {
            setFileInput(url)
        }
    }

    func setFileInput(_ url: URL) {
        guard !isFileTranscribing else { return }
        fileInputURL = url
        fileTranscriptURL = nil
        fileTranscriptionProgress = nil
        fileTranscriptionElapsed = 0
        fileTranscriptionRemaining = nil
        fileTranscriptionStatus = url.lastPathComponent
    }

    func transcribeInputFile() {
        guard canTranscribeFile, let inputURL = fileInputURL else { return }
        transcriberLoadID = nil
        transcriptStatus = liveTranscriptionEnabled ? .idle : .disabled
        let runID = UUID()
        fileTranscriptionID = runID
        isFileTranscribing = true
        fileTranscriptURL = nil
        fileTranscriptionProgress = nil
        fileTranscriptionElapsed = 0
        fileTranscriptionRemaining = nil
        fileTranscriptionStatus = "Starting..."
        startFileTranscriptionTimer()

        let model = fileTranscriptionModel
        let outputDir = outputDir
        fileTranscriptionTask = Task {
            defer {
                fileTranscriptionProgress = nil
                fileTranscriptionRemaining = nil
                isFileTranscribing = false
                fileTranscriptionTask = nil
                fileTranscriptionID = nil
                stopFileTranscriptionTimer(resetElapsed: false)
                prepareTranscriber()
            }
            do {
                let outputURL: URL
                if model.isMoonshine {
                    outputURL = try await moonshineTranscriber.transcribeFile(
                        inputURL: inputURL,
                        outputDirectory: outputDir,
                        model: model,
                        onStatus: fileTranscriptionUpdateHandler(for: runID)
                    )
                } else {
                    outputURL = try await whisperTranscriber.transcribeFile(
                        inputURL: inputURL,
                        outputDirectory: outputDir,
                        model: model,
                        onStatus: fileTranscriptionUpdateHandler(for: runID)
                    )
                }
                fileTranscriptURL = outputURL
                fileTranscriptionStatus = "Transcript saved"
            } catch is CancellationError {
                fileTranscriptionStatus = "Canceled"
            } catch {
                fileTranscriptionStatus = error.localizedDescription
            }
        }
    }

    func cancelFileTranscription() {
        guard isFileTranscribing else { return }
        fileTranscriptionStatus = "Canceling..."
        fileTranscriptionProgress = nil
        fileTranscriptionRemaining = nil
        fileTranscriptionTask?.cancel()
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private var micLevelHandler: @Sendable (AudioLevel) -> Void {
        { [weak self] level in
            guard let self, self.audioMeterThrottle.shouldPublish(.microphone) else { return }
            Task { @MainActor [weak self] in
                self?.updateMicLevel(level)
            }
        }
    }

    private var systemLevelHandler: @Sendable (AudioLevel) -> Void {
        { [weak self] level in
            guard let self, self.audioMeterThrottle.shouldPublish(.system) else { return }
            Task { @MainActor [weak self] in
                self?.updateSystemLevel(level)
            }
        }
    }

    private var transcriptUpdateHandler: @Sendable (LiveTranscriptionUpdate) -> Void {
        { [weak self] update in
            Task { @MainActor [weak self] in
                self?.handleTranscriptUpdate(update)
            }
        }
    }

    private var transcriptRefinementUpdateHandler: @Sendable (LiveTranscriptionUpdate) async -> Void {
        { [weak self] update in
            await MainActor.run {
                self?.handleTranscriptUpdate(update)
            }
        }
    }

    private var transcriptAudioHandler: @Sendable (LiveTranscriptAudioSegment) -> Void {
        { [weak self] segment in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.transcriptRefiner.enqueue(segment)
            }
        }
    }

    private var refinementStatusHandler: @Sendable (RefinementStatus) -> Void {
        { [weak self] status in
            Task { @MainActor [weak self] in
                guard let self, self.refinementStatus.notice != status.notice else { return }
                self.refinementStatus = status
            }
        }
    }

    private func transcriptUpdateHandler(for model: LiveTranscriptionModel, loadID: UUID) -> @Sendable (LiveTranscriptionUpdate) -> Void {
        { [weak self] update in
            Task { @MainActor [weak self] in
                guard let self,
                      self.transcriberLoadID == loadID,
                      self.transcriptionModel == model else { return }
                self.handleTranscriptUpdate(update)
            }
        }
    }

    private func fileTranscriptionUpdateHandler(for runID: UUID) -> @Sendable (String, Double?) -> Void {
        { [weak self] message, progress in
            Task { @MainActor [weak self] in
                guard self?.fileTranscriptionID == runID else { return }
                if !message.isEmpty {
                    self?.fileTranscriptionStatus = message
                }
                self?.fileTranscriptionProgress = progress
                self?.updateFileTranscriptionTiming(progress: progress)
            }
        }
    }

    private func startFileTranscriptionTimer() {
        fileTranscriptionTimer?.invalidate()
        fileTranscriptionStartedAt = Date()
        fileTranscriptionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.updateFileTranscriptionTiming(progress: self.fileTranscriptionProgress)
            }
        }
    }

    private func stopFileTranscriptionTimer(resetElapsed: Bool) {
        updateFileTranscriptionTiming(progress: fileTranscriptionProgress)
        fileTranscriptionTimer?.invalidate()
        fileTranscriptionTimer = nil
        fileTranscriptionStartedAt = nil
        if resetElapsed {
            fileTranscriptionElapsed = 0
        }
    }

    private func updateFileTranscriptionTiming(progress: Double?) {
        guard let startedAt = fileTranscriptionStartedAt else { return }
        let elapsed = Date().timeIntervalSince(startedAt)
        fileTranscriptionElapsed = elapsed

        guard let progress,
              progress > 0.02,
              progress < 1 else {
            fileTranscriptionRemaining = nil
            return
        }

        fileTranscriptionRemaining = max(0, elapsed * ((1 - progress) / progress))
    }

    private func handleTranscriptUpdate(_ update: LiveTranscriptionUpdate) {
        switch update {
        case .reset:
            sourceTranscriptEntries = []
            coveredCallRanges = []
            publishTranscript()
            transcriptStatus = liveTranscriptionEnabled ? .idle : .disabled
        case let .status(status):
            if transcriptStatus != status {
                transcriptStatus = status
            }
            if !status.isLoading {
                transcriptProgress = nil
                transcriberLoadID = nil
            }
        case let .progress(value):
            if transcriptProgress != value { transcriptProgress = value }
        case let .entry(entry):
            if entry.speaker == .call,
               TranscriptCoverageMerge.contains(entry, in: coveredCallRanges) {
                return
            }
            if let existingIndex = sourceTranscriptEntries.firstIndex(where: { $0.id == entry.id }) {
                guard sourceTranscriptEntries[existingIndex] != entry else { return }
                sourceTranscriptEntries[existingIndex] = entry
                let precedesPrevious = existingIndex > 0
                    && sourceTranscriptEntries[existingIndex - 1].start > entry.start
                let followsNext = existingIndex + 1 < sourceTranscriptEntries.count
                    && entry.start > sourceTranscriptEntries[existingIndex + 1].start
                if precedesPrevious || followsNext {
                    sourceTranscriptEntries.sort { $0.start < $1.start }
                }
            } else {
                let remainsSorted = sourceTranscriptEntries.last.map { $0.start <= entry.start } ?? true
                sourceTranscriptEntries.append(entry)
                if !remainsSorted {
                    sourceTranscriptEntries.sort { $0.start < $1.start }
                }
            }
            scheduleTranscriptPublish()
        case let .replace(originalIDs, entry):
            let originalIDSet = Set(originalIDs)
            sourceTranscriptEntries.removeAll { originalIDSet.contains($0.id) || $0.id == entry.id }
            sourceTranscriptEntries.append(entry)
            sourceTranscriptEntries.sort { $0.start < $1.start }
            scheduleTranscriptPublish()
        case let .replaceRange(speaker, start, end, entries):
            guard TranscriptCoverageMerge.replace(
                speaker: speaker,
                start: start,
                end: end,
                with: entries,
                entries: &sourceTranscriptEntries,
                coveredCallRanges: &coveredCallRanges
            ) else {
                return
            }
            scheduleTranscriptPublish()
        }
    }

    private func scheduleTranscriptPublish() {
        guard transcriptPublishTask == nil else { return }
        transcriptPublishTask = Task { [weak self] in
            // Apply caption and refinement updates together before SwiftUI lays out the transcript.
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            self?.publishTranscript()
        }
    }

    private func publishTranscript() {
        transcriptPublishTask?.cancel()
        transcriptPublishTask = nil
        liveTranscript.publish(sourceTranscriptEntries)
    }

    private func writeTranscriptOutput(to session: RecordingSession?) async {
        guard let session, !sourceTranscriptEntries.isEmpty else { return }
        let completeTranscript = sourceTranscriptEntries
        do {
            try await Task.detached(priority: .utility) {
                let transcriptURL = session.directory.appendingPathComponent("\(session.fileStem)-live-transcript.txt")
                let rawTranscriptURL = session.directory.appendingPathComponent("\(session.fileStem)-live-transcript-raw.txt")
                if FileManager.default.fileExists(atPath: transcriptURL.path),
                   !FileManager.default.fileExists(atPath: rawTranscriptURL.path) {
                    try FileManager.default.copyItem(at: transcriptURL, to: rawTranscriptURL)
                }
                try TranscriptRenderer.renderLive(completeTranscript)
                    .write(to: transcriptURL, atomically: true, encoding: .utf8)
            }.value
        } catch {
            lastError = "Could not save transcript: \(error.localizedDescription)"
        }
    }

    private func stopTranscriberAndWriteTranscript(to session: RecordingSession?) async {
        if transcriptionModel.isMoonshine {
            await moonshineTranscriber.stopAndWriteTranscript(to: session)
        } else {
            await whisperTranscriber.stopAndWriteTranscript(to: session)
        }
    }

    private func startMonitoring() async {
        guard !isRecording else { return }
        monitor.onMicLevel = micLevelHandler
        monitor.onSystemLevel = systemLevelHandler
        monitor.onSystemAvailable = { [weak self] isAvailable in
            Task { @MainActor [weak self] in
                if isAvailable {
                    self?.monitoringError = nil
                }
            }
        }
        monitor.onError = { [weak self] error in
            Task { @MainActor [weak self] in
                self?.monitoringError = self?.displayMessage(for: error)
            }
        }

        do {
            try await monitor.start(micDeviceID: selectedMicID)
        } catch {
            monitoringError = displayMessage(for: error)
            resetLevels()
        }
    }

    private func updateMicLevel(_ level: AudioLevel) {
        audioMeters.set(
            level.applyingGain(linearGain(fromDecibels: micGainDecibels)).normalized,
            for: .microphone
        )
    }

    private func updateSystemLevel(_ level: AudioLevel) {
        audioMeters.set(
            level.applyingGain(linearGain(fromDecibels: systemGainDecibels)).normalized,
            for: .system
        )
    }

    private func linearGain(fromDecibels decibels: Double) -> Double {
        pow(10, decibels / 20)
    }

    private func resetLevels() {
        audioMeters.reset()
        audioMeterThrottle.reset()
    }

    private func displayMessage(for error: Error) -> String {
        let message = error.localizedDescription
        if message.localizedCaseInsensitiveContains("TCC")
            || message.localizedCaseInsensitiveContains("system audio")
            || message.localizedCaseInsensitiveContains("CoreAudio status") {
            return "Allow MacRec in System Settings > Privacy & Security > Screen & System Audio Recording, then System Audio Recording Only if it appears."
        }
        return message
    }
}
