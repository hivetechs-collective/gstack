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
#       "cwd": "<parent cwd>",
#       "status": "busy",
#       "startedAt": "<ISO8601 from first JSONL line>",
#       "description": "<truncated 200 chars>",
#       "subagentType": "<inferred or 'general-purpose'>"
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

    # mtime freshness check
    file_mtime=$(stat -f %m "$subagent_file" 2>/dev/null || stat -c %Y "$subagent_file" 2>/dev/null || echo 0)
    age=$(( now_epoch - file_mtime ))
    if [ "$age" -gt "$FRESHNESS_SEC" ]; then
      continue
    fi

    # Derive path components.
    #   .../<project>/<parent-sid>/subagents/agent-<agentId>.jsonl
    sub_dir=$(dirname "$subagent_file")                  # .../<parent-sid>/subagents
    parent_dir=$(dirname "$sub_dir")                     # .../<parent-sid>
    parent_sid=$(basename "$parent_dir")
    project_dir=$(dirname "$parent_dir")                 # .../<project>
    parent_transcript="${parent_dir}.jsonl"
    file_base=$(basename "$subagent_file")
    agent_id="${file_base#agent-}"
    agent_id="${agent_id%.jsonl}"

    # Parse first JSONL line (the launch event). Tolerate malformed lines.
    first_line=$(head -n 1 "$subagent_file" 2>/dev/null)
    if [ -z "$first_line" ]; then
      continue
    fi

    # Extract fields with jq, defaulting if the line is malformed or missing keys.
    parsed=$(printf '%s' "$first_line" | jq -c '
      . as $l
      | {
          cwd:          ($l.cwd // ""),
          startedAt:    ($l.timestamp // ""),
          sessionKind:  ($l.sessionKind // "bg"),
          description:  (
            ($l.message.content // "")
            | if type == "string" then . else (tostring) end
            | .[0:200]
          )
        }
    ' 2>/dev/null) || continue

    [ -z "$parsed" ] && continue

    # cwd filter (if --cwd given)
    if [ -n "$FILTER_CWD" ]; then
      sub_cwd=$(printf '%s' "$parsed" | jq -r '.cwd // ""' 2>/dev/null)
      case "$sub_cwd" in
        "$FILTER_CWD"|"$FILTER_CWD"/*) : ;;  # match
        *) continue ;;
      esac
    fi

    # Terminal-state check: scan parent transcript for an event with
    # .toolUseResult.agentId == <agentId> AND .toolUseResult.status == "completed".
    # If the parent transcript is missing/unreadable, fall back to mtime-only
    # freshness (entry is "busy" if within window — conservative).
    is_terminal=0
    if [ -f "$parent_transcript" ]; then
      # grep first to avoid jq-ing the whole transcript (could be huge).
      # Then validate with jq to avoid false-positives on the agentId appearing
      # incidentally inside other content.
      if grep -F -q "$agent_id" "$parent_transcript" 2>/dev/null; then
        if grep -F "$agent_id" "$parent_transcript" 2>/dev/null \
            | jq -e --arg aid "$agent_id" '
                select(type == "object")
                | select(.toolUseResult.agentId == $aid)
                | select(.toolUseResult.status == "completed")
              ' >/dev/null 2>&1; then
          is_terminal=1
        fi
      fi
    fi

    if [ "$is_terminal" -eq 1 ]; then
      continue
    fi

    # Emit the merged entry.
    entry=$(printf '%s' "$parsed" | jq -c \
      --arg kind "subagent" \
      --arg parentSessionId "$parent_sid" \
      --arg sessionId "$agent_id" \
      --arg agentId "$agent_id" \
      --arg status "busy" \
      --arg subagentType "general-purpose" '
      {
        kind:            $kind,
        parentSessionId: $parentSessionId,
        sessionId:       $sessionId,
        agentId:         $agentId,
        cwd:             .cwd,
        status:          $status,
        startedAt:       .startedAt,
        description:     .description,
        subagentType:    $subagentType
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
