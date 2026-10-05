#!/usr/bin/env bash
#
# See README "Summary auditor".

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../_lib.sh"

SUMMARIES_DIR="${SUMMARIES_DIR:-$WORKSPACE_DIR/summaries}"
NAMES_FILE="${NAMES_FILE:-$CONFIG_DIR/names.txt}"
VARIANTS_FILE="${VARIANTS_FILE:-$CONFIG_DIR/name_variants.txt}"

if [[ ! -d "$SUMMARIES_DIR" ]]; then
  logerr "Error: summaries directory does not exist: $SUMMARIES_DIR"
  exit 1
fi

# Filter argument (optional): only audit summaries whose filename contains
# the given text (e.g. "nature_", "2026-05-05", or a session stem).
FILTER="${1:-}"

shopt -s nullglob
md_files=("$SUMMARIES_DIR/"*"${FILTER}"*.md)
shopt -u nullglob

if [[ ${#md_files[@]} -eq 0 ]]; then
  log "No summaries matched ${FILTER:+\"$FILTER\" in }$SUMMARIES_DIR"
  exit 0
fi

# Print the variant (left-hand) side of each rule in a variants file, keeping
# any `!` (capitalized-only) prefix.
#   variant_lefts "$file"
variant_lefts() {
  [[ -f "$1" ]] || return 0
  awk '
    /^[[:space:]]*$/ { next }
    /^[[:space:]]*#/ { next }
    {
      sub(/^[[:space:]]+/, "")
      sub(/[[:space:]]+$/, "")
      idx = match($0, /[[:space:]]*->[[:space:]]*/)
      if (idx == 0) next
      from = substr($0, 1, idx - 1)
      sub(/[[:space:]]+$/, "", from)
      print from
    }
  ' "$1"
}

canon_tmp=$(mktemp)
variant_tmp=$(mktemp)
trap 'command rm -f "$canon_tmp" "$variant_tmp"' EXIT

log "Auditing ${#md_files[@]} summary(s)"
log "Glossary: $NAMES_FILE | Variants: $VARIANTS_FILE (plus each session group's files)"

total_canonical_hits=0
total_variant_hits=0

for f in "${md_files[@]}"; do
  base=$(basename "$f")
  log ""
  log "  $base"

  # Each summary is checked against its session's glossary: shared + group.
  stem="${base%%--*}"
  session_names "$stem" > "$canon_tmp"
  {
    variant_lefts "$(group_file "$VARIANTS_FILE" "$(session_group "$stem")")"
    variant_lefts "$VARIANTS_FILE"
  } > "$variant_tmp"

  # Tally per file via perl: word-boundary, case-insensitive counts.
  CANON_FILE="$canon_tmp" VARIANT_FILE="$variant_tmp" SUMMARY_FILE="$f" perl -e '
    use strict; use warnings;
    sub load { my @r; open my $fh, "<", $_[0] or return @r; while (<$fh>) { chomp; s/^\s+|\s+$//g; push @r, $_ if length } close $fh; @r }
    my @canon   = load($ENV{CANON_FILE});
    my @variant = load($ENV{VARIANT_FILE});
    open my $sfh, "<", $ENV{SUMMARY_FILE} or die $!;
    my $text = do { local $/; <$sfh> };
    close $sfh;

    my $canon_total = 0;
    my @canon_hits;
    for my $name (@canon) {
      my $q = quotemeta($name);
      my $count = () = $text =~ /\b$q\b/gi;
      $canon_total += $count;
      push @canon_hits, [$name, $count] if $count;
    }

    my $var_total = 0;
    my @var_hits;
    for my $v (@variant) {
      my $cs = ($v =~ s/^!//);
      my $q = quotemeta($v);
      my $count = $cs ? (() = $text =~ /\b$q\b/g) : (() = $text =~ /\b$q\b/gi);
      $var_total += $count;
      push @var_hits, [$v, $count] if $count;
    }

    if (@canon_hits) {
      print "    canonical: ", join(", ", map { "$_->[0]($_->[1])" } sort { $b->[1] <=> $a->[1] } @canon_hits), "\n";
    } else {
      print "    canonical: (none found)\n";
    }
    if (@var_hits) {
      print "    LEAKED VARIANTS: ", join(", ", map { "$_->[0]($_->[1])" } sort { $b->[1] <=> $a->[1] } @var_hits), "\n";
    }
    print "    totals: canonical=$canon_total leaked=$var_total\n";
  '
done

log ""
log "Done."
