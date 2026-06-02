#!/usr/bin/env bash
# plan-w-team-symmetry-check.sh
#
# Verifies writer/reader symmetry for .claude/state/plan-w-team-* artifacts.
# Reads .claude/commands/plan-w-team/shared/state-artifacts.md as authoritative registry.
#
# Exit codes:
#   0 — all enforcing/handoff entries have both writer and reader
#   1 — enforcing/handoff orphan (registry entry has no reader match in code)
#   2 — stale registry entry (no writer match — artifact likely renamed/removed)
#   3 — environment failure (ripgrep missing, registry malformed or not found)
#   4 — orphan reader (code references .claude/state/plan-w-team-* with no registry entry)
#
# Usage:
#   plan-w-team-symmetry-check.sh
#   plan-w-team-symmetry-check.sh --json
#   plan-w-team-symmetry-check.sh --registry <path>

set -euo pipefail

REGISTRY=".claude/commands/plan-w-team/shared/state-artifacts.md"
JSON_OUTPUT=0

while [ $# -gt 0 ]; do
  case "$1" in
    --json) JSON_OUTPUT=1; shift ;;
    --registry) REGISTRY="$2"; shift 2 ;;
    -h|--help)
      grep '^#' "$0" | head -30
      exit 0
      ;;
    *) echo "Unknown arg: $1" >&2; exit 3 ;;
  esac
done

command -v rg >/dev/null 2>&1 || { echo "✗ ripgrep (rg) required" >&2; exit 3; }
[ -f "$REGISTRY" ] || { echo "✗ registry not found: $REGISTRY" >&2; exit 3; }

# Code scope: stage files + scripts + hooks. Explicitly exclude:
#   - the registry itself (self-reference, would false-match)
#   - docs/specs/ (specs describe artifacts in prose, not code)
#   - .claude/state/ (runtime artifacts, not source)
SCOPE=(
  ".claude/commands/plan-w-team.md"
  ".claude/commands/plan-w-team/"
  ".claude/scripts/"
  ".claude/hooks/"
)
EXCLUDES=(
  "--glob=!.claude/commands/plan-w-team/shared/state-artifacts.md"
  "--glob=!.claude/scripts/plan-w-team-symmetry-check.sh"
  "--glob=!docs/specs/**"
  "--glob=!.claude/state/**"
  # Test fixtures hard-code concrete-slug artifact paths (plan-w-team-manifest-feat-x.json,
  # …-wt-run.json, …-killed.json, …-b32.json) that are NOT production readers — counting
  # them as orphans kept the checker permanently RED, eroding the very signal P11 depends
  # on. Exclude the *.test.sh corpus from the orphan scan. (Audit P11.)
  "--glob=!**/*.test.sh"
)

orphans=()
stale=()
audit_trail_unreferenced=()
orphan_readers=()
registered_prefixes=()
ok_count=0
total=0

# Parse registry: lines starting with "| `" (artifact rows — header and separator don't match)
# Columns (pipe-separated, trimmed): pattern | writer_grep | reader_grep | mode | purpose
while IFS= read -r line; do
  # Split on " | " delimiter (table format). Strip leading/trailing pipes and spaces.
  row="${line#| }"
  row="${row% |}"

  # Use awk to split; backticks around fields are part of markdown formatting — strip them.
  pattern=$(awk -F ' *\\| *' '{print $1}' <<<"$row" | sed -E 's/^`//; s/`$//')
  writer_grep=$(awk -F ' *\\| *' '{print $2}' <<<"$row" | sed -E 's/^`//; s/`$//')
  reader_grep=$(awk -F ' *\\| *' '{print $3}' <<<"$row" | sed -E 's/^`//; s/`$//')
  mode=$(awk -F ' *\\| *' '{print $4}' <<<"$row" | sed -E 's/^`//; s/`$//; s/ +$//')

  # Skip the doc-example row (pattern column literally "pattern")
  [ "$pattern" = "pattern" ] && continue
  [ -z "$pattern" ] && continue

  total=$((total + 1))

  # Track the registered prefix (everything before the first placeholder) for the
  # orphan-reader pass below. Placeholders the registry uses: $SLUG, <category>.
  # This lets us match a concrete reader path against the registered template.
  prefix="${pattern%%\$SLUG*}"
  prefix="${prefix%%<*}"
  # If no placeholder, use the full pattern (literal global file).
  registered_prefixes+=("$prefix")

  # Writer check — every registered artifact must have a writer somewhere in code
  if ! rg --quiet "${EXCLUDES[@]}" -- "$writer_grep" "${SCOPE[@]}" 2>/dev/null; then
    stale+=("$pattern (writer_grep: $writer_grep)")
    continue
  fi

  # Reader check — dash means "no reader by design" (audit-trail only)
  if [ "$reader_grep" = "-" ]; then
    if [ "$mode" != "audit-trail" ]; then
      # Config error: only audit-trail may omit reader
      stale+=("$pattern (mode=$mode but reader_grep is '-'; only audit-trail allows this)")
      continue
    fi
    audit_trail_unreferenced+=("$pattern")
    ok_count=$((ok_count + 1))
    continue
  fi

  if ! rg --quiet "${EXCLUDES[@]}" -- "$reader_grep" "${SCOPE[@]}" 2>/dev/null; then
    case "$mode" in
      enforcing|handoff)
        orphans+=("$pattern [mode=$mode] (reader_grep: $reader_grep)")
        ;;
      audit-trail)
        audit_trail_unreferenced+=("$pattern (no reader; expected for audit-trail)")
        ok_count=$((ok_count + 1))
        ;;
      *)
        stale+=("$pattern (unknown mode: $mode)")
        ;;
    esac
    continue
  fi

  ok_count=$((ok_count + 1))
done < <(grep -E '^\| `\.claude/state/' "$REGISTRY")

# Pass 2 (R2-4): Bidirectional check — scan code for `.claude/state/plan-w-team-*`
# references and flag any path whose prefix has no registry entry. This catches
# the "orphan reader" defect class: a writer in stage A points at a file the
# registry never declared, so Pass 1 (registry → code) misses it entirely.
while IFS= read -r ref; do
  [ -z "$ref" ] && continue
  # Skip wildcard/glob mentions in prose: `.claude/state/plan-w-team-*` has rg
  # capture stop at the `*`, leaving a path that ends in a bare `-`. Real artifact
  # paths always have a meaningful suffix (slug, category, .json, .lock, etc).
  [[ "$ref" == *- ]] && continue
  matched=0
  for p in "${registered_prefixes[@]+"${registered_prefixes[@]}"}"; do
    [[ "$ref" == "$p"* ]] && { matched=1; break; }
  done
  [ "$matched" = "0" ] && orphan_readers+=("$ref")
done < <(rg --no-filename --only-matching "${EXCLUDES[@]}" -- '\.claude/state/plan-w-team-[a-zA-Z0-9_.-]*' "${SCOPE[@]}" 2>/dev/null | sort -u)

# Report
if [ "$JSON_OUTPUT" = "1" ]; then
  jq -n \
    --argjson total "$total" \
    --argjson ok "$ok_count" \
    --arg orphans "$(printf '%s\n' "${orphans[@]+"${orphans[@]}"}")" \
    --arg stale "$(printf '%s\n' "${stale[@]+"${stale[@]}"}")" \
    --arg audit "$(printf '%s\n' "${audit_trail_unreferenced[@]+"${audit_trail_unreferenced[@]}"}")" \
    --arg orphan_readers "$(printf '%s\n' "${orphan_readers[@]+"${orphan_readers[@]}"}")" \
    '{
      total: $total,
      ok: $ok,
      orphans: ($orphans | split("\n") | map(select(length > 0))),
      stale: ($stale | split("\n") | map(select(length > 0))),
      audit_trail_only: ($audit | split("\n") | map(select(length > 0))),
      orphan_readers: ($orphan_readers | split("\n") | map(select(length > 0)))
    }'
else
  echo "Writer↔Reader symmetry check"
  echo "  registry: $REGISTRY"
  echo "  entries:  $total"
  echo "  ok:       $ok_count"
  if [ "${#orphans[@]}" -gt 0 ]; then
    echo "  ✗ orphans (enforcing/handoff entries with no reader in code):"
    printf '      - %s\n' "${orphans[@]}"
  fi
  if [ "${#stale[@]}" -gt 0 ]; then
    echo "  ⚠ stale (registry entries with no writer in code):"
    printf '      - %s\n' "${stale[@]}"
  fi
  if [ "${#audit_trail_unreferenced[@]}" -gt 0 ]; then
    echo "  ℹ audit-trail (write-only by design):"
    printf '      - %s\n' "${audit_trail_unreferenced[@]}"
  fi
  if [ "${#orphan_readers[@]}" -gt 0 ]; then
    echo "  ✗ orphan readers (code references with no registry entry):"
    printf '      - %s\n' "${orphan_readers[@]}"
    echo "    → register each path in shared/state-artifacts.md OR remove the reader."
  fi
fi

# Exit precedence: stale (2) > orphan reader (4) > orphan (1) > pass (0).
# Stale means the registry is wrong, which undermines every other check.
# Orphan reader is more severe than orphan (registry → code) because it represents
# a writer pointing at a wholly undeclared file — no audit trail, no checker coverage.
if [ "${#stale[@]}" -gt 0 ]; then
  exit 2
fi
if [ "${#orphan_readers[@]}" -gt 0 ]; then
  exit 4
fi
if [ "${#orphans[@]}" -gt 0 ]; then
  exit 1
fi
exit 0
