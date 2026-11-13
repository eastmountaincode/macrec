#!/usr/bin/env python3
"""macrec_transcribe — turn a macrec session folder into a labeled transcript.

A session folder contains:
    *-me.m4a      — your microphone (always = "Me")
    *-call.m4a    — system audio (always = "Call")

Legacy mic.m4a / system.m4a sessions are also supported.

Pipeline:
    1. mlx-whisper transcribes each track independently → timestamped segments.
    2. microphone + call segments are labeled "Me" and "Call", respectively.
    3. both tracks are interleaved by start time and written as
       transcript.json (full data) and transcript.txt (human-readable).

Usage:
    macrec_transcribe.py SESSION_DIR [--model MODEL]
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass, asdict
from pathlib import Path
from typing import Iterable


@dataclass
class Segment:
    start: float
    end: float
    text: str
    speaker: str  # Structural track label: "Me" or "Call".


def transcribe_track(audio_path: Path, model: str) -> list[dict]:
    """Run mlx-whisper on a single audio file and return its segments list."""
    import mlx_whisper

    print(f"  transcribing {audio_path.name} with {model} …", flush=True)
    result = mlx_whisper.transcribe(
        str(audio_path),
        path_or_hf_repo=model,
        word_timestamps=False,
    )
    return result.get("segments", [])


def resolve_tracks(session: Path) -> tuple[Path, Path]:
    legacy_mic = session / "mic.m4a"
    legacy_system = session / "system.m4a"
    if legacy_mic.exists() and legacy_system.exists():
        return legacy_mic, legacy_system

    mic_matches = sorted(session.glob("*-me.m4a"))
    system_matches = sorted(session.glob("*-call.m4a"))
    if len(mic_matches) == 1 and len(system_matches) == 1:
        return mic_matches[0], system_matches[0]

    raise FileNotFoundError(
        f"{session} must contain one *-me.m4a and one *-call.m4a "
        "or legacy mic.m4a and system.m4a files"
    )


def merge(mic_segs: list[dict], call_segs: list[dict]) -> list[Segment]:
    out: list[Segment] = []
    for s in mic_segs:
        text = collapse_repeated_text(s["text"].strip())
        if text:
            out.append(Segment(start=float(s["start"]), end=float(s["end"]),
                               text=text, speaker="Me"))
    for s in call_segs:
        start, end = float(s["start"]), float(s["end"])
        text = collapse_repeated_text(s["text"].strip())
        if text:
            out.append(Segment(start=start, end=end,
                               text=text,
                               speaker="Call"))
    out.sort(key=lambda x: x.start)
    return remove_duplicate_loops(out)


def normalize_repeat_key(text: str) -> str:
    return re.sub(r"\s+", " ", re.sub(r"[^\w\s]", "", text.lower())).strip()


def collapse_repeated_text(text: str) -> str:
    words = text.split()
    if len(words) < 8:
        return text

    normalized_words = normalize_repeat_key(text).split()
    for size in range(1, min(16, len(normalized_words) // 3) + 1):
        phrase = normalized_words[:size]
        repeats = 0
        index = 0
        while normalized_words[index:index + size] == phrase:
            repeats += 1
            index += size
            if index >= len(normalized_words):
                break
        coverage = index / max(1, len(normalized_words))
        if repeats >= 3 and coverage >= 0.8:
            return " ".join(words[:size])
    return text


def remove_duplicate_loops(segments: list[Segment]) -> list[Segment]:
    cleaned: list[Segment] = []
    recent: dict[str, tuple[str, float, int]] = {}

    for segment in segments:
        key = normalize_repeat_key(segment.text)
        if not key:
            continue

        last_key, last_end, count = recent.get(segment.speaker, ("", -9999.0, 0))
        if key == last_key and segment.start - last_end < 20:
            recent[segment.speaker] = (key, segment.end, count + 1)
            if count >= 1:
                continue
        else:
            recent[segment.speaker] = (key, segment.end, 0)

        cleaned.append(segment)

    return cleaned


def fmt_time(t: float) -> str:
    h, rem = divmod(int(t), 3600)
    m, s = divmod(rem, 60)
    return f"{h:02d}:{m:02d}:{s:02d}"


def render_text(segments: Iterable[Segment]) -> str:
    lines: list[str] = []
    last_speaker: str | None = None
    for seg in segments:
        if seg.speaker != last_speaker:
            lines.append("")
            lines.append(f"[{fmt_time(seg.start)}] {seg.speaker}:")
            last_speaker = seg.speaker
        lines.append(f"  {seg.text}")
    return "\n".join(lines).strip() + "\n"


def main() -> int:
    ap = argparse.ArgumentParser(description="Transcribe a macrec session into a labeled transcript.")
    ap.add_argument("session_dir", type=Path, help="folder containing the macrec track files")
    ap.add_argument("--model", default="mlx-community/whisper-large-v3-mlx",
                    help="mlx-whisper model repo (default: whisper-large-v3-mlx)")
    args = ap.parse_args()

    session = args.session_dir.expanduser().resolve()
    try:
        mic, call = resolve_tracks(session)
    except FileNotFoundError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1

    print(f"session: {session}")
    mic_segs = transcribe_track(mic, args.model)
    call_segs = transcribe_track(call, args.model)
    merged = merge(mic_segs, call_segs)

    json_path = session / "transcript.json"
    txt_path = session / "transcript.txt"
    json_path.write_text(json.dumps([asdict(s) for s in merged], indent=2))
    txt_path.write_text(render_text(merged))

    labels = sorted({s.speaker for s in merged})
    print(f"\nwrote {txt_path.name} and {json_path.name}")
    print(f"track labels: {', '.join(labels)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
