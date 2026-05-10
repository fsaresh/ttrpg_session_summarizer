#!/usr/bin/env bash
#
# Validate that this machine is set up correctly to run the pipeline.
# Checks installed tools, reachable services, configured paths, and data
# files. Run this once after one-time setup (or any time you suspect
# something's misconfigured).
#
# Exits 0 if everything's healthy, 1 if anything failed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../_lib.sh"

passed=0
failed=0
warned=0

ok()   { printf '  [ ok ]  %s\n' "$*";       passed=$((passed + 1)); }
fail() { printf '  [FAIL]  %s\n' "$*" >&2;   failed=$((failed + 1)); }
warn() { printf '  [warn]  %s\n' "$*";       warned=$((warned + 1)); }

section() { printf '\n=== %s ===\n' "$*"; }

# ---------------------------------------------------------------------------
section "Required tools"
# ---------------------------------------------------------------------------

for tool in ffmpeg whisper-cli ollama jq curl perl awk; do
  if command -v "$tool" >/dev/null 2>&1; then
    ok "$tool ($(command -v "$tool"))"
  else
    fail "$tool not found on PATH (install per README \"One-time setup\")"
  fi
done

# ---------------------------------------------------------------------------
section "Workspace paths"
# ---------------------------------------------------------------------------

for var in WORKSPACE_DIR CONFIG_DIR; do
  val="${!var:-}"
  if [[ -z "$val" ]]; then
    fail "$var is unset (.env should set it)"
  elif [[ -d "$val" ]]; then
    ok "$var = $val"
  else
    fail "$var = $val (directory does not exist)"
  fi
done

for sub in recordings audio transcripts summaries; do
  d="$WORKSPACE_DIR/$sub"
  if [[ -d "$d" ]]; then
    ok "$d/"
  else
    warn "$d/ missing (will be created on first run; warning only)"
  fi
done

# ---------------------------------------------------------------------------
section "Whisper.cpp model"
# ---------------------------------------------------------------------------

if [[ -z "${MODEL_PATH:-}" ]]; then
  fail "MODEL_PATH is unset"
elif [[ -f "$MODEL_PATH" ]]; then
  size=$(du -h "$MODEL_PATH" | awk '{print $1}')
  ok "MODEL_PATH = $MODEL_PATH ($size)"
else
  fail "MODEL_PATH = $MODEL_PATH (file does not exist; download per README)"
fi

# ---------------------------------------------------------------------------
section "Ollama service and model"
# ---------------------------------------------------------------------------

if [[ -z "${OLLAMA_URL:-}" ]]; then
  fail "OLLAMA_URL is unset"
elif curl -sf "$OLLAMA_URL/api/tags" >/dev/null 2>&1; then
  ok "Ollama reachable at $OLLAMA_URL"

  if [[ -n "${MODEL:-}" ]]; then
    if curl -sf "$OLLAMA_URL/api/tags" | jq -e --arg m "$MODEL" '.models[] | select(.name == $m)' >/dev/null 2>&1; then
      ok "MODEL '$MODEL' is pulled"
    else
      fail "MODEL '$MODEL' not in ollama list (run: ollama pull $MODEL)"
    fi
  else
    fail "MODEL is unset"
  fi
else
  fail "Cannot reach Ollama at $OLLAMA_URL (start with: brew services start ollama)"
fi

# ---------------------------------------------------------------------------
section "Per-campaign data files"
# ---------------------------------------------------------------------------

for f in names.txt name_variants.txt summary_prompt.example.txt refine_prompt.example.txt; do
  p="$CONFIG_DIR/$f"
  if [[ -f "$p" ]]; then
    ok "$p"
  elif [[ "$f" == *.example.txt ]]; then
    fail "$p missing (shipped template; should always be present)"
  else
    warn "$p missing (run: cp $CONFIG_DIR/${f%.txt}.example.txt $p, then edit)"
  fi
done

# ---------------------------------------------------------------------------
section "Glossary lint"
# ---------------------------------------------------------------------------

if [[ -f "$CONFIG_DIR/names.txt" || -f "$CONFIG_DIR/name_variants.txt" ]]; then
  if "$SCRIPT_DIR/lint_glossary.sh" >/dev/null 2>&1; then
    ok "lint_glossary.sh passes"
  else
    fail "lint_glossary.sh reported errors (run it directly to see details)"
  fi
else
  warn "skipping lint (no names.txt / name_variants.txt yet)"
fi

# ---------------------------------------------------------------------------
section "Summary"
# ---------------------------------------------------------------------------

printf '  passed: %d   warnings: %d   failed: %d\n' "$passed" "$warned" "$failed"
exit $(( failed > 0 ? 1 : 0 ))
