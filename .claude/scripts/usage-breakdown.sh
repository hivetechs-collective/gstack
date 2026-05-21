#!/usr/bin/env bash
# usage-breakdown.sh
#
# Aggregates today's local Claude session transcripts (~/.claude/projects/**/*.jsonl)
# to produce a token-cost breakdown by Skill, Subagent (Agent tool), and MCP server.
# This mirrors what `/usage` shows interactively (Boris's screenshot pattern) but
# computes from local data — the /api/oauth/usage endpoint only returns 5h/7d windows,
# not the breakdown.
#
# Output: minified JSON
#   {
#     "total_tokens": <int>,
#     "skills":   [{"name": "...", "tokens": N, "pct": F}, ...],
#     "subagents":[{"name": "...", "tokens": N, "pct": F}, ...],
#     "mcp":      [{"name": "...", "tokens": N, "pct": F}, ...]
#   }
#
# Attribution: each turn's tokens are bucketed by the tools used in that turn's
# assistant message. The same tokens may be attributed to multiple buckets when
# a turn calls multiple tools — this matches Claude's interactive /usage shape
# (percentages can sum >100% because skills/agents/mcp overlap).
#
# === FAIL-OPEN ===
# Any failure → emit `{}` to stdout and exit 0.
#
# Cache TTL: 60s default. Statusline calls this every render; we cap recompute cost.
set -u

fail_open() { echo '{}'; exit 0; }
trap fail_open ERR

PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." 2>/dev/null && pwd)}"
[ -z "$PROJECT_ROOT" ] && fail_open

STATE_DIR="$PROJECT_ROOT/.claude/state"
mkdir -p "$STATE_DIR" 2>/dev/null
CACHE="$STATE_DIR/usage-breakdown-cache.json"

CACHE_TTL="${USAGE_BREAKDOWN_CACHE_TTL:-60}"

# Cache hit
if [ -f "$CACHE" ]; then
  age=$(($(date +%s) - $(stat -f %m "$CACHE" 2>/dev/null || stat -c %Y "$CACHE" 2>/dev/null || echo 0)))
  [ "$age" -lt "$CACHE_TTL" ] && { cat "$CACHE"; exit 0; }
fi

command -v jq >/dev/null 2>&1 || fail_open
command -v python3 >/dev/null 2>&1 || fail_open

PROJECTS_DIR="$HOME/.claude/projects"
[ -d "$PROJECTS_DIR" ] || fail_open

# Today's date in local time (so it matches user expectation of "today")
TODAY=$(date +%Y-%m-%d)

# Aggregate via python3 — bash+jq for 100+ files would be too slow
RESULT=$(TODAY="$TODAY" PROJECTS_DIR="$PROJECTS_DIR" python3 <<'PY' 2>/dev/null
import os
import json
import glob
from datetime import datetime, timezone, timedelta
from collections import defaultdict

projects_dir = os.environ["PROJECTS_DIR"]
today_str = os.environ["TODAY"]

# Local midnight cutoff in epoch
today_dt = datetime.strptime(today_str, "%Y-%m-%d").astimezone()
midnight = today_dt.replace(hour=0, minute=0, second=0, microsecond=0)
midnight_epoch = midnight.timestamp()

skill_tokens = defaultdict(int)
agent_tokens = defaultdict(int)
mcp_tokens = defaultdict(int)
total_tokens = 0

# Walk every session file modified today
for jsonl in glob.glob(f"{projects_dir}/*/*.jsonl"):
    try:
        mtime = os.path.getmtime(jsonl)
    except OSError:
        continue
    if mtime < midnight_epoch:
        continue

    with open(jsonl, "r", errors="replace") as f:
        for line in f:
            try:
                evt = json.loads(line)
            except (json.JSONDecodeError, ValueError):
                continue
            if evt.get("type") != "assistant":
                continue
            msg = evt.get("message", {})
            usage = msg.get("usage", {})
            if not usage:
                continue

            # Token cost for this turn — weight per Anthropic billing approximation
            # cache_read is 1/10 the cost; cache_create is ~1.25x input
            t_in   = usage.get("input_tokens", 0) or 0
            t_out  = usage.get("output_tokens", 0) or 0
            t_read = usage.get("cache_read_input_tokens", 0) or 0
            t_make = usage.get("cache_creation_input_tokens", 0) or 0
            turn_cost = t_in + t_out + int(t_read * 0.1) + int(t_make * 1.25)
            if turn_cost == 0:
                continue

            total_tokens += turn_cost

            # Discover tools used in this turn
            content = msg.get("content", []) or []
            if not isinstance(content, list):
                continue
            for block in content:
                if not isinstance(block, dict):
                    continue
                if block.get("type") != "tool_use":
                    continue
                tname = block.get("name", "") or ""
                inp = block.get("input", {}) or {}

                if tname == "Skill":
                    sk = inp.get("skill", "") or ""
                    if sk:
                        skill_tokens[sk] += turn_cost
                elif tname == "Agent":
                    st = inp.get("subagent_type", "") or inp.get("name", "") or ""
                    if st:
                        agent_tokens[st] += turn_cost
                elif tname.startswith("mcp__"):
                    # mcp__<server>__<tool> — extract server
                    parts = tname.split("__", 2)
                    if len(parts) >= 2:
                        mcp_tokens[parts[1]] += turn_cost

def topk(d, k=3):
    items = sorted(d.items(), key=lambda kv: kv[1], reverse=True)[:k]
    out = []
    for name, tok in items:
        pct = round(100.0 * tok / total_tokens, 1) if total_tokens else 0.0
        out.append({"name": name, "tokens": tok, "pct": pct})
    return out

result = {
    "total_tokens": total_tokens,
    "skills": topk(skill_tokens),
    "subagents": topk(agent_tokens),
    "mcp": topk(mcp_tokens),
}
print(json.dumps(result, separators=(",", ":")))
PY
)

[ -z "$RESULT" ] && fail_open

# Validate before caching
echo "$RESULT" | python3 -c 'import json,sys; json.loads(sys.stdin.read())' 2>/dev/null || fail_open

# Atomic cache write
printf '%s' "$RESULT" > "$CACHE.tmp" 2>/dev/null && mv "$CACHE.tmp" "$CACHE" 2>/dev/null
printf '%s' "$RESULT"
