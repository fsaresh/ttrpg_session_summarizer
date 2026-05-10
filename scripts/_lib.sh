#!/usr/bin/env bash
#
# Shared helpers for the OBS pipeline scripts. Source from sibling scripts:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "$SCRIPT_DIR/_lib.sh"
#
# This file holds helpers only — logging, duration formatting, and
# glossary parsing. Workspace paths and per-machine settings come from
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

# Wall-clock timestamp (HH:MM:SS).
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

# ---------------------------------------------------------------------------
# Glossary helpers
# ---------------------------------------------------------------------------

# Read a names file, emitting one canonical name per line. Skips blanks and
# lines starting with `#`. Trims surrounding whitespace. Missing file is
# treated as empty (no output, no error).
#   read_names "$NAMES_FILE"
read_names() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  awk '
    /^[[:space:]]*$/ { next }
    /^[[:space:]]*#/ { next }
    {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "")
      print
    }
  ' "$file"
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
