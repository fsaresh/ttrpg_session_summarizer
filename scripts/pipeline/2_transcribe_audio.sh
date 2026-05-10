#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../_lib.sh"

AUDIO_DIR="$WORKSPACE_DIR/audio"
TRANSCRIPT_DIR="$WORKSPACE_DIR/transcripts"

# See README "Tier 1: transcribe_audio" for model choices and tuning notes.
MODEL_PATH="${MODEL_PATH:-$HOME/source/external/whisper_models/ggml-large-v3.bin}"
WORD_THRESHOLD="${WORD_THRESHOLD:-0.95}"
ENTROPY_THRESHOLD="${ENTROPY_THRESHOLD:-3.0}"
TEMPERATURE_INC="${TEMPERATURE_INC:-0.5}"
THREADS="${THREADS:-8}"
NAMES_FILE="${NAMES_FILE:-$CONFIG_DIR/names.txt}"

if ! command -v whisper-cli >/dev/null 2>&1; then
  logerr "Error: whisper-cli not found. Install with: brew install whisper-cpp"
  exit 1
fi

if [[ ! -f "$MODEL_PATH" ]]; then
  logerr "Error: model file not found: $MODEL_PATH"
  logerr "  See README for download instructions."
  exit 1
fi

if [[ ! -d "$AUDIO_DIR" ]]; then
  logerr "Error: source directory does not exist: $AUDIO_DIR"
  exit 1
fi

mkdir -p "$TRANSCRIPT_DIR"

shopt -s nullglob
audio_files=("$AUDIO_DIR"/*.m4a "$AUDIO_DIR"/*.wav "$AUDIO_DIR"/*.mp3 "$AUDIO_DIR"/*.flac "$AUDIO_DIR"/*.ogg "$AUDIO_DIR"/*.aac)
shopt -u nullglob

if [[ ${#audio_files[@]} -eq 0 ]]; then
  log "No audio files found in $AUDIO_DIR"
  exit 0
fi

# Build a glossary prompt from NAMES_FILE so whisper biases transcription
# toward canonical spellings. --carry-initial-prompt makes the bias persist
# across all 30s decode chunks instead of just the first one.
WHISPER_PROMPT_ARGS=()
NAMES_PROMPT=$(read_names "$NAMES_FILE" | paste -sd ', ' -)
if [[ -n "$NAMES_PROMPT" ]]; then
  WHISPER_PROMPT_ARGS=(--prompt "Glossary: $NAMES_PROMPT." --carry-initial-prompt)
fi

script_start=$(date +%s)
log "Found ${#audio_files[@]} audio file(s). Model: $(basename "$MODEL_PATH")"
if [[ -n "$NAMES_PROMPT" ]]; then
  log "Glossary loaded from $NAMES_FILE ($(wc -w <<< "$NAMES_PROMPT" | tr -d ' ') words)"
fi

transcribed=0
skipped=0
failed=0

for src in "${audio_files[@]}"; do
  base=$(basename "$src")
  stem="${base%.*}"
  dst="$TRANSCRIPT_DIR/$stem.srt"

  if [[ -e "$dst" ]]; then
    log "  skip  $stem.srt (already exists)"
    skipped=$((skipped + 1))
    continue
  fi

  log "  ..    transcribing $base"
  file_start=$(date +%s)
  if whisper-cli \
      --model "$MODEL_PATH" \
      --file "$src" \
      --output-srt \
      --output-json-full \
      --output-file "$TRANSCRIPT_DIR/$stem" \
      --language "${LANGUAGE:-en}" \
      --word-thold "$WORD_THRESHOLD" \
      --suppress-nst \
      --entropy-thold "$ENTROPY_THRESHOLD" \
      --temperature-inc "$TEMPERATURE_INC" \
      --threads "$THREADS" \
      "${WHISPER_PROMPT_ARGS[@]}"; then
    log "  ok    $stem.srt ($(fmt_duration $(($(date +%s) - file_start))))"
    transcribed=$((transcribed + 1))
  else
    logerr "  FAIL  $base (see whisper-cli output above)"
    rm -f "$dst" "$TRANSCRIPT_DIR/$stem.json"
    failed=$((failed + 1))
  fi
done

log "Done. transcribed=$transcribed skipped=$skipped failed=$failed (total $(fmt_duration $(($(date +%s) - script_start))))"
log "Output: $TRANSCRIPT_DIR"
