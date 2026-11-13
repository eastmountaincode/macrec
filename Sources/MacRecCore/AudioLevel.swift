import AVFoundation
import CoreMedia
import Foundation

public struct AudioLevel: Sendable, Equatable {
    public let linear: Double
    public let decibels: Double

    public var normalized: Double {
        min(1, max(0, (decibels + 60) / 60))
    }

    public static let silence = AudioLevel(linear: 0)

    init(linear: Double) {
        let clamped = min(1, max(0, linear))
        self.linear = clamped
        self.decibels = clamped > 0 ? max(-60, 20 * log10(clamped)) : -60
    }

    public func applyingGain(_ gain: Double) -> AudioLevel {
        AudioLevel(linear: linear * gain)
    }
}

enum AudioLevelMeter {
    static func level(for audioBufferList: UnsafePointer<AudioBufferList>, format streamDescription: AudioStreamBasicDescription) -> AudioLevel {
        guard streamDescription.mFormatID == kAudioFormatLinearPCM else {
            return .silence
        }

        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: audioBufferList))
        let flags = streamDescription.mFormatFlags
        let bitsPerChannel = Int(streamDescription.mBitsPerChannel)
        let isFloat = flags & kAudioFormatFlagIsFloat != 0
        let isSignedInteger = flags & kAudioFormatFlagIsSignedInteger != 0

        return level(
            buffers: buffers.map { ($0.mData, Int($0.mDataByteSize)) },
            bitsPerChannel: bitsPerChannel,
            isFloat: isFloat,
            isSignedInteger: isSignedInteger
        )
    }

    static func level(for sampleBuffer: CMSampleBuffer) -> AudioLevel {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription),
              streamDescription.pointee.mFormatID == kAudioFormatLinearPCM else {
            return .silence
        }

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
        guard status == noErr, bufferListSize > 0 else { return .silence }

        let rawBufferList = UnsafeMutableRawPointer.allocate(
            byteCount: bufferListSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawBufferList.deallocate() }

        let audioBufferList = rawBufferList.bindMemory(to: AudioBufferList.self, capacity: 1)
        var blockBuffer: CMBlockBuffer?
        status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: audioBufferList,
            bufferListSize: bufferListSize,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else { return .silence }

        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        let flags = streamDescription.pointee.mFormatFlags
        let bitsPerChannel = Int(streamDescription.pointee.mBitsPerChannel)
        let isFloat = flags & kAudioFormatFlagIsFloat != 0
        let isSignedInteger = flags & kAudioFormatFlagIsSignedInteger != 0

        return level(
            buffers: buffers.map { ($0.mData, Int($0.mDataByteSize)) },
            bitsPerChannel: bitsPerChannel,
            isFloat: isFloat,
            isSignedInteger: isSignedInteger
        )
    }

    private static func level(
        buffers: [(UnsafeMutableRawPointer?, Int)],
        bitsPerChannel: Int,
        isFloat: Bool,
        isSignedInteger: Bool
    ) -> AudioLevel {
        var sumSquares = 0.0
        var sampleCount = 0

        for buffer in buffers {
            guard let data = buffer.0 else { continue }
            let byteCount = buffer.1

            if isFloat, bitsPerChannel == 32 {
                let samples = data.bindMemory(to: Float.self, capacity: byteCount / MemoryLayout<Float>.size)
                let count = byteCount / MemoryLayout<Float>.size
                for i in 0..<count {
                    let sample = Double(samples[i])
                    sumSquares += sample * sample
                }
                sampleCount += count
            } else if isSignedInteger, bitsPerChannel == 16 {
                let samples = data.bindMemory(to: Int16.self, capacity: byteCount / MemoryLayout<Int16>.size)
                let count = byteCount / MemoryLayout<Int16>.size
                for i in 0..<count {
                    let sample = Double(samples[i]) / Double(Int16.max)
                    sumSquares += sample * sample
                }
                sampleCount += count
            } else if isSignedInteger, bitsPerChannel == 32 {
                let samples = data.bindMemory(to: Int32.self, capacity: byteCount / MemoryLayout<Int32>.size)
                let count = byteCount / MemoryLayout<Int32>.size
                for i in 0..<count {
                    let sample = Double(samples[i]) / Double(Int32.max)
                    sumSquares += sample * sample
                }
                sampleCount += count
            }
        }

        guard sampleCount > 0 else { return .silence }
        return AudioLevel(linear: sqrt(sumSquares / Double(sampleCount)))
    }
}
