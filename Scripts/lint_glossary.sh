#!/usr/bin/env bash
#
# See README "Glossary linter".

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_lib.sh"

NAMES_FILE="${NAMES_FILE:-$SCRIPT_DIR/names.txt}"
VARIANTS_FILE="${VARIANTS_FILE:-$SCRIPT_DIR/name_variants.txt}"

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

log "Linting $NAMES_FILE"
if [[ ! -f "$NAMES_FILE" ]]; then
  issue "names file not found: $NAMES_FILE"
else
  process_findings < <(awk -v file="$NAMES_FILE" '
    /^[[:space:]]*$/ { next }
    /^[[:space:]]*#/ { next }
    {
      raw = $0
      trimmed = raw
      sub(/^[[:space:]]+/, "", trimmed)
      sub(/[[:space:]]+$/, "", trimmed)
      if (raw != trimmed)
        print "WHITESPACE\t" file ":" NR ": leading/trailing whitespace around \"" trimmed "\""
      if (trimmed in seen)
        print "DUP\t" file ":" NR ": duplicate name \"" trimmed "\" (also at line " seen[trimmed] ")"
      else
        seen[trimmed] = NR
    }
  ' "$NAMES_FILE")
fi

log "Linting $VARIANTS_FILE"
if [[ ! -f "$VARIANTS_FILE" ]]; then
  warn "variants file not found: $VARIANTS_FILE (post-pass will be a no-op)"
else
  canonicals_tmp=$(mktemp)
  trap 'command rm -f "$canonicals_tmp"' EXIT
  read_names "$NAMES_FILE" > "$canonicals_tmp"

  process_findings < <(awk -v file="$VARIANTS_FILE" -v canon_file="$canonicals_tmp" '
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
        print "UNKNOWN\t" file ":" NR ": canonical \"" to "\" not in names.txt (first word \"" first "\" missing)"
    }
  ' "$VARIANTS_FILE")
fi

log "Done. errors=$errors warnings=$warnings"
exit $(( errors > 0 ? 1 : 0 ))
