#!/usr/bin/env bash
# tests/skill/harness-shim.sh
#
# Fake Claude Code harness for /plan-w-team E2E scenarios.
#
# Simulates the real harness's behavior when running a UserPromptSubmit
# hook: feeds the hook stdin in the real JSON shape, captures stdout,
# applies the harness's delivery rules (delivers `systemMessage` as
# `hook_system_message`, DROPS `additionalContext` per the 2026-05-21
# audit in commit 4f83172), and emits a structured "simulated assistant
# context" JSON to stdout for tests to assert against.
#
# The bg-worker spawn that the hook performs (via pwt-goal.sh →
# `claude --bg`) is intercepted by a PATH-stub `claude` binary that
# records the invocation without actually spawning anything.
#
# Usage:
#   harness-shim.sh --prompt "Use /plan-w-team to ..."
#   harness-shim.sh --prompt-file path/to/fixture.txt
#   harness-shim.sh --prompt "..." --session-id parent-sid
#   harness-shim.sh --prompt "..." --sandbox /tmp/sb   # use existing sandbox
#   harness-shim.sh --prompt "..." --hook PATH         # override hook path
#
# Exit codes:
#   0 — shim ran the hook successfully (hook's own exit code is in sim-ctx)
#   2 — shim setup failure (missing prompt, missing hook, missing jq, etc.)

set -u

PROMPT=""
PROMPT_FILE=""
SESSION_ID="harness-shim-parent-$$"
SANDBOX_DIR=""
HOOK_PATH=""
KEEP_SANDBOX=0

usage() {
    sed -n '/^# Usage:/,/^# Exit codes:/p' "$0" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
    case "$1" in
        --prompt)       PROMPT="${2:-}"; shift 2 ;;
        --prompt-file)  PROMPT_FILE="${2:-}"; shift 2 ;;
        --session-id)   SESSION_ID="${2:-}"; shift 2 ;;
        --sandbox)      SANDBOX_DIR="${2:-}"; shift 2 ;;
        --hook)         HOOK_PATH="${2:-}"; shift 2 ;;
        --keep-sandbox) KEEP_SANDBOX=1; shift ;;
        -h|--help)      usage; exit 0 ;;
        *)              echo "ShimError: unknown arg: $1" >&2; exit 2 ;;
    esac
done

if ! command -v jq >/dev/null 2>&1; then
    echo "ShimError: jq required (install: brew install jq)" >&2
    exit 2
fi

# ─── Read prompt fixture ─────────────────────────────────────────────────────
if [ -n "$PROMPT_FILE" ]; then
    if [ ! -r "$PROMPT_FILE" ]; then
        echo "ShimError: prompt-file not readable: $PROMPT_FILE" >&2
        exit 2
    fi
    PROMPT=$(cat "$PROMPT_FILE")
fi

if [ -z "$PROMPT" ]; then
    echo "ShimError: missing prompt fixture (use --prompt or --prompt-file)" >&2
    exit 2
fi

# ─── Resolve / create sandbox ────────────────────────────────────────────────
SHIM_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT_GUESS="$(cd "$SHIM_DIR/../.." && pwd)"
SANDBOX_OWNED=0

if [ -z "$SANDBOX_DIR" ]; then
    SANDBOX_DIR=$(mktemp -d -t pwt-shim-XXXXXX)
    SANDBOX_OWNED=1
fi

if [ ! -d "$SANDBOX_DIR" ]; then
    echo "ShimError: sandbox not a directory: $SANDBOX_DIR" >&2
    exit 2
fi

mkdir -p "$SANDBOX_DIR/.claude/hooks" \
         "$SANDBOX_DIR/.claude/scripts" \
         "$SANDBOX_DIR/.claude/state" || {
    echo "ShimError: cannot create sandbox subdirs" >&2
    exit 2
}

# Copy hooks + scripts (NOT state) if the sandbox is empty
if [ ! -f "$SANDBOX_DIR/.claude/hooks/plan-w-team-route-prompt.sh" ]; then
    cp -R "$REPO_ROOT_GUESS/.claude/hooks/." "$SANDBOX_DIR/.claude/hooks/" 2>/dev/null || true
    cp -R "$REPO_ROOT_GUESS/.claude/scripts/." "$SANDBOX_DIR/.claude/scripts/" 2>/dev/null || true
fi

# ─── Resolve hook path ───────────────────────────────────────────────────────
if [ -z "$HOOK_PATH" ]; then
    HOOK_PATH="$SANDBOX_DIR/.claude/hooks/plan-w-team-route-prompt.sh"
fi
if [ ! -x "$HOOK_PATH" ]; then
    echo "ShimError: hook not found or not executable: $HOOK_PATH" >&2
    exit 2
fi

# ─── Stage PATH-stub for `claude` ────────────────────────────────────────────
STUB_DIR="$SANDBOX_DIR/.shim-bin"
mkdir -p "$STUB_DIR"
STUB_LOG="$SANDBOX_DIR/.shim-stub-invocations.log"
: > "$STUB_LOG"

cat > "$STUB_DIR/claude" <<'STUB_EOF'
#!/usr/bin/env bash
# Stub `claude` binary used by harness-shim.sh.
# Records every invocation; for `claude --bg "<text>"` emits the
# format pwt-goal.sh parses to learn the worker SID.
LOG="${SHIM_STUB_LOG:-/dev/null}"

# JSON-encode argv so the recorder can faithfully reconstruct it.
python3 - "$@" <<'PYEOF' >> "$LOG" 2>/dev/null || true
import json, sys
record = {"ts": __import__("time").time(), "argv": sys.argv[1:]}
print(json.dumps(record))
PYEOF

case "${1:-}" in
    --bg)
        # Emit a deterministic fake SID with the shape the parser expects:
        #   `backgrounded · <8-hex>`
        # The middle dot is U+00B7 just like real Claude Code output.
        FAKE_SID="${SHIM_FAKE_SID:-abc12345}"
        printf 'backgrounded · %s\n' "$FAKE_SID"
        exit 0
        ;;
    agents)
        # Minimal JSON listing so the supervisor protocol's polls have
        # something parseable to consume (sim-ctx scenarios don't poll,
        # but unit tests might exercise this path).
        echo '[]'
        exit 0
        ;;
    *)
        # Other subcommands: no-op, exit 0
        exit 0
        ;;
esac
STUB_EOF
chmod +x "$STUB_DIR/claude"

# ─── Build UserPromptSubmit hook input JSON ──────────────────────────────────
HOOK_INPUT=$(jq -nc \
    --arg p "$PROMPT" \
    --arg s "$SESSION_ID" \
    '{prompt: $p, session_id: $s}')

# ─── Run hook with stub on PATH, capture stdout/stderr/exit ──────────────────
HOOK_STDOUT_FILE=$(mktemp -t pwt-shim-out-XXXXXX)
HOOK_STDERR_FILE=$(mktemp -t pwt-shim-err-XXXXXX)

# Env contract for the hook + pwt-goal.sh:
#   PATH                              — stub binary takes precedence
#   CLAUDE_PROJECT_DIR                — overrides hook's relative resolution
#   PLAN_W_TEAM_HOOK_TEST_MODE=1      — skip macOS notification watcher
#   PLAN_W_TEAM_DISABLE_GOAL=1        — skip goal-evaluator wiring inside hook ctx
#   SHIM_STUB_LOG                     — where the stub records its invocations
#   SHIM_FAKE_SID                     — overridable fake worker SID
# The hook embeds nested python heredocs that bash 3.2 (macOS /bin/bash) can't
# parse. Preserve any homebrew bash prefix on PATH so the shebang resolves to
# bash 4+ (5+ on Apple Silicon).
HOMEBREW_PREFIX=""
for cand in /opt/homebrew/bin /usr/local/bin; do
    if [ -x "$cand/bash" ]; then
        HOMEBREW_PREFIX="$cand:${HOMEBREW_PREFIX}"
    fi
done

HOOK_EXIT=0
# PWT_PROJECT_ROOT_OVERRIDE pins pwt-goal.sh's PROJECT_ROOT to the sandbox so
# the registration helper writes to .shim-sandbox/.claude/state/, not the real
# repo's state directory. Without this, every shim invocation pollutes
# pwt-launches.jsonl and the spawned-children manifests in the real checkout.
env -i \
    HOME="${HOME:-/tmp}" \
    PATH="$STUB_DIR:${HOMEBREW_PREFIX}/usr/local/bin:/usr/bin:/bin" \
    CLAUDE_PROJECT_DIR="$SANDBOX_DIR" \
    PWT_PROJECT_ROOT_OVERRIDE="$SANDBOX_DIR" \
    PLAN_W_TEAM_HOOK_TEST_MODE=1 \
    PLAN_W_TEAM_DISABLE_GOAL=1 \
    SHIM_STUB_LOG="$STUB_LOG" \
    SHIM_FAKE_SID="${SHIM_FAKE_SID:-abc12345}" \
    "$HOOK_PATH" <<<"$HOOK_INPUT" \
        > "$HOOK_STDOUT_FILE" 2> "$HOOK_STDERR_FILE" || HOOK_EXIT=$?

HOOK_STDOUT=$(cat "$HOOK_STDOUT_FILE")
HOOK_STDERR=$(cat "$HOOK_STDERR_FILE")

# ─── Parse hook stdout as JSON (if it is JSON) ───────────────────────────────
if [ -n "$HOOK_STDOUT" ] && echo "$HOOK_STDOUT" | jq empty >/dev/null 2>&1; then
    HOOK_STDOUT_JSON=$(echo "$HOOK_STDOUT" | jq -c '.')
    JSON_OK=1
else
    HOOK_STDOUT_JSON='null'
    JSON_OK=0
fi

# ─── Apply harness delivery rules ────────────────────────────────────────────
# RULE A: systemMessage is DELIVERED as hook_system_message attachment
# RULE B: additionalContext is DROPPED (silently — never reaches assistant)
# RULE C: decision (block) and continue fields pass through as metadata
if [ "$JSON_OK" = "1" ]; then
    DELIVERED_SYSMSG=$(echo "$HOOK_STDOUT_JSON" | jq -r '.systemMessage // null')
    HAD_ADDCTX=$(echo "$HOOK_STDOUT_JSON" | jq 'has("additionalContext")')
    DELIVERED_DECISION=$(echo "$HOOK_STDOUT_JSON" | jq -r '.decision // null')
else
    DELIVERED_SYSMSG="null"
    HAD_ADDCTX="false"
    DELIVERED_DECISION="null"
fi

# ─── Parse stub invocations to enumerate bg sessions spawned ─────────────────
BG_SESSIONS_JSON='[]'
if [ -s "$STUB_LOG" ]; then
    BG_SESSIONS_JSON=$(jq -s '[.[] | select(.argv[0] == "--bg") | {ts, argv}]' "$STUB_LOG" 2>/dev/null || echo '[]')
fi

# ─── Enumerate state files created during this run ───────────────────────────
STATE_FILES_JSON='[]'
if [ -d "$SANDBOX_DIR/.claude/state" ]; then
    STATE_FILES_JSON=$(find "$SANDBOX_DIR/.claude/state" -type f 2>/dev/null \
        | sed "s|$SANDBOX_DIR/||" \
        | jq -R . | jq -s '.')
fi

# ─── Emit simulated assistant context JSON ───────────────────────────────────
SIM_CTX=$(jq -n \
    --arg sandbox "$SANDBOX_DIR" \
    --argjson hook_exit "$HOOK_EXIT" \
    --arg stdout_raw "$HOOK_STDOUT" \
    --argjson stdout_json "$HOOK_STDOUT_JSON" \
    --arg stderr "$HOOK_STDERR" \
    --argjson json_parsed "$([ "$JSON_OK" = "1" ] && echo true || echo false)" \
    --arg sysmsg "$DELIVERED_SYSMSG" \
    --argjson had_addctx "$HAD_ADDCTX" \
    --arg decision "$DELIVERED_DECISION" \
    --argjson bg_sessions "$BG_SESSIONS_JSON" \
    --argjson state_files "$STATE_FILES_JSON" \
    '{
        sandbox: $sandbox,
        hook: {
            exit_code: $hook_exit,
            stdout_raw: $stdout_raw,
            stdout_json: $stdout_json,
            stdout_json_parsed: $json_parsed,
            stderr: $stderr
        },
        delivered_to_assistant: {
            hook_system_message: (if $sysmsg == "null" then null else $sysmsg end),
            additionalContext_dropped: $had_addctx,
            decision: (if $decision == "null" then null else $decision end)
        },
        side_effects: {
            bg_sessions_spawned: $bg_sessions,
            state_files_created: $state_files
        }
    }')

echo "$SIM_CTX"

# Cleanup
rm -f "$HOOK_STDOUT_FILE" "$HOOK_STDERR_FILE"
if [ "$SANDBOX_OWNED" = "1" ] && [ "$KEEP_SANDBOX" = "0" ]; then
    rm -rf "$SANDBOX_DIR" 2>/dev/null || true
fi

exit 0
