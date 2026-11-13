# MacRec

MacRec is a macOS app and command-line tool that records microphone and system audio to separate `.m4a` files.

By default, the app uses Moonshine for live captions and Whisper large v3 to refine the transcript in the background. It can also transcribe existing audio and video files. Transcription runs on-device after the models are downloaded.

## Build and run

Building requires Xcode. System audio capture requires macOS 14.2 or later.

```sh
git clone https://github.com/eastmountaincode/macrec.git
cd macrec
./scripts/build-app.sh
open dist/MacRec.app
```

Grant microphone and system audio permissions when prompted. Use **Record** to start a session or **Transcribe audio** to open an existing file.

## Command line

```sh
./dist/macrec devices
./dist/macrec record
```

Press Ctrl+C to stop recording. Recordings are saved to `~/Desktop/macrec` by default.

The `python/macrec_transcribe.py` script transcribes both tracks from a saved session and writes `transcript.txt` and `transcript.json`.
