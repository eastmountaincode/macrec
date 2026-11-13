import Combine
import Foundation
import Testing
@testable import MacRecApp

@Test @MainActor
func fileTranscriptionCannotInterruptARecording() {
    for phase in 0..<3 {
        let model = AppModel(startServices: false)
        model.isStartingRecording = phase == 0
        model.isRecording = phase == 1
        model.isStoppingRecording = phase == 2
        model.setFileInput(URL(fileURLWithPath: "/tmp/example.wav"))

        #expect(!model.canTranscribeFile)
        model.transcribeInputFile()
        #expect(!model.isFileTranscribing)

        model.selectTranscriptionModel(.moonshineSmall)
        model.setLiveTranscriptionEnabled(false)
        #expect(model.transcriptionModel == .moonshineMedium)
        #expect(model.liveTranscriptionEnabled)
    }
}

@Test @MainActor
func fileTranscriptionKeepsItsInputAndBlocksRecording() {
    let model = AppModel(startServices: false)
    let input = URL(fileURLWithPath: "/tmp/original.wav")
    model.setFileInput(input)
    model.liveTranscriptionEnabled = false
    model.isFileTranscribing = true

    model.setFileInput(URL(fileURLWithPath: "/tmp/replacement.wav"))
    model.toggleRecording()

    #expect(model.fileInputURL == input)
    #expect(!model.canRecord)
    #expect(!model.isStartingRecording)
}

@Test @MainActor
func captionUpdatesDoNotInvalidateRecordingControls() {
    let model = AppModel(startServices: false)
    var controlUpdates = 0
    let subscription = model.objectWillChange.sink { controlUpdates += 1 }
    let entries = (0..<200).map { index in
        LiveTranscriptEntry(
            id: "line-\(index)",
            speaker: .me,
            start: Float(index),
            end: Float(index + 1),
            text: "Caption \(index)"
        )
    }

    model.liveTranscript.publish(entries)
    #expect(model.liveTranscript.entries.count == 180)
    #expect(model.liveTranscript.entries.first?.id == "line-20")
    #expect(model.liveTranscript.revision == 1)
    model.liveTranscript.publish(entries)
    #expect(model.liveTranscript.revision == 1)
    #expect(controlUpdates == 0)
    withExtendedLifetime(subscription) {}
}

@Test
func transcriptExportKeepsAllEntriesAndOrdersSimultaneousSpeechConsistently() {
    let first = LiveTranscriptEntry(id: "a", speaker: .me, start: 0, end: 1, text: "First")
    let second = LiveTranscriptEntry(id: "b", speaker: .call, start: 0, end: 1, text: "Second")
    #expect(TranscriptRenderer.renderLive([first, second]) == TranscriptRenderer.renderLive([second, first]))

    let entries = (0..<200).map { index in
        LiveTranscriptEntry(
            id: "line-\(index)", speaker: .me, start: Float(index), end: Float(index + 1), text: "Caption \(index)"
        )
    }
    let exported = TranscriptRenderer.renderLive(entries)
    #expect(exported.contains("Caption 0\n"))
    #expect(exported.contains("Caption 199\n"))
}
