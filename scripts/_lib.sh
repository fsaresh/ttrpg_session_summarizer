#!/usr/bin/env bash
#
# Shared helpers for the OBS pipeline scripts. Source from sibling scripts:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "$SCRIPT_DIR/_lib.sh"
#
# This file holds helpers only — logging, duration formatting, audio
# lookup, Ollama requests, and glossary parsing. Workspace paths and per-machine settings come from
# the .env file at repo root (or .env.example as fallback), sourced below.

# ---------------------------------------------------------------------------
# Environment loading
# ---------------------------------------------------------------------------

# Pull in WORKSPACE_DIR, CONFIG_DIR, model paths, and stage tunables from
# .env at the repo root. If the user hasn't created .env, fall back to
# .env.example so the pipeline works out of the box with shipped defaults.
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$LIB_DIR/../.env}"
if [[ ! -f "$ENV_FILE" ]]; then
  ENV_FILE="$LIB_DIR/../.env.example"
fi
if [[ -f "$ENV_FILE" ]]; then
  source "$ENV_FILE"
fi
unset LIB_DIR

# ---------------------------------------------------------------------------
# Generic helpers
# ---------------------------------------------------------------------------

# Wall-clock timestamp (HH:MM:SS) to use in logging.
ts() { date +%H:%M:%S; }

# Drop-in replacements for echo that prefix every line with the current
# timestamp. Use `log` for stdout and `logerr` for stderr.
log()    { printf '[%s] %s\n' "$(ts)" "$*"; }
logerr() { printf '[%s] %s\n' "$(ts)" "$*" >&2; }

# Format a duration in seconds as a human-readable string.
#   12       -> "12s"
#   305      -> "5m05s"
#   7820     -> "2h10m20s"
fmt_duration() {
  local sec=$1
  if (( sec < 60 )); then
    printf '%ds' "$sec"
  elif (( sec < 3600 )); then
    printf '%dm%02ds' $((sec / 60)) $((sec % 60))
  else
    printf '%dh%02dm%02ds' $((sec / 3600)) $((sec % 3600 / 60)) $((sec % 60))
  fi
}

# Print the path of the audio file for a session stem (any supported
# extension), or nothing if there isn't one.
#   audio=$(find_audio "$AUDIO_DIR" "$stem")
find_audio() {
  local dir="$1" stem="$2" ext
  for ext in flac wav m4a mp3 ogg aac; do
    if [[ -f "$dir/$stem.$ext" ]]; then
      printf '%s\n' "$dir/$stem.$ext"
      return
    fi
  done
}

# ---------------------------------------------------------------------------
# Ollama helpers
# ---------------------------------------------------------------------------

# Exit with an error unless Ollama is reachable and has $MODEL pulled.
require_ollama_model() {
  local tags
  if ! tags=$(curl -sf --max-time 10 "$OLLAMA_URL/api/tags"); then
    logerr "Error: cannot reach Ollama at $OLLAMA_URL"
    logerr "  Is the service running? Try: brew services start ollama"
    exit 1
  fi
  if ! jq -e --arg m "$MODEL" '.models[] | select(.name == $m)' <<<"$tags" >/dev/null; then
    logerr "Error: model '$MODEL' is not installed in Ollama."
    logerr "  Pull it with: ollama pull $MODEL"
    exit 1
  fi
}

# Size the context window for a prompt of the given byte count: a
# conservative 3 bytes/token estimate plus room for the reply, rounded up to
# a multiple of 8192, capped at the ceiling. See README "Stage 4".
#   ctx=$(fit_num_ctx "$prompt_bytes" "$NUM_CTX")
fit_num_ctx() {
  local bytes=$1 ceiling=$2
  local ctx=$(( (bytes / 3 + 4096 + 8191) / 8192 * 8192 ))
  (( ctx > ceiling )) && ctx=$ceiling
  printf '%d\n' "$ctx"
}

# Send an /api/chat request (JSON on stdin) to Ollama and print the reply
# text. Logs the reason and returns 1 on failure. Warns when the request
# nearly filled the context window, since Ollama truncates overflow silently.
#   reply=$(jq -n '...' | ollama_chat "$ctx")
ollama_chat() {
  local num_ctx=$1 response err content used
  if ! response=$(curl -s --fail-with-body --max-time "${OLLAMA_TIMEOUT:-3600}" \
      -X POST "$OLLAMA_URL/api/chat" \
      -H 'Content-Type: application/json' \
      --data-binary @-); then
    err=$(jq -r '.error // empty' <<<"$response" 2>/dev/null || true)
    logerr "        Ollama request failed${err:+: $err}"
    return 1
  fi
  content=$(jq -r '.message.content // empty' <<<"$response")
  if [[ -z "$content" ]]; then
    logerr "        empty content in Ollama response"
    return 1
  fi
  used=$(jq -r '(.prompt_eval_count // 0) + (.eval_count // 0)' <<<"$response")
  if (( used * 100 >= num_ctx * 95 )); then
    logerr "        warning: used $used of $num_ctx context tokens; the input may have been truncated. Raise NUM_CTX."
  fi
  printf '%s\n' "$content"
}

# ---------------------------------------------------------------------------
# Glossary helpers
# ---------------------------------------------------------------------------

# Read a names file, emitting one canonical name per line. Skips blanks and
# lines starting with `#`. Trims surrounding whitespace. A leading `~` marks a
# name to leave out of whisper's prompt (see README "Names glossary"): it is
# stripped by default, and with --whisper those names are skipped. Missing
# file is treated as empty (no output, no error).
#   read_names "$NAMES_FILE" [--whisper]
read_names() {
  local file="$1" whisper=0
  [[ "${2:-}" == "--whisper" ]] && whisper=1
  [[ -f "$file" ]] || return 0
  awk -v whisper="$whisper" '
    /^[[:space:]]*$/ { next }
    /^[[:space:]]*#/ { next }
    {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "")
      if (sub(/^~[[:space:]]*/, "") && whisper) next
      print
    }
  ' "$file"
}

# Print the group of a session stem ("nature" for nature_2026-09-17_18-31-42),
# or nothing if it has none. See README "Session groups".
#   group=$(session_group "$stem")
session_group() {
  if [[ "$1" =~ ^([A-Za-z0-9][A-Za-z0-9_-]*)_[0-9]{4}-[0-9]{2}-[0-9]{2} ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  fi
}

# Print the group-specific path for a shared config file: names.txt for
# group "nature" is nature_names.txt in the same directory. Prints nothing
# for an empty group.
#   group_file "$NAMES_FILE" "$group"
group_file() {
  if [[ -n "$2" ]]; then
    printf '%s/%s_%s\n' "$(dirname "$1")" "$2" "$(basename "$1")"
  fi
}

# Canonical names for a session: its group's glossary followed by the shared
# one ($NAMES_FILE), without duplicates. Group names come first because
# Stage 2 keeps only as many as fit in whisper's prompt. --whisper is passed
# through to read_names.
#   session_names "$stem" [--whisper]
session_names() {
  local group
  group=$(session_group "$1")
  {
    if [[ -n "$group" ]]; then
      read_names "$(group_file "$NAMES_FILE" "$group")" ${2:+"$2"}
    fi
    read_names "$NAMES_FILE" ${2:+"$2"}
  } | awk '!seen[$0]++'
}

# Apply a session's variant rules to stdin: its group's file first, then the
# shared $VARIANTS_FILE.
#   apply_session_variants "$stem" <input >output
apply_session_variants() {
  local group
  group=$(session_group "$1")
  if [[ -n "$group" ]]; then
    apply_name_variants "$(group_file "$VARIANTS_FILE" "$group")" | apply_name_variants "$VARIANTS_FILE"
  else
    apply_name_variants "$VARIANTS_FILE"
  fi
}

# Print the prompt file for a session: its group's copy of $1 if present,
# else $1, else the shipped example ($2). Prints nothing if none exist.
#   session_prompt_file "$SUMMARY_PROMPT_FILE" "$CONFIG_DIR/summary_prompt.example.txt" "$stem"
session_prompt_file() {
  local f
  for f in "$(group_file "$1" "$(session_group "$3")")" "$1" "$2"; do
    if [[ -n "$f" && -f "$f" ]]; then
      printf '%s\n' "$f"
      return
    fi
  done
}

# Apply variant -> canonical name substitutions to stdin, writing to stdout.
# Reads rules from a file in the format described at the top of
# config/name_variants.txt. If the variants file is missing, this is a
# passthrough.
#   apply_name_variants "$VARIANTS_FILE" <input >output
apply_name_variants() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    cat
    return
  fi
  VARIANTS_FILE="$file" perl -e '
    use strict; use warnings;
    my @rules;
    open my $fh, "<", $ENV{VARIANTS_FILE} or die "open $ENV{VARIANTS_FILE}: $!";
    while (my $line = <$fh>) {
      chomp $line;
      $line =~ s/^\s+|\s+$//g;
      next if $line eq "" || $line =~ /^#/;
      my ($from, $to) = split /\s*->\s*/, $line, 2;
      next unless defined $to;
      my $cap_only = ($from =~ s/^!//) ? 1 : 0;
      push @rules, [$from, $to, $cap_only];
    }
    close $fh;
    while (my $line = <STDIN>) {
      for my $r (@rules) {
        my ($from, $to, $cs) = @$r;
        if ($cs) { $line =~ s/\b\Q$from\E\b/$to/g; }
        else     { $line =~ s/\b\Q$from\E\b/$to/gi; }
      }
      print $line;
    }
  '
}
