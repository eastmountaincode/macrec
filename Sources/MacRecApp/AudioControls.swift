import SwiftUI
import Foundation

final class AudioMeterState: ObservableObject {
    enum Channel: Equatable, Sendable {
        case microphone
        case system
    }

    @Published private(set) var microphoneLevel: Double = 0
    @Published private(set) var systemLevel: Double = 0

    func set(_ value: Double, for channel: Channel) {
        switch channel {
        case .microphone:
            if microphoneLevel != value { microphoneLevel = value }
        case .system:
            if systemLevel != value { systemLevel = value }
        }
    }

    func reset() {
        set(0, for: .microphone)
        set(0, for: .system)
    }
}

final class AudioMeterThrottle: @unchecked Sendable {
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

struct SourceLabel: View {
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

struct SourceControlRow<Source: View>: View {
    let title: String
    let systemImage: String
    @Binding var gain: Double
    let meterState: AudioMeterState
    let meterChannel: AudioMeterState.Channel
    @ViewBuilder var source: Source

    var body: some View {
        HStack(spacing: 14) {
            SourceLabel(title: title, systemImage: systemImage)
            source.frame(width: 240, alignment: .leading)
            GainControl(decibels: $gain)
                .accessibilityLabel("\(title) gain")
            LiveLevelMeter(state: meterState, channel: meterChannel)
                .frame(width: 110)
                .accessibilityLabel("\(title) level")
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
