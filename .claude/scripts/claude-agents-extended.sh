#!/usr/bin/env bash
# claude-agents-extended.sh — `claude agents --json` superset that includes Agent-tool subagents.
#
# Problem: `claude agents --json` (verified live against Claude Code 2.1.150) only
# returns kind: "interactive" and kind: "background". Agent-tool subagents (the sidechain
# children spawned by the Agent tool) are invisible to it — they exist only as JSONL
# transcripts under ~/.claude/projects/<project>/<parent-sid>/subagents/agent-*.jsonl.
#
# This wrapper augments the base output with kind: "subagent" entries derived from
# those JSONL files, with terminal-state detection via the parent transcript.
#
# Flags:
#   --bg-only         skip subagent scan entirely; emit base output (optionally cwd-filtered).
#                     Used by ram-budget.sh which intentionally wants the old semantics:
#                     subagents are ~50MB each (much smaller than bg ~250-400MB), so
#                     including them in a RAM-headroom check would falsely refuse spawns.
#   --cwd <path>      filter both base and subagent entries to those whose cwd is <path>
#                     or a path under <path>. Mirrors what statusline.sh expects.
#
# Env:
#   SUBAGENT_FRESHNESS_SEC   how long since subagent JSONL mtime to consider it active.
#                            Default 60. Bounds false-positives to this window when the
#                            parent transcript is unreadable.
#   CLAUDE_PROJECTS_DIR      override projects dir for tests. Default ~/.claude/projects.
#   CLAUDE_AGENTS_RAW        if set, used in place of `claude agents --json` output.
#                            Tests use this to inject a known base array.
#   CLAUDE_AGENTS_EXTENDED_NO_RUN_CLAUDE
#                            if "1", skip running `claude agents --json` entirely (tests).
#
# Output:
#   JSON array merging base entries + subagent entries. Subagent entry shape:
#     {
#       "kind": "subagent",
#       "parentSessionId": "<uuid>",
#       "sessionId": "<agentId>",
#       "agentId": "<agentId>",
#       "cwd": "<parent session's cwd — what statusline filters on>",
#       "worktreePath": "<subagent's per-agent worktree, from .meta.json>",
#       "status": "busy",
#       "startedAt": <ms-epoch number, matches base entries>,
#       "description": "<from .meta.json or first message, truncated 200 chars>",
#       "subagentType": "<from .meta.json agentType or 'general-purpose'>",
#       "toolUseId": "<from .meta.json — enables precise terminal detection>"
#     }
#
# Exit: 0 always (advisory tool — failures fall through to empty/base output).

set -u

BG_ONLY=0
FILTER_CWD=""

while [ $# -gt 0 ]; do
  case "$1" in
    --bg-only) BG_ONLY=1 ;;
    --cwd)     FILTER_CWD="${2:-}"; shift ;;
    --cwd=*)   FILTER_CWD="${1#--cwd=}" ;;
    -h|--help)
      sed -n '2,40p' "$0"
      exit 0
      ;;
    *) ;;  # ignore unknown args for forward compat
  esac
  shift
done

PROJECTS_DIR="${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"
FRESHNESS_SEC="${SUBAGENT_FRESHNESS_SEC:-60}"

# ── 1. Base array from `claude agents --json` ────────────────────────────────
# Track whether the base call actually succeeded. Consumers like
# pwt-claims-cleanup.sh use the exit code as a signal: "if claude failed,
# don't infer anything about live SIDs." If we always exit 0 even on failure,
# callers can't distinguish "no agents running" from "claude unavailable" —
# and may incorrectly classify still-live SIDs as orphans.
base_ok=1
if [ -n "${CLAUDE_AGENTS_RAW:-}" ]; then
  base_json="$CLAUDE_AGENTS_RAW"
elif [ "${CLAUDE_AGENTS_EXTENDED_NO_RUN_CLAUDE:-}" = "1" ]; then
  base_json="[]"
elif command -v claude >/dev/null 2>&1; then
  if ! base_json=$(claude agents --json 2>/dev/null); then
    base_json="[]"
    base_ok=0
  fi
else
  base_json="[]"
  base_ok=0
fi

# jq is required for any meaningful merge. If it's missing, emit base verbatim
# (statusline.sh already gracefully degrades when jq is absent).
if ! command -v jq >/dev/null 2>&1; then
  printf '%s' "$base_json"
  exit 0
fi

# Validate base JSON; degrade to [] if malformed.
if ! printf '%s' "$base_json" | jq -e 'type == "array"' >/dev/null 2>&1; then
  base_json="[]"
fi

# Filter base by cwd if requested.
if [ -n "$FILTER_CWD" ]; then
  base_json=$(printf '%s' "$base_json" \
    | jq --arg cwd "$FILTER_CWD" \
        '[.[] | select(.cwd == $cwd or (.cwd | startswith($cwd + "/")))]' 2>/dev/null \
    || echo "[]")
fi

# ── 2. --bg-only: short-circuit, emit base ────────────────────────────────────
if [ "$BG_ONLY" -eq 1 ]; then
  printf '%s' "$base_json"
  exit 0
fi

# ── 3. Subagent scan ──────────────────────────────────────────────────────────
# Only proceed if the projects dir exists. Empty / missing → emit base and
# propagate base_ok as exit code (mirrors the "no fallback signal" path
# at the bottom).
if [ ! -d "$PROJECTS_DIR" ]; then
  printf '%s' "$base_json"
  [ "$base_ok" -eq 1 ]
  exit $?
fi

now_epoch=$(date +%s)
subagents_json="[]"

# Find candidate subagent JSONL files modified within the freshness window.
# -mtime -1 keeps the find cheap (last 24h); we filter precisely below.
# Using -path glob with shell expansion: `${PROJECTS_DIR}/*/*/subagents/agent-*.jsonl`.
candidates=$(find "$PROJECTS_DIR" -mindepth 4 -maxdepth 4 \
  -path '*/subagents/agent-*.jsonl' \
  -type f -mtime -1 2>/dev/null || true)

if [ -n "$candidates" ]; then
  # Build entries one per line as compact JSON, then collect into an array.
  tmp_entries=$(mktemp 2>/dev/null || echo "/tmp/cae-$$.entries")
  : > "$tmp_entries"

  while IFS= read -r subagent_file; do
    [ -z "$subagent_file" ] && continue
    [ -f "$subagent_file" ] || continue

    # Derive path components.
    #   .../<project>/<parent-sid>/subagents/agent-<agentId>.jsonl
    sub_dir=$(dirname "$subagent_file")                  # .../<parent-sid>/subagents
    parent_dir=$(dirname "$sub_dir")                     # .../<parent-sid>
    parent_sid=$(basename "$parent_dir")
    parent_transcript="${parent_dir}.jsonl"
    file_base=$(basename "$subagent_file")
    agent_id="${file_base#agent-}"
    agent_id="${agent_id%.jsonl}"
    meta_file="${sub_dir}/agent-${agent_id}.meta.json"

    # Claude Code 2.1.150 ships an .meta.json sidecar per subagent with
    # agentType, description, worktreePath, toolUseId. Prefer those over
    # parsing the JSONL — meta is stable, JSONL first-line is verbose prompt.
    meta_agent_type=""
    meta_description=""
    meta_worktree=""
    meta_tool_use_id=""
    if [ -f "$meta_file" ]; then
      meta_agent_type=$(jq -r '.agentType // ""' "$meta_file" 2>/dev/null)
      meta_description=$(jq -r '.description // ""' "$meta_file" 2>/dev/null)
      meta_worktree=$(jq -r '.worktreePath // ""' "$meta_file" 2>/dev/null)
      meta_tool_use_id=$(jq -r '.toolUseId // ""' "$meta_file" 2>/dev/null)
    fi

    # When no meta is available, validate that the JSONL first line is
    # parseable as a JSON object. Without meta AND with malformed JSONL,
    # we have no usable identity for the subagent — skip rather than emit
    # a half-empty record.
    if [ -z "$meta_agent_type" ] && [ -z "$meta_description" ]; then
      if ! head -n 1 "$subagent_file" 2>/dev/null | jq -e 'type == "object"' >/dev/null 2>&1; then
        continue
      fi
    fi

    # Terminal-state check: mtime is the authoritative signal. Active
    # subagents append to their JSONL on every assistant turn / tool call /
    # tool result, so a quiescent file (no writes in FRESHNESS_SEC) means
    # the subagent is either done or stuck — both reasons to exclude.
    #
    # Why NOT use parent transcript tool_result matching: Claude Code 2.1.x
    # async Agent tool calls emit a tool_result IMMEDIATELY upon launch with
    # content "Async agent launched successfully." The real completion
    # arrives later via task-notification, with no standard marker tying it
    # back to the toolUseId. Using tool_result presence as terminal signal
    # would mark every async subagent as terminal seconds after spawn.
    file_mtime=$(stat -f %m "$subagent_file" 2>/dev/null || stat -c %Y "$subagent_file" 2>/dev/null || echo 0)
    age=$(( now_epoch - file_mtime ))
    if [ "$age" -gt "$FRESHNESS_SEC" ]; then
      continue
    fi

    # Parent's cwd is the canonical cwd for filter matching — that's where
    # the user IS interactively. The session-start "last-prompt" line has
    # cwd=null in 2.1.150; scan up to 100 lines to find the first non-null
    # cwd from the actual conversation. The subagent's own worktree is
    # exposed separately as worktreePath.
    parent_cwd=""
    if [ -f "$parent_transcript" ]; then
      parent_cwd=$(head -n 100 "$parent_transcript" 2>/dev/null \
        | jq -r 'select(.cwd != null and .cwd != "") | .cwd' 2>/dev/null \
        | head -n 1)
    fi
    # Fallback: read subagent's own JSONL first line for cwd.
    if [ -z "$parent_cwd" ]; then
      parent_cwd=$(head -n 1 "$subagent_file" 2>/dev/null \
        | jq -r '.cwd // ""' 2>/dev/null)
    fi

    # cwd filter (if --cwd given): match if ANY of the following is true,
    # because a user cd'd into a subdir of the parent's startup cwd still
    # owns those subagents, and equally a subagent's per-agent worktree
    # may be the only path matching:
    #   - parent's cwd is under FILTER_CWD (subagent of a child session)
    #   - FILTER_CWD is under parent's cwd (user cd'd into a subdir)
    #   - subagent's worktree is under FILTER_CWD
    if [ -n "$FILTER_CWD" ]; then
      match=0
      case "$parent_cwd" in
        "$FILTER_CWD"|"$FILTER_CWD"/*) match=1 ;;
      esac
      case "$FILTER_CWD" in
        "$parent_cwd"|"$parent_cwd"/*) [ -n "$parent_cwd" ] && match=1 ;;
      esac
      case "$meta_worktree" in
        "$FILTER_CWD"|"$FILTER_CWD"/*) match=1 ;;
      esac
      [ "$match" -eq 0 ] && continue
    fi

    # Description fallback: if no meta, take first 200 chars of first message.
    description="$meta_description"
    if [ -z "$description" ]; then
      description=$(head -n 1 "$subagent_file" 2>/dev/null | jq -r '
        (.message.content // "")
        | if type == "string" then . else (tostring) end
        | .[0:200]
      ' 2>/dev/null)
    fi

    # startedAt as ms-epoch NUMBER to match base entries' shape. Prefer the
    # JSONL first-line timestamp (ISO string) → convert. Fall back to file
    # mtime in ms.
    started_at_iso=$(head -n 1 "$subagent_file" 2>/dev/null \
      | jq -r '.timestamp // ""' 2>/dev/null)
    started_at_ms=""
    if [ -n "$started_at_iso" ]; then
      started_at_ms=$(jq -nr --arg ts "$started_at_iso" '
        try ($ts | fromdateiso8601 * 1000 | floor) catch null
      ' 2>/dev/null)
    fi
    [ -z "$started_at_ms" ] || [ "$started_at_ms" = "null" ] && started_at_ms=$(( file_mtime * 1000 ))

    subagent_type="${meta_agent_type:-general-purpose}"

    # Emit. cwd is parent's cwd (matches statusline.sh filter); worktreePath
    # is the per-subagent worktree where it actually runs.
    entry=$(jq -nc \
      --arg kind "subagent" \
      --arg parentSessionId "$parent_sid" \
      --arg sessionId "$agent_id" \
      --arg agentId "$agent_id" \
      --arg cwd "$parent_cwd" \
      --arg worktreePath "$meta_worktree" \
      --arg status "busy" \
      --argjson startedAt "${started_at_ms:-0}" \
      --arg description "$description" \
      --arg subagentType "$subagent_type" \
      --arg toolUseId "$meta_tool_use_id" '
      {
        kind:            $kind,
        parentSessionId: $parentSessionId,
        sessionId:       $sessionId,
        agentId:         $agentId,
        cwd:             $cwd,
        worktreePath:    $worktreePath,
        status:          $status,
        startedAt:       $startedAt,
        description:     $description,
        subagentType:    $subagentType,
        toolUseId:       $toolUseId
      }
    ' 2>/dev/null) || continue

    [ -n "$entry" ] && printf '%s\n' "$entry" >> "$tmp_entries"
  done <<< "$candidates"

  if [ -s "$tmp_entries" ]; then
    subagents_json=$(jq -s '.' "$tmp_entries" 2>/dev/null || echo "[]")
  fi
  rm -f "$tmp_entries" 2>/dev/null
fi

# ── 4. Merge ──────────────────────────────────────────────────────────────────
merged=$(jq -n --argjson base "$base_json" --argjson subs "$subagents_json" \
  '$base + $subs' 2>/dev/null || echo "$base_json")

# Propagate the base-call failure when we have NO additional signal from
# subagents either. This preserves the caller's ability to use exit code
# as "I learned nothing reliable about live agents." When we did pick up
# subagents, the partial info is better than nothing — return exit 0.
sub_len=$(printf '%s' "$subagents_json" | jq 'length' 2>/dev/null || echo 0)
if [ "$base_ok" -eq 0 ] && [ "$sub_len" = "0" ]; then
  printf '%s' "$merged"
  exit 1
fi

printf '%s' "$merged"
