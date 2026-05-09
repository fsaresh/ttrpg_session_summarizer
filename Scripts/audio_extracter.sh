#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_lib.sh"

SRC_DIR="$OBS_DIR/Recordings"
DST_DIR="$OBS_DIR/Audio"

# See README "Tier 0: extract_audio" for tuning notes on the silence trim.
SILENCE_THRESHOLD="${SILENCE_THRESHOLD:--40dB}"
SILENCE_DURATION="${SILENCE_DURATION:-10}"

if ! command -v ffmpeg >/dev/null 2>&1; then
  logerr "Error: ffmpeg not found. Install with: brew install ffmpeg"
  exit 1
fi

if [[ ! -d "$SRC_DIR" ]]; then
  logerr "Error: source directory does not exist: $SRC_DIR"
  exit 1
fi

mkdir -p "$DST_DIR"

shopt -s nullglob
mp4_files=("$SRC_DIR"/*.mp4)
shopt -u nullglob

if [[ ${#mp4_files[@]} -eq 0 ]]; then
  log "No mp4 files found in $SRC_DIR"
  exit 0
fi

script_start=$(date +%s)
log "Found ${#mp4_files[@]} mp4 file(s)."

extracted=0
skipped=0
failed=0

for src in "${mp4_files[@]}"; do
  base=$(basename "$src" .mp4)
  dst="$DST_DIR/$base.wav"

  if [[ -e "$dst" ]]; then
    log "  skip  $base.wav (already exists)"
    skipped=$((skipped + 1))
    continue
  fi

  log "  ..    extracting $base.mp4"
  file_start=$(date +%s)
  if ffmpeg -hide_banner -loglevel error -n \
      -i "$src" \
      -vn -ac 1 -ar 16000 -c:a pcm_s16le -map_metadata -1 -map_chapters -1 \
      -af "areverse,silenceremove=start_periods=1:start_duration=${SILENCE_DURATION}:start_threshold=${SILENCE_THRESHOLD},areverse" \
      "$dst"; then
    log "  ok    $base.wav ($(fmt_duration $(($(date +%s) - file_start))))"
    extracted=$((extracted + 1))
  else
    logerr "  FAIL  $base.mp4 (see ffmpeg output above)"
    rm -f "$dst"
    failed=$((failed + 1))
  fi
done

log "Done. extracted=$extracted skipped=$skipped failed=$failed (total $(fmt_duration $(($(date +%s) - script_start))))"
log "Output: $DST_DIR"
