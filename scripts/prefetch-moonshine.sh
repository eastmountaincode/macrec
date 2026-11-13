#!/usr/bin/env bash
set -euo pipefail

MODEL="${1:-moonshine-medium-streaming-en}"
ROOT="${MOONSHINE_CACHE_ROOT:-$HOME/Library/Application Support/MacRec/Moonshine}"

case "$MODEL" in
  moonshine-medium-streaming-en)
    BASE_URL="https://download.moonshine.ai/model/medium-streaming-en/quantized"
    ;;
  moonshine-small-streaming-en)
    BASE_URL="https://download.moonshine.ai/model/small-streaming-en/quantized"
    ;;
  *)
    echo "Unsupported Moonshine model: $MODEL" >&2
    exit 2
    ;;
esac

COMPONENTS=(
  adapter.ort
  cross_kv.ort
  decoder_kv.ort
  decoder_kv_with_attention.ort
  encoder.ort
  frontend.ort
  streaming_config.json
  tokenizer.bin
)

TARGET_DIR="$ROOT/$MODEL"
mkdir -p "$TARGET_DIR"

echo "Prefetching $MODEL into $TARGET_DIR"
for component in "${COMPONENTS[@]}"; do
  target="$TARGET_DIR/$component"
  if [[ -s "$target" ]]; then
    echo "Already cached $component"
    continue
  fi

  tmp="$target.download"
  rm -f "$tmp"
  echo "Downloading $component"
  curl -L --fail --progress-bar -o "$tmp" "$BASE_URL/$component"
  mv "$tmp" "$target"
done

echo "Moonshine model ready: $TARGET_DIR"
