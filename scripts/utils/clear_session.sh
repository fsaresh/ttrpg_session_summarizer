#!/usr/bin/env bash
#
# Clear derived artifacts (transcripts, summaries) for a given session —
# useful when you want to rerun Stages 2-4 from scratch on a specific
# session. The original video in recordings/ and the extracted audio in
# audio/ are never touched: regenerating the audio is slow (ffmpeg has to
# re-process the full recording) and unnecessary unless the extraction params
# changed. If you need to reset the audio too, delete it manually.
#
# Argument is matched against the session filename stem, with or without
# its group prefix (see README "Session groups"), so:
#   nature_2026-04-21_19-51-46 → exactly that session
#   2026-04-21_19-51-46        → that session, whatever its group
#   2026-04-21                 → all sessions recorded on that date
#
# Pass -y / --yes to skip the confirmation prompt.
# Pass -l / --list to print the matching files and exit without deleting.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../_lib.sh"

if [[ $# -lt 1 ]]; then
  cat >&2 <<EOF
Usage: $(basename "$0") <session-id-or-prefix> [-y|--yes|-l|--list]

Clears transcripts/ and summaries/ entries for the given session.
Keeps the original .mp4/.mov in recordings/ and the extracted audio in audio/

Examples:
  $(basename "$0") nature_2026-04-21_19-51-46  # specific session
  $(basename "$0") 2026-04-21_19-51-46    # same session, any group
  $(basename "$0") 2026-04-21             # all sessions on that date
  $(basename "$0") 2026-04-21 -y          # skip confirmation
  $(basename "$0") 2026-04-21 -l          # list matching files; do not delete
EOF
  exit 1
fi

PATTERN="$1"
ASSUME_YES="false"
LIST_ONLY="false"
case "${2:-}" in
  -y|--yes)  ASSUME_YES="true" ;;
  -l|--list) LIST_ONLY="true" ;;
esac

# Require the pattern to start with a full YYYY-MM-DD date (after an optional
# group prefix) so a stray short
# prefix (e.g. "2026", "*", or empty) can't accidentally wipe a wide swath
# of derived artifacts.
if [[ ! "$PATTERN" =~ ^([A-Za-z0-9][A-Za-z0-9_-]*_)?[0-9]{4}-[0-9]{2}-[0-9]{2} ]]; then
  echo "Error: pattern must start with YYYY-MM-DD or <group>_YYYY-MM-DD (e.g. 2026-04-21, nature_2026-04-21)." >&2
  echo "       Got: '$PATTERN'" >&2
  exit 1
fi

# A bare date also matches the same date under any group prefix.
GLOB="$PATTERN"
[[ "$PATTERN" =~ ^[0-9] ]] && GLOB="?(*_)$PATTERN"

shopt -s nullglob extglob
srts=("$WORKSPACE_DIR/transcripts/"$GLOB*.srt)
txts=("$WORKSPACE_DIR/transcripts/"$GLOB*.txt)
jsons=("$WORKSPACE_DIR/transcripts/"$GLOB*.json)
mds=("$WORKSPACE_DIR/summaries/"$GLOB*.md)
shopt -u nullglob extglob

# bash 3.2 (macOS default) treats "${empty_array[@]}" as an unbound-variable
# error under `set -u`, so build all_files conditionally.
all_files=()
[[ ${#srts[@]}  -gt 0 ]] && all_files+=("${srts[@]}")
[[ ${#txts[@]}  -gt 0 ]] && all_files+=("${txts[@]}")
[[ ${#jsons[@]} -gt 0 ]] && all_files+=("${jsons[@]}")
[[ ${#mds[@]}   -gt 0 ]] && all_files+=("${mds[@]}")

if [[ ${#all_files[@]} -eq 0 ]]; then
  echo "No derived files found for pattern: $PATTERN"
  echo "(recordings/ and audio/ are never touched)"
  exit 0
fi

if [[ "$LIST_ONLY" == "true" ]]; then
  echo "Matching ${#all_files[@]} file(s) for pattern: $PATTERN"
  for f in "${all_files[@]}"; do
    echo "  $f"
  done
  exit 0
fi

echo "Will delete ${#all_files[@]} file(s):"
for f in "${all_files[@]}"; do
  echo "  $f"
done
echo
echo "(recordings/${PATTERN}*.mp4|.mov and audio/${PATTERN}*.{flac,wav,...} will NOT be touched.)"
echo

if [[ "$ASSUME_YES" != "true" ]]; then
  read -r -p "Proceed? [y/N] " confirm
  if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    echo "Aborted."
    exit 0
  fi
fi

deleted=0
for f in "${all_files[@]}"; do
  command rm -f "$f"
  deleted=$((deleted + 1))
done

echo "Done. Deleted $deleted file(s)."
