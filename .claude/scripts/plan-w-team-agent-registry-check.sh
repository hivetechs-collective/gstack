#!/usr/bin/env bash
# plan-w-team-agent-registry-check.sh — ADVISORY agent-registry validity check.
#
# WHY THIS EXISTS (GAP-1, audit 2026-07-15):
# An agent definition whose YAML frontmatter does not parse is silently NOT
# registered by the harness — `Agent(subagent_type: "<name>")` fails at spawn
# time with "agent type not found", and nothing warns before that. The audit
# found 15 such agents, three of which the skill actively dispatches to:
#   - system-architect            (01-specification.md §1b-pre — a MANDATED fan-out reviewer)
#   - unit-testing-specialist     (04-fix-first-review.md — retroactive test coverage)
#   - react-typescript-specialist (plan-w-team.md §Model Strategy — the named Hands lane)
# The §1b-pre fan-out silently degraded from 3 reviewers to 2 during the very
# run that found this. Per Cherny's P2: fixing this per-occurrence in the agent
# loop burns tokens and misses cases; a rule that fires closes the class forever.
#
# The dominant root cause is a plain-scalar `description:` whose text ends in a
# colon (e.g. "... Examples:"). In YAML a trailing colon is a mapping indicator,
# so the document fails to parse. The fix is a block scalar (`description: |`).
#
# ADVISORY BY DESIGN — never blocks (design principles #3/#8; audit brief
# forbids new hard gates). Always exits 0 unless --strict is passed explicitly
# by an operator. A few agents with invalid frontmatter ARE currently tolerated
# by the harness's more lenient parser; this reports them as AT-RISK rather than
# failing, because that tolerance is undocumented and must not be relied on.
#
# Usage:
#   plan-w-team-agent-registry-check.sh [--json] [--strict] [--agents-dir DIR]
#
# Exit codes: 0 always (advisory), or 1 with --strict when invalid agents found.
#             2 on usage error.
#
# bash 3.2 compatible (mac-mini /bin/bash) — no associative arrays, no ^^/,,.
# Registered in shared/state-artifacts.md: N/A — writes no state (read-only).

set -u

AGENTS_DIR=""
JSON=0
STRICT=0

while [ $# -gt 0 ]; do
    case "$1" in
        --json)       JSON=1 ;;
        --strict)     STRICT=1 ;;
        --agents-dir) shift; AGENTS_DIR="${1:-}" ;;
        -h|--help)
            sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *)
            echo "usage: $0 [--json] [--strict] [--agents-dir DIR]" >&2
            exit 2 ;;
    esac
    shift
done

if [ -z "$AGENTS_DIR" ]; then
    PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
    AGENTS_DIR="$PROJECT_ROOT/.claude/agents"
fi

if [ ! -d "$AGENTS_DIR" ]; then
    # Fail-open: a repo with no agents dir is not an error for an advisory check.
    [ "$JSON" = "1" ] && echo '{"checked":0,"invalid":0,"agents":[]}'
    exit 0
fi

# __pwt_frontmatter_invalid <file>
# Echoes a reason string when the frontmatter cannot parse, empty when it can.
# Detection is deliberately conservative: it reports only shapes we have
# CONFIRMED break registration, so it cannot cry wolf on exotic-but-valid YAML.
__pwt_frontmatter_invalid() {
    fm_file="$1"

    # Extract the frontmatter block (between the first two --- fences).
    fm=$(awk 'NR==1 && $0!="---"{exit} NR==1{next} /^---[[:space:]]*$/{exit} {print}' "$fm_file")
    [ -n "$fm" ] || { echo ""; return 0; }

    # A `key: value` line whose value is a PLAIN scalar ending in ':' is a YAML
    # mapping indicator -> parse error. Block scalars (| or >) are exempt: their
    # body is literal text and may legally contain or end with a colon.
    bad=$(printf '%s\n' "$fm" | awk '
        /^[A-Za-z_][A-Za-z0-9_-]*:[[:space:]]*[|>]/ { next }   # block scalar opener: safe
        /^[A-Za-z_][A-Za-z0-9_-]*:[[:space:]]+.*:[[:space:]]*$/ {
            split($0, p, ":"); print p[1]; exit
        }')
    if [ -n "$bad" ]; then
        echo "plain-scalar '${bad}:' ends in a colon (YAML mapping indicator) — use a block scalar: '${bad}: |'"
        return 0
    fi

    echo ""
}

CHECKED=0
INVALID=0
JSON_ROWS=""
PLAIN_ROWS=""

# `find | while` would subshell the counters away in bash 3.2 — use a temp list.
TMP_LIST="${TMPDIR:-/tmp}/pwt-agent-registry-$$.list"
find "$AGENTS_DIR" -name "*.md" -type f 2>/dev/null | LC_ALL=C sort > "$TMP_LIST"

while IFS= read -r f; do
    [ -n "$f" ] || continue
    name=$(awk '/^---$/{c++; next} c==1 && /^name:/{sub(/^name:[[:space:]]*/,""); print; exit}' "$f")
    [ -n "$name" ] || continue          # not an agent definition (no name:)
    CHECKED=$((CHECKED + 1))
    reason=$(__pwt_frontmatter_invalid "$f")
    if [ -n "$reason" ]; then
        INVALID=$((INVALID + 1))
        rel="${f#"$AGENTS_DIR"/}"
        PLAIN_ROWS="${PLAIN_ROWS}  ✗ ${name}
      ${rel}
      ${reason}
"
        esc_reason=$(printf '%s' "$reason" | sed 's/"/\\"/g')
        JSON_ROWS="${JSON_ROWS}{\"name\":\"${name}\",\"path\":\"${rel}\",\"reason\":\"${esc_reason}\"},"
    fi
done < "$TMP_LIST"
rm -f "$TMP_LIST"

JSON_ROWS="${JSON_ROWS%,}"

if [ "$JSON" = "1" ]; then
    printf '{"checked":%s,"invalid":%s,"agents":[%s]}\n' "$CHECKED" "$INVALID" "$JSON_ROWS"
else
    if [ "$INVALID" -eq 0 ]; then
        echo "[plan-w-team-agent-registry-check] ✓ ${CHECKED} agent definition(s) checked — all frontmatter parses"
    else
        echo "[plan-w-team-agent-registry-check] ⚠ ${INVALID} of ${CHECKED} agent definition(s) have frontmatter that will NOT register:"
        printf '%s' "$PLAIN_ROWS"
        echo "  → These agents cannot be spawned via Agent(subagent_type: ...). The failure is silent"
        echo "    until spawn time. Fix: convert the reported plain scalar to a block scalar."
        echo "  → Advisory only; this check never blocks a run."
    fi
fi

if [ "$STRICT" = "1" ] && [ "$INVALID" -gt 0 ]; then
    exit 1
fi
exit 0
