import Foundation
import AVFoundation
import CoreMedia

/// Captures the default (or chosen) microphone via AVCaptureSession.
final class MicrophoneCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let outputQueue = DispatchQueue(label: "macrec.mic.output", qos: .userInitiated)
    private let output = AVCaptureAudioDataOutput()
    var onSampleBuffer: ((CMSampleBuffer) -> Void)?

    func start(deviceID: String? = nil) throws {
        session.beginConfiguration()

        let device: AVCaptureDevice?
        if let deviceID = deviceID {
            device = AVCaptureDevice(uniqueID: deviceID)
        } else {
            device = AVCaptureDevice.default(for: .audio)
        }
        guard let device = device else {
            throw NSError(domain: "macrec", code: 3, userInfo: [NSLocalizedDescriptionKey: "No audio input device found"])
        }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw NSError(domain: "macrec", code: 4, userInfo: [NSLocalizedDescriptionKey: "Cannot add mic input"])
        }
        session.addInput(input)

        output.setSampleBufferDelegate(self, queue: outputQueue)
        guard session.canAddOutput(output) else {
            throw NSError(domain: "macrec", code: 5, userInfo: [NSLocalizedDescriptionKey: "Cannot add mic output"])
        }
        session.addOutput(output)

        session.commitConfiguration()
        session.startRunning()
    }

    func stop() {
        session.stopRunning()
    }

    static func defaultDeviceID() -> String? {
        AVCaptureDevice.default(for: .audio)?.uniqueID
    }

    static func availableDevices() -> [AVCaptureDevice] {
        let deviceTypes: [AVCaptureDevice.DeviceType]
        if #available(macOS 14.0, *) {
            deviceTypes = [.microphone, .external]
        } else {
            deviceTypes = [
                AVCaptureDevice.DeviceType(rawValue: "AVCaptureDeviceTypeBuiltInMicrophone"),
                AVCaptureDevice.DeviceType(rawValue: "AVCaptureDeviceTypeExternalUnknown"),
            ]
        }

        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .audio,
            position: .unspecified
        )
        return discovery.devices
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard sampleBuffer.isValid, sampleBuffer.numSamples > 0 else { return }
        onSampleBuffer?(sampleBuffer)
    }
}
