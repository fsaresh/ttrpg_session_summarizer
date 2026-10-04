#!/usr/bin/env bash
#
# Show per-session pipeline state. For each session (derived from .mp4/.mov in
# recordings/ or audio file in audio/), display whether each downstream
# artifact exists. Useful for "which sessions need processing?" and
# spotting stuck or partial runs.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../_lib.sh"

# Optional filter: pattern matched against session stems.
FILTER="${1:-}"

# Collect session stems from recordings/*.{mp4,mov} (preferred) and
# audio/*.{wav,m4a,mp3,flac,ogg,aac}. A "session stem" is the basename minus
# extension. Same stem may appear in both dirs (video + extracted audio); we
# de-dup by treating the set as a sorted unique list. nocaseglob so .MOV/.MP4
# match too, matching Stage 1's glob.
shopt -s nullglob nocaseglob
videos=("$WORKSPACE_DIR/recordings/${FILTER}"*.mp4
        "$WORKSPACE_DIR/recordings/${FILTER}"*.mov)
audios=("$WORKSPACE_DIR/audio/${FILTER}"*.wav
        "$WORKSPACE_DIR/audio/${FILTER}"*.m4a
        "$WORKSPACE_DIR/audio/${FILTER}"*.mp3
        "$WORKSPACE_DIR/audio/${FILTER}"*.flac
        "$WORKSPACE_DIR/audio/${FILTER}"*.ogg
        "$WORKSPACE_DIR/audio/${FILTER}"*.aac)
shopt -u nullglob nocaseglob

# Collect all stems then dedup-sort. (Avoiding bash 4 associative arrays
# since macOS ships bash 3.2.)
all_stems=""
# ${arr[@]+"${arr[@]}"} so an empty array doesn't trip `set -u` on bash 3.2.
for f in ${videos[@]+"${videos[@]}"} ${audios[@]+"${audios[@]}"}; do
  [[ -e "$f" ]] || continue
  stem=$(basename "$f")
  stem="${stem%.*}"
  all_stems="$all_stems"$'\n'"$stem"
done
sorted_stems=$(printf '%s' "$all_stems" | sort -u | sed '/^$/d')

if [[ -z "$sorted_stems" ]]; then
  log "No sessions matched ${FILTER:+\"$FILTER\" }in $WORKSPACE_DIR/{recordings,audio}/"
  exit 0
fi

IFS=$'\n' sorted=($sorted_stems)
unset IFS

# Header.
printf '%-26s  %s  %s  %s  %s  %s  %s\n' \
  "session" "video" "audio" "srt" "txt" "md" "refined"
printf '%-26s  %s  %s  %s  %s  %s  %s\n' \
  "$(printf '%.0s-' {1..26})" "-----" "-----" "---" "---" "--" "-------"

mark() { [[ -e "$1" ]] && printf '%-3s' '  •' || printf '%-3s' '   '; }
markn() { [[ -e "$1" ]] && printf '%-7s' '   •' || printf '%-7s' '       '; }

count_total=0
count_complete=0

for stem in "${sorted[@]}"; do
  # The source video may be .mp4 or .mov; treat existence of any as "video present".
  # Uppercase spellings are listed explicitly for case-sensitive volumes.
  has_video=
  for ext in mp4 mov MP4 MOV; do
    [[ -f "$WORKSPACE_DIR/recordings/$stem.$ext" ]] && { has_video=1; break; }
  done
  has_audio=$(find_audio "$WORKSPACE_DIR/audio" "$stem")
  srt="$WORKSPACE_DIR/transcripts/$stem.srt"
  txt="$WORKSPACE_DIR/transcripts/$stem.txt"

  shopt -s nullglob
  mds=("$WORKSPACE_DIR/summaries/$stem--"*.md)
  refined_mds=("$WORKSPACE_DIR/summaries/$stem--"*--refined.md)
  # mds includes refined; subtract.
  non_refined=()
  for m in ${mds[@]+"${mds[@]}"}; do
    [[ "$m" == *--refined.md ]] || non_refined+=("$m")
  done
  shopt -u nullglob

  printf '%-26s' "$stem"
  printf '  %s' "$([[ -n "$has_video" ]] && echo "•    " || echo "     ")"
  printf '  %s' "$([[ -n "$has_audio" ]] && echo "•    " || echo "     ")"
  printf '  %s' "$([[ -f "$srt" ]] && echo "•  " || echo "   ")"
  printf '  %s' "$([[ -f "$txt" ]] && echo "•  " || echo "   ")"
  printf '  %s' "$([[ ${#non_refined[@]} -gt 0 ]] && printf '×%-2d' "${#non_refined[@]}" || echo "   ")"
  printf '  %s'  "$([[ ${#refined_mds[@]} -gt 0 ]] && printf '×%-3d' "${#refined_mds[@]}" || echo "    ")"
  echo

  count_total=$((count_total + 1))
  if [[ -n "$has_audio" && -f "$srt" && -f "$txt" && ${#non_refined[@]} -gt 0 ]]; then
    count_complete=$((count_complete + 1))
  fi
done

echo
echo "  $count_complete / $count_total sessions have completed Stages 1-4 (video → audio → srt → txt → md)."
echo "  '×N' under md/refined columns indicates how many model variants exist for that session."
