#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_lib.sh"

WORK_DIR="$OBS_DIR/Transcripts"

# See README "Tier 2: clean_transcript" for tuning notes.
DEDUPE_WINDOW="${DEDUPE_WINDOW:-8}"
CONFIDENCE_THRESHOLD="${CONFIDENCE_THRESHOLD:-0.5}"

if [[ ! -d "$WORK_DIR" ]]; then
  logerr "Error: directory does not exist: $WORK_DIR"
  exit 1
fi

shopt -s nullglob
srt_files=("$WORK_DIR"/*.srt)
shopt -u nullglob

if [[ ${#srt_files[@]} -eq 0 ]]; then
  log "No .srt files found in $WORK_DIR"
  exit 0
fi

script_start=$(date +%s)
log "Found ${#srt_files[@]} .srt file(s)."

cleaned=0
skipped=0
failed=0

for src in "${srt_files[@]}"; do
  base=$(basename "$src" .srt)
  dst="$WORK_DIR/$base.txt"

  if [[ -e "$dst" ]]; then
    log "  skip  $base.txt (already exists)"
    skipped=$((skipped + 1))
    continue
  fi

  json="$WORK_DIR/$base.json"
  log "  ..    cleaning $base.srt$([[ -f "$json" ]] && echo " (+ json confidence)")"
  file_start=$(date +%s)
  # Source is either the JSON (token-level confidence preserved as [?] markers
  # on low-confidence tokens, one line per segment) or the SRT (legacy fallback
  # for sessions transcribed before --output-json-full was wired in). The same
  # awk pass handles SRT structural-line stripping and sliding-window dedupe
  # for both inputs.
  if {
    if [[ -f "$json" ]]; then
      jq -r --argjson t "$CONFIDENCE_THRESHOLD" '
        .transcription[]
        | [.tokens[]
            | select(.text | startswith("[_") | not)
            | if .p < $t then .text + "[?]" else .text end]
        | join("")
      ' "$json"
    else
      cat "$src"
    fi
  } | awk -v window="$DEDUPE_WINDOW" '
      /^[[:space:]]*[0-9]+[[:space:]]*$/ { next }
      /-->/ { next }
      {
        gsub(/^[[:space:]]+|[[:space:]]+$/, "")
        if ($0 == "") next
        if ($0 in last && (NR - last[$0]) < window) next
        last[$0] = NR
        print
      }
    ' > "$dst.tmp" && mv "$dst.tmp" "$dst"; then
    log "  ok    $base.txt ($(fmt_duration $(($(date +%s) - file_start))))"
    cleaned=$((cleaned + 1))
  else
    logerr "  FAIL  $base.srt (see jq/awk output above)"
    rm -f "$dst.tmp" "$dst"
    failed=$((failed + 1))
  fi
done

log "Done. cleaned=$cleaned skipped=$skipped failed=$failed (total $(fmt_duration $(($(date +%s) - script_start))))"
log "Output: $WORK_DIR"
