#!/usr/bin/env bash
# auto-launch.sh — read the most recent version-uplift report and spawn a
# /plan-w-team worker to adopt each finding marked auto_integrate_safe=true.
#
# Wired from session-start.sh after detect-version.sh emits a pending-flag.
# Best-effort: never blocks session init; surfaces all errors as exit 0 + log.
#
# Kill switch:
#   Create .claude/state/version-uplift-no-auto-adopt.flag (any contents).
#   While present, this script always exits 0 without spawning.
#
# Flags:
#   --report=PATH     Use this report JSON instead of newest in --report-dir.
#   --report-dir=DIR  Directory to scan for *.json (default:
#                       docs/operations/version-uplift-reports).
#   --max-chars=N     Cap goal directive length (default: 3500). Matches the
#                       pwt-goal.sh PLAN_W_TEAM_GOAL_MAX preflight ceiling.
#   --dry-run         Emit the constructed directive on stdout; do not spawn.
#   --no-clear-flag   Do not delete the pending-flag on success (test mode).
#   --pending-flag=PATH  Override pending-flag path (default:
#                          .claude/state/version-uplift-pending.flag).
#   --kill-switch=PATH   Override kill-switch path (default:
#                          .claude/state/version-uplift-no-auto-adopt.flag).
#
# Exit codes:
#   0  no-op (no findings, kill switch present, no report, etc.) OR success
#   2  unrecoverable: bad report JSON, pwt-goal.sh missing
#   3  malformed flag

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

REPORT=""
REPORT_DIR="docs/operations/version-uplift-reports"
MAX_CHARS=3500
DRY_RUN=0
CLEAR_FLAG=1
PENDING_FLAG=".claude/state/version-uplift-pending.flag"
KILL_SWITCH=".claude/state/version-uplift-no-auto-adopt.flag"

for arg in "$@"; do
    case "$arg" in
        --report=*) REPORT="${arg#*=}" ;;
        --report-dir=*) REPORT_DIR="${arg#*=}" ;;
        --max-chars=*) MAX_CHARS="${arg#*=}" ;;
        --dry-run) DRY_RUN=1 ;;
        --no-clear-flag) CLEAR_FLAG=0 ;;
        --pending-flag=*) PENDING_FLAG="${arg#*=}" ;;
        --kill-switch=*) KILL_SWITCH="${arg#*=}" ;;
        --help|-h)
            sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "auto-launch.sh: unknown arg: $arg" >&2
            exit 3
            ;;
    esac
done

cd "$REPO_ROOT"

log() { printf 'auto-launch: %s\n' "$*" >&2; }

# --- kill switch ---
if [ -f "$KILL_SWITCH" ]; then
    log "kill switch present at $KILL_SWITCH — skipping"
    exit 0
fi

# --- locate report ---
if [ -z "$REPORT" ]; then
    if [ ! -d "$REPORT_DIR" ]; then
        log "no report dir at $REPORT_DIR — nothing to do"
        exit 0
    fi
    REPORT=$(ls -1t "$REPORT_DIR"/*.json 2>/dev/null | head -1 || true)
    if [ -z "$REPORT" ]; then
        log "no JSON reports found under $REPORT_DIR — nothing to do"
        exit 0
    fi
fi

if [ ! -f "$REPORT" ]; then
    log "report not found: $REPORT"
    exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
    log "jq required but not in PATH"
    exit 2
fi

# Validate report shape.
if ! jq -e '.findings | type == "array"' "$REPORT" >/dev/null 2>&1; then
    log "report JSON malformed (missing .findings array): $REPORT"
    exit 2
fi

# --- filter auto-safe findings ---
N_SAFE=$(jq '[.findings[] | select(.auto_integrate_safe==true)] | length' "$REPORT")
if [ "$N_SAFE" -eq 0 ]; then
    log "0 auto_integrate_safe findings in $REPORT — nothing to do"
    # Clear pending flag — there's nothing for a future session to act on.
    [ "$CLEAR_FLAG" -eq 1 ] && [ -f "$PENDING_FLAG" ] && rm -f "$PENDING_FLAG"
    exit 0
fi

log "$N_SAFE auto_integrate_safe finding(s) in $REPORT"

# --- build directive ---
# Header (fixed) + numbered list of findings. Truncate to MAX_CHARS — we only
# include as many findings as fit. The worker reads the full report itself if
# it needs the rest.
HEADER='Adopt the Claude Code version-uplift findings flagged as auto_integrate_safe in the most recent report at docs/operations/version-uplift-reports/. For each finding below, update the relevant config / hook / doc / agent surface to use the new feature, add a one-line note to CLAUDE.md (`Features Adopted` table), and commit with prefix `feat(version-uplift):`. Do not adopt findings outside this list. Findings:'

FOOTER=$'\n\nDone when: all listed findings adopted, tests pass, CLAUDE.md table updated, and `bash tests/version-uplift/version-uplift.test.sh` exits 0.'

# Stream findings into the directive, one at a time, stopping before MAX_CHARS.
TMPDIR=$(mktemp -d -t auto-launch-XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT
DIRECTIVE_FILE="$TMPDIR/directive.txt"
printf '%s' "$HEADER" > "$DIRECTIVE_FILE"

jq -r '
    .findings
    | map(select(.auto_integrate_safe==true))
    | to_entries[]
    | "\(.key + 1). [surface=\(.value.surface)] \(.value.entry)"
' "$REPORT" > "$TMPDIR/findings.txt"

while IFS= read -r line; do
    CUR_LEN=$(wc -c < "$DIRECTIVE_FILE" | tr -d ' ')
    PROSPECTIVE=$((CUR_LEN + ${#line} + ${#FOOTER} + 2))
    if [ "$PROSPECTIVE" -gt "$MAX_CHARS" ]; then
        printf '\n(... %d more — see report)' \
            "$(grep -c '^' "$TMPDIR/findings.txt")" >> "$DIRECTIVE_FILE"
        break
    fi
    printf '\n%s' "$line" >> "$DIRECTIVE_FILE"
done < "$TMPDIR/findings.txt"

printf '%s' "$FOOTER" >> "$DIRECTIVE_FILE"

FINAL_LEN=$(wc -c < "$DIRECTIVE_FILE" | tr -d ' ')
log "directive: $FINAL_LEN chars (cap $MAX_CHARS)"

if [ "$FINAL_LEN" -gt "$MAX_CHARS" ]; then
    log "directive exceeds cap — refusing to spawn"
    exit 0
fi

# --- dry-run: print and exit ---
if [ "$DRY_RUN" -eq 1 ]; then
    cat "$DIRECTIVE_FILE"
    exit 0
fi

# --- spawn worker via pwt-goal.sh --worker-only ---
PWT="$REPO_ROOT/.claude/scripts/pwt-goal.sh"
if [ ! -x "$PWT" ]; then
    log "pwt-goal.sh not executable at $PWT"
    exit 2
fi

# Pass directive via argv. Inherit env so PLAN_W_TEAM_FORCE_SPAWN / etc. flow.
DIRECTIVE=$(cat "$DIRECTIVE_FILE")
if "$PWT" --worker-only "$DIRECTIVE" >&2; then
    log "worker spawned"
    [ "$CLEAR_FLAG" -eq 1 ] && [ -f "$PENDING_FLAG" ] && rm -f "$PENDING_FLAG"
    exit 0
else
    rc=$?
    log "pwt-goal.sh --worker-only exited $rc — leaving pending flag in place"
    exit 0
fi
