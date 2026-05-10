#!/usr/bin/env bash
#
# Standard per-session entry point: chains the four core pipeline stages.
# Run this after dropping a new .mp4 into recordings/ (or audio file into
# audio/). All four stages are idempotent — already-processed sessions are
# skipped automatically.
#
# Optional helpers live in scripts/utils/ (refine, audit, lint, clear).

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"$REPO_DIR/scripts/pipeline/1_extract_audio.sh"
"$REPO_DIR/scripts/pipeline/2_transcribe_audio.sh"
"$REPO_DIR/scripts/pipeline/3_clean_transcript.sh"
"$REPO_DIR/scripts/pipeline/4_summarize_session.sh"
