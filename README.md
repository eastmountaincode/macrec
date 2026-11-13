# macrec

A clean replacement for the OBS-based "record system audio + my mic" workflow on macOS.

## What it does

Records two audio tracks straight to disk via Apple's native APIs:

- `<date>-<title>-me.m4a` — your microphone (= "Me" in the transcript)
- `<date>-<title>-call.m4a` — everything coming out of your speakers (= the other people in the call)

A separate Python pipeline turns a recording into a transcript labeled structurally by track: `Me` for the microphone and `Call` for system audio.
The SwiftUI app also runs a live transcript while recording. Moonshine medium supplies the immediate captions, then Whisper large v3 automatically rechecks finalized passages in the background for better accuracy. Speech-to-text stays offline/on-device after the models are downloaded.
The desktop app opens two windows during pre-meeting setup: **MacRec** for configuration and recording controls, and **Live Companion** for the transcript you keep beside the meeting.
The app also has a **Transcribe audio** tab for existing audio/video files; drop a file, choose a Moonshine model, and write a transcript to the selected output folder.

## Layout

```
macrec/
├── Package.swift                    SwiftPM manifest
├── NOTES.md                         Lightweight project decisions / future ideas
├── Sources/
│   ├── MacRecCore/                  Recording engine (shared library)
│   │   ├── Recorder.swift           Top-level actor; start() / stop()
│   │   ├── SystemAudioCapture.swift CoreAudio process-tap wrapper
│   │   ├── MicrophoneCapture.swift  AVCaptureSession wrapper
│   │   ├── AudioFileWriter.swift    AVAssetWriter → .m4a
│   │   ├── AudioDevices.swift       Public device-listing API
│   │   └── RecordingSession.swift   Session metadata / file paths
│   ├── macrec/                      Command-line front-end
│   │   └── main.swift               `macrec record`, `macrec devices`
│   └── MacRecApp/                   SwiftUI dock app
│       ├── MacRecApp.swift          Window with Start/Stop, settings, transcript, recents
│       ├── LocalMoonshineTranscription.swift
│       │                              Moonshine live transcript backend
│       ├── LiveTranscriptRefiner.swift
│       │                              Whisper large-v3 accuracy pass
│       └── LocalWhisperTranscription.swift
│                                      WhisperKit fallback live transcript backend
├── python/
│   ├── macrec_transcribe.py         Two-track transcription pipeline
│   └── requirements.txt
└── Tests/
```

## Building (requires Xcode)

The project requires Xcode (not just Command Line Tools) to build, because the CLT-only toolchain on macOS 15 ships with a broken `libPackageDescription.dylib` and a mismatched SDK/compiler pair.

```sh
# Install Xcode from the App Store first.
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer

git clone https://github.com/eastmountaincode/macrec.git
cd macrec
swift build --product macrec
swift build --product MacRecApp
swift test
./.build/debug/macrec record
```

To create a local double-clickable app bundle and release CLI:

```sh
scripts/build-app.sh
open dist/MacRec.app
dist/macrec record
```

During development, install the rebuilt app into `/Applications` in one step:

```sh
INSTALL=1 scripts/build-app.sh
open /Applications/MacRec.app
```

When `INSTALL=1` is used, the build script also prefetches the default Moonshine model into:

```sh
~/Library/Application Support/MacRec/Moonshine
```

That cache is outside the app bundle, so reinstalling MacRec does not erase it. To skip Moonshine prefetching during an install build:

```sh
PREFETCH_MOONSHINE=0 INSTALL=1 scripts/build-app.sh
```

Whisper fallback models are downloaded on demand by the app, or can be prefetched explicitly:

```sh
PREFETCH_WHISPER=1 INSTALL=1 scripts/build-app.sh
```

## Permissions

First run can trigger two macOS prompts:

1. **Microphone** — required to record your mic.
2. **System Audio Recording Only** — required to record call/system audio through the CoreAudio tap. The app bundle declares `NSAudioCaptureUsageDescription` so macOS can show the system-audio permission prompt. On some macOS builds this permission still appears inside the broader **Screen & System Audio Recording** settings page.

Re-run after granting both.

## CLI usage

```sh
macrec record                    # records to ~/Desktop/macrec/macrec-<timestamp>/
macrec record --title "Yaz follow up"
macrec record --output ~/Recordings
macrec record --mic <device-id>  # see `macrec devices` for IDs
macrec record --mic-gain-db 3 --system-gain-db -6
macrec devices                   # list available audio inputs
```

Stop with Ctrl-C; both tracks are finalized cleanly before exit.

The SwiftUI app exposes the same per-track gain controls next to each live meter. Gain is applied inside MacRec to the saved track and preview meter; it does not change the Mac's global microphone or speaker volume.

## Live transcription

The app's **Live transcript** switch uses local speech-to-text models. It transcribes the two tracks independently:

- `Me` from the selected microphone
- `Call` from Mac system audio

The default model is **Moonshine medium** because it is built for low-latency streaming speech. **Moonshine small**, **Whisper large v3**, **Whisper turbo**, and **Distil Whisper** remain available in the picker. The app starts loading the selected model on launch; Record stays disabled while it is missing or warming up. First use can download the selected model into Application Support, and later launches reuse the local cache.

When Moonshine is selected, Whisper large v3 independently checks each complete 30-second window of call audio. Moonshine remains visible immediately; Whisper then replaces that window with its refined result, including speech Moonshine did not detect in the first place. Finalized microphone lines are also rechecked in short batches. This does not require a managed glossary. The recording folder keeps both versions:

- `*-live-transcript.txt` — the enhanced transcript
- `*-live-transcript-raw.txt` — the original Moonshine transcript for comparison or recovery

The status line reports how many call windows Whisper checked and how many microphone passages it improved. The standalone Whisper live backends still skip quiet chunks and apply conservative repeated-phrase cleanup.

The live transcript follows new speech automatically without repeatedly animating the scroll position. Scrolling upward pauses live-follow so incoming captions do not pull the view away; **Jump to live** returns to the newest line. Transcript rows are created lazily, and the fast input meters update independently so they do not force the companion to redraw continuously.

These labels come only from the two recorded tracks. MacRec does not infer participant identities: every voice captured from the call/system track remains `Call`.

## Live Companion

The **Live Companion** opens when MacRec launches, before recording begins. Closing or hiding either window does not stop a recording, and **Show Live Companion** in the control window reopens it. **Dock with MacRec** snaps the transcript into the right side of the control window; **Pop Out** restores the separate companion at its saved position. Docking and popping out are presentation changes only and can safely happen during a recording. The app remembers docked versus separate mode and the companion's monitor, position, and size between launches.

## Existing audio

Use the **Transcribe audio** tab for files that already exist. It accepts audio or video files through drag-and-drop or the file picker, extracts the audio track, runs the selected Moonshine model locally, and writes `<input-name>-transcript.txt` to the output folder.

The first version of this flow supports Moonshine models. Whisper remains available for live fallback, but file transcription is intentionally starting with Moonshine because that is the path performing best in local testing.

## Transcribing a session

```sh
cd python
pip install -r requirements.txt
python macrec_transcribe.py ~/Desktop/macrec/macrec-2026-04-29_14-30-00
```

This produces `transcript.json` and `transcript.txt` inside the session folder, with each segment labeled `Me` (microphone track) or `Call` (call/system track).

The transcriber supports both current date/title track names and old `mic.m4a` / `system.m4a` sessions. It also applies a conservative repeated-phrase cleanup pass to reduce Whisper loops after dead air.

## Status

- [x] Recording engine (Swift, CoreAudio process tap + AVCaptureSession)
- [x] CLI front-end
- [x] SwiftUI dock app
- [x] Local Moonshine + WhisperKit live transcript scaffold
- [x] Automatic Moonshine-to-Whisper large-v3 accuracy refinement
- [x] Two-track Python transcription pipeline
- [x] Verified SwiftPM build (CLI + SwiftUI app) with full Xcode toolchain
- [x] Verified recording permissions + two-track capture on a live call
- [x] Tune the live transcript path against a real meeting recording
- [ ] Code-signing + notarization for distribution
