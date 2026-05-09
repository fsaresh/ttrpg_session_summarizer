#!/usr/bin/env bash
#
# Standard per-session entry point: chains the four core pipeline stages.
# Run this after dropping a new .mp4 into Recordings/ (or audio file into
# Audio/). All four stages are idempotent — already-processed sessions are
# skipped automatically.
#
# Optional helpers live in Scripts/utils/ (refine, audit, lint, clear).

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"$REPO_DIR/Scripts/pipeline/extract_audio.sh"
"$REPO_DIR/Scripts/pipeline/transcribe_audio.sh"
"$REPO_DIR/Scripts/pipeline/clean_transcript.sh"
"$REPO_DIR/Scripts/pipeline/summarize_session.sh"
