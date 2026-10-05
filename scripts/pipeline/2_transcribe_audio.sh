#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../_lib.sh"

AUDIO_DIR="$WORKSPACE_DIR/audio"
TRANSCRIPT_DIR="$WORKSPACE_DIR/transcripts"

# See README "Tier 1: transcribe_audio" for model choices and tuning notes.
MODEL_PATH="${MODEL_PATH:-$HOME/source/external/whisper_models/ggml-large-v3-turbo-q5_0.bin}"
WORD_THRESHOLD="${WORD_THRESHOLD:-0.95}"
ENTROPY_THRESHOLD="${ENTROPY_THRESHOLD:-3.0}"
TEMPERATURE_INC="${TEMPERATURE_INC:-0.5}"
THREADS="${THREADS:-8}"
NAMES_FILE="${NAMES_FILE:-$CONFIG_DIR/names.txt}"
# whisper keeps at most ~223 prompt tokens; see README "Stage 2".
WHISPER_PROMPT_CHARS="${WHISPER_PROMPT_CHARS:-600}"

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

script_start=$(date +%s)
log "Found ${#audio_files[@]} audio file(s). Model: $(basename "$MODEL_PATH")"

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

  # Glossary prompt (group names, then shared) biases whisper toward canonical
  # spellings. `~`-marked names are left out; the rest are kept in order until
  # the prompt budget runs out.
  # --carry-initial-prompt keeps the prompt for every 30s chunk.
  all_names=$(session_names "$stem" --whisper)
  glossary=$(awk -v max="$WHISPER_PROMPT_CHARS" '
    { len += (NR > 1 ? 2 : 0) + length($0); if (len > max) exit; out = out (NR > 1 ? ", " : "") $0 }
    END { print out }' <<<"$all_names")
  prompt_args=()
  glossary_note=""
  if [[ -n "$glossary" ]]; then
    prompt_args=(--prompt "Glossary: $glossary." --carry-initial-prompt)
    kept=$(awk -F", " '{ print NF }' <<<"$glossary")
    total=$(wc -l <<<"$all_names" | tr -d ' ')
    glossary_note=" (glossary: $kept of $total names)"
  fi

  log "  ..    transcribing $base$glossary_note"
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
      ${prompt_args[@]+"${prompt_args[@]}"}; then
    log "  ok    $stem.srt ($(fmt_duration $(($(date +%s) - file_start))))"
    transcribed=$((transcribed + 1))
  else
    logerr "  FAIL  $base (see whisper-cli output above)"
    command rm -f "$dst" "$TRANSCRIPT_DIR/$stem.json"
    failed=$((failed + 1))
  fi
done

log "Done. transcribed=$transcribed skipped=$skipped failed=$failed (total $(fmt_duration $(($(date +%s) - script_start))))"
log "Output: $TRANSCRIPT_DIR"
