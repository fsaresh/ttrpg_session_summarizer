#!/usr/bin/env bash
#
# Clear all derived artifacts (audio, transcripts, summaries) for a given
# session — useful when you want to rerun the pipeline from scratch on a
# specific session. The original .mp4 in Recordings/ is never touched.
#
# Argument is a glob prefix matched against the session filename stem, so:
#   2026-04-21_19-51-46   → exactly that session
#   2026-04-21            → all sessions recorded on that date
#
# Pass -y / --yes to skip the confirmation prompt.
# Pass -l / --list to print the matching files and exit without deleting.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_lib.sh"

if [[ $# -lt 1 ]]; then
  cat >&2 <<EOF
Usage: $(basename "$0") <session-id-or-prefix> [-y|--yes|-l|--list]

Clears Audio, Transcripts, and Summaries entries for the given session.
Keeps the original .mp4 in Recordings/.

Examples:
  $(basename "$0") 2026-04-21_19-51-46    # specific session
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

# Require the pattern to start with a full YYYY-MM-DD date so a stray short
# prefix (e.g. "2026", "*", or empty) can't accidentally wipe a wide swath
# of derived artifacts.
if [[ ! "$PATTERN" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2} ]]; then
  echo "Error: pattern must start with YYYY-MM-DD (e.g. 2026-04-21)." >&2
  echo "       Got: '$PATTERN'" >&2
  exit 1
fi

shopt -s nullglob
audio=("$OBS_DIR/Audio/${PATTERN}"*.wav)
srts=("$OBS_DIR/Transcripts/${PATTERN}"*.srt)
txts=("$OBS_DIR/Transcripts/${PATTERN}"*.txt)
jsons=("$OBS_DIR/Transcripts/${PATTERN}"*.json)
mds=("$OBS_DIR/Summaries/${PATTERN}"*.md)
shopt -u nullglob

# bash 3.2 (macOS default) treats "${empty_array[@]}" as an unbound-variable
# error under `set -u`, so build all_files conditionally.
all_files=()
[[ ${#audio[@]} -gt 0 ]] && all_files+=("${audio[@]}")
[[ ${#srts[@]}  -gt 0 ]] && all_files+=("${srts[@]}")
[[ ${#txts[@]}  -gt 0 ]] && all_files+=("${txts[@]}")
[[ ${#jsons[@]} -gt 0 ]] && all_files+=("${jsons[@]}")
[[ ${#mds[@]}   -gt 0 ]] && all_files+=("${mds[@]}")

if [[ ${#all_files[@]} -eq 0 ]]; then
  echo "No derived files found for pattern: $PATTERN"
  echo "(Recordings/ is never touched)"
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
echo "(Recordings/${PATTERN}*.mp4 will NOT be touched.)"
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
