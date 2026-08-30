#!/usr/bin/env bash
# pwt-coordination-hints.sh — Governor Contract phase 3 (C7): governed coordination hints.
#
# GOVERNED-ONLY. From ONE testable chokepoint it does all three C7 surfaces, with the dual-path
# resolution deliberately PINNED (the run straddles a worktree and the main checkout):
#   1. SCOPE-LOCK (RUN-LOCAL): annotate each matching .tasks[] object with predicted_paths (jq
#      rewrite; PRESERVES id/subject/scope/door_type — the only fields the Step-5/6 drift reader
#      touches — so the annotation is inert to drift detection).
#   2. MANIFEST (CANONICAL-MAIN): record coordination_hints via pwt-manifest.sh set (git-common-dir).
#   3. SINK: emit EXACTLY ONE {event:"coordination-hint", task_id, predicted_paths} per task through
#      pwt_governor_emit_event (the governor's event_sink).
#
# Hints are ADVISORY Step-2 PREDICTIONS (a ship-time refresh from the actual diff is a deferred item).
# UNGOVERNED ⇒ NO-OP (exit 0): the scope-lock heredoc is untouched (byte-identical), no manifest
# field, no sink line. Kill switch: PWT_DISABLE_COORDINATION_HINTS=1.
#
# Usage: pwt-coordination-hints.sh emit --slug <slug> --hints '<json-array>'
#   <json-array> = [{"task_id":"1","predicted_paths":["a","b"]}, ...] — the lead (02-task-breakdown)
#   assembles it from task files_touched metadata.
# Exit: 0 ALWAYS (fail-open observability; a coordination hint must never block the pipeline);
#       2 usage error only.

set -u

SLUG=""
HINTS=""
SUB="${1:-}"
[ -n "$SUB" ] && shift || true
while [ $# -gt 0 ]; do
    case "$1" in
        --slug)  SLUG="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
        --hints) HINTS="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
        -h|--help) SUB="help"; shift ;;
        *) shift ;;
    esac
done

case "$SUB" in
    emit) : ;;
    help|"") echo "usage: pwt-coordination-hints.sh emit --slug <slug> --hints '<json-array>'" >&2
             [ "$SUB" = "help" ] && exit 0 || exit 2 ;;
    *) echo "pwt-coordination-hints: unknown subcommand '$SUB'" >&2; exit 2 ;;
esac

[ "${PWT_DISABLE_COORDINATION_HINTS:-0}" = "1" ] && exit 0
[ -n "$SLUG" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

SELF_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"

# Governed-only: source the lib and bail out (no-op) when ungoverned.
if [ -r "$SELF_DIR/pwt-governor-lib.sh" ]; then
    # shellcheck disable=SC1090
    . "$SELF_DIR/pwt-governor-lib.sh" 2>/dev/null || true
fi
command -v pwt_governed >/dev/null 2>&1 || exit 0
pwt_governed || exit 0

# --hints must be a JSON array; a malformed value is a no-op (never a crash).
[ -n "$HINTS" ] || exit 0
printf '%s' "$HINTS" | jq -e 'type == "array"' >/dev/null 2>&1 || exit 0
# An EMPTY hints array is a full no-op: nothing to annotate, record, or emit. Skipping here keeps
# the scope-lock byte-identical (a jq rewrite would reformat it even with nothing to add).
printf '%s' "$HINTS" | jq -e 'length > 0' >/dev/null 2>&1 || exit 0

# ── run-local root (the worktree/CWD checkout, NOT the canonical main) ────────
if [ -n "${PWT_PROJECT_ROOT_OVERRIDE:-}" ]; then
    RUN_ROOT="${PWT_PROJECT_ROOT_OVERRIDE%/}"
else
    RUN_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")
fi
SCOPE_LOCK="$RUN_ROOT/.claude/state/plan-w-team-scope-lock-${SLUG}.json"

# ── (1) SCOPE-LOCK (run-local): add predicted_paths per matching task ────────
if [ -f "$SCOPE_LOCK" ] && jq -e . "$SCOPE_LOCK" >/dev/null 2>&1; then
    __cl_tmp="${SCOPE_LOCK}.tmp.$$"
    if jq --argjson hints "$HINTS" '
        .tasks = ((.tasks // []) | map(
            .id as $id
            | (($hints | map(select(.task_id == $id)) | .[0].predicted_paths) // null) as $pp
            | if $pp == null then . else . + {predicted_paths: $pp} end
        ))
    ' "$SCOPE_LOCK" > "$__cl_tmp" 2>/dev/null; then
        mv "$__cl_tmp" "$SCOPE_LOCK" 2>/dev/null || rm -f "$__cl_tmp" 2>/dev/null || true
    else
        rm -f "$__cl_tmp" 2>/dev/null || true
    fi
fi

# ── (2) MANIFEST (canonical-main): record coordination_hints ─────────────────
if [ -x "$SELF_DIR/pwt-manifest.sh" ]; then
    "$SELF_DIR/pwt-manifest.sh" set --slug "$SLUG" --coordination-hints "$HINTS" >/dev/null 2>&1 || true
fi

# ── (3) SINK: one coordination-hint event per task ───────────────────────────
if command -v pwt_governor_emit_event >/dev/null 2>&1; then
    __n=$(printf '%s' "$HINTS" | jq 'length' 2>/dev/null || echo 0)
    __i=0
    while [ "$__i" -lt "${__n:-0}" ]; do
        __detail=$(printf '%s' "$HINTS" | jq -c --argjson i "$__i" \
            '{event:"coordination-hint", task_id: .[$i].task_id, predicted_paths: (.[$i].predicted_paths // [])}' 2>/dev/null)
        [ -n "$__detail" ] && pwt_governor_emit_event "$SLUG" "$__detail" >/dev/null 2>&1 || true
        __i=$((__i + 1))
    done
fi

exit 0
