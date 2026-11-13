import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MacRecCore

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
        VStack(alignment: .leading, spacing: 16) {
            recordPanel
            Divider()
            settingsPanel
            Divider()
            transcriptionControlsPanel
            Divider()
            outputPanel
            recentsPanel
        }
    }

    private var transcribeAudioLayout: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Transcribe audio")
                    .font(.title2.weight(.semibold))
                Spacer()
                Picker("Model", selection: $model.fileTranscriptionModel) {
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
                        Button("Choose file…") { model.chooseInputFile() }
                            .disabled(model.isFileTranscribing)

                        Button("Transcribe") { model.transcribeInputFile() }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.fileInputURL == nil || !model.canTranscribeFile)

                        if model.isFileTranscribing {
                            Button("Cancel") { model.cancelFileTranscription() }
                                .keyboardShortcut(.cancelAction)
                        }

                        if let output = model.fileTranscriptURL {
                            Button("Show in Finder") { model.revealInFinder(output) }
                        }
                    }

                    if model.isSessionActive {
                        Text("Stop recording before transcribing a file.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
                    Button("Choose folder…") { model.chooseOutputDir() }
                        .disabled(model.isFileTranscribing || model.isSessionActive)

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
                                Text("Elapsed \(RecordingDuration.format(model.fileTranscriptionElapsed))")
                                    .foregroundStyle(.secondary)
                                if let remaining = model.fileTranscriptionRemaining {
                                    Text("About \(RecordingDuration.format(remaining)) remaining")
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
        guard !model.isFileTranscribing, let provider = providers.first else { return false }
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
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                TextField("Recording title (optional)", text: $model.title)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                    .accessibilityLabel("Recording title")
                    .disabled(model.isSessionActive)

                Button(action: model.toggleRecording) {
                    Label(recordButtonTitle, systemImage: model.isRecording ? "stop.fill" : "record.circle")
                        .frame(width: 110)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(model.isRecording ? .red : .accentColor)
                .disabled(model.isStartingRecording || model.isStoppingRecording || (!model.isRecording && !model.canRecord))
            }

            HStack(spacing: 12) {
                if let startedAt = model.recordingStartedAt {
                    Label(model.isStoppingRecording ? "Saving recording…" : "Recording", systemImage: "record.circle.fill")
                        .foregroundStyle(.red)
                    RecordingDuration(startedAt: startedAt)
                } else {
                    Text(model.isFileTranscribing ? "Transcribing file…" : "Monitoring inputs")
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if !companionIsDocked {
                    Button {
                        MacRecWindowCoordinator.shared.showCompanion(using: openWindow)
                    } label: {
                        Label("Show transcript", systemImage: "rectangle.on.rectangle")
                    }
                }

                Button("Clear", action: model.clearMeetingState)
                    .disabled(model.isSessionActive)
                    .help("Clear the title and displayed transcript. Saved files are kept.")
            }
            .font(.callout)
            .buttonStyle(.borderless)

            if let error = model.lastError ?? model.monitoringError {
                HStack(alignment: .top, spacing: 10) {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                    if model.lastError == nil && !model.isSessionActive {
                        Button("Retry", action: model.retryMonitoring)
                    }
                }
                .font(.callout)
            }
        }
    }

    private var recordButtonTitle: String {
        if model.isStartingRecording { return "Starting…" }
        if model.isStoppingRecording { return "Finishing…" }
        return model.isRecording ? "Stop" : "Record"
    }

    private var settingsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Audio sources").font(.headline)

            HStack(spacing: 14) {
                SourceLabel(title: "", systemImage: nil)
                Text("Input").frame(width: 240, alignment: .leading)
                Text("Gain").frame(width: 166, alignment: .leading)
                Text("Level").frame(width: 110, alignment: .leading)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)

            SourceControlRow(
                title: "Microphone",
                systemImage: "mic.fill",
                gain: Binding(
                    get: { model.micGainDecibels },
                    set: { model.setMicGainDecibels($0) }
                ),
                meterState: model.audioMeters,
                meterChannel: .microphone
            ) {
                HStack(spacing: 8) {
                    Picker("Microphone", selection: Binding(
                        get: { model.selectedMicID ?? "" },
                        set: { model.selectMic($0.isEmpty ? nil : $0) }
                    )) {
                        ForEach(model.inputs, id: \.id) { device in
                            Text(device.name).tag(device.id)
                        }
                    }
                    .labelsHidden()
                    .disabled(model.isSessionActive)

                    Button(action: model.refreshInputs) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Refresh microphones")
                    .accessibilityLabel("Refresh microphones")
                    .disabled(model.isSessionActive)
                }
            }

            SourceControlRow(
                title: "System audio",
                systemImage: "speaker.wave.2.fill",
                gain: Binding(
                    get: { model.systemGainDecibels },
                    set: { model.setSystemGainDecibels($0) }
                ),
                meterState: model.audioMeters,
                meterChannel: .system
            ) {
                Text("All Mac audio")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var transcriptionControlsPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 16) {
                Toggle("Live transcript", isOn: Binding(
                    get: { model.liveTranscriptionEnabled },
                    set: { model.setLiveTranscriptionEnabled($0) }
                ))
                .font(.headline)
                .disabled(model.isSessionActive || model.isFileTranscribing || model.isTranscriberLoading)

                if model.liveTranscriptionEnabled {
                    Picker("Model", selection: Binding(
                        get: { model.transcriptionModel },
                        set: { model.selectTranscriptionModel($0) }
                    )) {
                        ForEach(LiveTranscriptionModel.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    .frame(width: 240)
                    .disabled(model.isSessionActive || model.isFileTranscribing || model.isTranscriberLoading)
                }
                Spacer()
            }

            if model.liveTranscriptionEnabled {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if model.isTranscriberLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: model.transcriptStatus.isFailure ? "exclamationmark.triangle" : "text.bubble")
                    }
                    Text(model.isRecording && model.isTranscriberReady ? "Transcribing…" : model.transcriptStatus.message)
                        .textSelection(.enabled)
                    if !model.isTranscriberReady && !model.isTranscriberLoading && !model.isSessionActive && !model.isFileTranscribing {
                        Button("Retry", action: model.prepareTranscriber)
                            .buttonStyle(.borderless)
                    }
                }
                .font(.callout)
                .foregroundStyle(model.transcriptStatus.isFailure ? Color.red : Color.secondary)

                if model.isTranscriberLoading, let progress = model.transcriptProgress {
                    ProgressView(value: progress)
                        .frame(maxWidth: 360)
                }

                if model.transcriptionModel.isMoonshine, let notice = model.refinementStatus.notice {
                    Text(notice)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var outputPanel: some View {
        HStack(spacing: 12) {
            Label("Save to", systemImage: "folder")
                .font(.headline)
            Text(model.outputDir.path)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(model.outputDir.path)
            Spacer(minLength: 0)
            Button("Choose…", action: model.chooseOutputDir)
                .disabled(model.isSessionActive || model.isFileTranscribing)
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
                                Button("Show in Finder") { model.revealInFinder(url) }
                                    .buttonStyle(.borderless)
                            }
                        }
                    }
                }
                .frame(maxHeight: 160)
            }
        }
    }

}
