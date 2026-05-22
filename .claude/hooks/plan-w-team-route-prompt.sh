#!/usr/bin/env bash
# plan-w-team-route-prompt.sh
#
# UserPromptSubmit hook — defense-in-depth enforcement of the /plan-w-team
# routing rule. When the user's prompt contains a "use /plan-w-team to ..."
# trigger phrase (natural-language autonomous-run pattern), this hook spawns
# a bg WORKER via `pwt-goal.sh --worker-only` and injects `additionalContext`
# so the ORIGIN ASSISTANT TURN becomes the live supervisor (observes the
# worker, surfaces every stage transition / pause-site / supervisor decision
# / terminal block as native assistant messages in the origin transcript).
#
# This replaces the previous "block + spawn detached supervisor pair" behavior
# that left the origin chat silent between launch confirmation and any future
# user input. See docs/specs/pwt-origin-chat-live-supervisor.md (AC1).
#
# Backward compat (AC7): explicit shell `pwt-goal.sh --launch` (run outside a
# Claude Code chat) still spawns the worker+supervisor pair as before. Only
# the hook path changed.
#
# === FAIL-OPEN CONTRACT ===
# This hook MUST NEVER block the user from working. On any internal error
# (missing jq, missing pwt-goal.sh, malformed input, launch failure, syntax
# error, anything), exit 0 silently so the prompt flows through unchanged.
# The "block" exit (2) is reserved for the ONE confirmed-launch path.
#
# === DISABLE MECHANISMS (any of these) ===
#   1. env: export PLAN_W_TEAM_DISABLE_PROMPT_ROUTE=1
#   2. sentinel: touch .claude/.pwt-route-disabled
#   3. settings: remove this hook entry from .claude/settings.json
#
# Do NOT disable by renaming this file — settings.json keeps the reference
# and Claude Code's hook runner exits 127, breaking every prompt. (This is
# the failure mode that made 1b4a64e dangerous.)
#
# === TRIGGER DETECTION (UNANCHORED — natural-language sacred) ===
# Trigger phrases fire anywhere in the prompt. Natural language is the
# user's product principle for /plan-w-team — they must be able to say
# "now lets test it, use /plan-w-team to ..." or "based on our analysis,
# use /plan-w-team to ..." and have it route. No position anchoring, no
# pleasantry-only prefix lists, no content-keyword exclusions. The trigger
# phrase list itself is specific enough ("use /plan-w-team to" etc.) to
# keep false positives low. The only OPT-OUT mechanisms are:
#   1. in-session phrases ("in this session", "run /plan-w-team here")
#   2. sentinel file (.claude/.pwt-route-disabled)
#   3. env var (PLAN_W_TEAM_DISABLE_PROMPT_ROUTE=1)
#   4. removing the entry from settings.json

set -u

# ─── Fail-open guard: any unexpected error → exit 0 (allow) ──────────────────
fail_open() { exit 0; }
trap fail_open ERR

# ─── Kill switches (env + sentinel file) ─────────────────────────────────────
[ "${PLAN_W_TEAM_DISABLE_PROMPT_ROUTE:-}" = "1" ] && exit 0

PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." 2>/dev/null && pwd)}"
[ -z "$PROJECT_ROOT" ] && exit 0
[ -f "$PROJECT_ROOT/.claude/.pwt-route-disabled" ] && exit 0

# ─── Read stdin (hook contract) ──────────────────────────────────────────────
INPUT=$(cat 2>/dev/null || echo '{}')

# ─── Extract prompt: jq → python3 → grep+sed (graceful fallback chain) ───────
PROMPT=""
PARENT_SID_FROM_HOOK=""
if command -v jq >/dev/null 2>&1; then
    PROMPT=$(echo "$INPUT" | jq -r '.prompt // empty' 2>/dev/null || echo "")
    PARENT_SID_FROM_HOOK=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || echo "")
fi
if [ -z "$PROMPT" ] && command -v python3 >/dev/null 2>&1; then
    PROMPT=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('prompt',''))" 2>/dev/null || echo "")
fi
if [ -z "$PARENT_SID_FROM_HOOK" ] && command -v python3 >/dev/null 2>&1; then
    PARENT_SID_FROM_HOOK=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('session_id',''))" 2>/dev/null || echo "")
fi
if [ -z "$PROMPT" ]; then
    PROMPT=$(echo "$INPUT" | grep -oE '"prompt"[[:space:]]*:[[:space:]]*"([^"\\]|\\.)*"' \
        | head -1 | sed -E 's/^"prompt"[[:space:]]*:[[:space:]]*"//; s/"$//; s/\\"/"/g; s/\\n/ /g' \
        2>/dev/null || echo "")
fi

# Normalize parent sid to first 8 chars (matches pwt-launches.jsonl convention)
[ -n "$PARENT_SID_FROM_HOOK" ] && PARENT_SID_FROM_HOOK="${PARENT_SID_FROM_HOOK:0:8}"

# No prompt → allow
[ -z "$PROMPT" ] && exit 0

# ─── Slash-command guard (RECURSION-CRITICAL) ────────────────────────────────
# If the prompt starts with a slash, it is an explicit skill/command
# invocation, NOT natural-language routing. NEVER re-route slash commands.
#
# Critical recursion case: pwt-goal.sh --launch spawns `claude --bg` with
# bootstrap text "/goal Use /plan-w-team to <REQUEST>". That child session's
# UserPromptSubmit hook fires on this very text. Without this guard, the
# child detects "use /plan-w-team to" and launches ANOTHER claude --bg with
# the request re-wrapped — an infinite cascade observed in production on
# 2026-05-20 (19 background agents accumulated before discovery).
#
# Allowing leading whitespace before "/" handles indented bootstraps.
#
# System-injected event prefixes (`<task-notification>`, `<system-reminder>`,
# `<command-*>`, `<bash-*>`, `<user-prompt-submit-hook>`) are also bypassed.
# These are NOT user prompts — they are tool-result events, command-stdout
# wrappers, and hook-injected context that Claude Code surfaces as new turns.
# Their bodies can echo arbitrary user content (e.g. a Monitor watcher
# tailing pwt-launches.jsonl re-emits the original "use /plan-w-team to ..."
# request inside its event payload). Without this guard, the route hook
# treats the event echo as a fresh natural-language launch trigger and
# spawns yet another worker — the recursion path observed in production on
# 2026-05-21 (worker bf7cf4e2 spawned with a <task-notification>-prefixed
# prompt; see docs/specs/pwt-recursion-stale-cleanup.md for the disk
# evidence).
TRIMMED=$(printf '%s' "$PROMPT" | sed -E 's/^[[:space:]]+//')
case "$TRIMMED" in
    /*) exit 0 ;;
    "<task-notification>"*) exit 0 ;;
    "<system-reminder>"*) exit 0 ;;
    "<command-name>"*) exit 0 ;;
    "<command-message>"*) exit 0 ;;
    "<command-args>"*) exit 0 ;;
    "<local-command-stdout>"*) exit 0 ;;
    "<local-command-stderr>"*) exit 0 ;;
    "<bash-stdout>"*) exit 0 ;;
    "<bash-stderr>"*) exit 0 ;;
    "<user-prompt-submit-hook>"*) exit 0 ;;
esac

# ─── Unanchored trigger detection ────────────────────────────────────────────
# Trigger phrases match anywhere in the prompt. Natural language for any
# effort is the product principle. Trust the specificity of the trigger
# phrase list ("use /plan-w-team to" etc.) to keep false positives low,
# and trust opt-out mechanisms for the edge cases.
PROMPT_LC=$(printf '%s' "$PROMPT" | tr '[:upper:]' '[:lower:]')

MATCHED_PATTERN=""
for pat in \
    "use /plan-w-team to " \
    "use our /plan-w-team to " \
    "using /plan-w-team " \
    "with /plan-w-team " \
    "kick off /plan-w-team " \
    "kick off a /plan-w-team " \
    "start a /plan-w-team run " \
    "start /plan-w-team " \
    "run /plan-w-team to "; do
    if printf '%s' "$PROMPT_LC" | grep -qF "$pat"; then
        MATCHED_PATTERN="$pat"
        break
    fi
done

# Combined trigger: ("definition of done" OR "done when") + "/plan-w-team"
# anywhere in prompt. Documented in CLAUDE.md + skill manifest as a trigger
# for autonomous-run intent. Restored from 1b4a64e (dropped in 904759f rewrite).
if [ -z "$MATCHED_PATTERN" ]; then
    if printf '%s' "$PROMPT_LC" | grep -qF "/plan-w-team"; then
        if printf '%s' "$PROMPT_LC" | grep -qE "(definition of done|done when)"; then
            MATCHED_PATTERN="definition-of-done+/plan-w-team"
        fi
    fi
fi

# No trigger → allow
[ -z "$MATCHED_PATTERN" ] && exit 0

# ─── In-session opt-in: explicit override ────────────────────────────────────
for opt in \
    "in this session" \
    "right now in this session" \
    "run /plan-w-team here" \
    "invoke /plan-w-team in this session" \
    "/plan-w-team here in this session"; do
    if printf '%s' "$PROMPT_LC" | grep -qF "$opt"; then
        exit 0
    fi
done

# ─── Intent classifier (BUG 1 fix — see docs/specs/pwt-route-hook-fixes.md) ──
# The unanchored substring match above is intentionally broad to keep
# natural-language entry sacred (memory: feedback_pwt_routing_natural_lang_absolute).
# But that broadness produces false positives on questions, descriptions,
# and bug-doc references that merely mention the trigger phrase. The
# classifier below runs POST-MATCH to distinguish imperative (LAUNCH)
# from descriptive/interrogative (SKIP).
#
# Fail-closed contract: if python3 is missing or the classifier errors,
# SKIP launch (no false positive). The user can re-phrase with an
# explicit start-of-prompt trigger to force the launch. This inverts
# the file-level fail-open contract for this specific decision point
# because a false-positive launch is the documented harm we're fixing.
#
# If signals are ambiguous (low confidence), the hook EMITS an
# additionalContext block explaining the ambiguity and SKIPS the launch,
# letting the origin assistant decide how to surface it.
if command -v python3 >/dev/null 2>&1; then
    CLASSIFIER_OUT=$(
        PWT_PROMPT="$PROMPT" PWT_MATCHED="$MATCHED_PATTERN" \
        python3 - <<'CLPY' 2>/dev/null
import os, re, sys, json

prompt = os.environ.get("PWT_PROMPT", "")
matched = os.environ.get("PWT_MATCHED", "")

# Phrases that mark the matched text as DESCRIPTIVE rather than imperative
METAPHRASES = [
    "my idea", "my plan", "the idea is", "the plan was",
    "the doc says", "the spec says", "the manifest says", "the manifest's",
    "bug 1:", "bug 2:", "bug 3:", "bug n:",
    "for example", "for instance", "e.g.", "such as",
    "he said", "she said", "they said", "user said", "the user said",
    "i was thinking", "we were thinking",
    "phrase is", "substring-matches", "substring matches",
    "literal:", "pattern:", "verbatim:",
]

# Close-range negation (must be within ~30 chars of the verb)
NEGATIONS = [
    "don't ", "do not ", "shouldn't ", "should not ",
    "wouldn't ", "would not ", "won't ", "will not ", "never ",
]

# Modals that turn an imperative-looking clause into a hypothetical
HYPOTHETICALS = ["would", "could", "should", "might", "may"]

# Conditional / interrogative-conjunctive starters
CONDITIONALS = [" if ", " whether ", " unless "]

# Determiners that mark "/plan-w-team" as a noun reference, not a verb object
DETERMINERS = ["the ", "a ", "an ", "our ", "this ", "that ", "its ", "any "]


def is_inside_quote(s, pos):
    """True if position pos of s falls inside a quoted span (' " or `)."""
    in_single = in_double = in_back = False
    i = 0
    while i < pos and i < len(s):
        ch = s[i]
        if ch == "\\" and i + 1 < len(s):
            i += 2
            continue
        if ch == "'" and not in_double and not in_back:
            in_single = not in_single
        elif ch == '"' and not in_single and not in_back:
            in_double = not in_double
        elif ch == "`" and not in_single and not in_double:
            in_back = not in_back
        i += 1
    return in_single or in_double or in_back


def classify(prompt, matched):
    p_lc = prompt.lower()
    if matched.startswith("definition-of-done"):
        anchor = "/plan-w-team"
    else:
        anchor = matched.rstrip().lower()

    pos = p_lc.find(anchor)
    if pos < 0:
        return ("low", "anchor not found in prompt")

    # 1. Embedded quote → descriptive
    if is_inside_quote(prompt, pos):
        return ("high-descriptive", "match is inside a quoted span")

    # 2. Slice the clause that contains the match
    pre_full = p_lc[:pos]
    last_term = max(pre_full.rfind("."), pre_full.rfind("?"),
                    pre_full.rfind("!"), pre_full.rfind("\n"))
    preceding = pre_full[last_term + 1:].strip() if last_term >= 0 else pre_full.strip()

    # 80/40-char windows. Use pre_full (un-stripped) so trailing whitespace
    # is preserved for word-boundary checks against patterns ending in a space.
    recent = pre_full[-80:]
    near = pre_full[-40:]

    # 3. Metaphrase / descriptor markers
    for m in METAPHRASES:
        if m in recent:
            return ("high-descriptive", "metaphrase: %r" % m)

    # 4. Negation close to the verb
    for n in NEGATIONS:
        if n in near:
            return ("high-descriptive", "negation: %r" % n.strip())

    # 5. Hypothetical modal directly preceding the trigger verb (within 20 chars)
    for mod in HYPOTHETICALS:
        if re.search(r"\b" + re.escape(mod) + r"\b[^.?!]{0,20}$", near):
            return ("high-descriptive", "hypothetical modal: %r" % mod)

    # 6. Conditional / interrogative conjunction in the clause
    pre_padded = " " + preceding + " "
    for c in CONDITIONALS:
        if c in pre_padded:
            return ("high-descriptive", "conditional: %r" % c.strip())

    # 7. Interrogative: '?' follows the matched anchor anywhere in the prompt
    if "?" in prompt[pos:]:
        return ("high-descriptive", "interrogative: '?' follows match")

    # 8. Noun-reference: determiner immediately precedes "/plan-w-team"
    # Check pre_full (not the stripped clause) so trailing space matters.
    if anchor == "/plan-w-team":
        for art in DETERMINERS:
            if pre_full.endswith(art):
                return ("high-descriptive", "noun-reference: determiner %r" % art.strip())

    # 9. Default → imperative
    return ("high-imperative", "no skip signals; imperative interpretation")


verdict, reason = classify(prompt, matched)
print(verdict + "\t" + reason)
CLPY
    )
    CLASSIFIER_VERDICT=$(printf '%s' "$CLASSIFIER_OUT" | cut -f1)
    CLASSIFIER_REASON=$(printf '%s' "$CLASSIFIER_OUT" | cut -f2-)
else
    # python3 missing → fail closed (no spawn). False positive is the harm.
    CLASSIFIER_VERDICT="missing-python"
    CLASSIFIER_REASON="python3 not available; skipping launch for safety"
fi

case "$CLASSIFIER_VERDICT" in
    high-imperative)
        # Continue to launcher. No change to existing behavior.
        :
        ;;
    high-descriptive|missing-python)
        # Skip launch. The prompt was descriptive/interrogative or the
        # classifier could not run. Exit silently (no additionalContext —
        # the origin assistant doesn't need to know about a phantom
        # trigger that was correctly suppressed).
        exit 0
        ;;
    low|*)
        # Uncertain → emit additionalContext explaining the ambiguity and
        # SKIP the launch. The origin assistant can surface it to the user.
        PWT_CLASS_REASON="$CLASSIFIER_REASON" \
        PWT_CLASS_MATCH="$MATCHED_PATTERN" \
        python3 - <<'AMBIPY' 2>/dev/null || exit 0
import json, os
reason = os.environ.get("PWT_CLASS_REASON", "ambiguous")
matched = os.environ.get("PWT_CLASS_MATCH", "")
msg = (
    "/plan-w-team route hook: ambiguous trigger.\n"
    "The substring %r matched, but the intent classifier could not "
    "determine if the user meant to LAUNCH or merely REFERENCE the "
    "command (reason: %s). No worker was spawned. If you intended to "
    "launch, re-phrase with a clear imperative (e.g., "
    '"Use /plan-w-team to <verb> <object>") at the start of a new turn.'
) % (matched, reason)
print(json.dumps({"additionalContext": msg}))
AMBIPY
        exit 0
        ;;
esac

# ─── Locate launcher; fail open if missing ───────────────────────────────────
PWT_GOAL="$PROJECT_ROOT/.claude/scripts/pwt-goal.sh"
[ -x "$PWT_GOAL" ] || exit 0

# ─── Foreground worker spawn (--worker-only mode) ────────────────────────────
# We need the worker SID *before* returning so the additionalContext payload
# can hand it to the origin assistant. `pwt-goal.sh --worker-only` runs
# `claude --bg` synchronously and emits "worker_sid=<SID>" on stdout. The
# whole call typically completes in <1.5s. We CANNOT background this and
# poll a log file like the old --launch path because the hook must return
# the SID in its response payload.
LOG_DIR="$PROJECT_ROOT/.claude/state/pwt-launch-logs"
mkdir -p "$LOG_DIR" 2>/dev/null || true
TS=$(date +%Y%m%d-%H%M%S)
LOG_FILE="$LOG_DIR/launch-$TS-$$.log"

# Run synchronously, capture stdout + stderr. PWT_PARENT_SID lets pwt-goal.sh
# record the chain (worker.parent_sid = origin chat sid) so the statusline
# classifies it as "mine".
PWT_GOAL_OUT=$(
    PWT_PARENT_SID="$PARENT_SID_FROM_HOOK" \
        "$PWT_GOAL" --worker-only "$PROMPT" 2>"$LOG_FILE.err" </dev/null
)
PWT_GOAL_RC=$?
# Mirror everything to a log file for debugging.
{
    echo "=== pwt-goal --worker-only (exit $PWT_GOAL_RC) ==="
    echo "$PWT_GOAL_OUT"
    echo "=== stderr ==="
    cat "$LOG_FILE.err" 2>/dev/null
} > "$LOG_FILE" 2>/dev/null || true
rm -f "$LOG_FILE.err" 2>/dev/null || true

# Parse worker SID from machine-readable line.
SESSION_ID=$(printf '%s\n' "$PWT_GOAL_OUT" \
    | grep -oE '^worker_sid=[a-f0-9]{8}' \
    | head -1 | cut -d= -f2 || echo "")

# Worker spawn failed → fail open so the origin assistant gets the unmodified
# prompt and can fall back to its skill-level routing.
[ -z "$SESSION_ID" ] && exit 0

# ─── Spawn completion watcher (macOS desktop notification on finish) ─────────
# Skipped in test mode — the watcher polls real jobs dirs which won't exist
# for fake session IDs and would either hang or pollute /tmp.
WATCHER="$PROJECT_ROOT/.claude/scripts/pwt-watch.sh"
if [ -x "$WATCHER" ] && [ "${PLAN_W_TEAM_HOOK_TEST_MODE:-}" != "1" ]; then
    nohup "$WATCHER" "$SESSION_ID" >/dev/null 2>&1 </dev/null &
    disown $! 2>/dev/null || true
fi

# ─── Emit non-blocking response with supervisor protocol ─────────────────────
# The origin assistant turn proceeds normally; additionalContext is injected
# alongside the user's prompt with instructions to act as the live supervisor.
PWT_MATCHED="$MATCHED_PATTERN" \
PWT_LOG="$LOG_FILE" \
PWT_SID="$SESSION_ID" \
PWT_PROMPT="$PROMPT" \
PWT_PROJECT_ROOT="$PROJECT_ROOT" \
python3 - <<'PYEOF' 2>/dev/null || exit 0
import json, os
matched      = os.environ.get("PWT_MATCHED", "?").strip()
log          = os.environ.get("PWT_LOG", "?")
sid          = os.environ.get("PWT_SID", "").strip()
prompt       = os.environ.get("PWT_PROMPT", "")
project_root = os.environ.get("PWT_PROJECT_ROOT", "")

# === Supervisor protocol injected into the origin assistant's context. ======
# Written as a single multi-line string. The origin assistant reads this on
# the same turn as the user's prompt and is expected to follow it.
protocol = f"""=== /plan-w-team origin-chat supervisor protocol (PWT-O1) ===

The user's prompt matched the natural-language /plan-w-team trigger pattern:
    '{matched}'

A background WORKER session has already been spawned to execute the
/plan-w-team pipeline for the user's request. Your job for the remainder of
THIS assistant turn is to act as the LIVE SUPERVISOR, surfacing every
worker state transition as a native assistant message in this transcript.

DO NOT re-invoke /plan-w-team. DO NOT call pwt-goal.sh. The worker is
already running.

Worker context:
- Worker session ID: {sid}
- User's literal request:
    {prompt!r}
- Launch log: {log}
- Project root: {project_root}

Supervisor responsibilities (perform in order, this turn):

1. STATUS BLOCK (AC3): Within your next message, emit a visible status
   block to the transcript:

       🚀 /plan-w-team routed → bg worker {sid}
          watching for stage transitions, pause-sites, supervisor decisions

   This MUST appear within one assistant turn of receiving this context.

2. POLLING LOOP (AC4): Observe worker state by polling, surfacing every
   transition as an assistant message. Use these primitives:
     - `claude agents --json` — worker liveness + stage hint
     - `claude logs {sid} --tail 200` — worker transcript tail
     - `{project_root}/.claude/state/plan-w-team-goal-*.json` —
       feature-specific terminal state for the active SLUG
     - `{project_root}/.claude/state/pwt-completion-summary-{sid}.md` —
       written by ship/retro stages on success/halt

   Cadence: poll every ~30-60s via Bash + sleep, or schedule the next poll
   via ScheduleWakeup (preferred for runs >5min — avoids cache burn).
   Surface every NEW stage transition, pause-site, and supervisor decision
   to the transcript with a short status block. Do NOT echo unchanged state.

3. ESCALATION (AC6): If the worker hits a hard-gate pause site
   (`push-ack`, `secret-scan-allow`, `scope-unlock-for-drift`) or logs 3
   consecutive `confidence=low` supervisor decisions, surface it as a
   ⚠ HALT block and STOP polling — the user must respond.
   Note: PLAN_W_TEAM_AUTO_APPROVE_PUSH=1 (set by --worker-only) auto-clears
   the push-ack gate inside the worker; you'll see worker progress past it
   without a halt — that's expected.

4. TERMINAL BLOCK (AC5): When the worker reaches a terminal state
   (SUCCESS / ESCALATION / DEAD), emit a final summary block:

       ✅ /plan-w-team terminal: <SUCCESS|ESCALATION|DEAD>
          worker {sid}
          duration: <start→end>
          AC verdict: <pass/fail counts from spec>
          files changed: <stat>
          next action: <imperative>

   Also write the same content to
   `{project_root}/.claude/state/pwt-completion-summary-{sid}.md` so the
   existing `plan-w-completion-surface.sh` hook can archive it for the
   user's next session.

5. EXIT: After the terminal block, you are done. Do not continue polling.

Hard rules:
- NEVER edit code, configs, or specs. The worker does all implementation.
- NEVER spawn additional bg agents.
- NEVER push to remote — that is the worker + user's responsibility.
- If `claude agents --json` no longer lists session {sid} for >2 polls,
  treat it as DEAD and emit the terminal block.

The `pwt-completion-summary-{sid}.md` artifact and the macOS completion
notification are unchanged from prior surfacing work — they continue to
fire as additional channels alongside your live transcript updates.

=== end protocol ==="""

sysmsg = (
    f"🚀 /plan-w-team origin-chat supervisor active\n"
    f"   worker:  {sid}\n"
    f"   trigger: {matched}\n"
    f"   log:     {log}\n\n"
    f"The origin assistant will surface worker progress as transcript "
    f"messages until terminal state."
)

msg = {
    # NOTE: no "decision" field → prompt flows through, assistant turn runs.
    "additionalContext": protocol,
    "systemMessage": sysmsg,
}
print(json.dumps(msg))
PYEOF
exit 0
