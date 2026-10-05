#!/usr/bin/env bash
#
# Conceptually a stage-4 refinement pass — feeds the original transcript and
# the first-pass summary back to the LLM with instructions to identify and
# fill in missed beats. Lives under utils/ rather than pipeline/ because it's
# opt-in: not run by run.sh, and only useful when you want a second-pass
# improvement on an existing summary.
#
# See README "Refine pass" for full details.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../_lib.sh"

TXT_DIR="$WORKSPACE_DIR/transcripts"
MD_DIR="$WORKSPACE_DIR/summaries"

# Defaults below are the script-level fallback; they're overridden by
# config/settings.conf (sourced from _lib.sh) and by env vars at run time.
MODEL="${MODEL:-qwen2.5:32b-instruct-q4_K_M}"
NUM_CTX="${NUM_CTX:-65536}"
REFINE_TEMPERATURE="${REFINE_TEMPERATURE:-0.2}"
OLLAMA_URL="${OLLAMA_URL:-http://localhost:11434}"
NAMES_FILE="${NAMES_FILE:-$CONFIG_DIR/names.txt}"
VARIANTS_FILE="${VARIANTS_FILE:-$CONFIG_DIR/name_variants.txt}"

# System prompt: the session group's copy, then the user's customized version,
# then the shipped .example.txt. See README "Session groups".
REFINE_PROMPT_FILE="${REFINE_PROMPT_FILE:-$CONFIG_DIR/refine_prompt.txt}"
REFINE_PROMPT_EXAMPLE="$CONFIG_DIR/refine_prompt.example.txt"
if [[ ! -f "$REFINE_PROMPT_FILE" && ! -f "$REFINE_PROMPT_EXAMPLE" ]]; then
  logerr "Error: no refine prompt found at $CONFIG_DIR/refine_prompt.{txt,example.txt}"
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  logerr "Error: jq not found. Install with: brew install jq"
  exit 1
fi

require_ollama_model

if [[ ! -d "$MD_DIR" ]]; then
  logerr "Error: summaries directory does not exist: $MD_DIR"
  exit 1
fi

MODEL_TAG="${MODEL//:/-}"

# Glob first-pass summaries; skip any already-refined output ("--refined" suffix
# before .md). Filter argument optional: only process summaries whose filename
# contains the given text (e.g. "nature_" or a date).
FILTER="${1:-}"
shopt -s nullglob
first_pass=()
for f in "$MD_DIR/"*"${FILTER}"*.md; do
  case "$f" in
    *--refined.md) continue ;;
  esac
  first_pass+=("$f")
done
shopt -u nullglob

if [[ ${#first_pass[@]} -eq 0 ]]; then
  log "No first-pass summaries matched ${FILTER:+\"$FILTER\" in }$MD_DIR"
  exit 0
fi

# Set NAMES_PREAMBLE and NAMES_TAIL; same shape as 4_summarize_session.sh so
# the refiner uses the same name-normalization signal.
#   set_names_wrapper "$names_list"
set_names_wrapper() {
  NAMES_PREAMBLE=""
  NAMES_TAIL=""
  [[ -n "$1" ]] || return 0
  NAMES_PREAMBLE="The transcript and draft below were produced by an automated speech-to-text pipeline and may contain mistranscriptions of names from this campaign. The following list is the canonical, authoritative spellings — these are the only acceptable forms. You MUST normalize every variant or near-spelling encountered to the canonical form shown here.

Glossary:
$1

"
  NAMES_TAIL="

Reminder: every occurrence in your output of any name listed in the glossary above must use the canonical spelling, regardless of how the transcript or draft spelled it."
}

script_start=$(date +%s)
log "Found ${#first_pass[@]} first-pass summary(s). Model: $MODEL  num_ctx ceiling: $NUM_CTX"

refined=0
skipped=0
failed=0

for draft in "${first_pass[@]}"; do
  base=$(basename "$draft" .md)
  dst="$MD_DIR/$base--refined.md"

  # Derive the transcript stem by stripping the "--<model>" suffix.
  session_stem="${base%%--*}"
  transcript="$TXT_DIR/$session_stem.txt"

  if [[ -e "$dst" ]]; then
    log "  skip  $(basename "$dst") (already exists)"
    skipped=$((skipped + 1))
    continue
  fi

  if [[ ! -f "$transcript" ]]; then
    logerr "  SKIP  $base (no transcript at $transcript)"
    failed=$((failed + 1))
    continue
  fi

  set_names_wrapper "$(session_names "$session_stem")"
  prompt_file=$(session_prompt_file "$REFINE_PROMPT_FILE" "$REFINE_PROMPT_EXAMPLE" "$session_stem")
  REFINE_SYSTEM_PROMPT=$(<"$prompt_file")

  log "  ..    refining $base (prompt: $(basename "$prompt_file"))"
  file_start=$(date +%s)

  prompt_bytes=$(( ${#REFINE_SYSTEM_PROMPT} + ${#NAMES_PREAMBLE} + ${#NAMES_TAIL} + $(wc -c < "$draft") + $(wc -c < "$transcript") ))
  ctx=$(fit_num_ctx "$prompt_bytes" "$NUM_CTX")

  if ! content=$(jq -n \
    --arg model "$MODEL" \
    --arg system "$REFINE_SYSTEM_PROMPT" \
    --arg pre "$NAMES_PREAMBLE" \
    --rawfile draft "$draft" \
    --rawfile transcript "$transcript" \
    --arg tail "$NAMES_TAIL" \
    --argjson num_ctx "$ctx" \
    --argjson temperature "$REFINE_TEMPERATURE" \
    '{
      model: $model,
      messages: [
        {role: "system", content: $system},
        {role: "user",   content: ($pre + "DRAFT OUTLINE TO REVIEW:\n\n" + $draft + "\n\nORIGINAL TRANSCRIPT:\n\n" + $transcript + $tail)}
      ],
      stream: false,
      options: {num_ctx: $num_ctx, temperature: $temperature}
    }' | ollama_chat "$ctx"); then
    logerr "  FAIL  $base"
    failed=$((failed + 1))
    continue
  fi

  printf '%s\n' "$content" | apply_session_variants "$session_stem" > "$dst.tmp" && mv "$dst.tmp" "$dst"
  log "  ok    $(basename "$dst") ($(fmt_duration $(($(date +%s) - file_start))), num_ctx $ctx)"
  refined=$((refined + 1))
done

log "Done. refined=$refined skipped=$skipped failed=$failed (total $(fmt_duration $(($(date +%s) - script_start))))"
log "Output: $MD_DIR"
