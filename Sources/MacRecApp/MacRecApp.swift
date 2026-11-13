import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MacRecCore

private enum MacRecWindowFrames {
    private static let undockedControlFrameKey = "MacRecUndockedControlFrame"

    @MainActor
    static var controlWindow: NSWindow? {
        if let keyWindow = NSApp.keyWindow, keyWindow.title == "MacRec" {
            return keyWindow
        }
        return NSApp.windows.first(where: { $0.title == "MacRec" })
    }

    @MainActor
    static func rememberUndockedControlFrame() {
        guard let frame = controlWindow?.frame else { return }
        UserDefaults.standard.set(NSStringFromRect(frame), forKey: undockedControlFrameKey)
    }

    @MainActor
    static func restoreUndockedControlFrame() {
        guard let value = UserDefaults.standard.string(forKey: undockedControlFrameKey),
              let window = controlWindow else { return }
        let frame = NSRectFromString(value)
        guard frame.width >= 820, frame.height >= 600 else { return }
        window.setFrame(frame, display: true, animate: true)
    }
}

@MainActor
private final class MacRecWindowCoordinator {
    static let shared = MacRecWindowCoordinator()

    private var usesManualWindows = false
    private var manualControlWindow: NSWindow?
    private var manualCompanionWindow: NSWindow?

    func reopenManualControlWindowIfNeeded() -> Bool {
        guard usesManualWindows else { return false }
        showManualControlWindow()
        return true
    }

    func showManualControlWindow() {
        usesManualWindows = true
        if let manualControlWindow {
            manualControlWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let rootView = ContentView()
            .environmentObject(AppModel.shared)
        let controller = NSHostingController(rootView: rootView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "MacRec"
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setFrameAutosaveName("MacRecControlWindow")
        if !window.setFrameUsingName("MacRecControlWindow") {
            window.center()
        }
        manualControlWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showCompanion(using sceneAction: OpenWindowAction) {
        if let existing = NSApp.windows.first(where: { $0.title == "Live Companion" }) {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        guard usesManualWindows else {
            sceneAction(id: "live-companion")
            return
        }

        if let manualCompanionWindow {
            manualCompanionWindow.makeKeyAndOrderFront(nil)
            return
        }

        let rootView = LiveCompanionView()
            .environmentObject(AppModel.shared)
        let controller = NSHostingController(rootView: rootView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Live Companion"
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setFrameAutosaveName("MacRecLiveCompanionWindow")
        if !window.setFrameUsingName("MacRecLiveCompanionWindow") {
            window.center()
        }
        manualCompanionWindow = window
        window.makeKeyAndOrderFront(nil)
    }

    func closeCompanion() {
        NSApp.windows.first(where: { $0.title == "Live Companion" })?.close()
    }
}

@MainActor
private final class MacRecApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldSaveSecureApplicationState(_ app: NSApplication) -> Bool {
        false
    }

    func applicationShouldRestoreSecureApplicationState(_ app: NSApplication) -> Bool {
        false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        scheduleControlWindowCheck(after: 0.4, allowManualFallback: false)
        scheduleControlWindowCheck(after: 1.5, allowManualFallback: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        scheduleControlWindowCheck(after: 0, allowManualFallback: true)
        return true
    }

    private func scheduleControlWindowCheck(after delay: TimeInterval, allowManualFallback: Bool) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            Self.ensureControlWindowIsVisible(allowManualFallback: allowManualFallback)
        }
    }

    private static func ensureControlWindowIsVisible(allowManualFallback: Bool) {
        let newWindowItem = NSApp.mainMenu?
            .item(withTitle: "File")?
            .submenu?
            .items
            .first(where: { $0.title == "New MacRec Window" })
        if let window = MacRecWindowFrames.controlWindow {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
            return
        }
        if MacRecWindowCoordinator.shared.reopenManualControlWindowIfNeeded() {
            return
        }
        if let newWindowItem, let action = newWindowItem.action {
            NSApp.sendAction(action, to: newWindowItem.target, from: newWindowItem)
        }
        guard allowManualFallback else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            if MacRecWindowFrames.controlWindow == nil {
                MacRecWindowCoordinator.shared.showManualControlWindow()
            }
        }
    }
}

@main
struct MacRecApp: App {
    @NSApplicationDelegateAdaptor(MacRecApplicationDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared
    @AppStorage("MacRecCompanionIsDocked") private var companionIsDocked = false

    var body: some Scene {
        WindowGroup("MacRec", id: "controls") {
            ContentView()
                .environmentObject(model)
                .frame(
                    minWidth: companionIsDocked ? 1200 : 820,
                    idealWidth: companionIsDocked ? 1240 : 900,
                    maxWidth: companionIsDocked ? 1440 : 1050,
                    minHeight: 600,
                    idealHeight: 640,
                    maxHeight: 800
                )
        }
        .windowResizability(.contentSize)
        .defaultSize(width: companionIsDocked ? 1240 : 900, height: 640)

        Window("Live Companion", id: "live-companion") {
            LiveCompanionView()
                .environmentObject(model)
                .frame(minWidth: 360, idealWidth: 460, maxWidth: 760, minHeight: 420, idealHeight: 680, maxHeight: 1000)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 460, height: 680)
    }
}

private final class AudioMeterState: ObservableObject {
    enum Channel: Equatable, Sendable {
        case microphone
        case system
    }

    @Published private(set) var microphoneLevel: Double = 0
    @Published private(set) var systemLevel: Double = 0

    func set(_ value: Double, for channel: Channel) {
        switch channel {
        case .microphone:
            microphoneLevel = value
        case .system:
            systemLevel = value
        }
    }

    func reset() {
        microphoneLevel = 0
        systemLevel = 0
    }
}

private final class AudioMeterThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var lastMicrophoneUpdate = Date.distantPast
    private var lastSystemUpdate = Date.distantPast
    private let minimumInterval: TimeInterval

    init(updatesPerSecond: Double) {
        minimumInterval = 1 / updatesPerSecond
    }

    func shouldPublish(_ channel: AudioMeterState.Channel, now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        switch channel {
        case .microphone:
            guard now.timeIntervalSince(lastMicrophoneUpdate) >= minimumInterval else { return false }
            lastMicrophoneUpdate = now
        case .system:
            guard now.timeIntervalSince(lastSystemUpdate) >= minimumInterval else { return false }
            lastSystemUpdate = now
        }
        return true
    }

    func reset() {
        lock.lock()
        lastMicrophoneUpdate = .distantPast
        lastSystemUpdate = .distantPast
        lock.unlock()
    }
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var isRecording = false
    @Published var isStartingRecording = false
    @Published var isStoppingRecording = false
    @Published var elapsed: TimeInterval = 0
    @Published var currentSessionDir: URL?
    @Published var lastError: String?
    @Published var title: String = ""
    @Published var outputDir: URL = AppModel.defaultOutputDir()
    @Published var selectedMicID: String?
    @Published var inputs: [AudioInputDevice] = []
    @Published var recents: [URL] = []
    @Published var micGainDecibels: Double = 0
    @Published var systemGainDecibels: Double = 0
    @Published var liveTranscriptionEnabled = true
    @Published var transcriptionModel: LiveTranscriptionModel = .moonshineMedium
    @Published var transcriptStatus: String = LiveTranscriptionModel.moonshineMedium.loadPrompt
    @Published var transcriptProgress: Double?
    @Published var isTranscriberReady = false
    @Published var isTranscriberLoading = false
    @Published var transcriptEntries: [LiveTranscriptEntry] = []
    private(set) var transcriptRevision: UInt64 = 0
    @Published var refinementStatus = "Preparing accuracy refinement..."
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
    fileprivate let audioMeters = AudioMeterState()
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
    private var timer: Timer?
    private var startedAt: Date?
    private var transcriberLoadID: UUID?
    private var fileTranscriptionTask: Task<Void, Never>?
    private var fileTranscriptionID: UUID?
    private var fileTranscriptionStartedAt: Date?
    private var fileTranscriptionTimer: Timer?

    init() {
        refreshInputs()
        refreshRecents()
        Task {
            await startMonitoring()
            prepareTranscriber()
            await transcriptRefiner.prepare(onStatus: refinementStatusHandler)
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
        selectedMicID = id
        guard !isRecording else { return }
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
            isStartingRecording = true
            Task {
                await start()
                isStartingRecording = false
            }
        }
    }

    var canRecord: Bool {
        !isRecording && !isStartingRecording && !isStoppingRecording && (!liveTranscriptionEnabled || isTranscriberReady)
    }

    func prepareTranscriber() {
        guard liveTranscriptionEnabled, !isRecording else { return }
        let model = transcriptionModel
        let loadID = UUID()
        transcriberLoadID = loadID
        isTranscriberLoading = true
        isTranscriberReady = false
        Task {
            if model.isMoonshine {
                await moonshineTranscriber.prepare(
                    model: model,
                    onUpdate: transcriptUpdateHandler(for: model, loadID: loadID)
                )
            } else {
                await whisperTranscriber.prepare(
                    modelID: model.rawValue,
                    onUpdate: transcriptUpdateHandler(for: model, loadID: loadID)
                )
            }
        }
    }

    func selectTranscriptionModel(_ model: LiveTranscriptionModel) {
        transcriberLoadID = nil
        transcriptionModel = model
        isTranscriberReady = false
        isTranscriberLoading = false
        transcriptProgress = nil
        transcriptStatus = liveTranscriptionEnabled ? model.loadPrompt : "Live transcript off"
    }

    func cancelTranscriberLoad() {
        transcriberLoadID = nil
    }

    func retryMonitoring() {
        guard !isRecording else { return }
        lastError = nil
        Task { await startMonitoring() }
    }

    func clearMeetingState() {
        guard !isRecording, !isStartingRecording, !isStoppingRecording else { return }
        title = ""
        sourceTranscriptEntries = []
        coveredCallRanges = []
        publishTranscript()
        currentSessionDir = nil
        elapsed = 0
        lastError = nil
        Task {
            await transcriptRefiner.reset()
        }

        guard !isTranscriberLoading else { return }
        transcriptProgress = nil
        if liveTranscriptionEnabled {
            transcriptStatus = isTranscriberReady ? transcriptionModel.readyStatus : transcriptionModel.loadPrompt
        } else {
            transcriptStatus = "Live transcript off"
        }
    }

    private func start() async {
        do {
            guard !liveTranscriptionEnabled || isTranscriberReady else {
                lastError = transcriptionModel.loadPrompt
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
            startedAt = Date()
            currentSessionDir = session.directory
            isRecording = true
            lastError = nil
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let s = self.startedAt else { return }
                    self.elapsed = Date().timeIntervalSince(s)
                }
            }
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
        writeTranscriptOutput(to: finishedSession)
        timer?.invalidate(); timer = nil
        isRecording = false
        elapsed = 0
        startedAt = nil
        refreshRecents()
        await startMonitoring()
    }

    private func startTranscriptionInputPipelines(for model: LiveTranscriptionModel) {
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
                    await moonshineTranscriber.appendSystemSample(sample)
                    await transcriptRefiner.appendSystemSample(sample)
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
        fileInputURL = url
        fileTranscriptURL = nil
        fileTranscriptionProgress = nil
        fileTranscriptionElapsed = 0
        fileTranscriptionRemaining = nil
        fileTranscriptionStatus = url.lastPathComponent
    }

    func transcribeInputFile() {
        guard !isFileTranscribing, let inputURL = fileInputURL else { return }
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
                await MainActor.run {
                    guard self.fileTranscriptionID == runID else { return }
                    self.fileTranscriptURL = outputURL
                    self.fileTranscriptionStatus = "Wrote \(outputURL.lastPathComponent)"
                    self.fileTranscriptionProgress = nil
                    self.fileTranscriptionRemaining = nil
                    self.isFileTranscribing = false
                    self.fileTranscriptionTask = nil
                    self.fileTranscriptionID = nil
                    self.stopFileTranscriptionTimer(resetElapsed: false)
                }
            } catch is CancellationError {
                await MainActor.run {
                    guard self.fileTranscriptionID == runID else { return }
                    self.fileTranscriptionStatus = "Canceled."
                    self.fileTranscriptionProgress = nil
                    self.fileTranscriptionRemaining = nil
                    self.isFileTranscribing = false
                    self.fileTranscriptionTask = nil
                    self.fileTranscriptionID = nil
                    self.stopFileTranscriptionTimer(resetElapsed: false)
                }
            } catch {
                await MainActor.run {
                    guard self.fileTranscriptionID == runID else { return }
                    self.fileTranscriptionStatus = error.localizedDescription
                    self.fileTranscriptionProgress = nil
                    self.fileTranscriptionRemaining = nil
                    self.isFileTranscribing = false
                    self.fileTranscriptionTask = nil
                    self.fileTranscriptionID = nil
                    self.stopFileTranscriptionTimer(resetElapsed: false)
                }
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

    private var refinementStatusHandler: @Sendable (String) -> Void {
        { [weak self] status in
            Task { @MainActor [weak self] in
                self?.refinementStatus = status
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
            transcriptStatus = liveTranscriptionEnabled ? transcriptionModel.loadPrompt : "Live transcript off"
        case let .status(message):
            transcriptStatus = message
            if message == transcriptionModel.readyStatus || message == "Whisper ready." || message == "Moonshine ready." {
                isTranscriberReady = true
                isTranscriberLoading = false
                transcriberLoadID = nil
            } else if message.localizedCaseInsensitiveContains("failed") {
                isTranscriberReady = false
                isTranscriberLoading = false
                transcriberLoadID = nil
            }
        case let .progress(value):
            transcriptProgress = value
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
        let entries = Array(sourceTranscriptEntries.suffix(180))
        guard transcriptEntries != entries else { return }
        transcriptRevision &+= 1
        transcriptEntries = entries
    }

    private func writeTranscriptOutput(to session: RecordingSession?) {
        guard let session else { return }

        let completeTranscript = sourceTranscriptEntries
        if !completeTranscript.isEmpty {
            let transcriptURL = session.directory.appendingPathComponent("\(session.fileStem)-live-transcript.txt")
            let rawTranscriptURL = session.directory.appendingPathComponent("\(session.fileStem)-live-transcript-raw.txt")
            if FileManager.default.fileExists(atPath: transcriptURL.path),
               !FileManager.default.fileExists(atPath: rawTranscriptURL.path) {
                try? FileManager.default.copyItem(at: transcriptURL, to: rawTranscriptURL)
            }
            try? TranscriptRenderer.renderLive(completeTranscript)
                .write(to: transcriptURL, atomically: true, encoding: .utf8)
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
                    self?.lastError = nil
                }
            }
        }
        monitor.onError = { [weak self] error in
            Task { @MainActor [weak self] in
                self?.lastError = self?.displayMessage(for: error)
            }
        }

        do {
            try await monitor.start(micDeviceID: selectedMicID)
        } catch {
            lastError = displayMessage(for: error)
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

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @AppStorage("MacRecCompanionIsDocked") private var companionIsDocked = false
    @State private var isFileDropTargeted = false

    var body: some View {
        TabView {
            liveInputLayout
                .tabItem { Text("Live input") }

            transcribeAudioLayout
                .tabItem { Text("Transcribe audio") }
        }
        .frame(maxWidth: companionIsDocked ? 1440 : 1050, maxHeight: .infinity, alignment: .top)
        .background(
            WindowConfiguration(
                autosaveName: "MacRecControlWindow",
                minSize: NSSize(width: companionIsDocked ? 1200 : 820, height: 600),
                maxSize: NSSize(width: companionIsDocked ? 1440 : 1050, height: 800),
                supportsFullScreenOverlay: false
            )
        )
        .task {
            // The companion is part of pre-meeting setup. Open it as soon as
            // the control surface appears, never as a side effect of Record.
            if !companionIsDocked {
                MacRecWindowCoordinator.shared.showCompanion(using: openWindow)
            }
        }
    }

    private var liveInputLayout: some View {
        HStack(alignment: .top, spacing: 18) {
            controlColumn
                .frame(minWidth: 780, maxWidth: .infinity, alignment: .top)

            if companionIsDocked {
                Divider()
                DockedCompanionPanel(onPopOut: popOutCompanion)
                    .frame(width: 360)
            }
        }
        .padding(20)
        .frame(
            minWidth: companionIsDocked ? 1160 : 780,
            maxWidth: companionIsDocked ? 1440 : 1050,
            maxHeight: .infinity,
            alignment: .top
        )
    }

    private var controlColumn: some View {
        VStack(spacing: 16) {
            transcriptionControlsPanel
            Divider()
            settingsPanel
            Divider()
            recordPanel
            Divider()
            recentsPanel
        }
    }

    private var transcribeAudioLayout: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Transcribe audio")
                    .font(.title2.weight(.semibold))
                Spacer()
                Picker("", selection: $model.fileTranscriptionModel) {
                    ForEach(LiveTranscriptionModel.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .labelsHidden()
                .frame(width: 200)
                .disabled(model.isFileTranscribing)
            }

            Divider()

            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 14) {
                    fileDropArea

                    HStack(spacing: 12) {
                        Button("Choose...") { model.chooseInputFile() }
                            .disabled(model.isFileTranscribing)

                        Button("Transcribe") { model.transcribeInputFile() }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.fileInputURL == nil || model.isFileTranscribing)

                        if model.isFileTranscribing {
                            Button("Cancel") { model.cancelFileTranscription() }
                                .keyboardShortcut(.cancelAction)
                        }

                        if let output = model.fileTranscriptURL {
                            Button("Reveal") { model.revealInFinder(output) }
                        }
                    }
                }
                .frame(maxWidth: 560, alignment: .topLeading)

                Divider()

                VStack(alignment: .leading, spacing: 12) {
                    Text("Output")
                        .font(.headline)
                    Text(model.outputDir.path)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Choose folder...") { model.chooseOutputDir() }
                        .disabled(model.isFileTranscribing)

                    Divider()

                    Text(model.fileTranscriptionStatus)
                        .font(.callout)
                        .foregroundStyle(model.fileTranscriptURL == nil ? .secondary : .primary)
                        .lineLimit(3)

                    if model.isFileTranscribing {
                        VStack(alignment: .leading, spacing: 6) {
                            if let progress = model.fileTranscriptionProgress {
                                HStack(spacing: 10) {
                                    ProgressView(value: progress)
                                        .frame(maxWidth: .infinity)
                                    Text("\(Int(progress * 100))%")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                        .frame(width: 38, alignment: .trailing)
                                }
                            } else {
                                HStack(spacing: 10) {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text("Working...")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            HStack(spacing: 10) {
                                Text("Elapsed \(formatElapsed(model.fileTranscriptionElapsed))")
                                    .foregroundStyle(.secondary)
                                if let remaining = model.fileTranscriptionRemaining {
                                    Text("ETA \(formatElapsed(remaining))")
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text("ETA calculating")
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .font(.caption.monospacedDigit())
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }

            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: 980, maxHeight: .infinity, alignment: .topLeading)
    }

    private var fileDropArea: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform.badge.magnifyingglass")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(.secondary)
            Text(model.fileInputURL?.lastPathComponent ?? "Drop audio or video")
                .font(.headline)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            if let url = model.fileInputURL {
                Text(url.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .truncationMode(.middle)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 210)
        .padding(18)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isFileDropTargeted ? Color.accentColor : Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, dash: [7, 5]))
        }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isFileDropTargeted) { providers in
            handleFileDrop(providers)
        }
    }

    private func handleFileDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            let url: URL?
            if let data = item as? Data {
                url = URL(dataRepresentation: data, relativeTo: nil)
            } else {
                url = item as? URL
            }
            guard let url else { return }
            Task { @MainActor in
                model.setFileInput(url)
            }
        }
        return true
    }

    private func popOutCompanion() {
        companionIsDocked = false
        MacRecWindowCoordinator.shared.showCompanion(using: openWindow)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            MacRecWindowFrames.restoreUndockedControlFrame()
        }
    }

    private var recordPanel: some View {
        VStack(spacing: 8) {
            Button(action: { model.toggleRecording() }) {
                Text(recordButtonTitle)
                    .font(.title2.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .tint(model.isRecording ? .red : .accentColor)
            .disabled(model.isStartingRecording || model.isStoppingRecording || (!model.isRecording && !model.canRecord))

            if model.isRecording {
                Text(formatElapsed(model.elapsed))
                    .font(.system(.title3, design: .monospaced))
                    .foregroundStyle(.secondary)
            } else {
                Text("Monitoring inputs")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Button {
                    if companionIsDocked {
                        popOutCompanion()
                    } else {
                        MacRecWindowCoordinator.shared.showCompanion(using: openWindow)
                    }
                } label: {
                    Label(
                        companionIsDocked ? "Pop Out Live Companion" : "Show Live Companion",
                        systemImage: "rectangle.on.rectangle"
                    )
                }

                Button {
                    model.clearMeetingState()
                } label: {
                    Label("Clear meeting", systemImage: "xmark.circle")
                }
                .disabled(model.isRecording || model.isStartingRecording || model.isStoppingRecording)
            }
            .buttonStyle(.borderless)

            if let err = model.lastError {
                HStack(spacing: 10) {
                    Text(err)
                        .foregroundStyle(.red)
                        .font(.callout)
                    if !model.isRecording {
                        Button("Retry monitoring") { model.retryMonitoring() }
                            .buttonStyle(.borderless)
                    }
                }
            }
        }
    }

    private var recordButtonTitle: String {
        if model.isStartingRecording { return "Starting…" }
        if model.isStoppingRecording { return "Finishing…" }
        return model.isRecording ? "Stop" : "Record"
    }

    private var settingsPanel: some View {
        let previewNames = RecordingSession.previewFileNames(title: model.title)

        return VStack(alignment: .leading, spacing: 10) {
            Text("Sources").font(.headline)

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 14) {
                    SourceLabel(title: "Title", systemImage: "textformat")
                    TextField("", text: $model.title)
                        .textFieldStyle(.roundedBorder)
                        .disabled(model.isRecording)
                }

                HStack(spacing: 14) {
                    SourceLabel(title: "Output folder", systemImage: "folder.fill")
                    HStack {
                        Text(model.outputDir.path)
                            .truncationMode(.middle)
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Choose...") { model.chooseOutputDir() }
                            .disabled(model.isRecording)
                    }
                }

                HStack(spacing: 14) {
                    SourceLabel(title: "", systemImage: nil)
                    HStack(spacing: 14) {
                        Text("Source")
                            .frame(width: 240, alignment: .leading)
                        Text("Gain")
                            .frame(width: 166, alignment: .leading)
                        Text("Level")
                            .frame(width: 110, alignment: .leading)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                SourceControlRow(
                    title: "Mic track",
                    systemImage: "mic.fill",
                    fileName: previewNames.mic,
                    gain: Binding(
                        get: { model.micGainDecibels },
                        set: { model.setMicGainDecibels($0) }
                    ),
                    meterState: model.audioMeters,
                    meterChannel: .microphone,
                    isRecording: model.isRecording
                ) {
                    HStack(spacing: 8) {
                        Picker("", selection: Binding(
                            get: { model.selectedMicID ?? "" },
                            set: { model.selectMic($0.isEmpty ? nil : $0) }
                        )) {
                            ForEach(model.inputs, id: \.id) { dev in
                                Text(dev.name).tag(dev.id)
                            }
                        }
                        .labelsHidden()
                        .disabled(model.isRecording)

                        Button(action: { model.refreshInputs() }) {
                            Image(systemName: "arrow.clockwise")
                        }
                        .disabled(model.isRecording)
                    }
                }

                SourceControlRow(
                    title: "Call audio",
                    systemImage: "speaker.wave.2.fill",
                    fileName: previewNames.system,
                    gain: Binding(
                        get: { model.systemGainDecibels },
                        set: { model.setSystemGainDecibels($0) }
                    ),
                    meterState: model.audioMeters,
                    meterChannel: .system,
                    isRecording: model.isRecording
                ) {
                    Text("Mac system audio")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var transcriptionControlsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Load model").font(.headline)

            HStack(spacing: 12) {
                Toggle("Live transcript", isOn: $model.liveTranscriptionEnabled)
                    .disabled(model.isRecording)
                    .onChange(of: model.liveTranscriptionEnabled) { enabled in
                        if enabled {
                            model.isTranscriberReady = false
                            model.transcriptStatus = model.transcriptionModel.loadPrompt
                        } else {
                            model.cancelTranscriberLoad()
                            model.isTranscriberReady = false
                            model.isTranscriberLoading = false
                            model.transcriptProgress = nil
                            model.transcriptStatus = "Live transcript off"
                        }
                    }
                Picker("", selection: Binding(
                    get: { model.transcriptionModel },
                    set: { model.selectTranscriptionModel($0) }
                )) {
                    ForEach(LiveTranscriptionModel.allCases) { model in
                        Text(model.title).tag(model)
                    }
                }
                .labelsHidden()
                .frame(width: 190)
                .disabled(model.isRecording || !model.liveTranscriptionEnabled)
                Button(model.isTranscriberReady ? "Loaded" : "Load") {
                    model.prepareTranscriber()
                }
                .disabled(model.isRecording || !model.liveTranscriptionEnabled || model.isTranscriberLoading || model.isTranscriberReady)
                Spacer()
                Text(model.transcriptStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if model.liveTranscriptionEnabled, model.isTranscriberLoading {
                if let progress = model.transcriptProgress {
                    ProgressView(value: progress)
                        .frame(maxWidth: .infinity)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                }
            }

            if model.liveTranscriptionEnabled, model.transcriptionModel.isMoonshine {
                HStack(spacing: 6) {
                    Image(systemName: model.refinementStatus.localizedCaseInsensitiveContains("ready") || model.refinementStatus.localizedCaseInsensitiveContains("current") || model.refinementStatus.localizedCaseInsensitiveContains("checked") ? "checkmark.circle.fill" : "waveform.badge.magnifyingglass")
                        .foregroundStyle(.secondary)
                    Text(model.refinementStatus)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var recentsPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recent recordings").font(.headline)
            if model.recents.isEmpty {
                Text("No recordings yet.").foregroundStyle(.secondary).font(.callout)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(model.recents.prefix(10), id: \.self) { url in
                            HStack {
                                Text(url.lastPathComponent).font(.callout)
                                Spacer()
                                Button("Reveal") { model.revealInFinder(url) }
                                    .buttonStyle(.borderless)
                            }
                        }
                    }
                }
                .frame(maxHeight: 160)
            }
        }
    }

    private func formatElapsed(_ t: TimeInterval) -> String {
        let total = Int(t)
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

}

struct LiveCompanionView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("MacRecCompanionIsDocked") private var companionIsDocked = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            companionControls
            Divider()
            LiveTranscriptPanel()
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            WindowConfiguration(
                autosaveName: "MacRecLiveCompanionWindow",
                minSize: NSSize(width: 360, height: 420),
                maxSize: NSSize(width: 760, height: 1000),
                supportsFullScreenOverlay: true
            )
        )
        .task {
            if companionIsDocked {
                DispatchQueue.main.async {
                    MacRecWindowCoordinator.shared.closeCompanion()
                }
            }
        }
    }

    private var companionControls: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(model.isRecording ? Color.green : Color.secondary)
                .frame(width: 9, height: 9)
            Text(model.isRecording ? Self.formatElapsed(model.elapsed) : "Ready")
                .font(.callout.monospacedDigit().weight(.medium))
                .foregroundStyle(model.isRecording ? .primary : .secondary)

            Spacer(minLength: 8)

            Button(action: dockCompanion) {
                Label("Dock with MacRec", systemImage: "rectangle.leadinghalf.inset.filled")
            }
            .help("Move the live transcript back into the MacRec control window.")
        }
    }

    private func dockCompanion() {
        MacRecWindowFrames.rememberUndockedControlFrame()
        companionIsDocked = true
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            MacRecWindowFrames.controlWindow?.makeKeyAndOrderFront(nil)
            MacRecWindowCoordinator.shared.closeCompanion()
        }
    }

    private static func formatElapsed(_ time: TimeInterval) -> String {
        let total = max(0, Int(time))
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}

private struct DockedCompanionPanel: View {
    @EnvironmentObject var model: AppModel
    let onPopOut: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Circle()
                    .fill(model.isRecording ? Color.green : Color.secondary)
                    .frame(width: 9, height: 9)
                Text(model.isRecording ? Self.formatElapsed(model.elapsed) : "Live Companion")
                    .font(.callout.monospacedDigit().weight(.medium))
                    .foregroundStyle(model.isRecording ? .primary : .secondary)
                Spacer(minLength: 8)
                Button(action: onPopOut) {
                    Label("Pop Out", systemImage: "rectangle.on.rectangle")
                }
            }

            Divider()
            LiveTranscriptPanel()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private static func formatElapsed(_ time: TimeInterval) -> String {
        let total = max(0, Int(time))
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}

private struct LiveTranscriptPanel: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        LiveTranscriptViewport(
            entries: model.transcriptEntries,
            revision: model.transcriptRevision,
            liveTranscriptionEnabled: model.liveTranscriptionEnabled,
            isRecording: model.isRecording
        )
        .equatable()
    }
}

private struct LiveTranscriptViewport: View, Equatable {
    let entries: [LiveTranscriptEntry]
    let revision: UInt64
    let liveTranscriptionEnabled: Bool
    let isRecording: Bool

    @State private var followState = TranscriptFollowState()

    private static let bottomID = "macrec-live-transcript-bottom"
    private static let scrollSpace = "macrec-live-transcript-scroll-space"

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.revision == rhs.revision
            && lhs.liveTranscriptionEnabled == rhs.liveTranscriptionEnabled
            && lhs.isRecording == rhs.isRecording
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Live transcript")
                    .font(.headline)
                Spacer()
                if liveTranscriptionEnabled {
                    Circle()
                        .fill(isRecording ? Color.green : Color.secondary)
                        .frame(width: 8, height: 8)
                }
            }

            if entries.isEmpty {
                Text(emptyMessage)
                    .foregroundStyle(.secondary)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            } else {
                ScrollViewReader { proxy in
                    GeometryReader { viewport in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 6) {
                                ForEach(entries) { entry in
                                    LiveTranscriptRow(entry: entry)
                                        .equatable()
                                }

                                Color.clear
                                    .frame(height: 1)
                                    .id(Self.bottomID)
                                    .background {
                                        GeometryReader { bottom in
                                            Color.clear.preference(
                                                key: TranscriptBottomPreferenceKey.self,
                                                value: bottom.frame(in: .named(Self.scrollSpace)).maxY
                                            )
                                        }
                                    }
                            }
                        }
                        .coordinateSpace(name: Self.scrollSpace)
                        .onAppear {
                            scrollToLive(using: proxy)
                        }
                        .onChange(of: revision) { _ in
                            guard followState.isFollowingLive else { return }
                            // Frequent partial-caption updates made overlapping
                            // animations feel jerky. Keeping the tail pinned is
                            // smoother and preserves direct manual scrolling.
                            DispatchQueue.main.async {
                                guard followState.isFollowingLive else { return }
                                scrollToLive(using: proxy)
                            }
                        }
                        .onPreferenceChange(TranscriptBottomPreferenceKey.self) { bottom in
                            updateFollowState(
                                bottom: bottom,
                                viewportHeight: viewport.size.height
                            )
                        }
                        .overlay(alignment: .bottomTrailing) {
                            if !followState.isFollowingLive {
                                Button {
                                    followState.jumpToLive()
                                    scrollToLive(using: proxy)
                                } label: {
                                    Label("Jump to live", systemImage: "arrow.down.to.line")
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                                .padding(8)
                            }
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var emptyMessage: String {
        guard liveTranscriptionEnabled else { return "Live transcription is off in the control window." }
        return isRecording
            ? "Listening for speech..."
            : "Ready before the meeting. Speech will appear here as soon as recording begins."
    }

    private func scrollToLive(using proxy: ScrollViewProxy) {
        proxy.scrollTo(Self.bottomID, anchor: .bottom)
    }

    private func updateFollowState(bottom: CGFloat, viewportHeight: CGFloat) {
        followState.observe(
            bottom: Double(bottom),
            viewportHeight: Double(viewportHeight),
            revision: revision
        )
    }
}

private struct LiveTranscriptRow: View, Equatable {
    let entry: LiveTranscriptEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Text(entry.speaker.displayName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(entry.speaker == .me ? .blue : .green)
                .frame(width: 66, alignment: .leading)
            Text(entry.text)
                .font(.body)
                .foregroundStyle(entry.isFinal ? .primary : .secondary)
                .italic(!entry.isFinal)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .opacity(entry.isFinal ? 1 : 0.78)
        .id(entry.id)
    }
}

private struct TranscriptBottomPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct WindowConfiguration: NSViewRepresentable {
    let autosaveName: String
    let minSize: NSSize
    let maxSize: NSSize
    let supportsFullScreenOverlay: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            applySizing(to: view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        applySizing(to: nsView.window)
    }

    private func applySizing(to window: NSWindow?) {
        guard let window else { return }
        if window.frameAutosaveName != autosaveName {
            window.setFrameAutosaveName(autosaveName)
        }
        if window.minSize != minSize {
            window.minSize = minSize
        }
        if window.maxSize != maxSize {
            window.maxSize = maxSize
        }
        if window.level != .normal {
            window.level = .normal
        }

        let isFullScreenAuxiliary = window.collectionBehavior.contains(.fullScreenAuxiliary)
        if supportsFullScreenOverlay, !isFullScreenAuxiliary {
            window.collectionBehavior.insert(.fullScreenAuxiliary)
        } else if !supportsFullScreenOverlay, isFullScreenAuxiliary {
            window.collectionBehavior.remove(.fullScreenAuxiliary)
        }

        let current = window.frame
        let clampedWidth = min(max(current.width, minSize.width), maxSize.width)
        let clampedHeight = min(max(current.height, minSize.height), maxSize.height)
        guard clampedWidth != current.width || clampedHeight != current.height else { return }

        let newOrigin = NSPoint(
            x: current.midX - clampedWidth / 2,
            y: current.midY - clampedHeight / 2
        )
        window.setFrame(NSRect(origin: newOrigin, size: NSSize(width: clampedWidth, height: clampedHeight)), display: true)
    }
}

private struct SourceLabel: View {
    let title: String
    let systemImage: String?

    var body: some View {
        Group {
            if let systemImage {
                Label(title, systemImage: systemImage)
            } else {
                Text(title)
            }
        }
        .frame(width: 150, alignment: .leading)
    }
}

private struct SourceControlRow<Source: View>: View {
    let title: String
    let systemImage: String
    let fileName: String
    @Binding var gain: Double
    let meterState: AudioMeterState
    let meterChannel: AudioMeterState.Channel
    let isRecording: Bool
    @ViewBuilder var source: Source

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            SourceLabel(title: title, systemImage: systemImage)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 14) {
                    source
                        .frame(width: 240, alignment: .leading)
                    GainControl(decibels: $gain)
                    LiveLevelMeter(state: meterState, channel: meterChannel)
                        .frame(width: 110)
                }
                HStack(spacing: 8) {
                    Text("File")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .leading)
                    Text(fileName)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }
}

private struct LiveLevelMeter: View {
    @ObservedObject var state: AudioMeterState
    let channel: AudioMeterState.Channel

    var body: some View {
        LevelMeter(
            value: channel == .microphone
                ? state.microphoneLevel
                : state.systemLevel
        )
    }
}

struct GainControl: View {
    @Binding var decibels: Double

    var body: some View {
        HStack(spacing: 8) {
            Slider(value: $decibels, in: -24...24, step: 1)
                .frame(width: 110)
            Text(Self.format(decibels))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .trailing)
        }
    }

    private static func format(_ value: Double) -> String {
        if value == 0 { return "0 dB" }
        return String(format: "%+.0f dB", value)
    }
}

struct LevelMeter: View {
    let value: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(.quaternary)
                RoundedRectangle(cornerRadius: 3)
                    .fill(color)
                    .frame(width: max(3, proxy.size.width * min(1, max(0, value))))
            }
        }
        .frame(width: 96, height: 8)
        .accessibilityLabel("Input level")
        .accessibilityValue("\(Int(value * 100)) percent")
    }

    private var color: Color {
        switch value {
        case 0.82...:
            return .red
        case 0.62...:
            return .yellow
        default:
            return .green
        }
    }
}
