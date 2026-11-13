import Foundation
import CoreMedia

public actor Recorder {
    public enum State: Sendable { case idle, recording, stopping }

    private var state: State = .idle
    private var session: RecordingSession?
    private var micCapture: MicrophoneCapture?
    private var systemCapture: SystemAudioCapture?
    private var micWriter: SampleBufferAudioFileWriter?
    private var systemWriter: SystemAudioFileWriter?

    public init() {}

    public func currentState() -> State { state }

    public func setGains(micGainDecibels: Double, systemGainDecibels: Double) {
        micWriter?.setGain(AudioGain.linear(fromDecibels: micGainDecibels))
        systemWriter?.setGain(AudioGain.linear(fromDecibels: systemGainDecibels))
    }

    /// Begin a recording. Creates a dated folder under `outputDirectory` containing
    /// separate local microphone and system-audio tracks.
    public func start(
        outputDirectory: URL,
        title: String? = nil,
        micDeviceID: String? = nil,
        micGainDecibels: Double = 0,
        systemGainDecibels: Double = 0,
        onMicLevel: (@Sendable (AudioLevel) -> Void)? = nil,
        onSystemLevel: (@Sendable (AudioLevel) -> Void)? = nil,
        onMicSampleBuffer: (@Sendable (CMSampleBuffer) -> Void)? = nil,
        onSystemSample: (@Sendable (SystemAudioSample) -> Void)? = nil
    ) async throws -> RecordingSession {
        guard state == .idle else {
            throw NSError(domain: "macrec", code: 10, userInfo: [NSLocalizedDescriptionKey: "Recorder is not idle"])
        }
        let session = RecordingSession(directory: outputDirectory, title: title)
        try FileManager.default.createDirectory(at: session.directory, withIntermediateDirectories: true)

        let micGain = AudioGain.linear(fromDecibels: micGainDecibels)
        let systemGain = AudioGain.linear(fromDecibels: systemGainDecibels)

        let micWriter = SampleBufferAudioFileWriter(url: session.micFile, gain: micGain)
        let mic = MicrophoneCapture()
        mic.onSampleBuffer = { buf in
            micWriter.append(buf)
            onMicSampleBuffer?(buf)
            onMicLevel?(AudioLevelMeter.level(for: buf))
        }

        let sys = SystemAudioCapture()
        sys.onLevel = { level in
            onSystemLevel?(level)
        }
        sys.onError = { err in
            FileHandle.standardError.write(Data("system capture error: \(err)\n".utf8))
        }

        try mic.start(deviceID: micDeviceID)
        do {
            try await sys.start()
        } catch {
            mic.stop()
            throw error
        }

        guard let systemFormat = sys.currentFormat() else {
            mic.stop()
            await sys.stop()
            throw NSError(domain: "macrec", code: 12, userInfo: [NSLocalizedDescriptionKey: "System audio started without a readable stream format"])
        }

        let systemWriter: SystemAudioFileWriter
        do {
            systemWriter = try SystemAudioFileWriter(url: session.systemFile, sourceFormat: systemFormat, gain: systemGain)
        } catch {
            mic.stop()
            await sys.stop()
            throw error
        }
        sys.onSample = { sample in
            systemWriter.append(sample)
            onSystemSample?(sample)
        }

        self.session = session
        self.micCapture = mic
        self.systemCapture = sys
        self.micWriter = micWriter
        self.systemWriter = systemWriter
        self.state = .recording
        return session
    }

    @discardableResult
    public func stop() async throws -> RecordingSession {
        guard state == .recording, let session = session else {
            throw NSError(domain: "macrec", code: 11, userInfo: [NSLocalizedDescriptionKey: "Not recording"])
        }
        state = .stopping

        micCapture?.stop()
        await systemCapture?.stop()

        await micWriter?.finish()
        await systemWriter?.finish()

        self.micCapture = nil
        self.systemCapture = nil
        self.micWriter = nil
        self.systemWriter = nil
        self.session = nil
        self.state = .idle
        return session
    }
}
