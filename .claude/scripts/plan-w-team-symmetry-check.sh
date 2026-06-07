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
# Test hook (A4): PWT_SYMMETRY_SCOPE overrides the code scope with a colon-separated
# list of paths. Used by plan-w-team-symmetry-check-phantom.test.sh to drive the
# phantom-reader detection against crafted fixtures. Unset in production.
if [ -n "${PWT_SYMMETRY_SCOPE:-}" ]; then
  IFS=':' read -r -a SCOPE <<< "$PWT_SYMMETRY_SCOPE"
fi
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

  # A4 anti-phantom (1.33.0): the reader matched SOMEWHERE — but a `handoff`/`enforcing`
  # artifact whose only "reader" is a BARE-FILENAME MENTION inside the WRITER's own
  # MARKDOWN stage file is a phantom reader (prose describing the artifact, not a real
  # consumer). This is exactly how the post-ship→retro §8d handoff false-passed green for
  # months: `06-post-ship.md` prose said "retro §8d consumes plan-w-team-postship-….json"
  # while no §8d reader existed. We flag it ONLY when ALL of:
  #   (a) mode is enforcing/handoff;
  #   (b) writer_grep ≠ reader_grep — an identical pattern is a same-symbol artifact
  #       referenced by one variable across stages (legit), not a phantom;
  #   (c) reader_grep is a BARE filename pattern (contains no `=`) — the weakest possible
  #       proof of a reader. A real reader assigns it to a variable (`VAR="…path"`) or
  #       reads it (`-f "$VAR"`), which contains `=`; those are exempt;
  #   (d) every reader-matching file ALSO matches writer_grep AND is markdown (.md).
  #   (e) reader_grep is a SELF-MENTION of this artifact's own path — i.e. the
  #       de-escaped reader_grep is a substring of the `pattern` (artifact path)
  #       column. The postship phantom's reader_grep (`plan-w-team-postship-\$SLUG\.json`)
  #       IS the artifact's own filename, so a bare mention of it proves nothing.
  #       An arbitrary DISTINCT reader token (e.g. a real cross-stage symbol that is
  #       not the artifact's own name) is a genuine reader even when colocated with
  #       the writer, so it is exempt — this keeps the existing reader/writer
  #       symmetry fixtures green (brief A4: "must keep existing checks green").
  # Code-file (.sh) readers and `VAR=`-style readers are unaffected → existing checks stay
  # green (verified: this flags ONLY the postship phantom on the pre-1.33.0 tree). (brief A4)
  case "$reader_grep" in *=*) reader_is_bare=false ;; *) reader_is_bare=true ;; esac
  # (e) self-mention test: strip ERE escapes from reader_grep, then require it to be
  # a substring of the artifact path. bash 3.2 substring via case glob.
  reader_unesc=$(printf '%s' "$reader_grep" | sed 's/\\//g')
  reader_is_self_mention=false
  if [ -n "$reader_unesc" ]; then
    case "$pattern" in *"$reader_unesc"*) reader_is_self_mention=true ;; esac
  fi
  if { [ "$mode" = "enforcing" ] || [ "$mode" = "handoff" ]; } \
     && [ "$writer_grep" != "$reader_grep" ] && $reader_is_bare && $reader_is_self_mention; then
    reader_files=$(rg -l "${EXCLUDES[@]}" -- "$reader_grep" "${SCOPE[@]}" 2>/dev/null | sort -u || true)
    writer_files=$(rg -l "${EXCLUDES[@]}" -- "$writer_grep" "${SCOPE[@]}" 2>/dev/null | sort -u || true)
    non_writer_readers=$(comm -23 <(printf '%s\n' "$reader_files" | sed '/^$/d') \
                                  <(printf '%s\n' "$writer_files" | sed '/^$/d') 2>/dev/null || true)
    if [ -z "$non_writer_readers" ] && [ -n "$reader_files" ]; then
      all_md=true
      while IFS= read -r rf; do
        [ -n "$rf" ] || continue
        case "$rf" in *.md) ;; *) all_md=false ;; esac
      done <<RF
$reader_files
RF
      if $all_md; then
        orphans+=("$pattern [mode=$mode] (phantom reader: reader_grep matches ONLY the writer's own markdown — no real consumer)")
        continue
      fi
    fi
  fi

  ok_count=$((ok_count + 1))
done < <(grep -E '^\| `\.claude/state/' "$REGISTRY")

# Pass 2 (R2-4): Bidirectional check — scan code for `.claude/state/plan-w-team-*`
# references and flag any path whose prefix has no registry entry. This catches
# the "orphan reader" defect class: a writer in stage A points at a file the
# registry never declared, so Pass 1 (registry → code) misses it entirely.
while IFS= read -r ref; do
  [ -z "$ref" ] && continue
  # round-2 audit P11: the old `[[ "$ref" == *- ]] && continue` made Pass-2 DEAD
  # CODE for EVERY `$SLUG`-keyed artifact — the rg capture stops at the
  # `${SLUG}`/`<…>` placeholder boundary, so every such reader ends in `-` and was
  # blanket-skipped (4 real handoff artifacts were unregistered yet uncatchable).
  # Fix: skip ONLY the bare common prefix (a genuine `*` prose wildcard), and for
  # a `$SLUG`-keyed ref (ending in `-`) require an EXACT match against a registered
  # stem — a prefix match would let `…-fleet-intent-` falsely satisfy the registered
  # `…-fleet-` stem and hide a distinct unregistered artifact.
  [ "$ref" = ".claude/state/plan-w-team-" ] && continue
  matched=0
  case "$ref" in
    *-)
      for p in "${registered_prefixes[@]+"${registered_prefixes[@]}"}"; do
        [ "$ref" = "$p" ] && { matched=1; break; }
      done
      ;;
    *)
      for p in "${registered_prefixes[@]+"${registered_prefixes[@]}"}"; do
        [[ "$ref" == "$p"* ]] && { matched=1; break; }
      done
      ;;
  esac
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
