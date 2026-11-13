import AVFoundation
import CoreAudio
import Foundation

public struct SystemAudioSample: @unchecked Sendable {
    public let format: AudioStreamBasicDescription
    public let frameCount: AVAudioFrameCount
    public let buffers: [Data]
}

struct AudioGain {
    static func linear(fromDecibels decibels: Double) -> Double {
        pow(10, decibels / 20)
    }

    static func apply(_ gain: Double, to buffer: UnsafeMutableAudioBufferListPointer, format: AudioStreamBasicDescription) {
        guard gain != 1 else { return }

        let flags = format.mFormatFlags
        let bitsPerChannel = Int(format.mBitsPerChannel)
        let isFloat = flags & kAudioFormatFlagIsFloat != 0
        let isSignedInteger = flags & kAudioFormatFlagIsSignedInteger != 0

        for audioBuffer in buffer {
            guard let data = audioBuffer.mData else { continue }
            let byteCount = Int(audioBuffer.mDataByteSize)

            if isFloat, bitsPerChannel == 32 {
                let samples = data.bindMemory(to: Float.self, capacity: byteCount / MemoryLayout<Float>.size)
                for i in 0..<(byteCount / MemoryLayout<Float>.size) {
                    samples[i] = Float(max(-1, min(1, Double(samples[i]) * gain)))
                }
            } else if isSignedInteger, bitsPerChannel == 16 {
                let samples = data.bindMemory(to: Int16.self, capacity: byteCount / MemoryLayout<Int16>.size)
                for i in 0..<(byteCount / MemoryLayout<Int16>.size) {
                    let scaled = Double(samples[i]) * gain
                    samples[i] = Int16(max(Double(Int16.min), min(Double(Int16.max), scaled)))
                }
            } else if isSignedInteger, bitsPerChannel == 32 {
                let samples = data.bindMemory(to: Int32.self, capacity: byteCount / MemoryLayout<Int32>.size)
                for i in 0..<(byteCount / MemoryLayout<Int32>.size) {
                    let scaled = Double(samples[i]) * gain
                    samples[i] = Int32(max(Double(Int32.min), min(Double(Int32.max), scaled)))
                }
            }
        }
    }
}

private enum SystemAudioCaptureError: LocalizedError {
    case unsupportedOS
    case invalidFormat
    case coreAudio(operation: String, status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .unsupportedOS:
            return "System audio capture requires macOS 14.2 or newer."
        case .invalidFormat:
            return "System audio is not available in a recordable PCM format."
        case let .coreAudio(operation, status):
            return "\(operation) failed with CoreAudio status \(status)."
        }
    }
}

/// Captures all other app audio through a private CoreAudio process tap.
///
/// This uses macOS' "System Audio Recording Only" permission path instead of
/// ScreenCaptureKit's screen-recording stream. The app's own audio is excluded.
final class SystemAudioCapture: @unchecked Sendable {
    private let ioQueue = DispatchQueue(label: "macrec.system.tap", qos: .userInitiated)
    private let stateLock = NSLock()

    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var aggregateID: AudioObjectID = kAudioObjectUnknown
    private var ioProcID: AudioDeviceIOProcID?
    private var streamFormat: AudioStreamBasicDescription?

    var onSample: ((SystemAudioSample) -> Void)?
    var onLevel: ((AudioLevel) -> Void)?
    var onError: ((Error) -> Void)?

    func start() async throws {
        try startSync()
    }

    func stop() async {
        stopSync()
    }

    func currentFormat() -> AudioStreamBasicDescription? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return streamFormat
    }

    private func startSync() throws {
        if #available(macOS 14.2, *) {
            stateLock.lock()
            defer { stateLock.unlock() }

            guard tapID == kAudioObjectUnknown, aggregateID == kAudioObjectUnknown else { return }

            do {
                let tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
                tapDescription.name = "MacRec System Audio"
                tapDescription.isPrivate = true
                tapDescription.muteBehavior = .unmuted

                var newTapID: AudioObjectID = kAudioObjectUnknown
                try Self.check(
                    AudioHardwareCreateProcessTap(tapDescription, &newTapID),
                    "Create system audio tap"
                )
                tapID = newTapID

                let tapUID = try Self.stringProperty(newTapID, selector: kAudioTapPropertyUID)
                let format = try Self.streamDescriptionProperty(newTapID, selector: kAudioTapPropertyFormat)
                guard format.mFormatID == kAudioFormatLinearPCM else {
                    throw SystemAudioCaptureError.invalidFormat
                }
                streamFormat = format

                let aggregateDescription: [String: Any] = [
                    kAudioAggregateDeviceNameKey: "MacRec System Audio",
                    kAudioAggregateDeviceUIDKey: "com.macrec.system-audio.\(UUID().uuidString)",
                    kAudioAggregateDeviceIsPrivateKey: true,
                    kAudioAggregateDeviceTapListKey: [[
                        kAudioSubTapUIDKey: tapUID,
                        kAudioSubTapDriftCompensationKey: true,
                    ]],
                ]

                var newAggregateID: AudioObjectID = kAudioObjectUnknown
                try Self.check(
                    AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &newAggregateID),
                    "Create system audio aggregate device"
                )
                aggregateID = newAggregateID

                var newIOProcID: AudioDeviceIOProcID?
                let block: AudioDeviceIOBlock = { [weak self] _, inputData, _, _, _ in
                    guard let self else { return }
                    self.handle(inputData)
                }
                try Self.check(
                    AudioDeviceCreateIOProcIDWithBlock(&newIOProcID, newAggregateID, ioQueue, block),
                    "Create system audio IO callback"
                )
                ioProcID = newIOProcID

                try Self.check(
                    AudioDeviceStart(newAggregateID, newIOProcID),
                    "Start system audio tap"
                )
            } catch {
                stopLocked()
                throw error
            }
        } else {
            throw SystemAudioCaptureError.unsupportedOS
        }
    }

    private func stopSync() {
        stateLock.lock()
        defer { stateLock.unlock() }
        stopLocked()
    }

    private func stopLocked() {
        if aggregateID != kAudioObjectUnknown, let ioProcID {
            _ = AudioDeviceStop(aggregateID, ioProcID)
            _ = AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil

        if aggregateID != kAudioObjectUnknown {
            _ = AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        aggregateID = kAudioObjectUnknown

        if #available(macOS 14.2, *), tapID != kAudioObjectUnknown {
            _ = AudioHardwareDestroyProcessTap(tapID)
        }
        tapID = kAudioObjectUnknown
        streamFormat = nil
    }

    private func handle(_ inputData: UnsafePointer<AudioBufferList>) {
        guard let format = streamFormat else { return }
        let frameCount = Self.frameCount(in: inputData, format: format)
        guard frameCount > 0 else {
            onLevel?(.silence)
            return
        }

        onLevel?(AudioLevelMeter.level(for: inputData, format: format))
        onSample?(SystemAudioSample(
            format: format,
            frameCount: AVAudioFrameCount(frameCount),
            buffers: Self.copyBuffers(from: inputData)
        ))
    }

    private static func copyBuffers(from audioBufferList: UnsafePointer<AudioBufferList>) -> [Data] {
        UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: audioBufferList)).map { buffer in
            guard let data = buffer.mData, buffer.mDataByteSize > 0 else { return Data() }
            return Data(bytes: data, count: Int(buffer.mDataByteSize))
        }
    }

    private static func frameCount(
        in audioBufferList: UnsafePointer<AudioBufferList>,
        format: AudioStreamBasicDescription
    ) -> UInt32 {
        guard format.mBytesPerFrame > 0 else { return 0 }
        return UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: audioBufferList))
            .map { $0.mDataByteSize / format.mBytesPerFrame }
            .max() ?? 0
    }

    private static func stringProperty(_ objectID: AudioObjectID, selector: AudioObjectPropertySelector) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &dataSize), "Read CoreAudio property size")
        var value: Unmanaged<CFString>?
        try check(AudioObjectGetPropertyData(objectID, &address, 0, nil, &dataSize, &value), "Read CoreAudio string property")
        return value?.takeRetainedValue() as String? ?? ""
    }

    private static func streamDescriptionProperty(
        _ objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = AudioStreamBasicDescription()
        var dataSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioObjectGetPropertyData(objectID, &address, 0, nil, &dataSize, &value), "Read CoreAudio stream format")
        return value
    }

    private static func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else {
            throw SystemAudioCaptureError.coreAudio(operation: operation, status: status)
        }
    }
}

final class SystemAudioFileWriter: @unchecked Sendable {
    private let file: AVAudioFile
    private let format: AVAudioFormat
    private let sourceFormat: AudioStreamBasicDescription
    private var gain: Double
    private let queue = DispatchQueue(label: "macrec.system.writer", qos: .userInitiated)

    init(url: URL, sourceFormat: AudioStreamBasicDescription, gain: Double = 1) throws {
        var sourceFormat = sourceFormat
        guard let format = AVAudioFormat(streamDescription: &sourceFormat) else {
            throw SystemAudioCaptureError.invalidFormat
        }
        try? FileManager.default.removeItem(at: url)

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVEncoderBitRateKey: 128_000,
            AVNumberOfChannelsKey: Int(sourceFormat.mChannelsPerFrame),
            AVSampleRateKey: sourceFormat.mSampleRate,
        ]

        self.file = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        self.format = format
        self.sourceFormat = sourceFormat
        self.gain = gain
    }

    func append(_ sample: SystemAudioSample) {
        queue.async { [weak self] in
            guard let self else { return }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: self.format, frameCapacity: sample.frameCount) else { return }
            buffer.frameLength = sample.frameCount

            let destinationBuffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            for (index, data) in sample.buffers.enumerated() where index < destinationBuffers.count {
                guard let destination = destinationBuffers[index].mData else { continue }
                data.withUnsafeBytes { rawBuffer in
                    guard let source = rawBuffer.baseAddress else { return }
                    memcpy(destination, source, min(Int(destinationBuffers[index].mDataByteSize), data.count))
                }
            }

            AudioGain.apply(self.gain, to: destinationBuffers, format: self.sourceFormat)

            do {
                try self.file.write(from: buffer)
            } catch {
                FileHandle.standardError.write(Data("system audio write error: \(error)\n".utf8))
            }
        }
    }

    func setGain(_ gain: Double) {
        queue.async { [weak self] in
            self?.gain = gain
        }
    }

    func finish() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async {
                cont.resume()
            }
        }
    }
}
