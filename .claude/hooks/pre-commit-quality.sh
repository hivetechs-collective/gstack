#!/bin/bash
# Pre-Commit Quality Gate Hook
# PreToolUse hook (matcher: Bash) that quality-checks before git commit.
#
# Checks staged files for:
#   - debugger statements (blocks commit)
#   - Secret patterns: AWS keys, GitHub tokens, OpenAI keys, api_key assignments (blocks commit)
#   - console.log statements outside comments (warns)
#   - Conventional commit message format (warns)
#
# Exit codes:
#   0 - allow (clean or warnings only)
#   2 - block (errors found: debugger, secrets)

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
UTILS_DIR="$SCRIPT_DIR/utils"

source "$UTILS_DIR/hook-profile.sh"
hook_gate "pre:bash:pre-commit-quality" "standard,strict"

# Source JSON logger if available
if [ -f "$UTILS_DIR/json-logger.sh" ]; then
    source "$UTILS_DIR/json-logger.sh"
    LOGGING_ENABLED=true
else
    LOGGING_ENABLED=false
fi

# Read input from Claude Code
INPUT=$(cat)

# Extract the command from tool_input
COMMAND=$(echo "$INPUT" | grep -o '"command"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*:[[:space:]]*"\([^"]*\)".*/\1/' || echo "")

# Only activate on git commit (not --amend)
if ! echo "$COMMAND" | grep -qE '(^|[^[:alnum:]])git([[:space:]]+-[^[:space:]]+([[:space:]]+[^[:space:]]+)?)*[[:space:]]+commit([^[:alnum:]]|$)'; then
    echo "$INPUT"
    exit 0
fi

# Skip if this is an amend
if echo "$COMMAND" | grep -q '\-\-amend'; then
    echo "$INPUT"
    exit 0
fi

# Get staged files (Added, Copied, Modified, Renamed)
STAGED_FILES=$(git diff --cached --name-only --diff-filter=ACMR 2>/dev/null || echo "")

if [ -z "$STAGED_FILES" ]; then
    echo "$INPUT"
    exit 0
fi

ERRORS=()
WARNINGS=()

# Secret scan — delegate to shared scanner (single source of truth for pre-commit,
# ship-gate, and sync). The scanner handles ALL file extensions (including .env.*,
# .yaml, .sh, .md) and classifies placeholders vs live secrets.
SECRET_SCANNER="$SCRIPT_DIR/../scripts/secret-scan.sh"
# Allow-file aggregation: any per-feature `plan-w-team-secret-scan-allow-*`
# file under `.claude/state/` is merged into a temp allow-file for the scanner.
# Tradeoff: stale allow-files from abandoned features can mask real secrets
# during pre-commit; ship-gate (Step 6a-ter) runs with only the current feature's
# allow-file and catches that class of drift.
#
# STALENESS CONTROL (1.33.0, gap B4): an allow-file from a long-abandoned feature
# could permanently mask a real secret at the same path:line. Allow-files older
# than PLAN_W_TEAM_ALLOW_MAX_AGE_DAYS (default 30) are SKIPPED (not aggregated)
# and a warning naming the stale file is surfaced — the entry stops suppressing,
# so a real secret there is caught again. Retired allow-files are also deleted in
# Step 8 retro (07-retro.md cleanup `rm -f` set). Set the env to 0 to disable the
# age check (aggregate all), or to a smaller number to tighten.
SCAN_ARGS=(--staged)
ALLOW_AGG=""
ALLOW_MAX_AGE_DAYS="${PLAN_W_TEAM_ALLOW_MAX_AGE_DAYS:-30}"
_now_epoch=$(date +%s 2>/dev/null || echo 0)
_file_mtime() {  # portable mtime (macOS stat -f, GNU stat -c)
    stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0
}
# shellcheck disable=SC2125
for allow in .claude/state/plan-w-team-secret-scan-allow-*; do
    [ -f "$allow" ] || continue
    if [ "$ALLOW_MAX_AGE_DAYS" != "0" ] && [ "$_now_epoch" -gt 0 ]; then
        _mtime=$(_file_mtime "$allow")
        if [ "$_mtime" -gt 0 ]; then
            _age_days=$(( (_now_epoch - _mtime) / 86400 ))
            if [ "$_age_days" -gt "$ALLOW_MAX_AGE_DAYS" ]; then
                WARNINGS+=("stale secret-scan allow-file skipped (${_age_days}d > ${ALLOW_MAX_AGE_DAYS}d): $allow — remove it in retro or refresh it")
                continue
            fi
        fi
    fi
    if [ -z "$ALLOW_AGG" ]; then
        ALLOW_AGG=$(mktemp -t secret-scan-allow.XXXXXX)
        trap 'rm -f "$ALLOW_AGG"' EXIT
    fi
    cat "$allow" >> "$ALLOW_AGG"
done
[ -n "$ALLOW_AGG" ] && SCAN_ARGS=(--allow "$ALLOW_AGG" --staged)

if [ -x "$SECRET_SCANNER" ]; then
    SCAN_STDERR=$("$SECRET_SCANNER" "${SCAN_ARGS[@]}" 2>&1 >/dev/null) || SCAN_EXIT=$?
    SCAN_EXIT=${SCAN_EXIT:-0}
    if [ "$SCAN_EXIT" -eq 1 ]; then
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            ERRORS+=("$line")
        done <<< "$SCAN_STDERR"
    elif [ "$SCAN_EXIT" -ne 0 ]; then
        WARNINGS+=("secret-scan.sh exited $SCAN_EXIT (internal error): $SCAN_STDERR")
    fi
else
    WARNINGS+=("secret-scan.sh not found at $SECRET_SCANNER — secret scanning SKIPPED")
fi

# Check each staged file for debugger statements + console.log warnings.
# These checks are scoped to code-file extensions; secret scanning above covers
# all file types.
while IFS= read -r file; do
    [ -z "$file" ] && continue

    case "$file" in
        *.js|*.jsx|*.ts|*.tsx|*.py|*.go|*.rs) ;;
        *) continue ;;
    esac

    STAGED_CONTENT=$(git show ":$file" 2>/dev/null || continue)

    if echo "$STAGED_CONTENT" | grep -nE '^\s*debugger\s*;?\s*$' > /dev/null 2>&1; then
        ERRORS+=("$file: contains 'debugger' statement")
    fi

    UNCOMMENTED=$(echo "$STAGED_CONTENT" | sed 's|//.*||' | sed 's|#.*||')
    if echo "$UNCOMMENTED" | grep -nE 'console\.log\(' > /dev/null 2>&1; then
        WARNINGS+=("$file: contains 'console.log' (consider removing before commit)")
    fi

done <<< "$STAGED_FILES"

# /plan-w-team commit gate — VERDICT CONSULT (was: inline `make test-skill`).
#
# WHY IT IS A CONSULT. This is a PreToolUse hook. Running the ~9-minute skill suite
# inside one meant the harness timeout killed it — and `--no-verify` cannot bypass a
# PreToolUse hook, so every non-lead commit staging `tests/skill/*` was simply
# blocked. The suite now runs OUT OF BAND via plan-w-team-test-green.sh and this
# gate consults the verdict it archives.
#
# WHY IT IS STILL A GATE. A stored verdict is agent-writable state read by a gate,
# so "green" on its own proves nothing. Three independent corroborations are
# required together, and EVERY uncertainty BLOCKS:
#   - log witness   — the run's log must exist and END with the literal SUITE_EXIT=0
#                     that run.sh emits, so a truncated or hand-shaped verdict fails;
#   - tree_digest   — recomputed here from STAGED content, so the suite must have
#                     seen exactly what is about to be committed;
#   - age window    — belt to the digest's braces (PWT_TEST_GREEN_MAX_AGE_S).
#   - what ran      — the verdict's `mode` + `suite_cmd` and the log's single
#                     SUITE_MODE= line: a SKILL_SKIP_* partial run, a single-file
#                     run, or a substituted suite command never passes (2.51.0).
# A `mode=retest` verdict (plan-w-team-test-green.sh --retest) is accepted only
# when its full BASE verdict passes every check above, is the one beside it and
# unreplaced, and the rerun set the gate REBUILDS from base → staged (same lib, not
# the retest's own list) is a subset of the files the retest log says ran.
# See docs/operations/test-green-retest.md.
# The one allow-without-verdict path is the consumer carve-out below: a checkout
# with no harness has no suite to have run.
#
# The verdict artifact is deliberately consulted with the hook's OWN jq-required
# read rather than `plan-w-team-test-green.sh --check`: --check corroborates none of
# the three, and its jq-absent fallback parses `green` out with sed.

# The watched-path set. SYMMETRY-LOCKED against the identical anchored block in
# .claude/scripts/plan-w-team-test-green.sh — here they are `case` patterns deciding
# whether to consult, there they are git pathspecs defining what tree_digest covers.
# If those two sets ever diverge the digest silently corroborates the wrong files.
# Asserted byte-identical by tests/skill/cases/pre-commit-hook-timeout.bats.
# `.claude/settings.json` is deliberately absent: config edits are damage-control
# protected on their own path and must not require a suite run to commit.
# BEGIN pwt-watched-globs
PWT_WATCHED_GLOBS='.claude/commands/plan-w-team*
.claude/scripts/plan-w-team-*
.claude/scripts/pwt-*
.claude/hooks/pre-commit-quality*
.claude/agents/team/*
.claude/agents/implementation/react-typescript-specialist.md
.claude/agents/implementation/rust-backend-specialist.md
.claude/scripts/secret-scan.sh
.claude/scripts/secret-doc-sync.sh
tests/skill/*'
# END pwt-watched-globs

_pwt_is_watched() {
    local f="$1" g
    while IFS= read -r g; do
        [ -n "$g" ] || continue
        # Unquoted so the value is used as a shell pattern; `*` matches `/` here
        # exactly as it does in a git pathspec, keeping both readings of the list
        # in agreement.
        case "$f" in $g) return 0 ;; esac
    done <<EOF
$PWT_WATCHED_GLOBS
EOF
    return 1
}

# The shared retest lib: the manifest/digest the gate recomputes and every
# "is this retest honest?" rule. Sourced lazily — only a harness checkout that is
# committing a watched path needs it, and a missing lib there BLOCKS (below).
PWT_RT_LIB="$SCRIPT_DIR/../scripts/plan-w-team-retest-lib.sh"

# _pwt_gate_retest <art> <staged_manifest> <tmpdir> — corroborates a mode=retest
# verdict (docs/operations/test-green-retest.md, rules R1–R7). The gate does NOT
# trust the retest's own `required` list: it rebuilds R itself from the base and
# the STAGED tree through the same lib, and requires R ⊆ RETEST_RAN of the log.
# Prints a block reason, or nothing when the retest is acceptable.
_pwt_gate_retest() {
    local art="$1" man="$2" tmpd="$3"
    local cmd lmode bslug bts bdig bfile chain rt_max_age n sdig sactual class
    cmd=$(jq -r '.suite_cmd // ""' "$art" 2>/dev/null || echo "")
    lmode=$(pwt_rt_log_mode "$TG_LOG" 2>/dev/null || echo "")
    # R0 — the retest log is the very log the verdict was written from: RETEST_RAN
    # rows read below are the witness for R ⊆ ran, so an appended row must not count.
    if ! pwt_rt_log_bound "$art" "$TG_LOG"; then
        echo "the retest verdict's log is not bound to it: $PWT_RT_ERR"; return 0
    fi
    # R0b — the witness rows are read from the log's final trailer block only; a row
    # printed above it (by a test, or a splice) makes the whole log unreadable.
    if ! pwt_rt_trailer "$TG_LOG" >/dev/null 2>&1; then
        echo "the retest log carries machine-readable rows outside its final trailer block (forged or spliced)"; return 0
    fi
    # R1 — the log is a retest log, produced by the canonical retest command.
    if [ "$lmode" != "retest" ]; then
        echo "the retest verdict's log does not carry exactly one SUITE_MODE=retest"; return 0
    fi
    if [ "$cmd" != "$PWT_RT_DEFAULT_RETEST_CMD" ]; then
        echo "the retest verdict ran a substituted command, not the canonical retest runner"; return 0
    fi
    # R2 — the base it names is the full verdict sitting beside it, unreplaced.
    bslug=$(jq -r '.base.slug // ""' "$art" 2>/dev/null || echo "")
    if ! pwt_rt_is_safe_slug "$bslug"; then
        echo "the retest verdict names no usable base slug"; return 0
    fi
    if [ "$(basename "$art")" != "plan-w-team-test-green-${bslug}--retest.json" ] \
       || [ "$(jq -r '.slug // ""' "$art" 2>/dev/null || echo "")" != "${bslug}--retest" ]; then
        echo "the retest verdict's file name / slug do not match its base '${bslug}'"; return 0
    fi
    bfile="$TG_STATE_DIR/plan-w-team-test-green-${bslug}.json"
    bts=$(jq -r '.base.ts // ""' "$art" 2>/dev/null || echo "")
    bdig=$(jq -r '.base.tree_digest // ""' "$art" 2>/dev/null || echo "")
    if [ ! -f "$bfile" ] || ! jq -e . "$bfile" >/dev/null 2>&1; then
        echo "the retest's base full verdict is gone ($bfile)"; return 0
    fi
    if [ "$(jq -r '.ts // ""' "$bfile" 2>/dev/null || echo "")" != "$bts" ] \
       || [ "$(jq -r '.tree_digest // ""' "$bfile" 2>/dev/null || echo "")" != "$bdig" ]; then
        echo "the retest's base full verdict has been replaced since the retest ran"; return 0
    fi
    # R3–R5 — the base is itself a full, witnessed, fresh, self-verifying run.
    rt_max_age="${PWT_TEST_RETEST_BASE_MAX_AGE_S:-$TG_MAX_AGE}"
    if ! pwt_rt_check_base "$bfile" "$rt_max_age"; then
        echo "the retest's base is not acceptable: $PWT_RT_ERR"; return 0
    fi
    # R5b — the SUBJECT the retest ran on is the subject being committed (review -1).
    # The watched digest above says nothing about an unwatched hook or script the
    # rerun set was built from; the retest records the subject digest it ran on, and
    # the staged (index) subject must hash to it. A retest verdict without one
    # predates the subject manifest and is refused — re-run the retest.
    sdig=$(jq -r '.subject_digest // ""' "$art" 2>/dev/null || echo "")
    if ! pwt_rt_is_hex64 "$sdig"; then
        echo "the retest verdict records no subject_digest (it predates the subject manifest, or the tree moved during it) — re-run the retest"; return 0
    fi
    if ! pwt_rt_subject_manifest "$TG_ROOT" staged > "$tmpd/staged.sman" 2>/dev/null; then
        echo "the staged subject manifest could not be computed"; return 0
    fi
    sactual=$(pwt_rt_digest "$tmpd/staged.sman" 2>/dev/null || echo "")
    if [ "$sactual" != "$sdig" ]; then
        # Name the first differing path when the retest's own subject manifest is
        # still there and still hashes to the digest it recorded.
        n=$(jq -r '.subject_manifest_path // ""' "$art" 2>/dev/null || echo "")
        if [ -n "$n" ] && [ -r "$n" ] && [ "$(pwt_rt_sha256_file "$n")" = "$sdig" ]; then
            n=$(pwt_rt_delta "$n" "$tmpd/staged.sman" 2>/dev/null | head -1 | tr -d '"\\' | cut -c1-120)
        else
            n=""
        fi
        echo "the retest ran on a different .claude/ + tests/ tree than the one staged${n:+ (first difference: $n)} — stage or stash the difference, or re-run the retest"; return 0
    fi
    # R6 — rebuild R from base → STAGED and require every file of it to have run.
    if ! pwt_rt_delta "$PWT_RT_BASE_MANIFEST" "$man" > "$tmpd/delta" 2>/dev/null; then
        echo "the change set since the base could not be computed"; return 0
    fi
    if n=$(pwt_rt_needs_full "$tmpd/delta"); then
        echo "the staged change set touches the harness or gate machinery ($n) — only a full run can certify it"; return 0
    fi
    if ! pwt_rt_delta "$PWT_RT_BASE_SUBJECT_MANIFEST" "$tmpd/staged.sman" > "$tmpd/sdelta" 2>/dev/null \
       || ! pwt_rt_unwatched "$tmpd/sdelta" "$PWT_WATCHED_GLOBS" > "$tmpd/udelta" 2>/dev/null; then
        echo "the unwatched change set since the base could not be computed"; return 0
    fi
    # R6b — a red base with no watched change is a flaky pass, never a fix (review -3):
    # refused unless the operator opts in here too. Recomputed from base → staged,
    # AND read from the verdict — either one saying flaky is enough.
    class=$(jq -r '.classification // ""' "$art" 2>/dev/null || echo "")
    if [ "${PWT_TEST_RETEST_ALLOW_FLAKY:-0}" != "1" ]; then
        if [ "$class" = "flaky" ] || { [ "$PWT_RT_BASE_GREEN" != "true" ] && [ ! -s "$tmpd/delta" ]; }; then
            echo "the retest is a FLAKY pass — its base is red and no watched file changed since — set PWT_TEST_RETEST_ALLOW_FLAKY=1 to accept it knowingly, or run a full run"; return 0
        fi
    fi
    # Fail closed exactly as the wrapper does: a base failure the runner could not
    # tie to a file cannot be retested by file (pwt_rt_check_base already refuses it;
    # this is the second, independent refusal — never a swallowed `|| true`).
    if ! pwt_rt_parse_failures "$PWT_RT_BASE_LOG" > "$tmpd/basefailed" 2>/dev/null; then
        echo "the base log has an unattributed or leak failure, or could not be parsed — only a full run can clear it"; return 0
    fi
    if ! pwt_rt_required "$TG_ROOT" "$tmpd/basefailed" "$tmpd/delta" "$PWT_RT_BASE_GREEN" \
            "$PWT_RT_BASE_MANIFEST" "$man" "$tmpd/udelta" > "$tmpd/required" 2>/dev/null || [ ! -s "$tmpd/required" ]; then
        echo "the rerun set for the staged tree could not be built — only a full run can certify it"; return 0
    fi
    n=$(grep -c . "$tmpd/required" 2>/dev/null || echo 0)
    if [ "$n" -gt "$PWT_RT_MAX_FILES" ]; then
        echo "the rerun set has $n files (> PWT_TEST_RETEST_MAX_FILES=$PWT_RT_MAX_FILES)"; return 0
    fi
    pwt_rt_ran "$TG_LOG" > "$tmpd/ran" 2>/dev/null || true
    LC_ALL=C comm -23 "$tmpd/required" "$tmpd/ran" > "$tmpd/missing" 2>/dev/null || true
    if [ -s "$tmpd/missing" ]; then
        n=$(grep -c . "$tmpd/missing" 2>/dev/null || echo 0)
        echo "the retest did not run $n file(s) the staged change requires (first: $(head -1 "$tmpd/missing" | cut -c1-120))"; return 0
    fi
    # R7 — bounded chain of retests on one full base.
    chain=$(jq -r '.chain // ""' "$art" 2>/dev/null || echo "")
    case "$chain" in ""|*[!0-9]*) chain=999999 ;; esac
    if [ "$chain" -lt 1 ] || [ "$chain" -gt "$PWT_RT_MAX_CHAIN" ]; then
        echo "the retest chain is out of bounds (chain=${chain}, PWT_TEST_RETEST_MAX_CHAIN=$PWT_RT_MAX_CHAIN) — run a full run"; return 0
    fi
    return 0
}

PLAN_TEAM_STAGED=false
while IFS= read -r file; do
    [ -z "$file" ] && continue
    if _pwt_is_watched "$file"; then
        PLAN_TEAM_STAGED=true; break
    fi
done <<< "$STAGED_FILES"

if [ "$PLAN_TEAM_STAGED" = "true" ]; then
    TG_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")
    TG_HAVE_HARNESS=false
    if [ -f "$TG_ROOT/Makefile" ] \
       && grep -q '^test-skill:' "$TG_ROOT/Makefile" 2>/dev/null \
       && [ -f "$TG_ROOT/tests/skill/run.sh" ]; then
        TG_HAVE_HARNESS=true
    fi

    if [ "$TG_HAVE_HARNESS" != "true" ]; then
        # Consumer-repo carve-out: they carry the skill without the source's bats
        # harness, so there is no suite for a verdict to describe. Unchanged
        # warn-and-allow behaviour.
        WARNINGS+=("plan-w-team files staged but this checkout has no skill harness (Makefile test-skill target + tests/skill/run.sh) — verdict consult skipped")
    else
        TG_STATE_DIR="$TG_ROOT/.claude/state"
        TG_MAX_AGE="${PWT_TEST_GREEN_MAX_AGE_S:-86400}"
        TG_SLUG=""
        TG_BLOCK=""
        TG_HINT_RETEST=false

        # Newest verdict in THIS checkout's state dir only. Never the dual-write set:
        # a sibling worktree's verdict describes a different tree.
        TG_ART=""
        for tg_f in "$TG_STATE_DIR/plan-w-team-test-green-"*.json; do
            [ -f "$tg_f" ] || continue
            if [ -z "$TG_ART" ] || [ "$tg_f" -nt "$TG_ART" ]; then TG_ART="$tg_f"; fi
        done

        if ! command -v jq >/dev/null 2>&1; then
            TG_BLOCK="jq is required to consult the test-green verdict and is not on PATH"
        elif ! command -v shasum >/dev/null 2>&1; then
            TG_BLOCK="shasum is required to corroborate the test-green verdict and is not on PATH"
        elif [ ! -f "$PWT_RT_LIB" ] || ! . "$PWT_RT_LIB" 2>/dev/null; then
            TG_BLOCK="the shared retest lib is missing or broken ($PWT_RT_LIB), so no verdict can be corroborated"
        elif [ -z "$TG_ART" ]; then
            TG_BLOCK="no test-green verdict in $TG_STATE_DIR — the skill suite has not been run for this checkout"
        elif ! jq -e . "$TG_ART" >/dev/null 2>&1; then
            TG_BLOCK="test-green verdict is not valid JSON: $TG_ART"
        else
            TG_SLUG=$(jq -r '.slug // ""' "$TG_ART" 2>/dev/null || echo "")
            TG_GREEN=$(jq -r '.green // false' "$TG_ART" 2>/dev/null || echo "false")
            TG_DIGEST=$(jq -r '.tree_digest // ""' "$TG_ART" 2>/dev/null || echo "")
            TG_LOG=$(jq -r '.log_path // ""' "$TG_ART" 2>/dev/null || echo "")
            # `.mode` is a trust-boundary field: shape it before it reaches a message.
            TG_MODE=$(jq -r '.mode // ""' "$TG_ART" 2>/dev/null | tr -cd 'a-z' | cut -c1-12 || echo "")
            # A retest's re-run hint names its BASE slug (the `--retest` suffix is
            # reserved and refused by the wrapper).
            TG_SLUG="${TG_SLUG%--retest}"

            TG_MTIME=$(_file_mtime "$TG_ART")
            TG_AGE=""
            if [ "$_now_epoch" -gt 0 ] && [ "$TG_MTIME" -gt 0 ] 2>/dev/null; then
                TG_AGE=$(( _now_epoch - TG_MTIME ))
            fi

            if [ "$TG_GREEN" != "true" ]; then
                # The artifact is a named trust boundary, so its free-text field is
                # stripped of quotes/backslashes/newlines and length-capped before it
                # reaches the block payload.
                TG_REASON=$(jq -r '.reason // "?"' "$TG_ART" 2>/dev/null | tr -d '"\\' | tr -d '\n\r' | cut -c1-40)
                TG_BLOCK="the archived test-green verdict is RED (${TG_REASON:-?})"
                [ "$TG_MODE" = "full" ] && TG_HINT_RETEST=true
            elif [ -z "$TG_DIGEST" ]; then
                TG_BLOCK="the verdict carries no tree_digest, so it cannot be tied to the staged content"
            elif [ -z "$TG_LOG" ] || [ ! -r "$TG_LOG" ]; then
                TG_BLOCK="the verdict's suite log is missing or unreadable (${TG_LOG:-<unset>}) — a verdict without its log is not a witnessed run"
            elif [ "$(tail -1 "$TG_LOG" 2>/dev/null | tr -d '\r')" != "SUITE_EXIT=0" ]; then
                TG_BLOCK="the verdict's suite log does not end with the literal SUITE_EXIT=0 marker — the run was killed, truncated, or never happened"
            elif [ -z "$TG_AGE" ]; then
                TG_BLOCK="the verdict's age could not be determined (unreadable mtime or clock)"
            elif [ "$TG_AGE" -lt 0 ]; then
                TG_BLOCK="the verdict's mtime is in the future (age ${TG_AGE}s) — refusing to trust a clock-skewed or back-dated verdict"
            elif [ "$TG_AGE" -gt "$TG_MAX_AGE" ]; then
                TG_BLOCK="the verdict is stale (${TG_AGE}s old > ${TG_MAX_AGE}s; tune PWT_TEST_GREEN_MAX_AGE_S)"
            else
                TG_TMP=$(mktemp -d -t pwt-gate.XXXXXX 2>/dev/null || echo "")
                TG_ACTUAL=""
                # Stage or stash first (review -2): the suite ran on the working tree,
                # the commit takes the index. The staged manifest is the index alone,
                # so it stands for the tested tree only while the two agree over the
                # watched set — a partially staged file, an unstaged deletion, or an
                # untracked watched file each break that, with its own reason.
                TG_UNSTAGED_RC=0
                TG_UNSTAGED=""
                if [ -n "$TG_TMP" ]; then
                    TG_UNSTAGED=$(pwt_rt_unstaged "$TG_ROOT" "$PWT_WATCHED_GLOBS" 2>/dev/null) || TG_UNSTAGED_RC=$?
                fi
                if [ -n "$TG_TMP" ] && [ "$TG_UNSTAGED_RC" = "0" ] \
                   && pwt_rt_manifest "$TG_ROOT" staged "$PWT_WATCHED_GLOBS" > "$TG_TMP/staged.man" 2>/dev/null; then
                    TG_ACTUAL=$(pwt_rt_digest "$TG_TMP/staged.man" 2>/dev/null || echo "")
                fi
                TG_UNSTAGED_FIRST=$(printf '%s\n' "$TG_UNSTAGED" | head -1 | tr -d '"\\' | cut -c1-140)
                if [ "$TG_UNSTAGED_RC" = "2" ]; then
                    TG_BLOCK="git could not compare the index with the working tree for the watched set, so the verdict cannot be tied to what is staged"
                elif [ "$TG_UNSTAGED_RC" != "0" ] && printf '%s\n' "$TG_UNSTAGED" | grep -q '^modified '; then
                    TG_BLOCK="watched files differ between the index and the working tree (first: ${TG_UNSTAGED_FIRST#modified }) — the suite ran on the working tree but the commit takes the index: stage or stash first"
                elif [ "$TG_UNSTAGED_RC" != "0" ]; then
                    TG_BLOCK="an untracked watched file exists (first: ${TG_UNSTAGED_FIRST#untracked }) — the suite ran with it but the commit leaves it out: stage or stash first (or ignore it)"
                elif [ -z "$TG_ACTUAL" ]; then
                    TG_BLOCK="the staged-content digest could not be computed, so the verdict cannot be corroborated"
                elif [ "$TG_ACTUAL" != "$TG_DIGEST" ]; then
                    TG_BLOCK="tree_digest mismatch — the suite ran against different content than what is staged (verdict ${TG_DIGEST%"${TG_DIGEST#??????????}"}…, staged ${TG_ACTUAL%"${TG_ACTUAL#??????????}"}…)"
                else
                    # WHAT ran, not only that something ended green (P3): a
                    # SKILL_SKIP_* partial run or a substituted suite command is
                    # never gate-acceptable, and a retest is corroborated whole.
                    case "$TG_MODE" in
                        full)
                            if ! pwt_rt_log_bound "$TG_ART" "$TG_LOG"; then
                                TG_BLOCK="the verdict's suite log is not bound to it: $PWT_RT_ERR"
                            elif [ "$(pwt_rt_log_mode "$TG_LOG" 2>/dev/null || echo "")" != "full" ]; then
                                TG_BLOCK="the verdict's log does not carry exactly one SUITE_MODE=full — a partial (SKILL_SKIP_*) or single-file run is not a suite run"
                            elif [ "$(jq -r '.suite_cmd // ""' "$TG_ART" 2>/dev/null || echo "")" != "$PWT_RT_DEFAULT_SUITE_CMD" ]; then
                                TG_BLOCK="the verdict was produced by a substituted suite command, not the skill suite"
                            fi ;;
                        retest)
                            TG_BLOCK=$(_pwt_gate_retest "$TG_ART" "$TG_TMP/staged.man" "$TG_TMP" || echo "the retest verdict could not be corroborated")
                            ;;
                        "")
                            TG_BLOCK="legacy verdict (no mode field — it predates the 2.51.0 retest gate) — run one full run" ;;
                        *)
                            TG_BLOCK="the verdict's mode '${TG_MODE}' is not gate-acceptable (only full or retest)" ;;
                    esac
                fi
                [ -n "$TG_TMP" ] && rm -rf "$TG_TMP" 2>/dev/null || true
            fi
        fi

        if [ -n "$TG_BLOCK" ]; then
            ERRORS+=("plan-w-team commit gate: $TG_BLOCK — run the suite out of band: .claude/scripts/plan-w-team-test-green.sh --slug ${TG_SLUG:-<slug>}   then re-commit")
            if [ "$TG_HINT_RETEST" = "true" ]; then
                ERRORS+=("  after fixing the failing file(s), a targeted retest is enough: .claude/scripts/plan-w-team-test-green.sh --slug ${TG_SLUG:-<slug>} --retest")
            fi
        fi
    fi
fi

# sync-allowlist symmetry gate — when ANY plan-w-team-* / pwt-* script or
# sync-to-project.sh is staged, verify that all such scripts appear in
# sync-to-project.sh's allowlist. This catches new scripts that would silently
# fail to propagate to consumer repos.
SYNC_ALLOWLIST_RELEVANT=false
while IFS= read -r file; do
    case "$file" in
        .claude/scripts/plan-w-team-*|\
        .claude/scripts/pwt-*|\
        .claude/scripts/sync-to-project.sh)
            SYNC_ALLOWLIST_RELEVANT=true; break ;;
    esac
done <<< "$STAGED_FILES"

if [ "$SYNC_ALLOWLIST_RELEVANT" = "true" ]; then
    ALLOWLIST_CHECK="$SCRIPT_DIR/../scripts/plan-w-team-sync-allowlist-check.sh"
    if [ -x "$ALLOWLIST_CHECK" ]; then
        if ! ALLOWLIST_OUT=$("$ALLOWLIST_CHECK" 2>&1); then
            ERRORS+=("Sync allowlist drift — new plan-w-team-* / pwt-* script not in sync-to-project.sh (run: .claude/scripts/plan-w-team-sync-allowlist-check.sh)")
            echo "[pre-commit-quality] sync-allowlist-check output:" >&2
            printf '%s\n' "$ALLOWLIST_OUT" >&2
        fi
    fi
    # Soft-skip when check script missing (e.g., during initial sync rollout)
fi

# secret-doc-sync gate — when secret-scan.sh is staged, the documented Pattern
# Catalog in secret-safety.md MUST be regenerated to match. `--check` exits 1
# on drift; we surface the diff via stderr (the script already prints it).
SECRET_SCAN_STAGED=false
while IFS= read -r file; do
    case "$file" in
        .claude/scripts/secret-scan.sh) SECRET_SCAN_STAGED=true; break ;;
    esac
done <<< "$STAGED_FILES"

if [ "$SECRET_SCAN_STAGED" = "true" ]; then
    SYNC_SCRIPT="$SCRIPT_DIR/../scripts/secret-doc-sync.sh"
    if [ -x "$SYNC_SCRIPT" ]; then
        if ! SYNC_OUT=$("$SYNC_SCRIPT" --check 2>&1); then
            ERRORS+=("secret-safety.md is out of sync with secret-scan.sh — run: .claude/scripts/secret-doc-sync.sh && git add .claude/commands/plan-w-team/shared/secret-safety.md")
            echo "[pre-commit-quality] secret-doc-sync --check output:" >&2
            printf '%s\n' "$SYNC_OUT" >&2
        fi
    else
        WARNINGS+=("secret-scan.sh staged but secret-doc-sync.sh not executable — skipping doc-sync check")
    fi
fi

# Count drift detection — warn when CLAUDE.md counts diverge from reality
# Triggers when staging CLAUDE.md, agents/, or hooks/
DRIFT_CHECK=false
while IFS= read -r file; do
    case "$file" in
        CLAUDE.md|.claude/agents/*|.claude/hooks/*) DRIFT_CHECK=true; break ;;
    esac
done <<< "$STAGED_FILES"

if [ "$DRIFT_CHECK" = "true" ] && [ -f "CLAUDE.md" ]; then
    ACTUAL_AGENTS=$(find .claude/agents -name "*.md" 2>/dev/null | wc -l | tr -d ' ')

    # Extract claimed agent count from CLAUDE.md (first "Agents: NNN" occurrence)
    CLAIMED_AGENTS=$(grep -oE 'Agents.*?[0-9]+' CLAUDE.md | head -1 | grep -oE '[0-9]+' | head -1)

    if [ -n "$CLAIMED_AGENTS" ] && [ "$CLAIMED_AGENTS" != "$ACTUAL_AGENTS" ]; then
        WARNINGS+=("Count drift: CLAUDE.md claims $CLAIMED_AGENTS agents but $ACTUAL_AGENTS exist on disk — update CLAUDE.md")
    fi
fi

# Check conventional commit message format if -m flag is present
COMMIT_MSG=""
if echo "$COMMAND" | grep -qE '\-m\s'; then
    # Extract the message after -m flag — handle both -m "msg" and -m 'msg'
    COMMIT_MSG=$(echo "$COMMAND" | sed -n "s/.*-m[[:space:]]*['\"]\\([^'\"]*\\)['\"].*/\\1/p")
    if [ -z "$COMMIT_MSG" ]; then
        # Try without quotes (heredoc style won't be captured but that's OK)
        COMMIT_MSG=$(echo "$COMMAND" | sed -n 's/.*-m[[:space:]]*\([^[:space:]]*\).*/\1/p')
    fi

    if [ -n "$COMMIT_MSG" ]; then
        # Check conventional commit format
        if ! echo "$COMMIT_MSG" | grep -qE '^(feat|fix|docs|style|refactor|test|chore|build|ci|perf|revert)(\(.+\))?: .+'; then
            WARNINGS+=("Commit message does not follow conventional commit format (feat|fix|docs|...): <description>")
        fi
    fi
fi

# Log findings
if [ "$LOGGING_ENABLED" = "true" ]; then
    err_count=${#ERRORS[@]}
    warn_count=${#WARNINGS[@]}
    log_hook "pre_commit_quality" "Bash" "checked" "errors=$err_count warnings=$warn_count"
fi

# Report findings
if [ ${#ERRORS[@]} -gt 0 ]; then
    # Build error message for additionalContext
    ERROR_MSG="PRE-COMMIT QUALITY GATE FAILED:\\n"
    for err in "${ERRORS[@]}"; do
        ERROR_MSG+="  ERROR: $err\\n"
        echo "[pre-commit-quality] ERROR: $err" >&2
    done
    for warn in "${WARNINGS[@]}"; do
        ERROR_MSG+="  WARNING: $warn\\n"
        echo "[pre-commit-quality] WARNING: $warn" >&2
    done
    ERROR_MSG+="Fix errors before committing. Remove debugger statements and secrets from staged files."

    echo "{\"decision\": \"block\", \"reason\": \"Pre-commit quality check failed\", \"systemMessage\": \"$ERROR_MSG\"}"
    exit 2
fi

if [ ${#WARNINGS[@]} -gt 0 ]; then
    for warn in "${WARNINGS[@]}"; do
        echo "[pre-commit-quality] WARNING: $warn" >&2
    done
fi

# Allow — echo input back unchanged
echo "$INPUT"
exit 0
