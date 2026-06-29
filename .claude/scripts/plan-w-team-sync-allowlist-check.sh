#!/usr/bin/env bash
# plan-w-team-sync-allowlist-check.sh
#
# Fail-loud verifier that the /plan-w-team script family stays in sync with
# sync-to-project.sh's allowlist. Pre-commit guard against a recurring
# /plan-w-team failure mode: new scripts ship but never propagate to consumer
# repos because the sync allowlist is hand-curated and gets forgotten.
#
# Treats sync-to-project.sh's `cp "$SOURCE_DIR/scripts/<NAME>"` lines as the
# source of truth. Any plan-w-team-* or pwt-* script not matched there is a
# hard fail (exit 1) with the offenders listed on stderr.
#
# Soft-skip (exit 0) when not in the claude-pattern repo — consumer repos
# don't carry sync-to-project.sh and shouldn't fail on a check that doesn't
# apply.
#
# Usage:
#   .claude/scripts/plan-w-team-sync-allowlist-check.sh
#
# Exit codes:
#   0 — no drift, or soft-skip (not in claude-pattern repo)
#   1 — drift detected (offenders printed to stderr)

set -euo pipefail

# Resolve repo root — prefer git, fall back to script-relative
if REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null); then
    :
else
    REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
fi

SCRIPTS_DIR="$REPO_ROOT/.claude/scripts"
SYNC_SCRIPT="$SCRIPTS_DIR/sync-to-project.sh"

# Soft-skip if sync-to-project.sh is absent (consumer repo)
if [ ! -f "$SYNC_SCRIPT" ]; then
    echo "[sync-allowlist-check] not in claude-pattern repo (no sync-to-project.sh); skipping"
    exit 0
fi

# Discover candidate scripts (plan-w-team-* and pwt-* in .claude/scripts/)
# Exclude tests, markdown, and non-runtime files.
CANDIDATES=$(find "$SCRIPTS_DIR" -maxdepth 1 -type f \
    \( -name 'plan-w-team-*' -o -name 'pwt-*' \) \
    ! -name '*.test.sh' ! -name '*.test.ts' ! -name '*.md' \
    -print 2>/dev/null | sort)

if [ -z "$CANDIDATES" ]; then
    echo "[sync-allowlist-check] no plan-w-team-* or pwt-* candidate scripts found"
    exit 0
fi

# Build the allowlist from sync-to-project.sh.
# Matches: cp "$SOURCE_DIR/scripts/<NAME>"
#
# Bug-2 guard (silent-abort): under `set -euo pipefail`, a grep that finds NO
# match exits 1, and pipefail propagates that exit through the pipeline — which
# `set -e` then turns into a whole-script abort BEFORE the diagnostic block below
# can print. Wrapping grep in `{ …; || true; }` makes "no match" yield an empty
# ALLOW instead of killing the script, so real drift still prints its offenders.
ALLOW=$({ grep -oE 'cp "\$SOURCE_DIR/scripts/[^"]+"' "$SYNC_SCRIPT" 2>/dev/null || true; } \
    | sed -E 's|cp "\$SOURCE_DIR/scripts/||; s|"$||' \
    | sort -u)

# Bug-1 guard (consumer false-positive): CANDIDATES is guaranteed non-empty here
# (checked above). If ALLOW is empty, this sync-to-project.sh is NOT the canonical
# claude-pattern format — e.g. a consumer carrying an older / different-format copy
# with no `cp "$SOURCE_DIR/scripts/…"` lines. Inferring "sync-to-project.sh present
# ⟹ source repo" was wrong: it left ALLOW empty, flagged EVERY candidate as
# "missing", and hard-failed the consumer. Treat empty-ALLOW as "not the source
# repo / format mismatch" and soft-skip (exit 0) with a one-line warning instead.
if [ -z "$ALLOW" ]; then
    echo "[sync-allowlist-check] sync-to-project.sh present but carries no 'cp \"\$SOURCE_DIR/scripts/…\"' allowlist lines (consumer or older format); skipping" >&2
    exit 0
fi

# Compare
MISSING=()
while IFS= read -r path; do
    [ -z "$path" ] && continue
    name=$(basename "$path")
    # Tests for the new script live in the same dir; tests are also candidates
    # for sync but only when explicitly added. For symmetry-check purposes,
    # test files (.test.sh / .test.ts) are excluded above. Real runtime scripts:
    if ! echo "$ALLOW" | grep -qxF "$name"; then
        MISSING+=("$name")
    fi
done <<<"$CANDIDATES"

# C7: load-bearing gate dependencies that are NOT plan-w-team-*/pwt-*-prefixed,
# so the discovery glob above misses them. They are required for the capacity /
# spawn / secret gates to function in a consumer repo; a rename that dropped one
# from the allowlist would silently make those gates fail-open with no drift
# warning (audit C7). Pin them explicitly.
#
# `plan-w-team-render-artifact.sh` IS prefixed (so the glob above already
# requires its cp line) — it is pinned here too as belt-and-suspenders: the
# visual-artifacts substrate is a load-bearing dependency of the Hook-1
# completion-summary emission, and the pin keeps it required even if a future
# rename ever drops the prefix.
REQUIRED_NONPREFIXED="ram-budget.sh disk-budget.sh claude-agents-extended.sh locate-claude.sh secret-scan.sh access-control-content-scan.sh secret-doc-sync.sh supervisor-merge-gate.sh supervisor-progress-check.sh plan-w-team-render-artifact.sh"
for name in $REQUIRED_NONPREFIXED; do
    # Only require it if the source script actually exists (don't demand a dep a
    # given checkout legitimately doesn't ship).
    [ -f "$SCRIPTS_DIR/$name" ] || continue
    if ! echo "$ALLOW" | grep -qxF "$name"; then
        MISSING+=("$name (non-prefixed gate dependency — audit C7)")
    fi
done

if [ "${#MISSING[@]}" -gt 0 ]; then
    {
        echo ""
        echo "✗ Sync allowlist drift detected"
        echo ""
        echo "  The following plan-w-team-* / pwt-* scripts exist in .claude/scripts/"
        echo "  but are NOT in sync-to-project.sh's allowlist:"
        echo ""
        for f in "${MISSING[@]}"; do
            echo "    - $f"
        done
        echo ""
        echo "  Fix: add a 'cp \"\$SOURCE_DIR/scripts/<NAME>\" ...' line for each"
        echo "  offender in $SYNC_SCRIPT, in the appropriate section."
        echo ""
        echo "  Why this matters: scripts not in the allowlist do not propagate"
        echo "  to consumer repos via sync-to-project.sh — they silently never"
        echo "  reach users."
        echo ""
    } >&2
    exit 1
fi

CANDIDATE_COUNT=$(echo "$CANDIDATES" | grep -c . || echo 0)
echo "✓ Sync allowlist symmetry verified ($CANDIDATE_COUNT candidate scripts all present)"
exit 0
