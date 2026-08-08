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

# Recompute the watched-tree digest the way test-green.sh records it, but sourcing
# STAGED content for staged files: the gate must corroborate what is about to be
# committed, not what happens to be sitting in the working tree. Unstaged watched
# files use their working-tree blob (or HEAD's, if deleted) — the same content the
# suite saw. Prints an empty string on any failure; the caller fails closed.
_pwt_staged_tree_digest() {
    local root="$1" g
    local globs=()
    while IFS= read -r g; do
        [ -n "$g" ] || continue
        globs+=("$g")
    done <<EOF
$PWT_WATCHED_GLOBS
EOF
    (
      set +e
      cd "$root" 2>/dev/null || exit 0
      staged_list=$(mktemp -t pwt-gate-staged.XXXXXX) || exit 0
      git diff --cached --name-only --diff-filter=ACMR > "$staged_list" 2>/dev/null
      files=$(git ls-files --cached --others --exclude-standard -- "${globs[@]}" 2>/dev/null | LC_ALL=C sort)
      # Fail closed on an empty watched set — see the matching guard in
      # plan-w-team-test-green.sh. Both sides would otherwise agree on the digest
      # of nothing, so a broken enumeration would corroborate itself.
      if [ -z "$files" ]; then rm -f "$staged_list" 2>/dev/null; exit 0; fi
      printf '%s\n' "$files" \
        | while IFS= read -r f; do
            [ -n "$f" ] || continue
            h=""
            if grep -qFx -- "$f" "$staged_list" 2>/dev/null; then
                h=$(git rev-parse ":$f" 2>/dev/null)
            fi
            if [ -z "$h" ]; then
                if [ -f "$f" ]; then
                    h=$(git hash-object --path "$f" -- "$f" 2>/dev/null)
                else
                    h=$(git rev-parse "HEAD:$f" 2>/dev/null)
                fi
            fi
            [ -n "$h" ] || h="-"
            printf '%s:%s\n' "$f" "$h"
          done \
        | shasum -a 256 2>/dev/null | awk '{print $1}'
      rm -f "$staged_list" 2>/dev/null
    )
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
        elif [ -z "$TG_ART" ]; then
            TG_BLOCK="no test-green verdict in $TG_STATE_DIR — the skill suite has not been run for this checkout"
        elif ! jq -e . "$TG_ART" >/dev/null 2>&1; then
            TG_BLOCK="test-green verdict is not valid JSON: $TG_ART"
        else
            TG_SLUG=$(jq -r '.slug // ""' "$TG_ART" 2>/dev/null || echo "")
            TG_GREEN=$(jq -r '.green // false' "$TG_ART" 2>/dev/null || echo "false")
            TG_DIGEST=$(jq -r '.tree_digest // ""' "$TG_ART" 2>/dev/null || echo "")
            TG_LOG=$(jq -r '.log_path // ""' "$TG_ART" 2>/dev/null || echo "")

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
                TG_ACTUAL=$(_pwt_staged_tree_digest "$TG_ROOT")
                if [ -z "$TG_ACTUAL" ]; then
                    TG_BLOCK="the staged-content digest could not be computed, so the verdict cannot be corroborated"
                elif [ "$TG_ACTUAL" != "$TG_DIGEST" ]; then
                    TG_BLOCK="tree_digest mismatch — the suite ran against different content than what is staged (verdict ${TG_DIGEST%"${TG_DIGEST#??????????}"}…, staged ${TG_ACTUAL%"${TG_ACTUAL#??????????}"}…)"
                fi
            fi
        fi

        if [ -n "$TG_BLOCK" ]; then
            ERRORS+=("plan-w-team commit gate: $TG_BLOCK — run the suite out of band: .claude/scripts/plan-w-team-test-green.sh --slug ${TG_SLUG:-<slug>}   then re-commit")
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
