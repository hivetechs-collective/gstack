#!/usr/bin/env bash
# secret-doc-sync.sh
#
# Regenerates the Pattern Catalog table in
# .claude/commands/plan-w-team/shared/secret-safety.md from the authoritative
# PATTERNS=() array in .claude/scripts/secret-scan.sh.
#
# Modes:
#   (default) — rewrite the section between the auto-gen markers and exit 0.
#   --check   — compare current doc against what would be generated.
#               Exit 0 if in sync, exit 1 if drift detected (prints diff).
#
# Exit codes:
#   0 — sync (or in-check, no drift)
#   1 — --check detected drift
#   2 — parse error (PATTERNS array malformed or empty)
#   3 — required file missing (scanner or doc)
#   4 — auto-gen markers missing in doc
#
# Idempotent. Safe to run repeatedly. The pre-commit hook calls --check
# whenever secret-scan.sh is staged so the doc cannot drift silently.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCANNER="$REPO_ROOT/.claude/scripts/secret-scan.sh"
DOC="$REPO_ROOT/.claude/commands/plan-w-team/shared/secret-safety.md"
BEGIN_MARKER='<!-- BEGIN AUTO-GENERATED: secret-patterns -->'
END_MARKER='<!-- END AUTO-GENERATED: secret-patterns -->'

CHECK_MODE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --check) CHECK_MODE=1; shift ;;
    -h|--help)
      grep '^#' "$0" | head -25
      exit 0
      ;;
    *) echo "Unknown arg: $1" >&2; exit 3 ;;
  esac
done

[ -f "$SCANNER" ] || { echo "✗ scanner not found: $SCANNER" >&2; exit 3; }
[ -f "$DOC" ]     || { echo "✗ doc not found: $DOC" >&2; exit 3; }

grep -qF "$BEGIN_MARKER" "$DOC" || { echo "✗ missing BEGIN marker in $DOC" >&2; exit 4; }
grep -qF "$END_MARKER"   "$DOC" || { echo "✗ missing END marker in $DOC" >&2; exit 4; }

# Extract PATTERNS=( ... ) block. Each meaningful line is 'name|regex|remediation'.
# We tolerate leading whitespace and trailing comments inside the array.
PATTERNS_RAW=$(awk '
  /^PATTERNS=\(/ { inarr=1; next }
  inarr && /^\)/ { inarr=0; exit }
  inarr { print }
' "$SCANNER")

[ -n "$PATTERNS_RAW" ] || { echo "✗ PATTERNS=() array empty or unparseable in $SCANNER" >&2; exit 2; }

# Strip surrounding single quotes and skip blank/comment lines, emit name|regex|remediation.
PARSED=$(printf '%s\n' "$PATTERNS_RAW" | awk '
  {
    # Trim whitespace
    sub(/^[[:space:]]+/, "")
    sub(/[[:space:]]+$/, "")
  }
  /^$/   { next }
  /^#/   { next }
  /^'\''.*'\''$/ {
    # Strip leading and trailing single quote
    sub(/^'\''/, "")
    sub(/'\''$/, "")
    print
  }
')

[ -n "$PARSED" ] || { echo "✗ no parseable pattern entries found" >&2; exit 2; }

# Validate every parsed line has exactly 3 pipe-separated fields.
# (Regex itself may contain `|` inside character classes; PATTERNS in this
# scanner uses only outer `|` as the delimiter, so a strict 3-field check is
# correct. If a future regex needs a literal `|`, escape it as `\|` and update
# this validator.)
while IFS= read -r line; do
  [ -z "$line" ] && continue
  field_count=$(awk -F'|' '{print NF}' <<<"$line")
  if [ "$field_count" -ne 3 ]; then
    echo "✗ malformed pattern entry (expected 3 |-fields, got $field_count): $line" >&2
    exit 2
  fi
done <<<"$PARSED"

# Compute longest column widths for table alignment (matches existing doc style).
NAME_W=4   # min: "Name"
PAT_W=15   # min: "Pattern (shape)"
REM_W=11   # min: "Remediation"

while IFS='|' read -r name pat rem; do
  [ -z "$name" ] && continue
  # Wrap with backticks for length calc (markdown uses these)
  nl=$(( ${#name} + 2 ))
  pl=$(( ${#pat}  + 2 ))
  rl=${#rem}
  [ "$nl" -gt "$NAME_W" ] && NAME_W=$nl
  [ "$pl" -gt "$PAT_W"  ] && PAT_W=$pl
  [ "$rl" -gt "$REM_W"  ] && REM_W=$rl
done <<<"$PARSED"

# Build the new auto-gen block. Use printf %-*s for left-aligned padding.
TABLE=$(
  printf '| %-*s | %-*s | %-*s |\n' "$NAME_W" "Name" "$PAT_W" "Pattern (shape)" "$REM_W" "Remediation"
  # Separator: dashes match column width
  sep_name=$(printf '%*s' "$NAME_W" '' | tr ' ' '-')
  sep_pat=$(printf  '%*s' "$PAT_W"  '' | tr ' ' '-')
  sep_rem=$(printf  '%*s' "$REM_W"  '' | tr ' ' '-')
  printf '| %s | %s | %s |\n' "$sep_name" "$sep_pat" "$sep_rem"
  while IFS='|' read -r name pat rem; do
    [ -z "$name" ] && continue
    printf '| %-*s | %-*s | %-*s |\n' \
      "$NAME_W" "\`$name\`" \
      "$PAT_W"  "\`$pat\`" \
      "$REM_W"  "$rem"
  done <<<"$PARSED"
)

# Splice into the doc: preserve everything before BEGIN and after END.
# BSD awk does not accept multi-line -v values, so use line-number splicing.
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

BEGIN_LINE=$(grep -nF "$BEGIN_MARKER" "$DOC" | head -1 | cut -d: -f1)
END_LINE=$(grep -nF "$END_MARKER"   "$DOC" | head -1 | cut -d: -f1)

if [ -z "$BEGIN_LINE" ] || [ -z "$END_LINE" ] || [ "$BEGIN_LINE" -ge "$END_LINE" ]; then
  echo "✗ markers missing or in wrong order in $DOC (begin=$BEGIN_LINE, end=$END_LINE)" >&2
  exit 4
fi

# Head: everything up to and including the BEGIN marker line.
# Body: the new auto-gen block (no markers — we already kept the BEGIN line and will append END).
# Tail: everything from the END marker line onward.
{
  head -n "$BEGIN_LINE" "$DOC"
  printf '\n%s\n\n' "$TABLE"
  tail -n +"$END_LINE" "$DOC"
} > "$TMP"

# Sanity: the awk pass above MUST yield a file containing both markers exactly
# once each; otherwise the splice was malformed (e.g. duplicate marker in input).
b=$(grep -cF "$BEGIN_MARKER" "$TMP" || true)
e=$(grep -cF "$END_MARKER"   "$TMP" || true)
if [ "$b" != "1" ] || [ "$e" != "1" ]; then
  echo "✗ post-splice marker count wrong (begin=$b, end=$e); refusing to write" >&2
  exit 4
fi

if [ "$CHECK_MODE" = "1" ]; then
  if ! diff -q "$DOC" "$TMP" >/dev/null 2>&1; then
    echo "✗ secret-safety.md is out of sync with secret-scan.sh PATTERNS array"
    echo "  run: .claude/scripts/secret-doc-sync.sh"
    echo ""
    echo "--- diff (current → expected) ---"
    diff -u "$DOC" "$TMP" || true
    exit 1
  fi
  exit 0
fi

# Write back. mv is atomic on the same filesystem.
mv "$TMP" "$DOC"
trap - EXIT

# Pattern count for confirmation
COUNT=$(printf '%s\n' "$PARSED" | grep -c '^[^[:space:]]')
echo "✓ secret-safety.md synced — $COUNT patterns"
