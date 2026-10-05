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

# System prompt: the session group's copy, then the user's customized version,
# then the shipped .example.txt. See README "Session groups".
SUMMARY_PROMPT_FILE="${SUMMARY_PROMPT_FILE:-$CONFIG_DIR/summary_prompt.txt}"
SUMMARY_PROMPT_EXAMPLE="$CONFIG_DIR/summary_prompt.example.txt"
if [[ ! -f "$SUMMARY_PROMPT_FILE" && ! -f "$SUMMARY_PROMPT_EXAMPLE" ]]; then
  logerr "Error: no summary prompt found at $CONFIG_DIR/summary_prompt.{txt,example.txt}"
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  logerr "Error: jq not found. Install with: brew install jq"
  exit 1
fi

require_ollama_model

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

# Set NAMES_PREAMBLE and NAMES_TAIL, which wrap a transcript so the model
# normalizes any variant spellings it sees. Both are empty when the session
# has no glossary names.
#   set_names_wrapper "$names_list"
set_names_wrapper() {
  NAMES_PREAMBLE=""
  NAMES_TAIL=""
  [[ -n "$1" ]] || return 0
  NAMES_PREAMBLE="The transcript below was produced by an automated speech-to-text system and contains many mistranscriptions of names from this campaign. The following list is the canonical, authoritative spellings — these are the only acceptable forms. You MUST normalize every variant, homophone, or near-spelling encountered in the transcript to the canonical form shown here. For example, if the transcript writes \"Phoenix\" but the glossary lists \"Phaenix\", output \"Phaenix\". Do not preserve transcript variants of glossary names; do not invent new variants. Names not in the glossary should be preserved as written.

Glossary:
$1

Transcript follows.

"
  NAMES_TAIL="

End of transcript. Reminder: every occurrence in your output of any name listed in the glossary above must use the canonical spelling, regardless of how the transcript spelled it."
}

script_start=$(date +%s)
log "Found ${#txt_files[@]} cleaned transcript(s). Model: $MODEL  num_ctx ceiling: $NUM_CTX"

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

  names_list=$(session_names "$base")
  set_names_wrapper "$names_list"
  prompt_file=$(session_prompt_file "$SUMMARY_PROMPT_FILE" "$SUMMARY_PROMPT_EXAMPLE" "$base")
  SYSTEM_PROMPT=$(<"$prompt_file")

  log "  ..    summarizing $base.txt (prompt: $(basename "$prompt_file")${names_list:+, glossary: $(wc -l <<<"$names_list" | tr -d ' ') names})"
  file_start=$(date +%s)

  prompt_bytes=$(( ${#SYSTEM_PROMPT} + ${#NAMES_PREAMBLE} + ${#NAMES_TAIL} + $(wc -c < "$src") ))
  ctx=$(fit_num_ctx "$prompt_bytes" "$NUM_CTX")

  if ! content=$(jq -n \
    --arg model "$MODEL" \
    --arg system "$SYSTEM_PROMPT" \
    --arg names_preamble "$NAMES_PREAMBLE" \
    --arg names_tail "$NAMES_TAIL" \
    --rawfile content "$src" \
    --argjson num_ctx "$ctx" \
    --argjson temperature "$SUMMARIZE_TEMPERATURE" \
    '{
      model: $model,
      messages: [
        {role: "system", content: $system},
        {role: "user", content: ($names_preamble + $content + $names_tail)}
      ],
      stream: false,
      options: {num_ctx: $num_ctx, temperature: $temperature}
    }' | ollama_chat "$ctx"); then
    logerr "  FAIL  $base.txt"
    failed=$((failed + 1))
    continue
  fi

  printf '%s\n' "$content" | apply_session_variants "$base" > "$dst.tmp" && mv "$dst.tmp" "$dst"
  log "  ok    $dst_name ($(fmt_duration $(($(date +%s) - file_start))), num_ctx $ctx)"
  summarized=$((summarized + 1))
done

log "Done. summarized=$summarized skipped=$skipped failed=$failed (total $(fmt_duration $(($(date +%s) - script_start))))"
log "Output: $SUMMARIES_DIR"
