import Foundation
import AVFoundation
import CoreMedia

private final class SampleBufferBox: @unchecked Sendable {
    let value: CMSampleBuffer

    init(_ value: CMSampleBuffer) {
        self.value = value
    }
}

/// Wraps an AVAssetWriter to encode incoming CMSampleBuffers as AAC into an .m4a file.
/// Audio-only writer; uses the timestamps already on the buffers, so two writers fed from
/// captures started in the same session line up sample-accurately.
final class AudioFileWriter: @unchecked Sendable {
    private let url: URL
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private var started = false
    private var sessionStartTime: CMTime = .invalid
    private let queue = DispatchQueue(label: "macrec.audiowriter", qos: .userInitiated)

    init(url: URL, sourceFormat: CMFormatDescription? = nil) throws {
        self.url = url
        try? FileManager.default.removeItem(at: url)
        self.writer = try AVAssetWriter(outputURL: url, fileType: .m4a)

        var settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVEncoderBitRateKey: 128_000,
        ]
        if let asbd = sourceFormat?.audioStreamBasicDescription {
            settings[AVNumberOfChannelsKey] = Int(asbd.mChannelsPerFrame)
            settings[AVSampleRateKey] = asbd.mSampleRate
        } else {
            settings[AVNumberOfChannelsKey] = 2
            settings[AVSampleRateKey] = 48_000
        }

        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else {
            throw NSError(domain: "macrec", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot add audio input to writer"])
        }
        writer.add(input)
        self.input = input
    }

    func append(_ sampleBuffer: CMSampleBuffer) {
        let box = SampleBufferBox(sampleBuffer)
        queue.async { [weak self] in
            guard let self else { return }
            let sampleBuffer = box.value
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            if !self.started {
                guard self.writer.startWriting() else { return }
                self.writer.startSession(atSourceTime: pts)
                self.sessionStartTime = pts
                self.started = true
            }
            if self.input.isReadyForMoreMediaData {
                self.input.append(sampleBuffer)
            }
        }
    }

    func finish() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async { [weak self] in
                guard let self, self.started else { cont.resume(); return }
                self.input.markAsFinished()
                self.writer.finishWriting {
                    cont.resume()
                }
            }
        }
    }

    var outputURL: URL { url }
}

final class SampleBufferAudioFileWriter: @unchecked Sendable {
    private let url: URL
    private var file: AVAudioFile?
    private var format: AVAudioFormat?
    private var sourceFormat: AudioStreamBasicDescription?
    private var gain: Double
    private let queue = DispatchQueue(label: "macrec.samplebufferwriter", qos: .userInitiated)

    init(url: URL, gain: Double = 1) {
        self.url = url
        self.gain = gain
        try? FileManager.default.removeItem(at: url)
    }

    func append(_ sampleBuffer: CMSampleBuffer) {
        let box = SampleBufferBox(sampleBuffer)
        queue.async { [weak self] in
            guard let self else { return }
            do {
                try self.appendOnQueue(box.value)
            } catch {
                FileHandle.standardError.write(Data("audio write error: \(error)\n".utf8))
            }
        }
    }

    func setGain(_ gain: Double) {
        queue.async { [weak self] in
            self?.gain = gain
        }
    }

    private func appendOnQueue(_ sampleBuffer: CMSampleBuffer) throws {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescriptionPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription),
              streamDescriptionPointer.pointee.mFormatID == kAudioFormatLinearPCM else {
            return
        }

        let streamDescription = streamDescriptionPointer.pointee
        if file == nil {
            try openFile(sourceFormat: streamDescription)
        }
        guard let format, let sourceFormat else { return }

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
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
        guard status == noErr, bufferListSize > 0 else { return }

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
        guard status == noErr else { return }

        let sourceBuffers = UnsafeMutableAudioBufferListPointer(sourceBufferList)
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        for (index, sourceBuffer) in sourceBuffers.enumerated() where index < destinationBuffers.count {
            guard let source = sourceBuffer.mData, let destination = destinationBuffers[index].mData else { continue }
            memcpy(destination, source, min(Int(sourceBuffer.mDataByteSize), Int(destinationBuffers[index].mDataByteSize)))
        }

        AudioGain.apply(gain, to: destinationBuffers, format: sourceFormat)
        try file?.write(from: buffer)
    }

    private func openFile(sourceFormat: AudioStreamBasicDescription) throws {
        var sourceFormat = sourceFormat
        guard let format = AVAudioFormat(streamDescription: &sourceFormat) else { return }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVEncoderBitRateKey: 128_000,
            AVNumberOfChannelsKey: Int(sourceFormat.mChannelsPerFrame),
            AVSampleRateKey: sourceFormat.mSampleRate,
        ]

        file = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        self.format = format
        self.sourceFormat = sourceFormat
    }

    func finish() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async {
                cont.resume()
            }
        }
    }

    var outputURL: URL { url }
}
