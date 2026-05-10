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

# System prompt is loaded from config/. Try the user's customized version
# first, fall back to the shipped .example.txt.
REFINE_PROMPT_FILE="${REFINE_PROMPT_FILE:-$CONFIG_DIR/refine_prompt.txt}"
if [[ ! -f "$REFINE_PROMPT_FILE" ]]; then
  REFINE_PROMPT_FILE="$CONFIG_DIR/refine_prompt.example.txt"
fi
if [[ ! -f "$REFINE_PROMPT_FILE" ]]; then
  logerr "Error: no refine prompt found at $CONFIG_DIR/refine_prompt.{txt,example.txt}"
  exit 1
fi
REFINE_SYSTEM_PROMPT=$(<"$REFINE_PROMPT_FILE")

if ! command -v jq >/dev/null 2>&1; then
  logerr "Error: jq not found. Install with: brew install jq"
  exit 1
fi

if ! curl -sf "$OLLAMA_URL/api/tags" >/dev/null 2>&1; then
  logerr "Error: cannot reach Ollama at $OLLAMA_URL"
  exit 1
fi

if ! curl -sf "$OLLAMA_URL/api/tags" | jq -e --arg m "$MODEL" '.models[] | select(.name == $m)' >/dev/null; then
  logerr "Error: model '$MODEL' is not installed in Ollama."
  logerr "  Pull it with: ollama pull $MODEL"
  exit 1
fi

if [[ ! -d "$MD_DIR" ]]; then
  logerr "Error: summaries directory does not exist: $MD_DIR"
  exit 1
fi

MODEL_TAG="${MODEL//:/-}"

# Glob first-pass summaries; skip any already-refined output ("--refined" suffix
# before .md). Filter argument optional: only process summaries whose filename
# starts with the given prefix.
FILTER="${1:-}"
shopt -s nullglob
first_pass=()
for f in "$MD_DIR/${FILTER}"*.md; do
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

# Build the canonical-names preamble; same shape as 4_summarize_session.sh so
# the refiner uses the same name-normalization signal.
NAMES_PREAMBLE=""
NAMES_TAIL=""
NAMES_LIST=$(read_names "$NAMES_FILE")
if [[ -n "$NAMES_LIST" ]]; then
  NAMES_PREAMBLE="The transcript and draft below were produced by an automated speech-to-text pipeline and may contain mistranscriptions of names from this campaign. The following list is the canonical, authoritative spellings — these are the only acceptable forms. You MUST normalize every variant or near-spelling encountered to the canonical form shown here.

Glossary:
$NAMES_LIST

"
  NAMES_TAIL="

Reminder: every occurrence in your output of any name listed in the glossary above must use the canonical spelling, regardless of how the transcript or draft spelled it."
fi

script_start=$(date +%s)
log "Found ${#first_pass[@]} first-pass summary(s). Model: $MODEL  num_ctx: $NUM_CTX"

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

  log "  ..    refining $base"
  file_start=$(date +%s)

  user_content=$(jq -n \
    --arg pre "$NAMES_PREAMBLE" \
    --rawfile draft "$draft" \
    --rawfile transcript "$transcript" \
    --arg tail "$NAMES_TAIL" \
    -r '$pre + "DRAFT OUTLINE TO REVIEW:\n\n" + $draft + "\n\nORIGINAL TRANSCRIPT:\n\n" + $transcript + $tail')

  request=$(jq -n \
    --arg model "$MODEL" \
    --arg system "$REFINE_SYSTEM_PROMPT" \
    --arg user "$user_content" \
    --argjson num_ctx "$NUM_CTX" \
    --argjson temperature "$REFINE_TEMPERATURE" \
    '{
      model: $model,
      messages: [
        {role: "system", content: $system},
        {role: "user",   content: $user}
      ],
      stream: false,
      options: {num_ctx: $num_ctx, temperature: $temperature}
    }')

  response=$(curl -sf -X POST "$OLLAMA_URL/api/chat" \
    -H 'Content-Type: application/json' \
    -d "$request" || echo "")

  if [[ -z "$response" ]]; then
    logerr "  FAIL  $base (no response from Ollama)"
    failed=$((failed + 1))
    continue
  fi

  if echo "$response" | jq -e '.error' >/dev/null 2>&1; then
    err=$(echo "$response" | jq -r '.error')
    logerr "  FAIL  $base (Ollama error: $err)"
    failed=$((failed + 1))
    continue
  fi

  content=$(echo "$response" | jq -r '.message.content // empty')
  if [[ -z "$content" ]]; then
    logerr "  FAIL  $base (empty content in response)"
    failed=$((failed + 1))
    continue
  fi

  printf '%s\n' "$content" | apply_name_variants "$VARIANTS_FILE" > "$dst.tmp" && mv "$dst.tmp" "$dst"
  log "  ok    $(basename "$dst") ($(fmt_duration $(($(date +%s) - file_start))))"
  refined=$((refined + 1))
done

log "Done. refined=$refined skipped=$skipped failed=$failed (total $(fmt_duration $(($(date +%s) - script_start))))"
log "Output: $MD_DIR"
