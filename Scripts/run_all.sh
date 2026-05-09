#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pushd "$SCRIPT_DIR" >/dev/null

./audio_extracter.sh
./audio_transcriber.sh
./transcript_cleaner.sh
./session_summarizer.sh

popd >/dev/null
