#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../_lib.sh"

RECORDINGS_DIR="$WORKSPACE_DIR/recordings"
AUDIO_DIR="$WORKSPACE_DIR/audio"

# See README "Tier 0: extract_audio" for tuning notes on the silence trim.
SILENCE_THRESHOLD="${SILENCE_THRESHOLD:--40dB}"
SILENCE_DURATION="${SILENCE_DURATION:-10}"

if ! command -v ffmpeg >/dev/null 2>&1; then
  logerr "Error: ffmpeg not found. Install with: brew install ffmpeg"
  exit 1
fi

if [[ ! -d "$RECORDINGS_DIR" ]]; then
  logerr "Error: source directory does not exist: $RECORDINGS_DIR"
  exit 1
fi

mkdir -p "$AUDIO_DIR"

shopt -s nullglob nocaseglob
video_files=("$RECORDINGS_DIR"/*.mp4 "$RECORDINGS_DIR"/*.mov)
shopt -u nullglob nocaseglob

if [[ ${#video_files[@]} -eq 0 ]]; then
  log "No video files (.mp4/.mov) found in $RECORDINGS_DIR"
  shopt -s nullglob
  audio_present=("$AUDIO_DIR"/*.wav "$AUDIO_DIR"/*.m4a "$AUDIO_DIR"/*.mp3 "$AUDIO_DIR"/*.flac "$AUDIO_DIR"/*.ogg "$AUDIO_DIR"/*.aac)
  shopt -u nullglob
  if [[ ${#audio_present[@]} -gt 0 ]]; then
    log "(${#audio_present[@]} audio file(s) already in $AUDIO_DIR — Stage 1 is a no-op when starting from audio directly. Stage 2 will pick those up.)"
  fi
  exit 0
fi

script_start=$(date +%s)
log "Found ${#video_files[@]} video file(s)."

extracted=0
skipped=0
failed=0

for src in "${video_files[@]}"; do
  name=$(basename "$src")
  base="${name%.*}"
  dst="$AUDIO_DIR/$base.flac"

  existing=$(find_audio "$AUDIO_DIR" "$base")
  if [[ -n "$existing" ]]; then
    log "  skip  $(basename "$existing") (already exists)"
    skipped=$((skipped + 1))
    continue
  fi

  log "  ..    extracting $name"
  file_start=$(date +%s)
  if ffmpeg -hide_banner -loglevel error -n \
      -i "$src" \
      -vn -ac 1 -ar 16000 -c:a flac -sample_fmt s16 -map_metadata -1 -map_chapters -1 \
      -af "aformat=sample_rates=16000:channel_layouts=mono,areverse,silenceremove=start_periods=1:start_duration=${SILENCE_DURATION}:start_threshold=${SILENCE_THRESHOLD},areverse" \
      "$dst"; then
    log "  ok    $base.flac ($(fmt_duration $(($(date +%s) - file_start))))"
    extracted=$((extracted + 1))
  else
    logerr "  FAIL  $name (see ffmpeg output above)"
    command rm -f "$dst"
    failed=$((failed + 1))
  fi
done

log "Done. extracted=$extracted skipped=$skipped failed=$failed (total $(fmt_duration $(($(date +%s) - script_start))))"
log "Output: $AUDIO_DIR"
