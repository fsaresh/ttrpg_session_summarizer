#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../_lib.sh"

TRANSCRIPTS_DIR="$WORKSPACE_DIR/transcripts"
SUMMARIES_DIR="$WORKSPACE_DIR/summaries"

# See README "Tier 3: summarize_session" for setup, model choice, and tuning.
# Defaults below are the script-level fallback; they're overridden by
# config/settings.conf (sourced from _lib.sh) and by env vars at run time.
MODEL="${MODEL:-qwen2.5:32b-instruct-q4_K_M}"
NUM_CTX="${NUM_CTX:-65536}"
SUMMARIZE_TEMPERATURE="${SUMMARIZE_TEMPERATURE:-0.3}"
OLLAMA_URL="${OLLAMA_URL:-http://localhost:11434}"
NAMES_FILE="${NAMES_FILE:-$CONFIG_DIR/names.txt}"
VARIANTS_FILE="${VARIANTS_FILE:-$CONFIG_DIR/name_variants.txt}"

# System prompt is loaded from config/. Try the user's customized version
# first, fall back to the shipped .example.txt.
SUMMARY_PROMPT_FILE="${SUMMARY_PROMPT_FILE:-$CONFIG_DIR/summary_prompt.txt}"
if [[ ! -f "$SUMMARY_PROMPT_FILE" ]]; then
  SUMMARY_PROMPT_FILE="$CONFIG_DIR/summary_prompt.example.txt"
fi
if [[ ! -f "$SUMMARY_PROMPT_FILE" ]]; then
  logerr "Error: no summary prompt found at $CONFIG_DIR/summary_prompt.{txt,example.txt}"
  exit 1
fi
SYSTEM_PROMPT=$(<"$SUMMARY_PROMPT_FILE")

if ! command -v jq >/dev/null 2>&1; then
  logerr "Error: jq not found. Install with: brew install jq"
  exit 1
fi

if ! curl -sf "$OLLAMA_URL/api/tags" >/dev/null 2>&1; then
  logerr "Error: cannot reach Ollama at $OLLAMA_URL"
  logerr "  Is the service running? Try: brew services start ollama"
  exit 1
fi

if ! curl -sf "$OLLAMA_URL/api/tags" | jq -e --arg m "$MODEL" '.models[] | select(.name == $m)' >/dev/null; then
  logerr "Error: model '$MODEL' is not installed in Ollama."
  logerr "  Pull it with: ollama pull $MODEL"
  exit 1
fi

if [[ ! -d "$TRANSCRIPTS_DIR" ]]; then
  logerr "Error: source directory does not exist: $TRANSCRIPTS_DIR"
  exit 1
fi

mkdir -p "$SUMMARIES_DIR"

shopt -s nullglob
txt_files=("$TRANSCRIPTS_DIR"/*.txt)
shopt -u nullglob

if [[ ${#txt_files[@]} -eq 0 ]]; then
  log "No .txt files found in $TRANSCRIPTS_DIR (run 3_clean_transcript.sh first)"
  exit 0
fi

# Sanitize the model tag for use in a filename (Ollama tags use ":" as a
# separator, which is awkward in filenames on some tools/shells).
MODEL_TAG="${MODEL//:/-}"

# Build a canonical-names preamble that gets prepended to each transcript so
# the model normalizes any variant spellings it sees. Empty if NAMES_FILE
# is missing or empty.
NAMES_PREAMBLE=""
NAMES_TAIL=""
NAMES_LIST=$(read_names "$NAMES_FILE")
if [[ -n "$NAMES_LIST" ]]; then
  NAMES_PREAMBLE="The transcript below was produced by an automated speech-to-text system and contains many mistranscriptions of names from this campaign. The following list is the canonical, authoritative spellings — these are the only acceptable forms. You MUST normalize every variant, homophone, or near-spelling encountered in the transcript to the canonical form shown here. For example, if the transcript writes \"Phoenix\" but the glossary lists \"Phaenix\", output \"Phaenix\". Do not preserve transcript variants of glossary names; do not invent new variants. Names not in the glossary should be preserved as written.

Glossary:
$NAMES_LIST

Transcript follows.

"
  NAMES_TAIL="

End of transcript. Reminder: every occurrence in your output of any name listed in the glossary above must use the canonical spelling, regardless of how the transcript spelled it."
fi

script_start=$(date +%s)
log "Found ${#txt_files[@]} cleaned transcript(s). Model: $MODEL  num_ctx: $NUM_CTX"
if [[ -n "$NAMES_LIST" ]]; then
  log "Glossary loaded from $NAMES_FILE ($(wc -l <<< "$NAMES_LIST" | tr -d ' ') names)"
fi

summarized=0
skipped=0
failed=0

for src in "${txt_files[@]}"; do
  base=$(basename "$src" .txt)
  dst_name="$base--$MODEL_TAG.md"
  dst="$SUMMARIES_DIR/$dst_name"

  if [[ -e "$dst" ]]; then
    log "  skip  $dst_name (already exists)"
    skipped=$((skipped + 1))
    continue
  fi

  log "  ..    summarizing $base.txt"
  file_start=$(date +%s)

  request=$(jq -n \
    --arg model "$MODEL" \
    --arg system "$SYSTEM_PROMPT" \
    --arg names_preamble "$NAMES_PREAMBLE" \
    --arg names_tail "$NAMES_TAIL" \
    --rawfile content "$src" \
    --argjson num_ctx "$NUM_CTX" \
    --argjson temperature "$SUMMARIZE_TEMPERATURE" \
    '{
      model: $model,
      messages: [
        {role: "system", content: $system},
        {role: "user", content: ($names_preamble + $content + $names_tail)}
      ],
      stream: false,
      options: {num_ctx: $num_ctx, temperature: $temperature}
    }')

  response=$(curl -sf -X POST "$OLLAMA_URL/api/chat" \
    -H 'Content-Type: application/json' \
    -d "$request" || echo "")

  if [[ -z "$response" ]]; then
    logerr "  FAIL  $base.txt (no response from Ollama)"
    failed=$((failed + 1))
    continue
  fi

  if echo "$response" | jq -e '.error' >/dev/null 2>&1; then
    err=$(echo "$response" | jq -r '.error')
    logerr "  FAIL  $base.txt (Ollama error: $err)"
    failed=$((failed + 1))
    continue
  fi

  content=$(echo "$response" | jq -r '.message.content // empty')
  if [[ -z "$content" ]]; then
    logerr "  FAIL  $base.txt (empty content in response)"
    failed=$((failed + 1))
    continue
  fi

  printf '%s\n' "$content" | apply_name_variants "$VARIANTS_FILE" > "$dst.tmp" && mv "$dst.tmp" "$dst"
  log "  ok    $dst_name ($(fmt_duration $(($(date +%s) - file_start))))"
  summarized=$((summarized + 1))
done

log "Done. summarized=$summarized skipped=$skipped failed=$failed (total $(fmt_duration $(($(date +%s) - script_start))))"
log "Output: $SUMMARIES_DIR"
