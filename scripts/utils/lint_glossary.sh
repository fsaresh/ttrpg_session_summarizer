#!/usr/bin/env bash
#
# See README "Glossary linter".

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../_lib.sh"

NAMES_FILE="${NAMES_FILE:-$CONFIG_DIR/names.txt}"
VARIANTS_FILE="${VARIANTS_FILE:-$CONFIG_DIR/name_variants.txt}"

errors=0
warnings=0

issue() { logerr "  ERROR  $*"; errors=$((errors + 1)); }
warn()  { log    "  WARN   $*"; warnings=$((warnings + 1)); }

process_findings() {
  while IFS=$'\t' read -r kind msg; do
    [[ -z "$kind" ]] && continue
    case "$kind" in
      WHITESPACE)            warn  "$msg" ;;
      MALFORMED|DUP|UNKNOWN) issue "$msg" ;;
    esac
  done
}

canonicals_tmp=$(mktemp)
trap 'command rm -f "$canonicals_tmp"' EXIT

# Lint one names file for stray whitespace and duplicates.
#   lint_names "$file"
lint_names() {
  local file="$1"
  log "Linting $file"
  process_findings < <(awk -v file="$file" '
    /^[[:space:]]*$/ { next }
    /^[[:space:]]*#/ { next }
    {
      raw = $0
      trimmed = raw
      sub(/^[[:space:]]+/, "", trimmed)
      sub(/[[:space:]]+$/, "", trimmed)
      if (raw != trimmed)
        print "WHITESPACE\t" file ":" NR ": leading/trailing whitespace around \"" trimmed "\""
      sub(/^~[[:space:]]*/, "", trimmed)
      if (trimmed in seen)
        print "DUP\t" file ":" NR ": duplicate name \"" trimmed "\" (also at line " seen[trimmed] ")"
      else
        seen[trimmed] = NR
    }
  ' "$file")
}

# Lint one variants file; every canonical must appear in one of the given
# names files.
#   lint_variants "$variants_file" "$names_file"...
lint_variants() {
  local file="$1" names
  shift
  log "Linting $file"
  for names in "$@"; do
    read_names "$names"
  done > "$canonicals_tmp"

  process_findings < <(awk -v file="$file" -v canon_file="$canonicals_tmp" '
    function known(word,    s) {
      if (word in canonical) return 1
      # Tolerate simple plurals — e.g. "Wardens" matches canonical "Warden".
      if (length(word) > 1 && substr(word, length(word)) == "s") {
        s = substr(word, 1, length(word) - 1)
        if (s in canonical) return 1
        if (length(s) > 1 && substr(s, length(s)) == "e") {
          s = substr(s, 1, length(s) - 1)
          if (s in canonical) return 1
        }
      }
      return 0
    }
    BEGIN {
      while ((getline line < canon_file) > 0) {
        canonical[line] = 1
        n = split(line, parts, " ")
        if (n > 1) canonical[parts[1]] = 1
      }
      close(canon_file)
    }
    /^[[:space:]]*$/ { next }
    /^[[:space:]]*#/ { next }
    {
      raw = $0
      trimmed = raw
      sub(/^[[:space:]]+/, "", trimmed)
      sub(/[[:space:]]+$/, "", trimmed)
      if (raw != trimmed)
        print "WHITESPACE\t" file ":" NR ": leading/trailing whitespace"

      arrow_idx = match(trimmed, /[[:space:]]*->[[:space:]]*/)
      if (arrow_idx == 0) {
        print "MALFORMED\t" file ":" NR ": missing \"->\" separator: \"" trimmed "\""
        next
      }
      from = substr(trimmed, 1, arrow_idx - 1)
      to   = substr(trimmed, arrow_idx + RLENGTH)
      sub(/[[:space:]]+$/, "", from)
      sub(/^[[:space:]]+/, "", to)
      if (from == "")
        print "MALFORMED\t" file ":" NR ": empty variant (left side of \"->\")"
      if (to == "")
        print "MALFORMED\t" file ":" NR ": empty canonical (right side of \"->\")"

      from_clean = from
      if (substr(from_clean, 1, 1) == "!") from_clean = substr(from_clean, 2)

      key = from_clean ":" to
      if (key in seen_rule)
        print "DUP\t" file ":" NR ": duplicate rule \"" from " -> " to "\" (also at line " seen_rule[key] ")"
      else
        seen_rule[key] = NR

      n = split(to, to_parts, " ")
      first = to_parts[1]
      if (!known(first))
        print "UNKNOWN\t" file ":" NR ": canonical \"" to "\" not in the glossary (first word \"" first "\" missing)"
    }
  ' "$file")
}

if [[ ! -f "$NAMES_FILE" ]]; then
  issue "names file not found: $NAMES_FILE"
else
  lint_names "$NAMES_FILE"
fi

if [[ ! -f "$VARIANTS_FILE" ]]; then
  warn "variants file not found: $VARIANTS_FILE (post-pass will be a no-op)"
else
  lint_variants "$VARIANTS_FILE" "$NAMES_FILE"
fi

# Session-group files (see README "Session groups"). A group's variants may
# point at shared names or the group's own.
shopt -s nullglob
group_files=("$(dirname "$NAMES_FILE")/"*_"$(basename "$NAMES_FILE")"
             "$(dirname "$VARIANTS_FILE")/"*_"$(basename "$VARIANTS_FILE")")
shopt -u nullglob

groups=$(for f in ${group_files[@]+"${group_files[@]}"}; do
  b=$(basename "$f")
  b="${b%_"$(basename "$NAMES_FILE")"}"
  printf '%s\n' "${b%_"$(basename "$VARIANTS_FILE")"}"
done | sort -u)

for group in $groups; do
  group_names=$(group_file "$NAMES_FILE" "$group")
  group_variants=$(group_file "$VARIANTS_FILE" "$group")
  if [[ -f "$group_names" ]]; then
    lint_names "$group_names"
  fi
  if [[ -f "$group_variants" ]]; then
    lint_variants "$group_variants" "$NAMES_FILE" "$group_names"
  fi
done

log "Done. errors=$errors warnings=$warnings"
exit $(( errors > 0 ? 1 : 0 ))
