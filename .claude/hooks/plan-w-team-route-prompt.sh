#!/usr/bin/env bash
# plan-w-team-route-prompt.sh
#
# UserPromptSubmit hook — defense-in-depth enforcement of the /plan-w-team
# routing rule. When the user's prompt contains a "use /plan-w-team to ..."
# trigger phrase (natural-language autonomous-run pattern), this hook spawns
# a bg WORKER via `pwt-goal.sh --supervisor-goal` (a strict superset of
# --worker-only: same SID emission + AUTO_PUSH=1 implication, plus an
# origin-side goal-state mirror) and injects `additionalContext` so the
# ORIGIN ASSISTANT TURN becomes the live supervisor (observes the worker,
# surfaces every stage transition / pause-site / supervisor decision
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
# ⚠ DELIVERY NONDETERMINISM (F6, 2026-08-18 cleanscale incident): this hook's
# firing is NOT observable from the origin session's context alone — in BOTH
# directions. (1) The systemMessage it emits can be silently dropped by the
# harness (observed: a trigger turn whose context contained no hook message at
# all, same failure class as the documented additionalContext drop). (2) The
# hook can silently NOT fire for a trigger that arrives MID-TURN (queued and
# delivered alongside a tool result — evidently bypassing UserPromptSubmit),
# then fire normally on a later fresh prompt. Consequence: nothing downstream
# may infer "the hook did/didn't spawn" from context. The authoritative record
# is the hook-spawn FLAG FILE this hook writes to disk
# (.claude/state/plan-w-team-hook-spawn-<parent_sid8>.flag) — manifest Step 3a
# (F1) reads it before any manual spawn, and pwt-goal.sh's PWT-DS1 guard
# enforces it process-level (same-origin wide window + liveness + audit).
#
# LIMITATION: UserPromptSubmit hooks do NOT fire on mid-work interrupt
# prompts — interrupts bypass this hook and must be routed manually (after
# a double-spawn check).
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

# ─── pwt bg-bootstrap sentinel guard (item 6 / defect e — phantom lanes) ─────
# Recognize a /plan-w-team bg BOOTSTRAP prompt by CONTENT and never route it,
# INDEPENDENT of any env flag. The env kill switch above
# (PLAN_W_TEAM_DISABLE_PROMPT_ROUTE) is NOT reliable for a daemon-hosted
# `claude --bg` session: F1 (2026-09-01) measured that a `--bg` worker/supervisor
# is forked by the bg daemon and inherits the DAEMON's env, not the launcher's —
# so PLAN_W_TEAM_DISABLE_PROMPT_ROUTE set by pwt-goal.sh may never reach the
# forked session. The supervisor bootstrap is the live vector: it starts with
# `#` (bypasses the slash-guard above) and embeds the verbatim user request
# ("Use /plan-w-team to …"), so without an env-independent signal this hook would
# re-trigger inside the supervisor and spawn a phantom lane (the 2026-05-21
# cascade class). pwt-goal.sh writes this sentinel into EVERY bg bootstrap it
# emits (worker goal text + supervisor bootstrap); the prompt text always crosses
# to the forked session (argv is the one channel F1 confirms crosses), so the
# sentinel is authoritative where the env flag is not. Recognition is by content
# here, never by env flag alone (item 6 requirement).
case "$PROMPT" in
    *PWT-BOOTSTRAP-DO-NOT-ROUTE*) exit 0 ;;
esac

# ─── Unanchored trigger detection ────────────────────────────────────────────
# Trigger phrases match anywhere in the prompt. Natural language for any
# effort is the product principle. Trust the specificity of the trigger
# phrase list ("use /plan-w-team to" etc.) to keep false positives low,
# and trust opt-out mechanisms for the edge cases.
PROMPT_LC=$(printf '%s' "$PROMPT" | tr '[:upper:]' '[:lower:]')

# Trigger match (W3, 2026-07-16 — widened from a fixed exact-substring list).
#
# The old list was nine literal `grep -qF` substrings ("use /plan-w-team to ",
# …). Any interpolated word broke every one of them: the real prompt
#   "Use the /plan-w-team skill to evaluate and improve …"
# produced NO route at all — no launch-log entry, no systemMessage, no trace —
# because "the … skill" sits between "use" and "to", and the prompt carried no
# "definition of done"/"done when" for the combined trigger below. Routing had
# to be done by hand, which is the gap: natural language is the interface, so
# the matcher must tolerate ordinary English, not a memorised phrase list.
#
# TWO alternations, each PRESERVING the old list's semantics for its verb class
# and adding only tolerance for interpolated articles/nouns:
#
#   A. (use|run) [the|our|a|an|your] /plan-w-team [skill|run|…] <to|for> …
#      to/for REQUIRED — matching the old "use /plan-w-team to ",
#      "use our /plan-w-team to ", "run /plan-w-team to ". Keeps a bare
#      question ("should I use /plan-w-team?") from spawning, as before.
#
#   B. (using|with|via|start|kick off|launch) [the|our|…] /plan-w-team …
#      to/for OPTIONAL — matching the old "using /plan-w-team ",
#      "with /plan-w-team ", "start /plan-w-team ", "kick off /plan-w-team ",
#      which never required it. Narrowing these would DROP live triggers.
#
# The leading verb is what keeps a casual mention from spawning: "/plan-w-team
# is the orchestrator", "I like how /plan-w-team works", "Read the /plan-w-team
# docs" all put no trigger verb before the token. Unanchored by design — the
# intent can appear at any position, after any pleasantry, with no content-word
# guard (natural language is the interface).
__PWT_ART='((the|our|a|an|your)[[:space:]]+)?'
__PWT_NOUN='([[:space:]]+(skill|run|workflow|pipeline))?'
TRIGGER_RE="((use|used|run)[[:space:]]+${__PWT_ART}/plan-w-team${__PWT_NOUN}[[:space:]]+(to|for)[[:space:]])|((using|with|via|start|starting|kick off|kicking off|launch|launching|running)[[:space:]]+${__PWT_ART}/plan-w-team${__PWT_NOUN}([[:space:]]|\$))"

MATCHED_PATTERN=""
if printf '%s\n' "$PROMPT_LC" | grep -qE "$TRIGGER_RE"; then
    MATCHED_PATTERN=$(printf '%s\n' "$PROMPT_LC" | grep -oE "$TRIGGER_RE" | head -1)
fi

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

# ─── PARALLEL-WORKER GATE (PWG) ──────────────────────────────────────────────
# Defense against the 2026-05-22 cleanscale incident: while a /plan-w-team
# worker is actively running, the user types a fresh imperative trigger. The
# classifier correctly parses it as imperative, but the user's intent is
# ambiguous — they may want a parallel worker (different feature) OR they may
# want to direct/cancel the existing worker. Silently spawning produces two
# workers racing on the same files.
#
# Strategy: enumerate active bg /plan-w-team workers in the current project;
# if any exist (and we're not the parent), refuse to spawn and surface a
# disambiguation systemMessage. The origin assistant handles the reply on
# the next turn (parallel | direct | cancel).
#
# Existing guards do not catch this:
#   - PWT-DS1 flag-file is 60s scoped; long-running workers age past it.
#   - PWT-DS2 env signal only fires inside worker processes.
#   - Classifier is textual; the ambiguity is situational.
#
# Kill switch: PLAN_W_TEAM_DISABLE_PARALLEL_GATE=1 bypasses the gate
# (proceeds with spawn even with active workers). Use for deliberate
# parallel-feature workflows.
#
# Fail-open: any internal error (jq missing, claude CLI missing, malformed
# JSON) → proceed to spawn. The gate adds friction; if state can't be
# queried, the existing PWT-DS1 flag-file still backs up double-spawn.
# See docs/specs/parallel-worker-gate.md.

# Resolve absolute path to the claude binary up front via locate-claude.sh
# so the PWG gate works even when the hook's inherited PATH lacks the install
# dir. Fallback cascade:
#   1. $PROJECT_ROOT/.claude/scripts/locate-claude.sh
#   2. command -v claude (PATH lookup — preserves pre-2026-05-23 behavior)
PWG_LOCATE="$PROJECT_ROOT/.claude/scripts/locate-claude.sh"
PWG_CLAUDE_BIN=""
if [ -x "$PWG_LOCATE" ]; then
    PWG_CLAUDE_BIN=$("$PWG_LOCATE" 2>/dev/null) || PWG_CLAUDE_BIN=""
fi
if [ -z "$PWG_CLAUDE_BIN" ] && command -v claude >/dev/null 2>&1; then
    PWG_CLAUDE_BIN="claude"
fi

if [ "${PLAN_W_TEAM_DISABLE_PARALLEL_GATE:-}" != "1" ] \
   && [ -n "$PWG_CLAUDE_BIN" ] \
   && command -v jq >/dev/null 2>&1; then

    # Resolve canonical project root (worktree-aware). Strip trailing /.git
    # from --git-common-dir to get the main repo's working tree. Fall back to
    # PROJECT_ROOT literal on any git failure.
    PWG_CANON_ROOT=""
    if PWG_GIT_COMMON=$(git -C "$PROJECT_ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null); then
        PWG_CANON_ROOT="${PWG_GIT_COMMON%/.git}"
        PWG_CANON_ROOT="${PWG_CANON_ROOT%/.git/}"
        # If --git-common-dir returns e.g. "/repo/.git/worktrees/foo", climb up
        # to the parent /.git path then strip.
        case "$PWG_GIT_COMMON" in
            */.git/worktrees/*) PWG_CANON_ROOT="${PWG_GIT_COMMON%/.git/worktrees/*}" ;;
        esac
    fi
    [ -z "$PWG_CANON_ROOT" ] && PWG_CANON_ROOT="$PROJECT_ROOT"

    # Query the agents list through the retry wrapper (audit C2). A bare single
    # `claude agents --json` returns empty-but-exit-0 INTERMITTENTLY UNDER LOAD
    # (memory reference_claude_agents_json_flaky) — precisely the concurrent-
    # worker load this gate exists to detect. The old single un-retried call
    # therefore failed OPEN exactly when a peer worker existed, re-opening the
    # 2026-05-22 two-workers-racing-same-files incident. claude-agents-extended.sh
    # absorbs the flakiness via CLAUDE_AGENTS_RETRY and is the same view the
    # statusline/cleanup consumers trust. Fall back to a retried raw-bin call
    # (using the PATH-resolved $PWG_CLAUDE_BIN) when the wrapper is unsynced.
    PWG_EXTENDED="$PWG_CANON_ROOT/.claude/scripts/claude-agents-extended.sh"
    [ -x "$PWG_EXTENDED" ] || PWG_EXTENDED="$PROJECT_ROOT/.claude/scripts/claude-agents-extended.sh"
    PWG_AGENTS_RAW=""
    if [ -x "$PWG_EXTENDED" ]; then
        PWG_AGENTS_RAW=$(CLAUDE_AGENTS_RETRY="${CLAUDE_AGENTS_RETRY:-3}" "$PWG_EXTENDED" --json 2>/dev/null)
        # Wrapper exits non-zero when it could not reach `claude` (stripped PATH);
        # force the raw-bin fallback rather than trusting its "[]" fail value.
        [ $? -ne 0 ] && PWG_AGENTS_RAW=""
    fi
    if [ -z "$PWG_AGENTS_RAW" ] || ! printf '%s' "$PWG_AGENTS_RAW" | jq empty >/dev/null 2>&1; then
        _pwg_try=0
        while [ "$_pwg_try" -lt "${CLAUDE_AGENTS_RETRY:-3}" ]; do
            _pwg_try=$((_pwg_try + 1))
            PWG_AGENTS_RAW=$("$PWG_CLAUDE_BIN" agents --json 2>/dev/null || echo "")
            printf '%s' "$PWG_AGENTS_RAW" | jq -e 'type == "array" and length > 0' >/dev/null 2>&1 && break
            sleep 1
        done
    fi
    if [ -z "$PWG_AGENTS_RAW" ] || ! printf '%s' "$PWG_AGENTS_RAW" | jq empty >/dev/null 2>&1; then
        PWG_AGENTS_RAW="[]"
    fi
    # Observability (audit C2): an empty list after retries cannot distinguish
    # "genuinely no peer workers" (proceeding is correct) from "persistent
    # flakiness" (proceeding is a race). We proceed to avoid blocking the
    # legitimate first run, but emit a loud marker the origin-chat supervisor
    # surfaces, so a silent race window is at least visible in the transcript.
    if [ "$(printf '%s' "$PWG_AGENTS_RAW" | jq 'length' 2>/dev/null || echo 0)" = "0" ]; then
        echo "⚠ PWG: agents --json empty after ${CLAUDE_AGENTS_RETRY:-3} retries — proceeding with NO peer-worker confirmation (race window if a peer exists)" >&2
    fi

    # Filter for bg /plan-w-team workers in this project, excluding self.
    # The name field is wrapped in `tostring` because some agents may have
    # a null name. jq -c -r yields each match as a JSON object per line.
    #
    # NO STATUS FILTER BY DESIGN (parallel-worker-gate-idle-counted, 2026-05-22):
    # An idle worker (terminal SUCCESS, still alive in `claude agents --json`)
    # has the SAME conflict surface as a busy one — it owns the same SLUG,
    # workflow lock, baseline file, and worktree. The only valid exclusion is
    # "completely gone from claude agents --json", which is satisfied
    # implicitly by iterating only what the listing returns. The projection
    # below preserves `status` for display in the disambiguation message.
    PWG_MATCHES=$(
        printf '%s' "$PWG_AGENTS_RAW" | jq -c --arg root "$PWG_CANON_ROOT" --arg pself "${PARENT_SID_FROM_HOOK:0:8}" '
            [ .[] | select(
                .kind == "background"
                and ((.cwd // "") | startswith($root))
                and (((.name // "") | ascii_downcase) | (contains("/goal") or contains("/plan-w-team")))
                and ((.sessionId // "")[0:8] != $pself)
            ) | {sessionId, name, cwd, kind, status: (.status // "unknown")} ]
        ' 2>/dev/null || echo "[]"
    )
    PWG_COUNT=$(printf '%s' "$PWG_MATCHES" | jq 'length' 2>/dev/null || echo 0)
    [ -z "$PWG_COUNT" ] && PWG_COUNT=0

    if [ "$PWG_COUNT" -gt 0 ] 2>/dev/null; then
        # Refuse spawn. Emit disambiguation systemMessage and exit 0.
        # Slug/stage extraction is best-effort: parse from name if present,
        # else <unknown>. Stage is read from the goal state file if the slug
        # is identifiable; that's a soft signal — we still always emit the SID.
        PWG_PROJECT_ROOT="$PROJECT_ROOT" \
        PWG_MATCHES="$PWG_MATCHES" \
        python3 - <<'PWGPY' 2>/dev/null || exit 0
import json, os, re, sys

matches_raw = os.environ.get("PWG_MATCHES", "[]")
project_root = os.environ.get("PWG_PROJECT_ROOT", "")

try:
    matches = json.loads(matches_raw)
except Exception:
    print(json.dumps({"systemMessage": "⚠ /plan-w-team parallel-worker gate: failed to parse agents fixture; spawn refused for safety."}))
    sys.exit(0)

def derive_slug(name):
    if not name:
        return "<unknown>"
    m = re.search(r"slug[=:\s]+([A-Za-z0-9_\-]+)", name)
    if m:
        return m.group(1)
    # heuristic: first few words after "Use /plan-w-team to"
    m = re.search(r"/plan-w-team to ([A-Za-z0-9_\-\s]{1,40})", name, re.IGNORECASE)
    if m:
        words = m.group(1).strip().split()[:3]
        if words:
            return "-".join(w.lower() for w in words)
    return "<unknown>"

def read_stage(slug):
    if slug == "<unknown>":
        return "<unknown>"
    path = os.path.join(project_root, ".claude", "state", f"plan-w-team-goal-{slug}.json")
    try:
        with open(path) as f:
            data = json.load(f)
        return data.get("terminal_state") or data.get("stage") or "in-flight"
    except Exception:
        return "<unknown>"

lines = ["⚠ /plan-w-team workers already active in this project:"]
for m in matches:
    sid = (m.get("sessionId") or "")[:8] or "<unknown>"
    slug = derive_slug(m.get("name") or "")
    stage = read_stage(slug)
    status = m.get("status") or "unknown"
    lines.append(f"   worker: {sid} slug: {slug} stage: {stage} status: {status}")
lines.append("(idle workers still own the same SLUG/lock/baseline as busy workers — both count.)")
lines.append("Did you mean to spawn a parallel worker, or direct the existing one?")
lines.append("Reply: parallel | direct | cancel")

sysmsg = "\n".join(lines)
print(json.dumps({"systemMessage": sysmsg}))
PWGPY
        exit 0
    fi
fi
# ─── end PARALLEL-WORKER GATE ────────────────────────────────────────────────

# ─── Locate launcher; fail open if missing ───────────────────────────────────
PWT_GOAL="$PROJECT_ROOT/.claude/scripts/pwt-goal.sh"
[ -x "$PWT_GOAL" ] || exit 0

# ─── Foreground worker spawn (--supervisor-goal mode) ────────────────────────
# We need the worker SID *before* returning so the additionalContext payload
# can hand it to the origin assistant. `pwt-goal.sh --supervisor-goal` runs
# `claude --bg` synchronously, emits "worker_sid=<SID>" on stdout, AND mirrors
# the worker's goal-state file to the origin's .claude/state/ so the origin
# chat receives supervisor-goal authority for this run (per the decision
# matrix in shared/supervisor-protocol.md §Decision Matrix). This grants
# autonomous-merge authority for CI-green non-one-way-door PRs without the
# user needing to type `pwt-goal.sh --supervisor-goal` manually.
#
# Behavior is a strict superset of --worker-only: same SID emission, same
# AUTO_PUSH=1 implication. Only addition is the origin-side mirror file.
#
# Whole call typically completes in <1.5s. We CANNOT background this and
# poll a log file like the old --launch path because the hook must return
# the SID in its response payload.
LOG_DIR="$PROJECT_ROOT/.claude/state/pwt-launch-logs"
mkdir -p "$LOG_DIR" 2>/dev/null || true
TS=$(date +%Y%m%d-%H%M%S)
LOG_FILE="$LOG_DIR/launch-$TS-$$.log"

# Run synchronously, capture stdout + stderr. PWT_PARENT_SID lets pwt-goal.sh
# record the chain (worker.parent_sid = origin chat sid) so the statusline
# classifies it as "mine" AND so the mirror file lands in the correct origin
# .claude/state/ directory.
PWT_GOAL_OUT=$(
    PWT_PARENT_SID="$PARENT_SID_FROM_HOOK" \
        "$PWT_GOAL" --supervisor-goal "$PROMPT" 2>"$LOG_FILE.err" </dev/null
)
PWT_GOAL_RC=$?
# Mirror everything to a log file for debugging.
{
    echo "=== pwt-goal --supervisor-goal (exit $PWT_GOAL_RC) ==="
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

# ─── DETERMINISTIC DOUBLE-SPAWN GUARD (PWT-DS1) ─────────────────────────────
# Write a flag file recording that THIS turn's UserPromptSubmit already spawned
# a worker. pwt-goal.sh --worker-only reads this and refuses if the flag is
# fresh. This converts the Step 3a check from "LLM-attention-based" (origin
# assistant must visually scan systemMessage) to "process-level" (mechanical
# refusal at spawn time). Caught 2026-05-22: the systemMessage WAS delivered
# (verified line 2890 of session JSONL) but the assistant missed it visually,
# called pwt-goal.sh --worker-only, and produced a double-spawn.
#
# Flag is per-session (PARENT_SID). Tier A of the guard treats it as fresh
# within PWT_DOUBLE_SPAWN_WINDOW_MIN (default 3 min) via mtime; Tier B
# (PWT-DS1-LIVE) reads the recorded worker_sid from THIS flag beyond that
# window to check whether the worker is still live (the plan-mode-delay case),
# so the flag is deliberately NOT auto-deleted — it is aged out by mtime and
# swept by /plan-w-team retro.
PARENT_SID_SHORT="${PARENT_SID_FROM_HOOK:0:8}"
if [ -n "$PARENT_SID_SHORT" ]; then
    FLAG_DIR="$PROJECT_ROOT/.claude/state"
    mkdir -p "$FLAG_DIR" 2>/dev/null
    FLAG_FILE="$FLAG_DIR/plan-w-team-hook-spawn-${PARENT_SID_SHORT}.flag"
    cat > "$FLAG_FILE" <<FLAG
worker_sid=$SESSION_ID
parent_sid=$PARENT_SID_FROM_HOOK
spawned_at=$(date +%s)
spawned_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
trigger=$MATCHED_PATTERN
FLAG
fi

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
     - `./.claude/scripts/claude-agents-extended.sh` (with `claude agents
       --json` as fallback) — worker liveness + stage hint. The extended
       wrapper also surfaces Agent-tool subagents (kind: "subagent") so a
       worker fanning out via the Agent tool stays visible during polling.
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
   existing `plan-w-team-completion-surface.sh` hook can archive it for the
   user's next session.

5. EXIT: After the terminal block, you are done. Do not continue polling.

Hard rules:
- NEVER edit code, configs, or specs. The worker does all implementation.
- NEVER spawn additional bg agents.
- NEVER push to remote — that is the worker + user's responsibility.
- If the extended wrapper (or `claude agents --json` fallback) no longer
  lists session {sid} for >2 polls, treat it as DEAD and emit the terminal block.

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
