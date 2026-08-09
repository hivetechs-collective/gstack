#!/usr/bin/env bash
# plan-w-team-reuse-audit-gate.sh  (H1 Reuse Audit gate — spec / review / ship)
#
# PHASES
#   --phase spec    (default) Step-1 freeze pre-condition. UNCHANGED behavior:
#                   refuse the freeze unless the spec carries a non-blank
#                   "Existing-Code Survey / Reuse Audit" section. Exits 0/1/2.
#   --phase review  Step-5 §5c-quinquies. Re-verifies the FROZEN verdicts
#                   against what was actually built, and routes findings to the
#                   existing consolidate-into-existing classifier. NEVER blocks.
#   --phase ship    Step-6 §6c-quinquies. Same check, advisory re-assertion for
#                   the ship status block. NEVER blocks.
#
# WHAT review/ship DETECT — an UNHONORED VERDICT: a REUSE/EXTEND row whose
# target's concept key collides with a NEWLY-ADDED definition in the run diff.
# In words: the spec froze "reuse X", and the run added its own X anyway.
#
# NOT detected, deliberately: "the diff never references the target". A REUSE
# verdict often means "this exists, so we are NOT building one", which leaves no
# diff trace at all — flagging it would punish the most virtuous outcome. Worse,
# a run's own spec is committed on its own branch and its audit table cites every
# target verbatim, so a reference-based rule is either permanently inert or mostly
# noise. The betrayal worth catching has a POSITIVE, diff-visible signature.
#
# EXEMPT: BUILD-NEW rows, and any verdict carrying a parenthetical qualifier such
# as "REUSE (pattern)" — reuse-of-shape leaves no diff trace by construction.
#
# EXIT CODES — review/ship reuse plan-w-team-claim-abstraction.sh's contract
# verbatim, so callers already know the semantics:
#   0   spec: gate passes / kill switch. review|ship: verified clean.
#   1   spec ONLY: audit section missing or blank (refuse freeze).
#   2   spec file not found, or a usage/validation error.
#   11  review|ship: findings (route via 04-fix-first-review.md §5d).
#   12  review|ship: COULD NOT VERIFY (no range, no normalizer). Never "clean".
# review/ship NEVER return 1 — they do not block a ship.
#
# Kill switch: PLAN_W_TEAM_DISABLE_REUSE_AUDIT=1 -> exit 0, all phases.
# Cap:         PWT_REUSE_RECHECK_MAX (default 3) findings, then a LOUD notice.
#
# Usage:
#   plan-w-team-reuse-audit-gate.sh --spec docs/specs/<slug>.md
#   plan-w-team-reuse-audit-gate.sh --slug <slug> --phase review --diff-base <ref>
#   plan-w-team-reuse-audit-gate.sh --slug <slug> --phase ship [--root <dir>]
#
# bash 3.2 compatible (no associative arrays, no mapfile).

set -u

PROG="plan-w-team-reuse-audit-gate"

# ── Kill switch (before arg parsing, so it also neutralises a skewed call) ────
if [ "${PLAN_W_TEAM_DISABLE_REUSE_AUDIT:-}" = "1" ]; then
  echo "[$PROG] PLAN_W_TEAM_DISABLE_REUSE_AUDIT=1 — reuse-audit gate disabled (exit 0)"
  exit 0
fi

# ── Arg parsing ──────────────────────────────────────────────────────────────
# The `--flag) V="${2:-}"; shift; [ $# -gt 0 ] && shift ;;` idiom is mandatory
# (argparse-shift2-lint.test.sh): a bare `shift 2` on a value-less trailing flag
# shifts nothing, returns non-zero, and spins forever under `set -u`.
SPEC=""
SLUG=""
PHASE="spec"
DIFF_BASE=""
ROOT_ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --spec)      SPEC="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
    --slug)      SLUG="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
    --phase)     PHASE="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
    --diff-base) DIFF_BASE="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
    --root)      ROOT_ARG="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
    # head -60, not -40: this header is longer than 40 lines, and the §5c/§6c
    # wrappers probe `--help` for `--phase` to detect a pre-upgrade script.
    # A truncated help would hide the flag and silently disable the new rungs
    # in every consumer repo — a false green, which is worse than a loud absence.
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -60; exit 0 ;;
    --*) echo "[$PROG] ✗ unknown option: $1" >&2; exit 2 ;;
    *) [ -z "$SPEC" ] && SPEC="$1"; shift ;;
  esac
done

# ── Phase validation — no silent fallback (mirrors grounding-gate) ───────────
case "$PHASE" in
  spec|review|ship) : ;;
  *) echo "[$PROG] ✗ --phase must be 'spec', 'review' or 'ship' (got: '$PHASE')" >&2; exit 2 ;;
esac

# ── Slug validation — it becomes a path component ────────────────────────────
# Bound 128, not the canonical 64: real pwt-goal slugs run to ~90 characters.
# The charset excludes `/` and `.`, so traversal is not expressible rather than
# filtered. Closes the pre-existing `--slug ../../x` read-path hole.
if [ -n "$SLUG" ]; then
  [ "${#SLUG}" -le 128 ] || { echo "[$PROG] ✗ --slug exceeds 128 characters" >&2; exit 2; }
  case "$SLUG" in
    *[!a-z0-9-]*) echo "[$PROG] ✗ --slug may contain only [a-z0-9-]" >&2; exit 2 ;;
    -*)           echo "[$PROG] ✗ --slug may not start with '-'" >&2; exit 2 ;;
  esac
fi

# ── Root + spec resolution ───────────────────────────────────────────────────
if [ -n "$ROOT_ARG" ]; then
  ROOT="$ROOT_ARG"
else
  ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
fi

if [ -z "$SPEC" ] && [ -n "$SLUG" ]; then
  SPEC="docs/specs/${SLUG}.md"
fi

if [ -z "$SPEC" ]; then
  echo "[$PROG] ✗ no --spec or --slug given" >&2
  exit 2
fi

if [ ! -f "$SPEC" ] && [ -n "$ROOT" ] && [ -f "$ROOT/$SPEC" ]; then
  SPEC="$ROOT/$SPEC"
fi

if [ ! -f "$SPEC" ]; then
  echo "[$PROG] ✗ spec file not found: $SPEC" >&2
  echo "[$PROG]   author the spec (Step 1) before the freeze gate runs." >&2
  exit 2
fi

# ── Section extraction ───────────────────────────────────────────────────────
# DEPTH-AWARE and FENCE-AWARE. The previous version treated ANY heading line as
# a boundary, so it truncated the body at the first nested `###` sub-heading and
# at heading-shaped lines inside fenced code blocks (open followups ledger row
# 11, deep-audit-2026-06-08). Under --phase spec that defect false-FAILS loudly;
# under review/ship, combined with per-row fail-open, it would false-PASS
# SILENTLY — one stray `### ` line would drop every row below it from checking
# while still exiting 0. Only a heading at the same or shallower level closes
# the section; a deeper heading is part of it.
extract_section() {
  awk '
    BEGIN { insec = 0; fence = 0; seclvl = 0 }
    {
      line = $0
      if (line ~ /^[ \t]*(```|~~~)/) { if (insec == 1) print; fence = 1 - fence; next }
      if (fence == 1) { if (insec == 1) print; next }
      if (line ~ /^#+[ \t]/) {
        lvl = 0
        while (substr(line, lvl + 1, 1) == "#") lvl++
        low = tolower(line)
        if (insec == 1) {
          if (lvl <= seclvl) { insec = 0 } else { print; next }
        }
        if (insec == 0 && (low ~ /reuse audit/ || low ~ /existing-code survey/)) {
          insec = 1; seclvl = lvl; next
        }
        if (insec == 0) next
      }
      if (insec == 1) print
    }
  ' "$1"
}

# Heading present at all? (Anchored to a real heading line, not a prose mention.)
has_section() {
  grep -qE '^#{1,6}[[:space:]].*([Rr]euse [Aa]udit|[Ee]xisting-[Cc]ode [Ss]urvey)' "$1"
}

BODY=$(extract_section "$SPEC")
BODY_STRIPPED=$(printf '%s' "$BODY" | tr -d '[:space:]')

# ─────────────────────────────────────────────────────────────────────────────
# PHASE: spec — the Step-1 freeze gate. Behavior UNCHANGED.
# ─────────────────────────────────────────────────────────────────────────────
if [ "$PHASE" = "spec" ]; then
  if ! has_section "$SPEC"; then
    echo "[$PROG] ✗ spec has no 'Existing-Code Survey / Reuse Audit' section: $SPEC" >&2
    echo "[$PROG]   add the mandatory Reuse Audit section (see 01-specification.md)." >&2
    exit 1
  fi
  if [ -z "$BODY_STRIPPED" ]; then
    echo "[$PROG] ✗ Reuse Audit section present but BLANK: $SPEC" >&2
    echo "[$PROG]   list REUSE/EXTEND/BUILD-NEW verdicts, or state 'surveyed, nothing overlaps'." >&2
    exit 1
  fi
  if printf '%s' "$BODY" | grep -qE 'REUSE|EXTEND|BUILD-NEW'; then
    echo "[$PROG] ✓ Reuse Audit present with verdict(s) — gate passes"
    exit 0
  fi
  if printf '%s' "$BODY" | grep -qiE 'nothing overlaps|no overlap|no overlapping'; then
    echo "[$PROG] ✓ Reuse Audit present with explicit 'nothing overlaps' statement — gate passes"
    exit 0
  fi
  echo "[$PROG] ✗ Reuse Audit section has neither a REUSE/EXTEND/BUILD-NEW verdict" >&2
  echo "[$PROG]   nor an explicit 'surveyed, nothing overlaps' statement: $SPEC" >&2
  exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# PHASE: review | ship — verdict re-verification. NEVER blocks (no exit 1).
# ─────────────────────────────────────────────────────────────────────────────

# Legacy grace: a spec predating the mandatory Reuse Audit (pre-1.38.0) has no
# section. Blocking would break every --ship-only/--resume run on a historical
# spec and hard-fail consumer repos that sync the gate ahead of their specs.
# Mirrors §5a-ter's pre-1.49.0 grace. The freeze gate above grants no such
# grace, so any spec frozen by a CURRENT run still has a section.
if ! has_section "$SPEC"; then
  echo "[$PROG] ⚠ no Reuse Audit section — likely pre-1.38.0 spec; skipping recheck (legacy grace)"
  exit 0
fi
if [ -z "$BODY_STRIPPED" ]; then
  echo "[$PROG] ⚠ Reuse Audit section is blank — nothing to re-verify (spec-phase gate owns this)"
  exit 0
fi

NORMALIZER="$(cd "$(dirname "$0")" && pwd)/plan-w-team-claim-abstraction.sh"
if [ ! -x "$NORMALIZER" ]; then
  echo "[$PROG] SKIP reason=no-normalizer ($NORMALIZER absent — partial sync?)"
  echo "[$PROG]   refusing to substitute a weaker matcher; unverified, not clean."
  exit 12
fi

# ── Diff range — same convention as the sibling detector ─────────────────────
GITDIR_OK=0
if [ -n "$ROOT" ] && git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then GITDIR_OK=1; fi
if [ "$GITDIR_OK" -eq 0 ]; then
  echo "[$PROG] SKIP reason=no-repo"
  exit 12
fi
if [ -z "$DIFF_BASE" ]; then
  for cand in origin/HEAD origin/main main master; do
    if git -C "$ROOT" rev-parse --verify --quiet "$cand" >/dev/null 2>&1; then
      DIFF_BASE=$(git -C "$ROOT" merge-base HEAD "$cand" 2>/dev/null || echo "")
      [ -n "$DIFF_BASE" ] && break
    fi
  done
fi
if [ -z "$DIFF_BASE" ]; then
  echo "[$PROG] SKIP reason=no-range (pass --diff-base <ref>)"
  exit 12
fi
HEAD_SHA=$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo "")
if [ -z "$HEAD_SHA" ] || [ "$DIFF_BASE" = "$HEAD_SHA" ]; then
  echo "[$PROG] SKIP reason=empty-range (base == HEAD)"
  exit 12
fi

# ── Newly-added definitions in the diff ──────────────────────────────────────
# Added lines only, EXCLUDING the run's own spec/docs/CHANGELOG: a spec is
# committed on its own branch and its audit table names every target, so
# including it makes the detector inert or noisy. Definition shapes cover the
# languages this corpus and its consumers actually use.
ADDED_DEFS=$(
  git -C "$ROOT" diff --unified=0 "$DIFF_BASE"..HEAD -- . \
      ':(exclude)docs/specs/*' ':(exclude)docs/operations/*' \
      ':(exclude)*CHANGELOG*' ':(exclude)*.bats' ':(exclude)*.test.sh' 2>/dev/null \
  | grep '^+' | grep -v '^+++' \
  | sed -E -n '
      s/.*(function|def|fn)[[:space:]]+([A-Za-z_][A-Za-z0-9_]*).*/\2/p
      s/.*(const|let|var)[[:space:]]+([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=[[:space:]]*(\(|async|function).*/\2/p
      s/.*(class|interface|type|struct|enum)[[:space:]]+([A-Za-z_][A-Za-z0-9_]*).*/\2/p
      s/^\+[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*\(\)[[:space:]]*\{.*/\1/p
    ' \
  | sort -u
)

ADDED_KEYS=""
if [ -n "$ADDED_DEFS" ]; then
  ADDED_KEYS=$(
    printf '%s\n' "$ADDED_DEFS" | while IFS= read -r sym; do
      [ -n "$sym" ] || continue
      k=$("$NORMALIZER" normalize --symbol "$sym" 2>/dev/null || true)
      [ -n "$k" ] && printf '%s\t%s\n' "$k" "$sym"
    done
  )
fi

# ── Walk the audit rows ──────────────────────────────────────────────────────
# A target token is CONFIDENT only if, after stripping backticks/parens and any
# :LINE suffix, it has no leading '/', no '~', no '..' segment, and resolves
# under `git ls-files`. Resolution is by git, never `[ -f ]`: that confines it
# to tracked repo content and removes the absolute-path/traversal existence
# oracle. Anything else is NOT CHECKABLE and is skipped — fail-open is the
# default here, not the exception, because the failure being defended against
# is a wrongly-flagged run across the sync fleet.
MAX="${PWT_REUSE_RECHECK_MAX:-3}"
FINDINGS=0
TRUNCATED=0
CHECKED=0
FINDING_LINES=""

OLDIFS="$IFS"
IFS='
'
for row in $(printf '%s\n' "$BODY" | grep -E '^\|'); do
  case "$row" in *---*) continue ;; esac
  # Verdict: REUSE/EXTEND without a parenthetical qualifier; BUILD-NEW exempt.
  case "$row" in
    *BUILD-NEW*) continue ;;
  esac
  VERDICT=""
  case "$row" in
    *REUSE*)  VERDICT="REUSE" ;;
  esac
  case "$row" in
    *EXTEND*) [ -z "$VERDICT" ] && VERDICT="EXTEND" ;;
  esac
  [ -n "$VERDICT" ] || continue
  # "REUSE (pattern)" / "REUSE (shape)" — reuse-of-shape leaves no diff trace.
  case "$row" in
    *"REUSE ("*|*"EXTEND ("*) continue ;;
  esac

  # Candidate tokens: backticked spans in the row.
  TOKENS=$(printf '%s' "$row" | tr '|' '\n' | grep -o '`[^`]*`' | tr -d '`' || true)
  [ -n "$TOKENS" ] || continue

  for tok in $TOKENS; do
    # Strip a trailing :LINE or :LINE-LINE suffix.
    cand=$(printf '%s' "$tok" | sed -E 's/:[0-9]+(-[0-9]+)?$//')
    case "$cand" in
      /*|~*)      continue ;;   # absolute / home — never resolved
      *..*)       continue ;;   # traversal — never resolved
      *[\ \	]*) continue ;;   # whitespace — not a path token
      *\**|*\?*|*\[*|*\$*|*\`*|*\;*|*\&*|*\(*|*\)*) continue ;;  # metacharacters
      *.*|*/*)    : ;;          # a path, or a bare filename with an extension
      *)          continue ;;   # bare word (env var, prose) — not checkable
    esac
    # Resolve through git, never `[ -f ]` — that keeps resolution inside tracked
    # repo content and makes traversal/absolute paths unreachable rather than
    # merely filtered. Audit rows cite bare filenames (`plan-w-team-foo.sh`) at
    # least as often as full paths, so fall back to a basename lookup — but only
    # when it is UNAMBIGUOUS. Two files sharing a basename means we cannot tell
    # which one the verdict meant, and guessing would manufacture a false finding.
    if ! git -C "$ROOT" ls-files --error-unmatch -- "$cand" >/dev/null 2>&1; then
      case "$cand" in
        */*) continue ;;
      esac
      MATCHES=$(git -C "$ROOT" ls-files -- "*/$cand" "$cand" 2>/dev/null | head -3)
      NMATCH=$(printf '%s' "$MATCHES" | grep -c . || true)
      [ "$NMATCH" = "1" ] || continue
      cand="$MATCHES"
    fi

    CHECKED=$((CHECKED + 1))
    stem=$(basename "$cand"); stem="${stem%%.*}"
    # basename stems are frequently non-identifier (dashes); normalize needs an
    # identifier charset, so translate separators to underscores first.
    ident=$(printf '%s' "$stem" | tr -c 'A-Za-z0-9' '_')
    case "$ident" in [!A-Za-z_]*) ident="_$ident" ;; esac
    tkey=$("$NORMALIZER" normalize --symbol "$ident" 2>/dev/null || true)
    [ -n "$tkey" ] || continue

    HIT=$(printf '%s\n' "$ADDED_KEYS" | awk -F'\t' -v k="$tkey" '$1 == k {print $2; exit}')
    if [ -n "$HIT" ]; then
      if [ "$FINDINGS" -lt "$MAX" ]; then
        FINDING_LINES="${FINDING_LINES}unhonored-verdict verdict=${VERDICT} target=${cand} key=${tkey} added_definition=${HIT}
"
      else
        TRUNCATED=$((TRUNCATED + 1))
      fi
      FINDINGS=$((FINDINGS + 1))
      break
    fi
  done
done
IFS="$OLDIFS"

if [ "$FINDINGS" -gt 0 ]; then
  echo "[$PROG] FINDINGS n=$FINDINGS base=$DIFF_BASE checked_targets=$CHECKED"
  printf '%s' "$FINDING_LINES" | sed "s/^/[$PROG]   /"
  if [ "$TRUNCATED" -gt 0 ]; then
    echo "[$PROG] ⚠ TRUNCATED: $TRUNCATED further finding(s) suppressed by PWT_REUSE_RECHECK_MAX=$MAX"
    echo "[$PROG]   raise the cap to see them all; the count above is complete."
  fi
  echo "[$PROG]   Route each via 04-fix-first-review.md §5d consolidate-into-existing."
  echo "[$PROG]   Deferring instead? queue it: plan-w-team-followups.sh add --slug <slug> --text '<self-contained brief>'"
  exit 11
fi

echo "[$PROG] CLEAN base=$DIFF_BASE checked_targets=$CHECKED added_defs=$(printf '%s' "$ADDED_DEFS" | grep -c . || true)"
exit 0
