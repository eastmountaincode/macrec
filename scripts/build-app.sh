#!/usr/bin/env bash
set -euo pipefail
export COPYFILE_DISABLE=1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${CONFIG:-release}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
INSTALL="${INSTALL:-0}"
PREFETCH_WHISPER="${PREFETCH_WHISPER:-0}"
WHISPER_MODEL="${WHISPER_MODEL:-openai_whisper-large-v3-v20240930_626MB}"
PREFETCH_MOONSHINE="${PREFETCH_MOONSHINE:-$INSTALL}"
MOONSHINE_MODEL="${MOONSHINE_MODEL:-moonshine-medium-streaming-en}"
APP_NAME="MacRec"
INSTALL_APP_DIR="/Applications/$APP_NAME.app"
APP_DIR="$ROOT/dist/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

cd "$ROOT"

swift build -c "$CONFIG" --product MacRecApp
swift build -c "$CONFIG" --product macrec
if [[ "$PREFETCH_WHISPER" == "1" ]]; then
  swift build -c "$CONFIG" --product macrec-whisper-prefetch
fi

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$ROOT/dist"

cp "$ROOT/.build/$CONFIG/MacRecApp" "$MACOS_DIR/MacRecApp"
cp "$ROOT/.build/$CONFIG/macrec" "$ROOT/dist/macrec"
if [[ -x "$ROOT/.build/$CONFIG/macrec-whisper-prefetch" ]]; then
  cp "$ROOT/.build/$CONFIG/macrec-whisper-prefetch" "$ROOT/dist/macrec-whisper-prefetch"
fi
chmod +x "$MACOS_DIR/MacRecApp" "$ROOT/dist/macrec"
if [[ -f "$ROOT/dist/macrec-whisper-prefetch" ]]; then
  chmod +x "$ROOT/dist/macrec-whisper-prefetch"
fi

cat > "$CONTENTS_DIR/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>MacRecApp</string>
  <key>CFBundleIdentifier</key>
  <string>local.macrec.app</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>MacRec</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>MacRec records your microphone to a separate local audio track.</string>
  <key>NSAudioCaptureUsageDescription</key>
  <string>MacRec records Mac system audio to a separate local call audio track.</string>
</dict>
</plist>
PLIST

find "$APP_DIR" -name '._*' -delete
codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$APP_DIR"

echo "Built $APP_DIR"
echo "Built $ROOT/dist/macrec"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  echo "Note: app was ad-hoc signed. Rebuilding can make macOS re-check microphone/system-audio permissions."
fi

if [[ "$PREFETCH_WHISPER" == "1" ]]; then
  "$ROOT/dist/macrec-whisper-prefetch" --model "$WHISPER_MODEL"
fi

if [[ "$PREFETCH_MOONSHINE" == "1" ]]; then
  "$ROOT/scripts/prefetch-moonshine.sh" "$MOONSHINE_MODEL"
fi

if [[ "$INSTALL" == "1" ]]; then
  if pgrep -f "$INSTALL_APP_DIR/Contents/MacOS/MacRecApp" >/dev/null 2>&1; then
    osascript -e 'tell application id "local.macrec.app" to quit' >/dev/null 2>&1 || true
    for _ in {1..30}; do
      if ! pgrep -f "$INSTALL_APP_DIR/Contents/MacOS/MacRecApp" >/dev/null 2>&1; then
        break
      fi
      sleep 0.1
    done
    pkill -f "$INSTALL_APP_DIR/Contents/MacOS/MacRecApp" 2>/dev/null || true
  fi
  ditto --noqtn "$APP_DIR" "$INSTALL_APP_DIR"
  codesign --verify --deep --strict --verbose=2 "$INSTALL_APP_DIR"
  echo "Installed $INSTALL_APP_DIR"
fi
