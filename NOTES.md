# MacRec Notes

## Live transcription

- Moonshine medium is the default live transcription model because it is built for streaming and is performing much better than the prior Whisper chunking path for live captions.
- Keep WhisperKit models available as fallbacks; Moonshine is the preferred default for English meeting-style live captions, but not necessarily universally better for every offline, multilingual, or noisy transcription case.
- Moonshine live captions may split lines at pauses and occasionally produce awkward punctuation. That is acceptable for live viewing.
- The preferred live path is hybrid: Moonshine supplies immediate captions, while Whisper large v3 independently rechecks complete 30-second call-audio windows in the background. This independent buffer is essential because line-triggered refinement cannot recover speech Moonshine never emits. Finalized microphone lines still use roughly 8–12-second refinement batches.
- Do not feed the recent transcript back as a Whisper prompt by default. Testing showed that sentence-shaped conditioning could cause large v3 to return an empty result; the unprompted model correctly recovered terms such as `cytotoxicity`, `CH22`, and `GPA33`.
- Preserve `*-live-transcript-raw.txt` beside the enhanced transcript so automatic corrections stay reversible and easy to evaluate.
- Literal dictation is a separate problem from ordinary transcription. Spoken strings like "YYYY" or "hyphen" are ambiguous to speech models because they are trained to infer natural text, not exact character-level commands. Consider a future dictation cleanup/replacement layer for repeated letters, file-name patterns, URLs, and punctuation commands.
- Keep audio-meter publishing isolated from the companion's observable state. The meters update frequently and must not invalidate every selectable transcript row while the user scrolls.
- The transcript follows a stable bottom marker without animation only while the viewer remains at the live tail. Manual scrolling pauses follow mode and reveals a one-click **Jump to live** control; a lazy row stack keeps long meetings responsive.

## Transcript labels

- Labels come structurally from the recorded tracks: microphone speech is always `Me`, and system/call audio is always `Call`.
- Do not infer, cluster, number, or name individual participants. Multiple remote voices intentionally share the `Call` label.
- Use the same exact `Me` / `Call` convention in live, saved, and Python-generated transcripts.

## Future workflow

- The app should support two related workflows:
  - **Live input**: record microphone plus Mac system/call audio and show live captions.
  - **Transcribe audio**: drop or choose an existing audio/video file and write a transcript to the selected output folder using a local model.

## Window model

- Keep setup and during-meeting information in two single-instance windows backed by the same `AppModel`.
- Open Live Companion at application launch, not when Record is pressed; Record is already the point where the user needs to focus on the meeting.
- Persist companion frame, monitor, and layout mode. Closing the companion must never stop or alter recording, and the control window must provide a one-click way to reopen it.
- Treat Dock and Pop Out as two presentations of the same live transcript, not two copies of meeting state. Dock expands the control window and closes the companion scene; Pop Out shrinks the control window and restores the companion at its saved frame.
