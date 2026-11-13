import CoreMedia
import Foundation

public final class AudioMonitor: @unchecked Sendable {
    public var onMicLevel: (@Sendable (AudioLevel) -> Void)?
    public var onSystemLevel: (@Sendable (AudioLevel) -> Void)?
    public var onSystemAvailable: (@Sendable (Bool) -> Void)?
    public var onError: (@Sendable (Error) -> Void)?

    private var micCapture: MicrophoneCapture?
    private var systemCapture: SystemAudioCapture?

    public init() {}

    public func start(micDeviceID: String? = nil) async throws {
        await stop()

        let mic = MicrophoneCapture()
        mic.onSampleBuffer = { [weak self] buffer in
            self?.onMicLevel?(AudioLevelMeter.level(for: buffer))
        }

        let system = SystemAudioCapture()
        system.onLevel = { [weak self] level in
            self?.onSystemLevel?(level)
        }
        system.onError = { [weak self] error in
            self?.onError?(error)
        }

        try mic.start(deviceID: micDeviceID)
        micCapture = mic

        do {
            try await system.start()
            systemCapture = system
            onSystemAvailable?(true)
        } catch {
            onSystemAvailable?(false)
            onSystemLevel?(.silence)
            onError?(error)
        }
    }

    public func stop() async {
        micCapture?.stop()
        await systemCapture?.stop()
        micCapture = nil
        systemCapture = nil
    }
}
