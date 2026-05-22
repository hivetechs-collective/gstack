#!/usr/bin/env bash
# uplift.sh — Claude Code Version Uplift orchestrator.
#
# Runs: detect-version.sh -> fetch-changelog.sh -> evaluate-features.sh
# and writes a dated report into docs/operations/version-uplift-reports/.
#
# This is the entry point invoked by the /plan-w-team:version-uplift skill.
#
# Flags:
#   --force                  Run even if version unchanged.
#   --dry-run                Do not write state or report; emit to stdout only.
#   --since=VERSION          Override "previous" version detection.
#   --to=VERSION             Override "current" version detection.
#   --changelog-file=PATH    Use a local changelog file instead of mirror/fixture.
#   --allow-fixture          Allow fall-through to bundled test fixture.
#   --report-dir=PATH        Override report output directory.
#   --quiet                  Suppress informational output.
#
# Exit codes:
#   0  success (report generated OR no-op no-change)
#   2  dependency missing
#   3  malformed flag
#   4  no changelog source available

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$REPO_ROOT"

SCRIPTS=".claude/scripts/version-uplift"
DETECT="$SCRIPTS/detect-version.sh"
FETCH="$SCRIPTS/fetch-changelog.sh"
EVAL="$SCRIPTS/evaluate-features.sh"
CATALOG="$SCRIPTS/integration-points.json"

FORCE=0
DRY_RUN=0
SINCE=""
TO=""
CHANGELOG_FILE=""
ALLOW_FIXTURE=0
REPORT_DIR="docs/operations/version-uplift-reports"
QUIET=0

for arg in "$@"; do
    case "$arg" in
        --force) FORCE=1 ;;
        --dry-run) DRY_RUN=1 ;;
        --since=*) SINCE="${arg#*=}" ;;
        --to=*) TO="${arg#*=}" ;;
        --changelog-file=*) CHANGELOG_FILE="${arg#*=}" ;;
        --allow-fixture) ALLOW_FIXTURE=1 ;;
        --report-dir=*) REPORT_DIR="${arg#*=}" ;;
        --quiet) QUIET=1 ;;
        --help|-h)
            sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "uplift.sh: unknown arg: $arg" >&2
            exit 3
            ;;
    esac
done

log() {
    [ "$QUIET" -eq 1 ] || printf '%s\n' "$*" >&2
}

# Dependency check.
for f in "$DETECT" "$FETCH" "$EVAL" "$CATALOG"; do
    if [ ! -f "$f" ]; then
        echo "uplift.sh: missing dependency: $f" >&2
        exit 2
    fi
done

# --- Step 1: detect ---
DETECT_ARGS=()
[ "$FORCE" -eq 1 ] && DETECT_ARGS+=(--force)
[ "$DRY_RUN" -eq 1 ] && DETECT_ARGS+=(--no-persist)
[ -n "$TO" ] && DETECT_ARGS+=(--mock-current="$TO")

DETECTION=$("$DETECT" "${DETECT_ARGS[@]}")
log "detect: $DETECTION"

PREVIOUS=$(printf '%s' "$DETECTION" | jq -r '.previous')
CURRENT=$(printf '%s' "$DETECTION" | jq -r '.current')
CHANGED=$(printf '%s' "$DETECTION" | jq -r '.changed')

# --since= override (also implies forced run — user is asserting the range).
if [ -n "$SINCE" ]; then
    PREVIOUS="$SINCE"
    CHANGED="true"
fi

if [ "$CHANGED" != "true" ]; then
    log "uplift: version unchanged ($CURRENT). Pass --force to regenerate."
    exit 0
fi

# --- Step 2: fetch changelog ---
TMPDIR=$(mktemp -d -t uplift-orch-XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

CHANGELOG_JSON="$TMPDIR/changelog.json"

FETCH_ARGS=(--to="$CURRENT" --output="$CHANGELOG_JSON")
[ "$PREVIOUS" != "null" ] && [ -n "$PREVIOUS" ] && FETCH_ARGS+=(--from="$PREVIOUS")
if [ -n "$CHANGELOG_FILE" ]; then
    FETCH_ARGS+=(--from-file="$CHANGELOG_FILE")
elif [ "$ALLOW_FIXTURE" -eq 1 ]; then
    FETCH_ARGS+=(--allow-fixture)
else
    # No explicit source — let fetch-changelog.sh check the mirror first,
    # then fall back to curl. The mirror path is still preferred when set;
    # curl is the zero-LLM bash-only default for session-start automation.
    MIRROR="${CLAUDE_PATTERN_CHANGELOG_MIRROR:-.claude/state/claude-code-changelog-mirror.md}"
    if [ ! -f "$MIRROR" ]; then
        FETCH_ARGS+=(--curl)
    fi
fi

rc=0
"$FETCH" "${FETCH_ARGS[@]}" || rc=$?
if [ "$rc" -ne 0 ]; then
    if [ "$rc" -eq 2 ]; then
        log "uplift: no changelog source available."
        log "  Hints:"
        log "    - pass --changelog-file=PATH to use a local changelog file"
        log "    - pass --allow-fixture to use the bundled test fixture"
        log "    - or set \$CLAUDE_PATTERN_CHANGELOG_MIRROR to a mirror path"
        log "    - curl fetch was attempted (auto when no mirror) and failed"
        exit 4
    fi
    exit "$rc"
fi

# --- Step 3: evaluate ---
TODAY=$(date -u +%Y-%m-%d)
REPORT_BASE="${TODAY}-${CURRENT}"

if [ "$DRY_RUN" -eq 1 ]; then
    "$EVAL" --changelog="$CHANGELOG_JSON" \
        --catalog="$CATALOG" \
        --repo-root="$REPO_ROOT"
    log "uplift: dry-run complete (no files written)."
    exit 0
fi

mkdir -p "$REPORT_DIR"
REPORT_MD="$REPORT_DIR/${REPORT_BASE}.md"
REPORT_JSON="$REPORT_DIR/${REPORT_BASE}.json"

"$EVAL" --changelog="$CHANGELOG_JSON" \
    --catalog="$CATALOG" \
    --repo-root="$REPO_ROOT" \
    --output-md="$REPORT_MD" \
    --output-json="$REPORT_JSON"

log "uplift: wrote $REPORT_MD"
log "uplift: wrote $REPORT_JSON"
log ""
log "uplift: summary"
jq -r '.summary | to_entries[] | "  \(.key): \(.value)"' "$REPORT_JSON" >&2

printf '%s\n' "$REPORT_MD"
