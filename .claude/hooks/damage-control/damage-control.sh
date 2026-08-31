#!/bin/bash
# Claude Code Damage Control Hook
# Implements three-tier protection: zeroAccess > readOnly > noDelete
# Plus dangerous command blocking with ask mode for risky operations
#
# Adapted from disler/claude-code-damage-control

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PATTERNS_FILE="$SCRIPT_DIR/patterns.yaml"
UTILS_DIR="$(dirname "$SCRIPT_DIR")/utils"

# Source JSON logger if available
if [ -f "$UTILS_DIR/json-logger.sh" ]; then
    source "$UTILS_DIR/json-logger.sh"
    LOGGING_ENABLED=true
else
    LOGGING_ENABLED=false
fi

# Read input from Claude Code
INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | grep -o '"tool_name"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*:[[:space:]]*"\([^"]*\)".*/\1/' || echo "")

# Helper: Output JSON response (v2.1.0+ additionalContext support)
respond() {
    local decision="$1"
    local reason="$2"
    local message="$3"
    local target="${4:-unknown}"

    # Log security event
    if [ "$LOGGING_ENABLED" = "true" ]; then
        log_security "damage_control" "$TOOL_NAME" "$reason" "$decision" "$target"
    fi

    # Build additionalContext for Claude to understand the block reason
    local context="DAMAGE CONTROL: $reason. Target: $target. This is a safety guardrail - consider alternative approaches."

    # -----------------------------------------------------------------------
    # HOOK ENFORCEMENT CONTRACT (fixed 2026-07-26)
    # -----------------------------------------------------------------------
    # Registered PreToolUse (Bash|Write|Edit|MultiEdit|Read). Contract:
    #   exit 0 → allow; stdout IS parsed for JSON control
    #   exit 2 → BLOCK; STDERR is shown to Claude; stdout is NOT parsed
    #   other  → non-blocking error; the tool call PROCEEDS
    # (CLAUDE_CODE_CLI_REFERENCE.md:471-477;
    #  .claude/skills/ai-engineering/references/claude-sdk/docs/hooks.md:126-138)
    #
    # Two bugs fixed here:
    #  1. `block` printed its reason to STDOUT and exited 2. The exit code did
    #     block, but on exit 2 stdout is not parsed — so Claude never saw WHY.
    #     The reason now goes to STDERR.
    #  2. `ask` emitted a legacy TOP-LEVEL {"decision":"ask"} and exit 0. For
    #     PreToolUse the schema is hookSpecificOutput.permissionDecision
    #     (hooks.md:249-262); the top-level form is PermissionRequest's
    #     (CLAUDE_CODE_CLI_REFERENCE.md:484-492). Exit 0 with an unrecognized
    #     payload means ALLOW, so the whole ask tier — DROP/TRUNCATE TABLE,
    #     gcloud/az delete, docker system prune, redis-cli FLUSHDB, and the
    #     final-artifact rm guard — was inert in every lane.
    local esc_reason esc_message esc_context
    esc_reason=$(printf '%s' "$reason" | sed 's/\\/\\\\/g; s/"/\\"/g')
    esc_message=$(printf '%s' "$message" | sed 's/\\/\\\\/g; s/"/\\"/g')
    esc_context=$(printf '%s' "$context" | sed 's/\\/\\\\/g; s/"/\\"/g')

    if [ "$decision" = "block" ]; then
        printf '⛔ BLOCKED (damage-control): %s\n%s\n' "$reason" "$message" >&2
        exit 2
    elif [ "$decision" = "ask" ]; then
        # An `ask` needs a human at the keyboard. A bg /plan-w-team worker has
        # none, and under the standing `bypassPermissions` posture an ask
        # auto-approves — so in an unattended session `ask` silently degrades to
        # `allow` on exactly the irreversible operations it exists to gate.
        # Fail closed there instead; interactive sessions still get the prompt.
        # Escape hatch, consistent with the other guards:
        #   PLAN_W_TEAM_ALLOW_DESTRUCTIVE_UNATTENDED=1
        if [ "${PLAN_W_TEAM_DISABLE_PROMPT_ROUTE:-}" = "1" ] \
           && [ "${PLAN_W_TEAM_ALLOW_DESTRUCTIVE_UNATTENDED:-}" != "1" ]; then
            printf '⛔ BLOCKED (damage-control, unattended): %s\n%s\nThis operation is gated by an `ask` that no one can answer inside a bg worker. Surface a pending_escalation to the human, or re-run interactively. Override: PLAN_W_TEAM_ALLOW_DESTRUCTIVE_UNATTENDED=1\n' \
                "$reason" "$message" >&2
            exit 2
        fi
        printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"%s"},"systemMessage":"%s","additionalContext":"%s"}\n' \
            "$esc_reason" "$esc_message" "$esc_context"
        exit 0
    else
        exit 0
    fi
}

# Helper: Check if path matches any pattern in a list
path_matches() {
    local path="$1"
    local patterns="$2"

    while IFS= read -r pattern; do
        [ -z "$pattern" ] && continue
        # Expand ~ to home directory
        local expanded_pattern="${pattern/#\~/$HOME}"

        # Check for glob match
        if [[ "$path" == $expanded_pattern ]] || [[ "$path" == *"$expanded_pattern"* ]]; then
            return 0
        fi
    done <<< "$patterns"
    return 1
}

# Extract file path from input (for Edit/Write tools)
get_file_path() {
    echo "$INPUT" | grep -o '"file_path"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*:[[:space:]]*"\([^"]*\)".*/\1/' || echo ""
}

# Extract command from input (for Bash tool)
get_command() {
    echo "$INPUT" | grep -o '"command"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*:[[:space:]]*"\([^"]*\)".*/\1/' || echo ""
}

# Extract the PreToolUse payload's cwd (the dir the Bash command runs in), so a
# relative rm target (e.g. `rm -rf build`) resolves to the same path the command
# would actually delete — not the hook process's own CWD. Empty when absent.
get_cwd() {
    echo "$INPUT" | grep -o '"cwd"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*:[[:space:]]*"\([^"]*\)".*/\1/' || echo ""
}

# =============================================================================
# CONSUMER-LOCAL ADDITIONS — patterns.local.conf sidecar (append-only, data-only)
# =============================================================================
# A consumer (a synced repo) may add its OWN block/ask/path guards WITHOUT editing
# this file — which the sync overwrites wholesale every run (the silent-clobber
# class that twice wiped cleanscale's mobile-store one-way-door guard). They live
# in a sidecar `patterns.local.conf` beside this script; the SOURCE (claude-pattern)
# never ships that filename, so no rsync copy overwrites or deletes it, and a
# default `*.local.*` exclude + a retired-path guard back it up (see
# docs/operations/skill-upgrade-propagation.md).
#
# GUARANTEES (all tested):
#   • APPEND-ONLY / can only ESCALATE — the loader only appends to these arrays;
#     they are evaluated by severity, not origin: DC_LOCAL_BLOCK runs BEFORE the
#     built-in safe-rm allow and the built-in ask loops (a local block wins over a
#     built-in allow/ask); it can never de-escalate a built-in block.
#   • DATA-ONLY — the file is read line-by-line and its values are used ONLY as
#     quoted grep-ERE / substring data. It is NEVER sourced or eval'd, so a value
#     containing $(...), backticks, or ; is matched literally, never executed.
#   • FAIL-OPEN TO THE BUILT-INS, NEVER TO NO GUARD — a missing/unreadable/binary
#     file is a no-op; the built-ins still enforce. `set -e` is active and the
#     hook's contract treats a non-2 exit as "tool PROCEEDS", so the loader is
#     guarded (`[ -r ]` + invoked as `load_local_patterns || true`) to never abort
#     the hook with a non-2 exit — which would fail open to NO guard.
# Kill switch: DAMAGE_CONTROL_DISABLE_LOCAL=1. Override path: DAMAGE_CONTROL_LOCAL_FILE.
DC_LOCAL_FILE="${DAMAGE_CONTROL_LOCAL_FILE:-$SCRIPT_DIR/patterns.local.conf}"
DC_LOCAL_BLOCK=(); DC_LOCAL_BLOCK_CI=(); DC_LOCAL_ASK=(); DC_LOCAL_ASK_CI=()
DC_LOCAL_ZERO=(); DC_LOCAL_READONLY=(); DC_LOCAL_NODELETE=()

# Validate a consumer-supplied ERE actually compiles; log + reject if it does not
# (a malformed regex would make grep -E exit 2, read as "no match" inside the check,
# and silently never fire — the exact "believes they're guarded but aren't" class
# this feature exists to close). grep on empty input: valid regex → exit 1, invalid
# → exit 2, so rc<=1 means it compiles.
_dc_ere_ok() {  # $1 = pattern, $2 = key label
    printf '' | grep -qE "$1" 2>/dev/null
    [ "$?" -le 1 ] && return 0
    _dc_local_warn "ignored invalid ERE for key '$2': $1"
    return 1
}

# Warn about a local-conf problem to BOTH the security log and stderr (log may be
# unavailable when hooks/utils/ is excluded; stderr is always there). A dropped
# guard the consumer thinks is active is the exact class this feature closes.
DC_LOCAL_LOADED=0
_dc_local_warn() {  # $1 = message
    printf '⚠ damage-control(patterns.local.conf): %s [%s]\n' "$1" "$DC_LOCAL_FILE" >&2
    if [ "$LOGGING_ENABLED" = "true" ]; then
        log_security "damage_control_local" "$TOOL_NAME" "$1" "ignored" "$DC_LOCAL_FILE" 2>/dev/null || true
    fi
}

load_local_patterns() {
    [ "${DAMAGE_CONTROL_DISABLE_LOCAL:-}" = "1" ] && { DC_LOCAL_LOADED=1; return 0; }
    [ -f "$DC_LOCAL_FILE" ] || { DC_LOCAL_LOADED=1; return 0; }
    if [ ! -r "$DC_LOCAL_FILE" ]; then
        # Exists but unreadable — fail open to the built-ins, but SAY SO (an
        # operational fault the consumer must learn about, not a silent no-op).
        _dc_local_warn "exists but is unreadable — local guards NOT loaded"
        DC_LOCAL_LOADED=1; return 0
    fi
    local line key val
    # `|| [ -n "$line" ]` catches a final line with no trailing newline.
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"                            # strip a trailing CR (CRLF files)
        line="${line#"${line%%[![:space:]]*}"}"         # strip leading whitespace
        line="${line%"${line##*[![:space:]]}"}"         # strip trailing whitespace
        case "$line" in ''|'#'*) continue ;; esac
        case "$line" in
            *:*) : ;;
            *) _dc_local_warn "ignored malformed line (expected 'key: value'): $line"; continue ;;
        esac
        key="${line%%:*}"
        val="${line#*:}"
        val="${val#"${val%%[![:space:]]*}"}"            # strip leading ws on value
        val="${val%"${val##*[![:space:]]}"}"            # strip trailing ws on value
        if [ -z "$val" ]; then _dc_local_warn "ignored empty value for key '$key'"; continue; fi
        case "$key" in
            block)                _dc_ere_ok "$val" block   && DC_LOCAL_BLOCK+=("$val") ;;
            blockCI|block_ci)     _dc_ere_ok "$val" blockCI && DC_LOCAL_BLOCK_CI+=("$val") ;;
            ask)                  _dc_ere_ok "$val" ask     && DC_LOCAL_ASK+=("$val") ;;
            askCI|ask_ci)         _dc_ere_ok "$val" askCI   && DC_LOCAL_ASK_CI+=("$val") ;;
            zeroAccess|zero_access) DC_LOCAL_ZERO+=("$val") ;;
            readOnly|read_only)   DC_LOCAL_READONLY+=("$val") ;;
            noDelete|no_delete)   DC_LOCAL_NODELETE+=("$val") ;;
            *) _dc_local_warn "ignored unknown key: $key" ;;
        esac
    done < "$DC_LOCAL_FILE"
    DC_LOCAL_LOADED=1
    return 0
}

# =============================================================================
# BASH COMMAND PROTECTION
# =============================================================================
check_bash_command() {
    local cmd="$1"

    # ── CONSUMER-LOCAL BLOCK (patterns.local.conf) ────────────────────────────
    # Evaluated FIRST — before EVERYTHING, including the final-artifact guard's
    # `ask` — so a local block is the highest severity and always wins over a
    # built-in allow/ask (severity, not origin). It can never de-escalate a
    # built-in block. Data-only: $_lp is a quoted grep-ERE pattern, never eval'd.
    local _lp
    for _lp in "${DC_LOCAL_BLOCK[@]}"; do
        if echo "$cmd" | grep -qE "$_lp"; then
            respond "block" "Consumer-local block (patterns.local.conf)" "⛔ BLOCKED by a consumer-local guard: $_lp" "$cmd"
        fi
    done
    for _lp in "${DC_LOCAL_BLOCK_CI[@]}"; do
        if echo "$cmd" | grep -qiE "$_lp"; then
            respond "block" "Consumer-local block (patterns.local.conf)" "⛔ BLOCKED by a consumer-local guard: $_lp" "$cmd"
        fi
    done

    # ── FINAL-ARTIFACT GUARD (build-artifact-preservation, 1.28.0) ────────────
    # An rm -rf must NOT be blanket-allowed by the safe_rm_targets short-circuit
    # below if it would delete a FINAL installable (*.app/*.ipa/*.apk/*.aab) or
    # the protected kept-artifacts home. This runs FIRST — before both the
    # safe-target allow and the generic dangerous-rm block — so installables are
    # preserved-by-default even inside build/dist/target. It inspects the REAL
    # filesystem, not just the command string. Pure-intermediate rm -rf (no
    # installable present) falls through unchanged, so the GB-scale reclaim path
    # is not regressed. Mirrors the proactive layer in
    # .claude/scripts/plan-w-team-build-artifact-clean.sh; policy at
    # docs/operations/build-cleanup-preserve-installables.md.
    if echo "$cmd" | grep -qE 'rm\s+(-[^\s]*)?-[rf]'; then
        local _kept_home="${PWT_KEPT_ARTIFACTS_HOME:-.playwright-mcp}"
        local _cwd; _cwd=$(get_cwd)
        local _tok _abs _found _frc
        for _tok in $cmd; do
            case "$_tok" in -*|rm|sudo|'&&'|'||'|';'|'|') continue ;; esac
            _tok="${_tok%/}"
            [ -z "$_tok" ] && continue
            # Protected kept-artifacts home → hard block (string match on the token;
            # the home holds preserved installables and must never be cleanup-deleted).
            case "$_tok" in
                "$_kept_home"|"$_kept_home"/*|*/"$_kept_home"|*/"$_kept_home"/*)
                    respond "block" "rm -rf of the protected kept-artifacts home" \
                      "⛔ BLOCKED: the kept-artifacts home ($_kept_home) must never be deleted — it holds preserved installables (.app/.ipa/.apk/.aab). See docs/operations/build-cleanup-preserve-installables.md" "$_tok" ;;
            esac
            # Resolve a RELATIVE target against the payload cwd (the dir the command
            # actually runs in) so `rm -rf build` is scanned at the right path, not
            # the hook process's CWD. Absolute tokens are used as-is.
            _abs="$_tok"
            case "$_tok" in /*) : ;; *) [ -n "$_cwd" ] && _abs="$_cwd/$_tok" ;; esac
            # Target IS a final installable (extension on the token) → ask.
            case "$_tok" in
                *.app|*.ipa|*.apk|*.aab)
                    respond "ask" "rm -rf targets a final installable" \
                      "⚠️ CONFIRM: '$_tok' is a final installable (.app/.ipa/.apk/.aab). Preserve it (copy to the kept-artifacts home) before deleting, or confirm. See docs/operations/build-cleanup-preserve-installables.md" "$_tok" ;;
            esac
            [ -d "$_abs" ] || continue
            # Scan the dir for installables. FAIL CLOSED: if find could not fully
            # enumerate (unreadable subdir / FS error), do NOT fall through to the
            # safe_rm allow — ask, so an unenumerated installable is not deleted.
            if _found=$(find "$_abs" \( -name '*.app' -o -name '*.ipa' -o -name '*.apk' -o -name '*.aab' \) -prune -print 2>/dev/null); then
                _frc=0
            else
                _frc=$?
            fi
            if [ "$_frc" -ne 0 ]; then
                respond "ask" "rm -rf target could not be scanned for installables" \
                  "⚠️ CONFIRM: could not fully scan '$_tok' for final installables (find error). Preserve any installable before deleting, or confirm. See docs/operations/build-cleanup-preserve-installables.md" "$_tok"
            fi
            if [ -n "$_found" ]; then
                respond "ask" "rm -rf target contains a final installable" \
                  "⚠️ CONFIRM: '$_tok' contains a final installable (.app/.ipa/.apk/.aab). Preserve it before deleting, or confirm. See docs/operations/build-cleanup-preserve-installables.md" "$_tok"
            fi
        done
    fi

    # Safe targets for rm -rf — build caches and generated artifacts
    # These are always safe to delete and should never be blocked
    local safe_rm_targets=(
        '\.next'
        'node_modules'
        'dist'
        'target'
        'build'
        '__pycache__'
        '\.turbo'
        '\.parcel-cache'
        '\.cache'
        '\.tsbuildinfo'
    )

    # If this is an rm -rf command, check if it targets a safe directory
    if echo "$cmd" | grep -qE 'rm\s+(-[^\s]*)?-[rf]'; then
        for safe in "${safe_rm_targets[@]}"; do
            if echo "$cmd" | grep -qE "rm\s+(-[^\s]*)?-[rf]+\s+.*${safe}"; then
                # Safe build cache cleanup — allow without blocking
                return 0
            fi
        done
    fi

    # Dangerous patterns that should be blocked
    local block_patterns=(
        'rm\s+(-[^\s]*)?(-(rf|fr)|[^\s]*rf|[^\s]*fr)'
        'rmdir\s+--ignore-fail-on-non-empty'
        'chmod\s+777'
        'chown\s+(-R|--recursive)\s+root'
        'git\s+reset\s+--hard'
        'git\s+clean\s+-[fd]'
        'git\s+push.*--force([^-]|$)'
        'git\s+push.*\s-f([^o]|$)'
        'git\s+checkout\s+\.\s*$'
        'git\s+restore\s+\.\s*$'
        'git\s+stash\s+clear'
        'aws\s+ec2\s+terminate-instances'
        'aws\s+rds\s+delete-db'
        'aws\s+s3\s+rb.*--force'
        'terraform\s+destroy'
        'pulumi\s+destroy'
        'kubectl\s+delete\s+namespace'
        'kubectl\s+delete.*--all'
        'docker\s+rm\s+-f.*\$\(docker\s+ps'
        'npm\s+unpublish'
        'redis-cli.*FLUSHALL'
    )

    # Case-insensitive patterns (SQL)
    local block_patterns_ci=(
        'DROP\s+DATABASE'
        'DELETE\s+FROM\s+\w+\s*;?$'
    )

    # Patterns that should prompt for confirmation
    local ask_patterns=(
        'git\s+branch\s+-[dD]'
        'git\s+stash\s+drop'
        'git\s+push.*origin\s+(main|master)\b'
        'gcloud.*delete'
        'az\s+.*\s+delete'
        'docker\s+system\s+prune'
        'redis-cli.*FLUSHDB'
        'cargo\s+yank'
    )

    local ask_patterns_ci=(
        'DROP\s+TABLE'
        'TRUNCATE\s+TABLE'
        'DELETE\s+FROM.*WHERE'
    )

    # Check block patterns
    for pattern in "${block_patterns[@]}"; do
        if echo "$cmd" | grep -qE "$pattern"; then
            respond "block" "Dangerous command blocked" "⛔ BLOCKED: Command matches dangerous pattern: $pattern" "$cmd"
        fi
    done

    # Check case-insensitive block patterns
    for pattern in "${block_patterns_ci[@]}"; do
        if echo "$cmd" | grep -qiE "$pattern"; then
            respond "block" "Dangerous SQL blocked" "⛔ BLOCKED: SQL command is too dangerous: $pattern" "$cmd"
        fi
    done

    # Check ask patterns
    for pattern in "${ask_patterns[@]}"; do
        if echo "$cmd" | grep -qE "$pattern"; then
            respond "ask" "Risky command requires confirmation" "⚠️ CONFIRM: This command requires approval: $pattern" "$cmd"
        fi
    done

    # Check case-insensitive ask patterns
    for pattern in "${ask_patterns_ci[@]}"; do
        if echo "$cmd" | grep -qiE "$pattern"; then
            respond "ask" "Risky SQL requires confirmation" "⚠️ CONFIRM: This SQL requires approval: $pattern" "$cmd"
        fi
    done

    # ── CONSUMER-LOCAL ASK (patterns.local.conf) ──────────────────────────────
    # Evaluated AFTER the built-in block/ask loops so a local ask can never
    # downgrade a built-in block; it adds an ask where the built-ins are silent.
    for _lp in "${DC_LOCAL_ASK[@]}"; do
        if echo "$cmd" | grep -qE "$_lp"; then
            respond "ask" "Consumer-local ask (patterns.local.conf)" "⚠️ CONFIRM: consumer-local guard requires approval: $_lp" "$cmd"
        fi
    done
    for _lp in "${DC_LOCAL_ASK_CI[@]}"; do
        if echo "$cmd" | grep -qiE "$_lp"; then
            respond "ask" "Consumer-local ask (patterns.local.conf)" "⚠️ CONFIRM: consumer-local guard requires approval: $_lp" "$cmd"
        fi
    done
}

# =============================================================================
# FILE PATH PROTECTION
# =============================================================================
check_file_path() {
    local path="$1"
    local operation="$2"  # read, write, edit, delete

    # ── CONSUMER-LOCAL zeroAccess (patterns.local.conf) ───────────────────────
    # Evaluated BEFORE the .example allow short-circuit so a local zero-access
    # rule can ESCALATE over the built-in .example allowance. Data-only globbing.
    local _lp
    for _lp in "${DC_LOCAL_ZERO[@]}"; do
        if [[ "$path" == *"$_lp"* ]] || [[ "$path" == $_lp ]]; then
            respond "block" "Consumer-local zero-access (patterns.local.conf)" "⛔ BLOCKED by a consumer-local guard: $path matches $_lp" "$path"
        fi
    done

    # Allow .example template files (they contain dummy values, not real secrets)
    if [[ "$path" == *.example ]]; then
        return 0
    fi

    # Zero Access Paths - Block everything (except .example templates handled above)
    local zero_access=(
        "/.env"
        ".env.local"
        ".env.production"
        ".env.development"
        ".env.staging"
        "*.env"
        ".ssh/"
        "*.pem"
        "*.key"
        "id_rsa"
        "id_ed25519"
        ".gnupg/"
        ".aws/"
        ".config/gcloud/"
        ".azure/"
        ".kube/config"
        "*.tfstate"
        ".npmrc"
        ".pypirc"
        ".netrc"
        "*.p12"
        "*.pfx"
        "*secret*.json"
        "*credential*.json"
        "*token*.json"
        # Multi-account (/plan-w-team) live-token stores (F7): the per-lane
        # settings.local.json carries CLAUDE_CODE_OAUTH_TOKEN; the machine-global
        # claude-pwt/ store holds the registry (tokens), usage cache, and selection
        # log. Blocking Read/Write/Edit here stops a reviewer/evaluator agent from
        # reading a token into its transcript. Substring-matched (no ~ /
        # $XDG_CONFIG_HOME expansion), so `claude-pwt/` covers any XDG location.
        # KEEP IN SYNC with patterns.yaml zeroAccessPaths (declarative mirror).
        ".claude/settings.local.json"
        "claude-pwt/"
    )

    for pattern in "${zero_access[@]}"; do
        if [[ "$path" == *"$pattern"* ]] || [[ "$path" == $pattern ]]; then
            respond "block" "Zero-access path" "⛔ BLOCKED: This path contains secrets/credentials and cannot be accessed: $path" "$path"
        fi
    done

    # Read-Only Paths - Block write/edit/delete
    if [ "$operation" != "read" ]; then
        local read_only=(
            "/etc/"
            "/usr/"
            "/System/"
            "node_modules/"
            "target/"
            "dist/"
            ".next/"
            "__pycache__/"
            "package-lock.json"
            "yarn.lock"
            "pnpm-lock.yaml"
            "Cargo.lock"
        )

        for pattern in "${read_only[@]}"; do
            if [[ "$path" == *"$pattern"* ]]; then
                respond "block" "Read-only path" "⛔ BLOCKED: This path is read-only and cannot be modified: $path" "$path"
            fi
        done

        # CONSUMER-LOCAL readOnly additions (patterns.local.conf)
        for _lp in "${DC_LOCAL_READONLY[@]}"; do
            if [[ "$path" == *"$_lp"* ]] || [[ "$path" == $_lp ]]; then
                respond "block" "Consumer-local read-only (patterns.local.conf)" "⛔ BLOCKED by a consumer-local guard: $path is read-only ($_lp)" "$path"
            fi
        done
    fi

    # No-Delete Paths - Block only deletion
    if [ "$operation" = "delete" ]; then
        local no_delete=(
            "README.md"
            "LICENSE"
            "CHANGELOG.md"
            ".git/"
            ".gitignore"
            "Dockerfile"
            "docker-compose.yml"
            "Makefile"
            "Cargo.toml"
            "package.json"
            "tsconfig.json"
            ".claude/"
            "CLAUDE.md"
        )

        for pattern in "${no_delete[@]}"; do
            if [[ "$path" == *"$pattern"* ]]; then
                respond "block" "No-delete path" "⛔ BLOCKED: This critical file cannot be deleted: $path" "$path"
            fi
        done

        # CONSUMER-LOCAL noDelete additions (patterns.local.conf)
        for _lp in "${DC_LOCAL_NODELETE[@]}"; do
            if [[ "$path" == *"$_lp"* ]] || [[ "$path" == $_lp ]]; then
                respond "block" "Consumer-local no-delete (patterns.local.conf)" "⛔ BLOCKED by a consumer-local guard: $path cannot be deleted ($_lp)" "$path"
            fi
        done
    fi
}

# =============================================================================
# WRITE/EDIT CONTENT SECRET SCAN (B1 — make the advertised defense real)
# =============================================================================
# 03-execute.md advertises an active Edit/Write secret-content blocker, and
# patterns.yaml carried a `secretDetection:` block — but the Write|Edit case only
# ever ran check_file_path (a PATH check). The content was never scanned, so a
# live secret could be written into any non-zeroAccess file and sit in the tree /
# logs / transcripts until commit time. This wires the REAL defense: extract the
# content the tool is about to write and run it through secret-scan.sh — the
# single source of truth (placeholder suppression incl. the B3 token-adjacency
# fix, auto-generated-catalog skip, per-feature allow-files, redaction). A live
# hit blocks the Write/Edit. Kill switch: DAMAGE_CONTROL_DISABLE_SECRET_CONTENT=1
# (and the harness-level CLAUDE_DISABLED_HOOKS / CLAUDE_HOOK_PROFILE still apply).
SECRET_SCANNER="$SCRIPT_DIR/../../scripts/secret-scan.sh"

# Extract the content field the tool will write: `content` (Write) or
# `new_string` (Edit). Robust to multi-line / escaped JSON: jq → python3 →
# single-line grep/sed fallback. Always succeeds (may print empty).
extract_tool_content() {
    local out=""
    if command -v jq >/dev/null 2>&1; then
        out=$(printf '%s' "$INPUT" | jq -r '.tool_input.content // .tool_input.new_string // empty' 2>/dev/null || true)
        [ -n "$out" ] && { printf '%s' "$out"; return 0; }
    fi
    if command -v python3 >/dev/null 2>&1; then
        out=$(printf '%s' "$INPUT" | python3 -c 'import sys, json
try:
    d = json.load(sys.stdin); ti = d.get("tool_input", {})
    sys.stdout.write(ti.get("content") or ti.get("new_string") or "")
except Exception:
    pass' 2>/dev/null || true)
        [ -n "$out" ] && { printf '%s' "$out"; return 0; }
    fi
    printf '%s' "$INPUT" \
      | grep -oE '"(content|new_string)"[[:space:]]*:[[:space:]]*"[^"]*"' \
      | sed -E 's/.*:[[:space:]]*"(.*)"/\1/' || true
}

check_secret_content() {
    [ "${DAMAGE_CONTROL_DISABLE_SECRET_CONTENT:-}" = "1" ] && return 0
    [ -x "$SECRET_SCANNER" ] || return 0   # scanner missing → fail open (path check already ran)
    local content
    content=$(extract_tool_content)
    [ -z "$content" ] && return 0
    local tmp
    tmp=$(mktemp -t dc-secret.XXXXXX 2>/dev/null) || return 0
    printf '%s' "$content" > "$tmp"
    # Aggregate per-feature allow-files (same single source of truth pre-commit
    # uses), rooted at the payload cwd or the hook's own repo as fallback.
    local cwd agg="" allow
    cwd=$(get_cwd)
    [ -n "$cwd" ] || cwd="$(cd "$SCRIPT_DIR/../../.." 2>/dev/null && pwd)"
    for allow in "$cwd"/.claude/state/plan-w-team-secret-scan-allow-*; do
        [ -f "$allow" ] || continue
        [ -z "$agg" ] && agg=$(mktemp -t dc-allow.XXXXXX 2>/dev/null)
        [ -n "$agg" ] && cat "$allow" >> "$agg"
    done
    local rc=0
    if [ -n "$agg" ]; then
        "$SECRET_SCANNER" --allow "$agg" --paths "$tmp" >/dev/null 2>&1 || rc=$?
    else
        "$SECRET_SCANNER" --paths "$tmp" >/dev/null 2>&1 || rc=$?
    fi
    rm -f "$tmp" "$agg" 2>/dev/null || true
    if [ "$rc" -eq 1 ]; then
        respond "block" "Live secret in Write/Edit content" "⛔ BLOCKED: a live secret pattern was detected in the content you are about to write. Use a placeholder (e.g. YOUR_KEY_HERE) or an environment-variable reference instead of a hardcoded secret. (damage-control content scan via secret-scan.sh)" "secret-content"
    fi
}

# =============================================================================
# MAIN LOGIC
# =============================================================================

# Load consumer-local additions (patterns.local.conf sidecar) into the DC_LOCAL_*
# arrays before dispatch. `|| true` is load-bearing: the hook runs `set -e`, and a
# non-2 exit from here would make the whole hook a "non-blocking error → tool
# PROCEEDS" (fail-open to NO guard). This guarantees fail-open to the BUILT-INS.
load_local_patterns || true
# Partial-load guard: `|| true` is load-bearing (a non-2 exit would fail open to
# NO guard), but it also means an aborted load could leave DC_LOCAL_* partially
# populated with no signal. The sentinel is set only when the loader ran to the
# end; if it didn't, say so (the built-ins still enforce regardless).
[ "${DC_LOCAL_LOADED:-0}" = "1" ] || printf '⚠ damage-control: patterns.local.conf load did not complete — local guards may be partial\n' >&2

case "$TOOL_NAME" in
    Bash)
        cmd=$(get_command)
        if [ -n "$cmd" ]; then
            check_bash_command "$cmd"
        fi
        ;;

    Write|Edit)
        path=$(get_file_path)
        if [ -n "$path" ]; then
            check_file_path "$path" "write"
        fi
        check_secret_content
        ;;

    Read)
        path=$(get_file_path)
        if [ -n "$path" ]; then
            check_file_path "$path" "read"
        fi
        ;;
esac

# If we get here, allow the operation
exit 0
