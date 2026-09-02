#!/usr/bin/env bash
# usage-breakdown.sh
#
# Aggregates today's local Claude session transcripts (~/.claude/projects/**/*.jsonl)
# to produce a token-cost breakdown by Skill, Subagent (Agent tool), and MCP server.
# This mirrors what `/usage` shows interactively but computes from local data —
# the /api/oauth/usage endpoint only returns the plan windows, not the breakdown.
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
# === NON-BLOCKING (2026-09-02) ===
# The scan reads EVERY transcript modified today (127 MB on a fleet day) and ran
# INLINE in the status-line render, per repo, every 60 s. Claude Code cancels an
# in-flight status-line command when the next trigger fires, so under load the
# render died inside the scan and the display froze on its last completed frame.
# The input is machine-wide (~/.claude/projects), so the cache is now ONE file per
# machine, refreshed by a DETACHED bounded singleton; the render only reads it.
#
# USAGE
#   usage-breakdown.sh [--sync]     default: serve the cache, refresh detached if stale
#                                   --sync: refresh inline (bounded), then serve
# ENV
#   USAGE_BREAKDOWN_CACHE       cache file ($HOME/.config/claude-pattern/usage-breakdown.json)
#   USAGE_BREAKDOWN_CACHE_TTL   seconds before a refresh is started (120)
#   USAGE_BREAKDOWN_STALE_MAX   max age still served (3600)
#   USAGE_BREAKDOWN_TIMEOUT_S   scan bound, seconds (60)
#   USAGE_BREAKDOWN_COLD_WAIT   cold-cache wait for the first sample (1)
#   USAGE_BREAKDOWN_PROJECTS    transcript root ($HOME/.claude/projects)
#
# === FAIL-OPEN ===
# Any failure → `{}` on stdout, exit 0. A failed/killed scan never replaces the
# previous value.
#
# bash 3.2 (mac-mini /bin/bash).
set -u

MODE=serve
for a in "$@"; do case "$a" in --sync) MODE=sync ;; --refresh) MODE=refresh ;; esac; done

CACHE="${USAGE_BREAKDOWN_CACHE:-$HOME/.config/claude-pattern/usage-breakdown.json}"
LOCK="$CACHE.lock"
CACHE_TTL="${USAGE_BREAKDOWN_CACHE_TTL:-120}"
STALE_MAX="${USAGE_BREAKDOWN_STALE_MAX:-3600}"
BOUND_S="${USAGE_BREAKDOWN_TIMEOUT_S:-60}"
COLD_WAIT="${USAGE_BREAKDOWN_COLD_WAIT:-1}"
PROJECTS_DIR="${USAGE_BREAKDOWN_PROJECTS:-$HOME/.claude/projects}"
case "$CACHE_TTL$STALE_MAX$BOUND_S$COLD_WAIT" in *[!0-9]*) CACHE_TTL=120; STALE_MAX=3600; BOUND_S=60; COLD_WAIT=1 ;; esac

__age_s() {
  local f="$1" m
  [ -e "$f" ] || { echo 999999; return 0; }
  m=$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null || echo "")
  case "$m" in ''|*[!0-9]*) echo 999999; return 0 ;; esac
  echo $(( $(date +%s) - m ))
}
__serve() {
  if [ -s "$CACHE" ] && [ "$(__age_s "$CACHE")" -lt "$STALE_MAX" ] 2>/dev/null; then cat "$CACHE" 2>/dev/null || echo '{}'
  else echo '{}'; fi
  return 0
}
__lock() {
  mkdir -p "$(dirname "$CACHE")" 2>/dev/null || return 1
  if mkdir "$LOCK" 2>/dev/null; then return 0; fi
  if [ "$(__age_s "$LOCK")" -gt $(( BOUND_S * 2 )) ] 2>/dev/null; then
    rm -rf "$LOCK" 2>/dev/null; mkdir "$LOCK" 2>/dev/null && return 0
  fi
  return 1
}
__unlock() { rm -rf "$LOCK" 2>/dev/null; }
__timeout_bin() {
  if command -v gtimeout >/dev/null 2>&1; then echo gtimeout
  elif command -v timeout >/dev/null 2>&1; then echo timeout
  else echo ""; fi
}
__wait_for_fresh() {
  local since="$1" max="$2" i=0 m
  while [ "$i" -lt $(( max * 5 )) ]; do
    if [ -s "$CACHE" ]; then
      m=$(stat -f %m "$CACHE" 2>/dev/null || stat -c %Y "$CACHE" 2>/dev/null || echo 0)
      [ "${m:-0}" -ge "$since" ] 2>/dev/null && return 0
    fi
    sleep 0.2 2>/dev/null || sleep 1
    i=$(( i + 1 ))
  done
  return 1
}

__scan() {  # prints the JSON result or nothing
  command -v python3 >/dev/null 2>&1 || return 0
  [ -d "$PROJECTS_DIR" ] || return 0
  TODAY="$(date +%Y-%m-%d)" PROJECTS_DIR="$PROJECTS_DIR" python3 - <<'PY' 2>/dev/null
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
}

__refresh() {  # under the lock; a failed/empty scan keeps the previous value
  local out tb tmp="$CACHE.tmp.$$"
  tb=$(__timeout_bin)
  if [ -n "$tb" ]; then out=$("$tb" "${BOUND_S}s" bash "$0" --scan-only 2>/dev/null) || out=""
  else out=$(__scan) || out=""; fi
  [ -n "$out" ] || return 0
  printf '%s' "$out" | python3 -c 'import json,sys; json.loads(sys.stdin.read())' >/dev/null 2>&1 || return 0
  printf '%s' "$out" > "$tmp" 2>/dev/null && mv -f "$tmp" "$CACHE" 2>/dev/null
  rm -f "$tmp" 2>/dev/null
  return 0
}

for a in "$@"; do [ "$a" = "--scan-only" ] && { __scan; exit 0; }; done

case "$MODE" in
  refresh) trap '__unlock' EXIT INT TERM; __refresh; exit 0 ;;
  sync)
    since=$(date +%s)
    if __lock; then trap '__unlock' EXIT INT TERM; __refresh
    else __wait_for_fresh "$since" "$BOUND_S" || true; fi
    __serve; exit 0 ;;
esac

if [ -s "$CACHE" ] && [ "$(__age_s "$CACHE")" -lt "$CACHE_TTL" ] 2>/dev/null; then __serve; exit 0; fi

since=$(date +%s)
if __lock; then
  TB=$(__timeout_bin)
  (
    set -m 2>/dev/null
    if [ -n "$TB" ]; then nohup "$TB" "$(( BOUND_S + 5 ))s" bash "$0" --refresh </dev/null >/dev/null 2>&1 &
    else nohup bash "$0" --refresh </dev/null >/dev/null 2>&1 & fi
  ) 2>/dev/null
fi
[ -s "$CACHE" ] || __wait_for_fresh "$since" "$COLD_WAIT" || true
__serve
exit 0
