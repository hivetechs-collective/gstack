#!/bin/bash
# plan-w-team Goal Evaluator — Stop hook
#
# Replaces Anthropic's /goal wrapper with a deterministic shell evaluator.
# Fires after every Claude turn. Reads active /plan-w-team goal state file
# (created by the skill at top-of-pipeline) and decides whether the pipeline
# reached a terminal state.
#
# Why deterministic instead of Haiku-based: every terminal-state anchor in
# shared/goal-conditions.md is concrete enough to detect by jq-decoding the
# transcript JSONL (assistant text, tool_result, user content — escaped or
# raw) and pattern-matching the unescaped payloads. No LLM judgment needed,
# no eval hallucination, no tokens.
#
# Spec: docs/specs/pwt-t5-goal-wrapper.md (origin design);
#       docs/specs/pwt-evaluator-escaped-quotes.md (escaped-quote transcript detection)
# State file: .claude/state/plan-w-team-goal-<SLUG>.json
# Kill switch: PLAN_W_TEAM_DISABLE_GOAL=1 → exit 0 (let stop proceed normally)
# Block cap: default 8; set CLAUDE_CODE_STOP_HOOK_BLOCK_CAP=200 in shell env
#            for long /plan-w-team runs

set -u

# Always read stdin (hook contract)
INPUT=$(cat 2>/dev/null || echo '{}')

# Debug mode — emit structured diagnostics to stderr explaining WHY the hook
# decided terminal / not-terminal (which detector ran, what it matched). Enable
# via env PWT_GOAL_EVALUATOR_DEBUG=1 OR the --debug CLI flag (any position).
# This is the only window into the hook when it false-negatives — keep it
# informative. All debug output goes to stderr so the stdout JSON decision
# contract is never polluted.
PWT_DEBUG=0
[ "${PWT_GOAL_EVALUATOR_DEBUG:-}" = "1" ] && PWT_DEBUG=1
case " $* " in *" --debug "*) PWT_DEBUG=1 ;; esac
dbg() { [ "$PWT_DEBUG" = "1" ] && echo "[goal-evaluator:debug] $*" >&2 || true; }

# Kill switch — skip goal evaluation entirely
if [ "${PLAN_W_TEAM_DISABLE_GOAL:-}" = "1" ]; then
    dbg "kill switch PLAN_W_TEAM_DISABLE_GOAL=1 → allow stop"
    exit 0
fi

# stop_hook_active protection — if Claude Code already overrode us, don't fight
if [ "$(echo "$INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null)" = "true" ]; then
    exit 0
fi

PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
FALLBACK_STATE_DIR="$PROJECT_ROOT/.claude/state"
PWD_STATE_DIR="$PWD/.claude/state"

# Resolve and export CLAUDE_BIN so any helper script this hook invokes
# (or transitively spawns) can call claude without PATH lookup failures.
# The evaluator itself does not currently shell out to claude, but future
# helpers (e.g. supervisor-mirror lifecycle hooks, child-cleanup) will
# inherit a resolved $CLAUDE_BIN. Best-effort: missing helper = silent no-op.
LOCATE_CLAUDE="$PROJECT_ROOT/.claude/scripts/locate-claude.sh"
if [ -x "$LOCATE_CLAUDE" ]; then
    CLAUDE_BIN="$("$LOCATE_CLAUDE" 2>/dev/null)" || CLAUDE_BIN=""
    [ -n "$CLAUDE_BIN" ] && export CLAUDE_BIN
fi

# Source the shared transient-connection-error pattern set (API_HALT detection).
# Best-effort: a missing helper (older consumer repo) leaves pwt_is_transient_error
# undefined, and the API_HALT classifier below is guarded on `command -v`, so it
# simply no-ops there — fail-safe, no regression.
TRANSIENT_HELPER="$PROJECT_ROOT/.claude/scripts/pwt-transient-errors.sh"
if [ -r "$TRANSIENT_HELPER" ]; then
    # shellcheck source=/dev/null
    . "$TRANSIENT_HELPER"
fi

# Worktree-aware state lookup: check $PWD/.claude/state first (the case when
# /plan-w-team is running in a worktree), fall back to project root. We
# aggregate goal files from both locations so the evaluator catches active
# goals regardless of where they were written. See 2026-05-20 holistic-check
# retro for the failure this fixes.
shopt -s nullglob
declare -a GOAL_FILES=()
if [ -d "$PWD_STATE_DIR" ] && [ "$PWD_STATE_DIR" != "$FALLBACK_STATE_DIR" ]; then
    for f in "$PWD_STATE_DIR"/plan-w-team-goal-*.json; do
        GOAL_FILES+=("$f")
    done
fi
for f in "$FALLBACK_STATE_DIR"/plan-w-team-goal-*.json; do
    GOAL_FILES+=("$f")
done
shopt -u nullglob

# Pick effective STATE_DIR for any downstream writes: prefer $PWD if it holds a
# matching goal, else fall back. (Used by terminal-state persistence below.)
if [ -d "$PWD_STATE_DIR" ] && [ "$PWD_STATE_DIR" != "$FALLBACK_STATE_DIR" ] && \
   compgen -G "$PWD_STATE_DIR/plan-w-team-goal-*.json" >/dev/null 2>&1; then
    STATE_DIR="$PWD_STATE_DIR"
else
    STATE_DIR="$FALLBACK_STATE_DIR"
fi

# No active goal → let Claude stop normally
[ "${#GOAL_FILES[@]}" -eq 0 ] && exit 0

# Tools: jq required for state file parsing
if ! command -v jq >/dev/null 2>&1; then
    echo "[goal-evaluator] WARN: jq not available, skipping evaluation" >&2
    exit 0
fi

# ── ISO8601-or-mtime → epoch helper (portable, bash 3.2) ──────────────────────
# Used by the stale-snapshot guard below. Tries GNU `date -d` then BSD/macOS
# `date -j -f`. Emits epoch seconds on success, empty on failure (caller decides).
__iso_to_epoch() {
    local iso="$1"
    [ -z "$iso" ] && return 0
    date -u -d "$iso" +%s 2>/dev/null && return 0
    date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$iso" +%s 2>/dev/null && return 0
    return 0
}

# ── Anti-park signal reader (PWT-ANTIPARK, 2026-06-07) ────────────────────────
# Promotes feedback_supervisor_progress_objective from prose to an ENFORCED gate
# by letting the Stop hook consult the objective progress snapshot that
# supervisor-progress-check.sh writes. Echoes one line:
#   "<backlogKnown> <backlog> <verdict> <stallStreak>".
#
# SLUG-SCOPED (2026-06-07 hermeticity fix): the snapshot is keyed PER-RUN as
# `supervisor-progress-<slug>.json`, and $1 is the CURRENT run's SLUG. A snapshot
# written by another run (or a stale dead run) therefore can NEVER drive this run's
# Stop decision — the prior global, non-slug-keyed `supervisor-progress.json` read
# let a stale May-28 file (verdict STALLED, backlog 9) contaminate a live run's U18
# (the defect this fixes). Three independent fail-open guards, any of which yields
# NO signal (empty output → caller behaves byte-for-byte as pre-fix):
#   1. No slug arg, or no slug-keyed file        → empty.
#   2. Snapshot's own `slug` field != current    → empty (foreign-slug guard).
#   3. Snapshot older than PWT_ANTIPARK_MAX_AGE_S → empty (stale guard; ts, else
#      file mtime). A dead run's STALLED verdict must not haunt a new run forever.
# The gate can only ever ADD a block where the run was about to silently park; it
# never removes an existing block and never relaxes a terminal.
# Kill switch: PLAN_W_TEAM_DISABLE_ANTIPARK=1 → always empty (feature off).
# Staleness threshold: PWT_ANTIPARK_MAX_AGE_S (default 3600s = 1h).
__antipark_state() {
    [ "${PLAN_W_TEAM_DISABLE_ANTIPARK:-}" = "1" ] && return 0
    local slug="${1:-}"
    [ -z "$slug" ] && return 0
    local d f=""
    for d in "$STATE_DIR" "$FALLBACK_STATE_DIR"; do
        if [ -f "$d/supervisor-progress-${slug}.json" ]; then
            f="$d/supervisor-progress-${slug}.json"; break
        fi
    done
    [ -z "$f" ] && return 0
    # Foreign-slug guard: the snapshot's own slug must equal the current run's.
    # (A corrupt file yields empty snap_slug → mismatch → ignored, fail-open.)
    local snap_slug
    snap_slug=$(jq -r '.slug // ""' "$f" 2>/dev/null || echo "")
    [ "$snap_slug" != "$slug" ] && return 0
    # Stale-snapshot guard: ignore snapshots older than PWT_ANTIPARK_MAX_AGE_S.
    # Prefer the embedded ISO `ts`; fall back to file mtime if ts is unparseable.
    local max_age snap_ts snap_epoch now_epoch age
    max_age="${PWT_ANTIPARK_MAX_AGE_S:-3600}"
    snap_ts=$(jq -r '.ts // ""' "$f" 2>/dev/null || echo "")
    snap_epoch=$(__iso_to_epoch "$snap_ts")
    if [ -z "$snap_epoch" ]; then
        snap_epoch=$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null || echo "")
    fi
    if [ -n "$snap_epoch" ] && [ "$snap_epoch" -gt 0 ] 2>/dev/null; then
        now_epoch=$(date -u +%s)
        age=$(( now_epoch - snap_epoch ))
        [ "$age" -ge "$max_age" ] 2>/dev/null && return 0
    fi
    # Corrupt JSON → jq fails → empty (fail-open). Defaults guard missing keys.
    jq -r '"\(.backlogKnown // 0) \(.backlog // 0) \(.verdict // "") \(.stallStreak // 0)"' "$f" 2>/dev/null || true
}

# Transcript: Claude Code passes the path in the hook input
TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // ""' 2>/dev/null)

# ── Transcript decoder ──────────────────────────────────────────────────────
# THE FIX (2026-05-25): Claude Code stores assistant/user/tool message content
# as JSON-encoded strings inside the transcript JSONL. A status block emitted
# as assistant text therefore lands on disk with ESCAPED quotes:
#     ...,"text":"{\"stage\":\"retro-complete\",\"slug\":\"x\"}"
# The previous detectors ran `grep -F '"stage":"retro-complete"'` against the
# raw transcript file, which can NEVER match the escaped form — so valid
# terminal signals were silently rejected (false-negative), trapping
# autonomous runs (cleanscale hard-gate escalation incident, 2026-05-25).
#
# Approach A (implemented): parse each transcript entry with jq, extract every
# candidate text payload — assistant `.message.content[].text`, tool_result
# `.content` (string OR nested {type:text,text} array), and string-form user
# `.message.content` — and emit ONE decoded line per transcript entry with the
# quotes UNESCAPED by jq's own string decoding. Detectors then match against
# this decoded corpus. Because all keys of a single status block live in one
# entry's text payload, "same decoded line" is the faithful translation of the
# original "±5 lines of the slug anchor" proximity intent.
#
# Approach B (REJECTED): just add a second grep for the escaped variant
# `\"stage\":\"retro-complete\"`. Rejected because escaping is context-
# dependent and unbounded: double-encoding (`\\\"`) occurs when a status block
# is quoted inside another JSON string (tool input echoing an assistant
# message, nested tool_result arrays); fenced ```json blocks add their own
# layer; and matching literal backslash-quote sequences across the raw file
# also defeats the slug-anchor proximity defense (the anchor and the trigger
# can land on different physical lines after `tail`). jq decoding collapses ALL
# escape layers to canonical text in one pass and keeps each status block on a
# single logical line — Approach B would need a new grep per escape depth and
# still miss the array/double-encoded cases.
#
# Backward-compat: the RAW transcript tail is retained as a second corpus and
# OR'd into every detector, so transcripts that happened to carry raw-form
# patterns (direct file-write emission paths) are still detected. The fix ADDS
# escaped-form detection; it does not remove raw-form detection.
#
# Fail-safe: malformed JSONL lines are skipped by `jq -R 'fromjson? // empty'`
# so a corrupt transcript never crashes the hook (exits non-terminal cleanly).
decode_transcript() {
    # $1 = transcript file. Emits one decoded text line per parseable entry.
    local file="$1"
    [ -n "$file" ] && [ -f "$file" ] || return 0
    tail -500 "$file" 2>/dev/null \
        | jq -R 'fromjson? // empty' 2>/dev/null \
        | jq -r '
            ( .message.content? // empty ) as $c
            | if   ($c | type) == "string" then $c
              elif ($c | type) == "array" then
                [ $c[]
                  | if   (.type? == "text")        then (.text // "")
                    elif (.type? == "tool_result") then
                      ( if   (.content | type) == "string" then .content
                        elif (.content | type) == "array"  then
                          ([ .content[] | (.text? // "") ] | join(" "))
                        else "" end )
                    elif (.type? == "tool_use")    then
                      # Tool input may carry a status block (e.g. a Write of a
                      # state file). Flatten the input object back to compact
                      # JSON so its keys are matchable on this same line.
                      ( (.input // {}) | tostring )
                    else "" end
                ] | join("  ")
              else "" end
            # Collapse newlines so a multi-line status block stays on ONE
            # decoded line — preserves the "same status block" proximity model.
            | gsub("[\r\n]+"; " ")
            | select(length > 0)
        ' 2>/dev/null
}

# Background-task liveness (added 2026-05-22 — leverages Claude Code 2.1.145 feature).
# Hook input now includes a `background_tasks` array of currently-alive bg sessions.
# We extract the set of active SIDs (short 8-char form) to enable DEAD-worker
# detection in the parent-child propagation step: when a registered child has
# NO terminal_state AND its SID is not in active SIDs, the child crashed —
# we can propagate without stalling.
#
# Backward-compat: if the field is absent (older Claude Code versions),
# ACTIVE_SIDS will be empty and the dead-worker check is skipped — preserving
# the previous "wait forever for terminal_state" behavior.
ACTIVE_SIDS=$(echo "$INPUT" \
    | jq -r '.background_tasks // [] | .[] | .session_id // .sessionId // empty' 2>/dev/null \
    | awk '{print substr($0, 1, 8)}' \
    | sort -u)

# Evaluate each active goal. If ANY hits terminal, allow stop.
# If ALL are still pending, block stop with the most recent goal's reason.
BLOCK_REASON=""
ANY_TERMINAL=false

# PWT-SUP-YIELD-SID (2026-06-03): identity-based supervisor yield. The env-only
# PLAN_W_TEAM_SUPERVISOR_SESSION flag (checked far below) cannot exempt an ORIGIN
# chat that BECOMES a supervisor mid-session — it can't set its own launch env — so
# such a session was dragged into Stop-hook busy-poll every turn. PWT-WT2 worsened
# it: pwt-goal now reliably SEEDS the goal-state (with the owning worker's SID) into
# the launching checkout, so this hook always finds it for the origin session. Fix:
# only the OWNING worker (whose SID == the goal's worker_sid) must be blocked to run
# to terminal; any other session (supervisor/observer) yields and is re-woken
# event-driven by its background await-loop. SAFETY: a blocking goal with NO
# worker_sid (legacy / in-session /plan-w-team with no bg worker) is un-ownable →
# fail safe to BLOCK; an empty SELF_SID (older harness w/o .session_id) disables SID
# matching → BLOCK. The owning worker thus always blocks ("worker runs to terminal").
SELF_SID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
OWNS_BLOCKING=0             # this session IS the owning worker of some blocking goal
BLOCKING_GOAL_UNOWNABLE=0  # some blocking goal has no worker_sid → ownership unprovable

for GOAL_FILE in "${GOAL_FILES[@]}"; do
    if ! jq -e . "$GOAL_FILE" >/dev/null 2>&1; then
        # Corrupt state file — log and skip
        echo "[goal-evaluator] WARN: corrupt goal state at $GOAL_FILE; skipping" >&2
        continue
    fi

    SLUG=$(jq -r '.slug' "$GOAL_FILE")
    STARTED_AT=$(jq -r '.started_at' "$GOAL_FILE")
    EXISTING_TERMINAL=$(jq -r '.terminal_state // ""' "$GOAL_FILE")

    # Already marked terminal in a previous turn → allow stop.
    # Backward-compat escape hatch: a user/agent can write terminal_state
    # directly into the goal state file to force a graceful halt.
    #
    # C3 spoof-guard: inside a bg worker (--launch / --worker-only, marked by
    # PLAN_W_TEAM_DISABLE_PROMPT_ROUTE=1) this short-circuit is spoofable — the
    # worker's own LLM can jq-write terminal_state=SUCCESS to stop the /goal loop
    # while skipping the ship gate and AC AND-check. So in worker mode honor a
    # pre-existing terminal_state ONLY when the EVALUATOR itself wrote it
    # (terminal_state_source=evaluator, set on its write-back below). Interactive
    # sessions keep the unrestricted escape hatch — a human is watching. A human
    # halting a worker does so out-of-band (stop the bg session), not by trusting
    # the worker's own self-write. See audit C3.
    if [ -n "$EXISTING_TERMINAL" ]; then
        TERMINAL_SRC=$(jq -r '.terminal_state_source // ""' "$GOAL_FILE")
        if [ "${PLAN_W_TEAM_DISABLE_PROMPT_ROUTE:-}" = "1" ] && [ "$TERMINAL_SRC" != "evaluator" ]; then
            echo "[goal-evaluator] SLUG=$SLUG worker-mode spoof-guard: ignoring self-written terminal_state=$EXISTING_TERMINAL (no evaluator provenance) — continuing real detection" >&2
            dbg "SLUG=$SLUG worker-mode: un-provenanced terminal_state ignored (spoof guard)"
            # Do NOT short-circuit; fall through to real anchor detection.
        else
            dbg "SLUG=$SLUG already terminal_state=$EXISTING_TERMINAL (state-file short-circuit) → allowing stop"
            ANY_TERMINAL=true
            continue
        fi
    fi

    # Read recent transcript lines (last ~500) for anchor detection.
    #
    # SCAN is the union of two corpora:
    #   RAW     — the literal transcript tail (backward-compat: catches raw-form
    #             status blocks emitted via direct file-write paths).
    #   DECODED — jq-decoded text payloads, one per transcript entry, with
    #             escaped quotes unescaped (the FIX: catches status blocks
    #             stored inside assistant/user/tool message strings).
    #
    # Detectors match against SCAN so BOTH forms are detected. The slug-anchor
    # proximity defense is preserved because each DECODED entry is one logical
    # line — a status block's keys (stage/workflow_lock/slug, or
    # pending_escalations+slug, or low_confidence_routes+slug) all colocate on
    # that single line, so "same line" == "same status block".
    if [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
        RAW=$(tail -500 "$TRANSCRIPT_PATH" 2>/dev/null || echo "")
        DECODED=$(decode_transcript "$TRANSCRIPT_PATH")
        RECENT=$(printf '%s\n%s\n' "$RAW" "$DECODED")
        dbg "SLUG=$SLUG transcript=$TRANSCRIPT_PATH raw_lines=$(printf '%s' "$RAW" | grep -c '' || echo 0) decoded_lines=$(printf '%s' "$DECODED" | grep -c '' || echo 0)"
    else
        RECENT=""
        dbg "SLUG=$SLUG no transcript path (TRANSCRIPT_PATH='$TRANSCRIPT_PATH') — transcript detectors will be no-ops"
    fi

    TERMINAL=""
    REASON=""

    # (1) SUCCESS: status block with stage="retro-complete" AND workflow_lock="done"
    # PWT-T5b dogfood fix (2026-05-20): also require slug match to prevent
    # false positives from documentation/example text that mentions the
    # anchor strings. The status block always includes "slug":"<this-SLUG>".
    #
    # 2026-05-25 escaped-quote fix: all three anchors must colocate on the SAME
    # decoded line. Because decode_transcript emits one logical line per
    # transcript entry (newlines collapsed), a genuine status block's three
    # keys land together. Requiring same-line co-occurrence is the faithful
    # translation of "same status block" and is strictly stronger than the old
    # anywhere-in-corpus check — it prevents a documentation example that
    # mentions stage=retro-complete in one entry and this slug in an unrelated
    # entry from falsely combining into a SUCCESS.
    #
    # 2026-05-25 spacing fix: surface-status.sh emits PRETTY-PRINTED JSON
    # (`"stage": "retro-complete"` — colon-SPACE), and decode_transcript only
    # collapses newlines (not inner spacing), so the decoded block keeps the
    # `": "` form. A fixed-string grep for the compact `"stage":"retro-complete"`
    # never matched the real block — the very signal the retro emits. We use
    # space-tolerant ERE (`"key"[[:space:]]*:[[:space:]]*"val"`) which matches
    # BOTH compact (direct-write/tool-input) AND pretty-printed (status helper)
    # forms. The SLUG is safe-slugged (kebab `[a-z0-9-]`), so it carries no ERE
    # metacharacters.
    SLUG_RE="\"slug\"[[:space:]]*:[[:space:]]*\"${SLUG}\""
    if printf '%s\n' "$RECENT" \
         | grep -E '"stage"[[:space:]]*:[[:space:]]*"retro-complete"' \
         | grep -E '"workflow_lock"[[:space:]]*:[[:space:]]*"done"' \
         | grep -E "$SLUG_RE" >/dev/null 2>&1; then
        TERMINAL="SUCCESS"
        REASON="retro-complete status block emitted with workflow_lock=done for slug=$SLUG"
        dbg "(1) SUCCESS matched: stage=retro-complete + workflow_lock=done + slug=$SLUG colocated on one decoded line"

        # PWT-T5c: AND-check feature-specific done criteria
        CRITERIA_LEN=$(jq '.feature_specific_done_criteria // [] | length' "$GOAL_FILE")
        if [ "$CRITERIA_LEN" -gt 0 ]; then
            UNMET_DESCRIPTIONS=""
            NEW_CRITERIA=$(jq -c '.feature_specific_done_criteria' "$GOAL_FILE")
            for i in $(seq 0 $((CRITERIA_LEN - 1))); do
                PATTERN=$(echo "$NEW_CRITERIA" | jq -r ".[$i].pattern")
                ALREADY_MET=$(echo "$NEW_CRITERIA" | jq -r ".[$i].met")
                if [ "$ALREADY_MET" = "true" ]; then continue; fi
                # Validate regex compiles by attempting an empty-input grep
                if ! echo "" | grep -E "$PATTERN" >/dev/null 2>&1; then
                    : # grep returns 1 on no-match; ok. Real regex failure prints to stderr.
                fi
                if echo "$RECENT" | grep -E "$PATTERN" >/dev/null 2>&1; then
                    NEW_CRITERIA=$(echo "$NEW_CRITERIA" \
                        | jq --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
                             ".[$i].met = true | .[$i].met_at = \$ts")
                else
                    DESC=$(echo "$NEW_CRITERIA" | jq -r ".[$i].description")
                    UNMET_DESCRIPTIONS="${UNMET_DESCRIPTIONS}${UNMET_DESCRIPTIONS:+; }${DESC}"
                fi
            done
            # Persist updated criteria atomically
            jq --argjson c "$NEW_CRITERIA" '.feature_specific_done_criteria = $c' "$GOAL_FILE" \
                > "$GOAL_FILE.tmp" && mv "$GOAL_FILE.tmp" "$GOAL_FILE"
            if [ -n "$UNMET_DESCRIPTIONS" ]; then
                TERMINAL=""
                REASON=""
                # Will be picked up by the BLOCK_REASON branch below
                CRITERIA_BLOCK_REASON="Generic SUCCESS anchors present but feature-specific criteria unmet: ${UNMET_DESCRIPTIONS}. Continue pipeline until each criterion appears in transcript (typically as 'AC<N>: PASS' lines emitted by Step 5 review and Step 6 ship)."
            fi
        else
            # PWT-ANTIPARK (AC2) — empty/missing AC contract ≠ done while backlog remains.
            # An empty feature_specific_done_criteria array must NOT let the generic
            # retro-complete anchor trivially fire SUCCESS when the objective progress
            # snapshot reports an unmet backlog (the multi-epic program trap: epics
            # unbuilt, no AC contract, a stray retro-complete would otherwise win).
            # Fail-open: no snapshot / kill-switch → generic SUCCESS as today (T5b).
            AP_STATE=$(__antipark_state "$SLUG")
            if [ -n "$AP_STATE" ]; then
                AP_BK=$(echo "$AP_STATE" | awk '{print $1}')
                AP_BL=$(echo "$AP_STATE" | awk '{print $2}')
                if [ "${AP_BK:-0}" = "1" ] && [ "${AP_BL:-0}" -gt 0 ] 2>/dev/null; then
                    TERMINAL=""
                    REASON=""
                    CRITERIA_BLOCK_REASON="Generic SUCCESS anchors present but the feature-AC contract is EMPTY and objective backlog=${AP_BL} remains (supervisor-progress.json). An empty AC contract is treated as not-done while unblocked backlog remains (PWT-ANTIPARK AC2). Drain the backlog or encode remaining work as ACs, then re-emit retro-complete. Kill switch: PLAN_W_TEAM_DISABLE_ANTIPARK=1."
                    echo "[goal-evaluator] SLUG=$SLUG empty-AC-not-done: withholding SUCCESS (backlog=${AP_BL}, PWT-ANTIPARK)" >&2
                fi
            fi
        fi
    fi

    # C3 — deterministic ship-verdict corroboration (worker mode only).
    # Transcript anchors are assistant free-text a worker can fabricate. Inside a
    # bg worker, require Step 6 to have written a real PASS ship-verdict artifact
    # (only reachable after every §6 ENFORCING gate passed) before honoring
    # SUCCESS. Interactive runs keep transcript-only detection (human watching).
    if [ "$TERMINAL" = "SUCCESS" ] && [ "${PLAN_W_TEAM_DISABLE_PROMPT_ROUTE:-}" = "1" ]; then
        SHIP_VERDICT_FILE="$(dirname "$GOAL_FILE")/plan-w-team-ship-verdict-${SLUG}.json"
        if [ "$(jq -r '.verdict // ""' "$SHIP_VERDICT_FILE" 2>/dev/null)" != "PASS" ]; then
            TERMINAL=""
            REASON=""
            CRITERIA_BLOCK_REASON="Generic SUCCESS anchors present but no deterministic ship-verdict for slug=$SLUG. Step 6 writes .claude/state/plan-w-team-ship-verdict-${SLUG}.json with verdict=PASS only after every §6 ENFORCING gate passes; SUCCESS is withheld until it exists. Continue the pipeline through a real ship."
            echo "[goal-evaluator] SLUG=$SLUG worker-mode: SUCCESS anchors present but ship-verdict missing/!=PASS — withholding SUCCESS (C3 anti-spoof)" >&2
            dbg "SLUG=$SLUG worker-mode SUCCESS withheld — no PASS ship-verdict at $SHIP_VERDICT_FILE"
        fi
    fi

    if [ -z "$TERMINAL" ]; then
        dbg "(1) SUCCESS not matched: needed stage=retro-complete + workflow_lock=done + slug=$SLUG colocated on one decoded line"
    fi

    # (2) USER_ESCALATION_HALT: pending_escalations contains a hard-gate label
    # Slug-match defense: the status/summary block including the escalation MUST
    # carry "slug":"<SLUG>" within the same ~10 lines, otherwise the match is
    # likely from documentation text mentioning the site name.
    #
    # 2026-05-25 escaped-quote fix: $RECENT now includes the jq-decoded corpus,
    # so an escalation block emitted as escaped assistant text is matched. The
    # ±5-line window remains correct for both corpora: in DECODED text the
    # pending_escalations array and slug colocate on ONE line (well inside the
    # window); in RAW text a multi-line status block stays inside ±5 lines.
    if [ -z "$TERMINAL" ]; then
        # credential-wall (2026-06-02): a CLI non-interactive credential/token
        # wall hit during deploy/ship is a blocked-external operator escalation —
        # same shape as the browser-console REQ-5 gate. The credential-wall
        # detector hook emits a USER_ESCALATION_HALT block carrying
        # "pending_escalations":["credential-wall"], so the run halts for the
        # operator to provision the missing secret. Additive — the original three
        # hard-gate sites are unchanged.
        for SITE in push-ack secret-scan-allow scope-unlock-for-drift credential-wall; do
            # grep -B/-A scope: any pending_escalations line referencing $SITE
            # must have $SLUG within 10 lines (status block size).
            # Space-tolerant (2026-05-25): pretty-printed blocks render
            # `"pending_escalations": [ "push-ack" ]` with spaces; match both
            # compact and spaced via [[:space:]]* around colon and bracket.
            if echo "$RECENT" | grep -B5 -A5 -E "\"pending_escalations\"[[:space:]]*:[[:space:]]*\[[^]]*\"$SITE\"" \
                | grep -E "\"slug\"[[:space:]]*:[[:space:]]*\"$SLUG\"" >/dev/null 2>&1; then
                TERMINAL="USER_ESCALATION_HALT"
                REASON="hard-gate site '$SITE' in pending_escalations for slug=$SLUG — user must respond"
                dbg "(2) USER_ESCALATION_HALT matched: site=$SITE in pending_escalations within ±5 lines of slug=$SLUG"
                break
            fi
        done
        [ -z "$TERMINAL" ] && dbg "(2) USER_ESCALATION_HALT not matched: no hard-gate site (push-ack/secret-scan-allow/scope-unlock-for-drift) in pending_escalations within ±5 lines of slug=$SLUG"
    fi

    # (3) LOW_CONFIDENCE_STREAK: status block reports low_confidence_routes >= 3
    # Slug-match defense: extract low_confidence_routes values only from
    # transcript regions where this slug appears within ±5 lines.
    #
    # 2026-05-25 escaped-quote fix: same union-corpus + ±5-line-window
    # rationale as (2). Decoded lines colocate slug + low_confidence_routes.
    if [ -z "$TERMINAL" ]; then
        # Space-tolerant (2026-05-25): match both `"low_confidence_routes":N`
        # (compact) and `"low_confidence_routes": N` (pretty-printed). Extract
        # the trailing integer regardless of the colon spacing.
        MAX_LOW=$(echo "$RECENT" \
            | grep -B5 -A5 -E "\"slug\"[[:space:]]*:[[:space:]]*\"$SLUG\"" \
            | grep -oE '"low_confidence_routes"[[:space:]]*:[[:space:]]*[0-9]+' \
            | grep -oE '[0-9]+$' | sort -n | tail -1)
        if [ -n "$MAX_LOW" ] && [ "$MAX_LOW" -ge 3 ]; then
            TERMINAL="LOW_CONFIDENCE_STREAK"
            REASON="low_confidence_routes=$MAX_LOW (≥3 — supervisor confidence threshold breached)"
            dbg "(3) LOW_CONFIDENCE_STREAK matched: low_confidence_routes=$MAX_LOW within ±5 lines of slug=$SLUG"
        else
            dbg "(3) LOW_CONFIDENCE_STREAK not matched: max low_confidence_routes near slug=$SLUG = ${MAX_LOW:-none} (need ≥3)"
        fi
    fi

    # No (4) TIME_OR_TURN_CAP: removed by design. Only goal-success and hard-gate
    # escalations are valid terminal states (see shared/goal-conditions.md). If the
    # evaluator never returns success, the supervisor's low-confidence streak signal
    # (state 3) is the human-attention trigger, not a wall-clock or turn fallback.

    # (4) PARENT-CHILD PROPAGATION: when this goal has spawned workers (via
    # pwt-goal.sh --launch or similar), the worker's retro-complete anchors
    # land in the WORKER's transcript, not the parent's. Transcript-only
    # detection therefore stalls the parent indefinitely (2026-05-20 incident:
    # parent stalled 13 min after worker shipped).
    #
    # The spawned-children registry (.claude/state/plan-w-team-spawned-children-
    # <PARENT_SLUG>.jsonl) authoritatively records which workers this run
    # spawned. Each worker maintains its own goal state file. When every
    # registered worker has a non-null terminal_state, propagate the
    # worst-precedence state to the parent.
    #
    # Precedence (low → high severity):
    #   SUCCESS < LOW_CONFIDENCE_STREAK < USER_ESCALATION_HALT
    # A halted worker must halt the parent (surface to user). A clean worker
    # satisfies parent SUCCESS. Mixed signals win toward the more severe.
    #
    # Fail-open: missing/corrupt worker state never falsely terminates the
    # parent. Self-referential registry rows (slug == parent SLUG) are
    # skipped to prevent infinite hold-open.
    if [ -z "$TERMINAL" ]; then
        REGISTRY="${STATE_DIR}/plan-w-team-spawned-children-${SLUG}.jsonl"
        if [ ! -f "$REGISTRY" ] && [ "$STATE_DIR" != "$FALLBACK_STATE_DIR" ]; then
            REGISTRY="${FALLBACK_STATE_DIR}/plan-w-team-spawned-children-${SLUG}.jsonl"
        fi
        if [ -f "$REGISTRY" ]; then
            CHILD_SLUGS=$(jq -r 'select(.slug != null and .slug != "") | .slug' "$REGISTRY" 2>/dev/null \
                | sort -u)
            if [ -n "$CHILD_SLUGS" ]; then
                ALL_TERMINAL=true
                WORST_STATE=""
                WORST_REASON=""
                CHECKED_COUNT=0
                while IFS= read -r CHILD_SLUG; do
                    [ -z "$CHILD_SLUG" ] && continue
                    # Self-reference guard: prevent infinite hold-open if a
                    # registry row accidentally references the parent itself.
                    [ "$CHILD_SLUG" = "$SLUG" ] && continue

                    CHILD_STATE="${STATE_DIR}/plan-w-team-goal-${CHILD_SLUG}.json"
                    if [ ! -f "$CHILD_STATE" ] && [ "$STATE_DIR" != "$FALLBACK_STATE_DIR" ]; then
                        CHILD_STATE="${FALLBACK_STATE_DIR}/plan-w-team-goal-${CHILD_SLUG}.json"
                    fi

                    if [ ! -f "$CHILD_STATE" ]; then
                        # Child hasn't written its goal state yet — not terminal.
                        ALL_TERMINAL=false
                        continue
                    fi

                    if ! jq -e . "$CHILD_STATE" >/dev/null 2>&1; then
                        # Corrupt child state — warn and skip. Do NOT count
                        # toward ALL_TERMINAL=false; a corrupt file would
                        # otherwise pin the parent forever.
                        echo "[goal-evaluator] WARN: corrupt child state at $CHILD_STATE; skipping" >&2
                        continue
                    fi

                    CHILD_TERMINAL=$(jq -r '.terminal_state // ""' "$CHILD_STATE")
                    if [ -z "$CHILD_TERMINAL" ]; then
                        # 2.1.145 DEAD-worker detection: registry has the child's SID;
                        # if that SID is NOT in background_tasks AND the child has no
                        # terminal_state, the worker crashed without writing retro.
                        # Without this check, the parent stalls forever. Backward-compat:
                        # if ACTIVE_SIDS is empty (older Claude Code), skip → preserves
                        # original behavior of waiting for terminal_state.
                        CHILD_SID=$(jq -r 'select(.slug == "'"$CHILD_SLUG"'") | .session_id // ""' \
                            "$REGISTRY" 2>/dev/null | head -1 | cut -c1-8)
                        if [ -n "$ACTIVE_SIDS" ] && [ -n "$CHILD_SID" ] \
                           && ! echo "$ACTIVE_SIDS" | grep -qFx "$CHILD_SID"; then
                            # Worker dead, no terminal state → treat as LOW_CONFIDENCE
                            # so user investigates; do NOT pretend it succeeded.
                            # ALSO persist DEAD to the child's own goal file so this
                            # evaluator pass (and future ones) don't block on it.
                            DEAD_REASON="DEAD — SID $CHILD_SID not in background_tasks, no terminal_state written by worker"
                            jq --arg t "LOW_CONFIDENCE_STREAK" --arg r "$DEAD_REASON" \
                               --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
                               '.terminal_state = $t | .terminal_reason = $r | .terminated_at = $ts' \
                               "$CHILD_STATE" > "$CHILD_STATE.tmp" 2>/dev/null \
                                && mv "$CHILD_STATE.tmp" "$CHILD_STATE"
                            CHILD_TERMINAL="DEAD"
                            CHECKED_COUNT=$((CHECKED_COUNT+1))
                            if [ "$WORST_STATE" != "USER_ESCALATION_HALT" ]; then
                                WORST_STATE="LOW_CONFIDENCE_STREAK"
                                WORST_REASON="child SLUG=$CHILD_SLUG $DEAD_REASON"
                            fi
                            continue
                        fi
                        # 2026-05-29 API_HALT detection (additive, FAIL-SAFE): a worker
                        # that halted on a transient API/socket error is STILL listed in
                        # background_tasks (alive process, idle session), so the DEAD
                        # check above did NOT fire and it would otherwise block the parent
                        # forever. Classify API_HALT only when BOTH gates hold, so quoted
                        # error text in an ACTIVE transcript cannot false-positive:
                        #   (a) child transcript idle — mtime older than the threshold;
                        #   (b) last meaningful decoded turn matches a transient pattern.
                        # A healthy worker has recent mtime → gate (a) fails → IMMUNE.
                        # If the helper is absent or the transcript can't be resolved,
                        # this whole block no-ops and falls through to today's behavior.
                        if command -v pwt_is_transient_error >/dev/null 2>&1 \
                           && [ -n "$ACTIVE_SIDS" ] && [ -n "$CHILD_SID" ] \
                           && echo "$ACTIVE_SIDS" | grep -qFx "$CHILD_SID"; then
                            CT_BASE="${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}/$(printf '%s' "$PROJECT_ROOT" | sed 's#/#-#g')"
                            CHILD_TX=""
                            if [ -d "$CT_BASE" ]; then
                                for cand in "$CT_BASE/${CHILD_SID}"*.jsonl; do
                                    [ -f "$cand" ] && { CHILD_TX="$cand"; break; }
                                done
                            fi
                            if [ -n "$CHILD_TX" ]; then
                                NOW_EPOCH=$(date +%s)
                                TX_MTIME=$(stat -f %m "$CHILD_TX" 2>/dev/null || stat -c %Y "$CHILD_TX" 2>/dev/null || echo "$NOW_EPOCH")
                                IDLE_S=$(( NOW_EPOCH - TX_MTIME ))
                                IDLE_THRESH="${PWT_API_HALT_IDLE_S:-600}"
                                if [ "$IDLE_S" -ge "$IDLE_THRESH" ]; then
                                    LAST_MEANINGFUL=$(decode_transcript "$CHILD_TX" | grep -v '^[[:space:]]*$' | tail -1)
                                    if [ -n "$LAST_MEANINGFUL" ] && pwt_is_transient_error "$LAST_MEANINGFUL"; then
                                        HALT_REASON="API_HALT — child SID $CHILD_SID idle ${IDLE_S}s (>=${IDLE_THRESH}s) and last turn matches transient-connection pattern"
                                        jq --arg t "API_HALT" --arg r "$HALT_REASON" \
                                           --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
                                           '.terminal_state = $t | .terminal_reason = $r | .terminated_at = $ts' \
                                           "$CHILD_STATE" > "$CHILD_STATE.tmp" 2>/dev/null \
                                            && mv "$CHILD_STATE.tmp" "$CHILD_STATE" || rm -f "$CHILD_STATE.tmp" 2>/dev/null
                                        CHECKED_COUNT=$((CHECKED_COUNT+1))
                                        # Precedence: SUCCESS < API_HALT < LOW_CONFIDENCE_STREAK < USER_ESCALATION_HALT.
                                        if [ "$WORST_STATE" != "USER_ESCALATION_HALT" ] && [ "$WORST_STATE" != "LOW_CONFIDENCE_STREAK" ]; then
                                            WORST_STATE="API_HALT"
                                            WORST_REASON="child SLUG=$CHILD_SLUG $HALT_REASON"
                                        fi
                                        continue
                                    fi
                                fi
                            fi
                        fi
                        ALL_TERMINAL=false
                        continue
                    fi
                    CHECKED_COUNT=$((CHECKED_COUNT+1))

                    # Worst-precedence selection.
                    case "$CHILD_TERMINAL" in
                        USER_ESCALATION_HALT)
                            WORST_STATE="USER_ESCALATION_HALT"
                            WORST_REASON=$(jq -r '.terminal_reason // ""' "$CHILD_STATE")
                            ;;
                        LOW_CONFIDENCE_STREAK)
                            if [ "$WORST_STATE" != "USER_ESCALATION_HALT" ]; then
                                WORST_STATE="LOW_CONFIDENCE_STREAK"
                                WORST_REASON=$(jq -r '.terminal_reason // ""' "$CHILD_STATE")
                            fi
                            ;;
                        API_HALT)
                            # Recoverable (supervisor restarts bounded); ranks above
                            # SUCCESS but below LOW_CONFIDENCE_STREAK / USER_ESCALATION_HALT.
                            if [ "$WORST_STATE" != "USER_ESCALATION_HALT" ] && [ "$WORST_STATE" != "LOW_CONFIDENCE_STREAK" ]; then
                                WORST_STATE="API_HALT"
                                WORST_REASON=$(jq -r '.terminal_reason // ""' "$CHILD_STATE")
                            fi
                            ;;
                        SUCCESS)
                            if [ -z "$WORST_STATE" ]; then
                                WORST_STATE="SUCCESS"
                                WORST_REASON=$(jq -r '.terminal_reason // ""' "$CHILD_STATE")
                            fi
                            ;;
                    esac
                done <<< "$CHILD_SLUGS"

                if [ "$ALL_TERMINAL" = "true" ] && [ "$CHECKED_COUNT" -gt 0 ] && [ -n "$WORST_STATE" ]; then
                    TERMINAL="$WORST_STATE"
                    REASON="parent SLUG=$SLUG: all $CHECKED_COUNT spawned worker(s) terminal; worst-precedence=$WORST_STATE; worker_reason=$WORST_REASON"
                fi
            fi

            # (5) SUPERVISOR-MIRROR DEAD PROPAGATION: when a spawned-child
            # registry row has type=supervisor_mirror, its `path` field points
            # at an origin-side mirror goal-state file. If the worker's SID
            # (registry session_id) is NOT in background_tasks AND the mirror
            # is still non-terminal, the worker crashed without retro AND
            # without writing terminal_state to its OWN goal file. We must
            # propagate DEAD into the mirror so the origin chat's evaluator
            # stops waiting. See docs/specs/supervisor-mirror-lifecycle.md.
            #
            # This is a pure side-effect sweep — it does NOT modify the
            # current goal's TERMINAL/REASON. The patched mirror is itself
            # one of the GOAL_FILES iterated on subsequent evaluator passes
            # (via plan-w-team-goal-*.json glob), so its newly-set
            # terminal_state surfaces through normal EXISTING_TERMINAL.
            #
            # Backward-compat: when ACTIVE_SIDS is empty (older Claude Code
            # without background_tasks hook input), skip to preserve original
            # behavior — no mirror patches without authoritative liveness data.
            if [ -n "$ACTIVE_SIDS" ]; then
                while IFS= read -r MIRROR_ROW; do
                    [ -z "$MIRROR_ROW" ] && continue
                    MIRROR_PATH=$(printf '%s' "$MIRROR_ROW" | jq -r '.path // ""' 2>/dev/null)
                    MIRROR_SID=$(printf '%s' "$MIRROR_ROW" | jq -r '.session_id // ""' 2>/dev/null \
                        | cut -c1-8)
                    [ -z "$MIRROR_PATH" ] && continue
                    [ ! -f "$MIRROR_PATH" ] && continue
                    [ -z "$MIRROR_SID" ] && continue

                    MIRROR_EXISTING=$(jq -r '.terminal_state // ""' "$MIRROR_PATH" 2>/dev/null || echo "")
                    [ -n "$MIRROR_EXISTING" ] && continue

                    if ! echo "$ACTIVE_SIDS" | grep -qFx "$MIRROR_SID"; then
                        # Worker dead AND mirror non-terminal → propagate
                        # LOW_CONFIDENCE_STREAK so origin investigates.
                        MIRROR_DEAD_REASON="DEAD — supervisor_mirror worker SID $MIRROR_SID not in background_tasks, no terminal_state written by worker"
                        jq --arg t "LOW_CONFIDENCE_STREAK" --arg r "$MIRROR_DEAD_REASON" \
                           --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
                           '.terminal_state = $t | .terminal_reason = $r | .terminated_at = $ts' \
                           "$MIRROR_PATH" > "$MIRROR_PATH.tmp" 2>/dev/null \
                            && mv "$MIRROR_PATH.tmp" "$MIRROR_PATH" \
                            || rm -f "$MIRROR_PATH.tmp" 2>/dev/null
                        echo "[goal-evaluator] supervisor_mirror DEAD propagation: patched $MIRROR_PATH (worker $MIRROR_SID)" >&2
                    fi
                done < <(jq -c 'select(.type == "supervisor_mirror")' "$REGISTRY" 2>/dev/null)
            fi
        fi
    fi

    if [ -n "$TERMINAL" ]; then
        # Persist terminal state. terminal_state_source=evaluator is the C3
        # provenance marker: the worker-mode short-circuit guard above honors a
        # pre-existing terminal_state only when the evaluator (not the worker's
        # own LLM) wrote it.
        jq --arg t "$TERMINAL" --arg r "$REASON" --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
           '.terminal_state = $t | .terminal_reason = $r | .terminated_at = $ts | .terminal_state_source = "evaluator"' \
           "$GOAL_FILE" > "$GOAL_FILE.tmp" && mv "$GOAL_FILE.tmp" "$GOAL_FILE"
        ANY_TERMINAL=true
        echo "[goal-evaluator] SLUG=$SLUG terminal=$TERMINAL reason=$REASON" >&2
    else
        # Build a block reason combining condition status
        # PWT-T5c: prefer the specific criteria-unmet reason when it exists
        if [ -n "${CRITERIA_BLOCK_REASON:-}" ]; then
            BLOCK_REASON="$CRITERIA_BLOCK_REASON"
        else
            BLOCK_REASON="/plan-w-team SLUG=$SLUG not yet terminal. Continue pipeline. Need ONE of: status block with stage=retro-complete + workflow_lock=done; pending_escalations containing a hard-gate site (push-ack/secret-scan-allow/scope-unlock-for-drift); low_confidence_routes>=3."
        fi
        # PWT-SUP-YIELD-SID bookkeeping: this goal is BLOCKING — record whether THIS
        # session owns it. Match the goal's recorded worker_sid (8-hex short SID, see
        # pwt-goal PWT-WT2) against SELF_SID's prefix (session_id is a full UUID whose
        # first 8 chars are the short SID). No worker_sid → ownership unprovable.
        # Normalize (trim ALL whitespace + lowercase) so a malformed/padded worker_sid
        # can't slip past the fail-safe (adversarial verify CASE J: "  5de5b9ac" would
        # else make the GENUINE owner yield). Ownership is established ONLY by a
        # well-formed token starting with 8 hex chars; anything else (empty, short,
        # non-hex, was-whitespace) is UN-OWNABLE → fail safe to BLOCK, never yield.
        THIS_WORKER_SID=$(jq -r '.worker_sid // ""' "$GOAL_FILE" 2>/dev/null | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
        case "$THIS_WORKER_SID" in
            [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*)
                [ -n "$SELF_SID" ] && [ "${SELF_SID:0:8}" = "${THIS_WORKER_SID:0:8}" ] && OWNS_BLOCKING=1 ;;
            *)
                BLOCKING_GOAL_UNOWNABLE=1 ;;
        esac
        dbg "SLUG=$SLUG NOT terminal → blocking stop. reason=$BLOCK_REASON"
    fi
done

# PWT-ANTIPARK yield gate (2026-06-07) — promote feedback_supervisor_progress_objective
# from PROSE to an ENFORCED gate at the terminal-decision site. A supervisor session is
# normally allowed to YIELD (sleep) in the two branches below, on the assumption that its
# background await-loop will re-wake and re-dispatch. But when the objective progress
# snapshot says STALL-ALERT with backlog>0 (N flat ticks while unblocked work remains),
# a yield is a PARK — the exact 2026-06-07 cleanscale defect (run stopped with epics
# A/B/D/E/F unbuilt). Block it instead, so the supervisor is dragged back to RE-DISPATCH
# the next unblocked backlog item OR escalate a genuine hard-gate, never silently stop.
# The instant a dispatch moves a metric (commit/PR/AC) or touches a worktree, the
# progress verdict flips to PROGRESSING/IN-FLIGHT and the yield is permitted again
# (self-correcting). A single capability-blocked item (deploy token missing) is NOT one
# of the 3 registered hard-gates, so it never produces USER_ESCALATION_HALT and this gate
# keeps the run building the rest — single-item-blocker partitioning by construction.
# FAIL-OPEN: no snapshot / kill-switch (PLAN_W_TEAM_DISABLE_ANTIPARK=1) → ANTIPARK_BLOCK
# stays 0 and the yields behave byte-for-byte as before. This NEVER blocks a worker
# (workers don't take the yield path) and never relaxes an existing block or terminal.
ANTIPARK_BLOCK=0
if [ -n "$BLOCK_REASON" ]; then
    # $SLUG holds the last-iterated goal's slug (single-goal is the norm); the
    # slug-keyed snapshot read therefore scopes to this run only.
    AP_STATE=$(__antipark_state "$SLUG")
    if [ -n "$AP_STATE" ]; then
        AP_BK=$(echo "$AP_STATE" | awk '{print $1}')
        AP_BL=$(echo "$AP_STATE" | awk '{print $2}')
        AP_VERDICT=$(echo "$AP_STATE" | awk '{print $3}')
        if [ "${AP_BK:-0}" = "1" ] && [ "${AP_BL:-0}" -gt 0 ] 2>/dev/null && [ "$AP_VERDICT" = "STALL-ALERT" ]; then
            ANTIPARK_BLOCK=1
            BLOCK_REASON="ANTI-PARK: objective progress is STALL-ALERT with backlog=${AP_BL} unmet — a supervisor yield here would be a silent park (the 2026-06-07 incident). RE-DISPATCH the next unblocked backlog item OR escalate a genuine hard-gate (push-ack/secret-scan-allow/scope-unlock-for-drift); do NOT stop while safe unblocked work remains. Kill switch: PLAN_W_TEAM_DISABLE_ANTIPARK=1. (suppressed yield; original reason: ${BLOCK_REASON})"
            echo "[goal-evaluator] anti-park: STALL-ALERT + backlog=${AP_BL} → blocking supervisor yield (re-dispatch/escalate, PWT-ANTIPARK)" >&2
            dbg "anti-park engaged: verdict=$AP_VERDICT backlog=$AP_BL → ANTIPARK_BLOCK=1"
        fi
    fi
fi

# PWT-SUP-YIELD — a SUPERVISOR/origin session YIELDS instead of being blocked.
# A session that marks itself PLAN_W_TEAM_SUPERVISOR_SESSION=1 is SUPERVISING
# spawned workers, not driving a pipeline itself — its job is to WAIT. So it
# should be allowed to sleep (let Claude stop) and be re-woken EVENT-DRIVEN by
# its background await-loop (plan-w-team-await-terminal.sh) / ScheduleWakeup,
# rather than the goal-evaluator dragging it back to busy-poll every single turn
# (the friction observed 2026-06-02 in a live run). SAFETY INVARIANT — the
# owning WORKER never sets this flag: pwt-goal.sh forces PLAN_W_TEAM_SUPERVISOR_
# SESSION=0 into the worker's LAUNCH_ENV so it can't be inherited, so worker
# blocking is UNCHANGED ("the worker runs to terminal" holds by construction).
# All per-goal terminal detection + parent-child/mirror propagation above STILL
# ran this turn (a dead child is still propagated, a real terminal still
# persisted); only the final no-terminal-yet outcome flips block→yield, and only
# for the supervisor. The heartbeat re-arm in the await-loop still wakes the
# supervisor periodically to run its Step-0 progress/stall check, so a stalled
# worker is NOT masked.
if [ -n "$BLOCK_REASON" ] && [ "${PLAN_W_TEAM_SUPERVISOR_SESSION:-0}" = "1" ] && [ "$ANTIPARK_BLOCK" != "1" ]; then
    echo "[goal-evaluator] supervisor session (PLAN_W_TEAM_SUPERVISOR_SESSION=1) → yield, not block. Re-wake event-driven via plan-w-team-await-terminal.sh. (suppressed: $BLOCK_REASON)" >&2
    exit 0
fi

# PWT-SUP-YIELD-SID — identity-based supervisor yield (complements the env flag
# above). A session that owns NONE of the blocking goals — its SID differs from
# EVERY blocking goal's recorded worker_sid, and no blocking goal is un-ownable —
# is a supervisor/observer, not the worker driving a pipeline. It yields (lets
# Claude stop) and is re-woken event-driven by its background await-loop, exactly
# like an env-flagged supervisor. This fixes the mid-session supervisor that cannot
# set PLAN_W_TEAM_SUPERVISOR_SESSION in its launch env. The owning worker (SID
# match → OWNS_BLOCKING=1) and any un-ownable goal (no worker_sid →
# BLOCKING_GOAL_UNOWNABLE=1) still BLOCK, so "the worker runs to terminal" holds.
# ANTI-PARK GUARD (mirrors the env-flag path at the PWT-SUP-YIELD gate above): when
# objective progress is STALL-ALERT with unmet backlog (ANTIPARK_BLOCK=1), even a
# non-owning supervisor must NOT yield — that is the silent park the gate exists to
# prevent, and this SID path is the dominant mid-session origin-chat supervisor case
# (it cannot set PLAN_W_TEAM_SUPERVISOR_SESSION in its launch env), so without this
# guard the whole PWT-ANTIPARK protection is bypassed exactly where it matters most.
if [ -n "$BLOCK_REASON" ] && [ -n "$SELF_SID" ] \
   && [ "$OWNS_BLOCKING" = "0" ] && [ "$BLOCKING_GOAL_UNOWNABLE" = "0" ] \
   && [ "$ANTIPARK_BLOCK" != "1" ]; then
    echo "[goal-evaluator] non-owning session (SID ${SELF_SID:0:8} != every blocking goal's worker_sid) → supervisor yield, not block. Event-driven re-wake via plan-w-team-await-terminal.sh. (suppressed: $BLOCK_REASON)" >&2
    exit 0
fi

# Allow stop only if no pending blocks remain.
# (Previously: "if ANY_TERMINAL || no_block" — wrong. One goal going terminal
# must NOT suppress block emission for other still-pending goals. PWT-T5c
# dogfood fix: multi-goal isolation.)
if [ -z "$BLOCK_REASON" ]; then
    exit 0
fi

# Block stop — Claude continues with reason as guidance
jq -n --arg r "$BLOCK_REASON" '{"decision":"block","reason":$r}'
exit 0
