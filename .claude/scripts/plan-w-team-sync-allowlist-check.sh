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
ALLOW=$(grep -oE 'cp "\$SOURCE_DIR/scripts/[^"]+"' "$SYNC_SCRIPT" 2>/dev/null \
    | sed -E 's|cp "\$SOURCE_DIR/scripts/||; s|"$||' \
    | sort -u)

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
