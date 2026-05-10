#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../_lib.sh"

TRANSCRIPTS_DIR="$WORKSPACE_DIR/transcripts"
SUMMARIES_DIR="$WORKSPACE_DIR/summaries"

# See README "Tier 3: summarize_session" for setup, model choice, and tuning.
MODEL="${MODEL:-qwen2.5:32b-instruct-q4_K_M}"
NUM_CTX="${NUM_CTX:-65536}"
TEMPERATURE="${TEMPERATURE:-0.3}"
OLLAMA_URL="${OLLAMA_URL:-http://localhost:11434}"
NAMES_FILE="${NAMES_FILE:-$CONFIG_DIR/names.txt}"
VARIANTS_FILE="${VARIANTS_FILE:-$CONFIG_DIR/name_variants.txt}"

SYSTEM_PROMPT='You are a transcription analyst for a tabletop RPG campaign. You receive a cleaned plain-text transcript of a recently played game session. Your job is to extract a structured outline of what happened — NOT to write polished narrative prose. Your output is the input to a downstream pass that handles prose synthesis.

Output format (markdown):

## Session beats
Chronological bullet list of major plot or scene moments. One bullet per scene or significant event. Be specific about who did what, where, and what changed as a result.

## NPCs encountered
For each NPC the party interacted with: name, apparent role or affiliation, and a short description of their interaction in this session.

## Key decisions and outcomes
What the party chose. What happened as a result of those choices. Include things they explicitly chose not to do if it came up.

## Lore, clues, and worldbuilding
Anything mentioned about the larger campaign world: prophecies, references to past events, hints, factional info. Quote prophecies or potentially-significant phrasings exactly.

## Items, magic, abilities of note
Items found, lost, used. Spells or abilities that mattered. Anything with mechanical significance worth tracking.

## Character moments
Personal moments for individual player characters: emotional beats, growth, drama, internal conflict, relationships. Note which character (use their proper name from the transcript).

## Open threads
What is unresolved, what the party might pursue next, what questions linger.

## Notable quotes
Up to five lines from the transcript worth preserving verbatim — funny lines, dramatic moments, in-character declarations. Mark each with [quote].

Rules:
- Proper nouns: the user message provides a glossary of canonical spellings for this campaign. For any name in that glossary, output the canonical spelling — even when the transcript spells it differently (homophones, missing letters, phonetic variants). For names not in the glossary, preserve them exactly as the transcript spells them. Do not anglicize, paraphrase, or invent alternative spellings.
- Do not invent details or fill in gaps. If something is unclear, write "[unclear]".
- Skip rules-discussion meta-talk and out-of-character chat unless directly relevant to in-fiction events.
- Be comprehensive but compressed: this is an outline, not a novel.
- Do not add narrative voice or atmospheric prose — that is a separate pass.'

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
  log "No .txt files found in $TRANSCRIPTS_DIR (run clean_transcript.sh first)"
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
    --argjson temperature "$TEMPERATURE" \
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
