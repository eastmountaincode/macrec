import Foundation
import AVFoundation

public struct AudioInputDevice: Sendable, Hashable {
    public let id: String
    public let name: String
}

public enum AudioDevices {
    public static func availableInputs() -> [AudioInputDevice] {
        let devices = MicrophoneCapture.availableDevices().map {
            AudioInputDevice(id: $0.uniqueID, name: $0.localizedName)
        }
        guard let defaultID = MicrophoneCapture.defaultDeviceID() else { return devices }
        return devices.sorted { lhs, rhs in
            if lhs.id == defaultID { return true }
            if rhs.id == defaultID { return false }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }
}
