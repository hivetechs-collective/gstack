#!/usr/bin/env bash
# skill-test-precommit-installer.sh
#
# Installs (or removes) a pre-commit invocation of the /plan-w-team skill
# E2E test runner. Detects the target repo's existing hook system and
# integrates without clobbering — so it works in claude-pattern (.githooks),
# cleanscale (.husky), and any repo using lefthook or pre-commit too.
#
# Why this exists:
# Cleanscale disabled GitHub Actions on 2026-05-18 (PR #108) after burning
# 1000-1250 minutes in one session. They moved gating to local hooks via
# husky. Other repos may use lefthook, pre-commit (the Python tool), or
# plain .githooks/. The skill-test framework is git-hosted per repo; the
# pre-commit invocation must therefore adapt to whatever hook system the
# target uses, not assume one path.
#
# Usage:
#   skill-test-precommit-installer.sh [--repo <path>] [--runner <path>] [--remove] [--dry-run]
#
# Detection order (first hit wins):
#   1. .husky/                       → husky (CleanScale, most Node repos)
#   2. lefthook.yml | lefthook.yaml  → lefthook
#   3. .pre-commit-config.yaml       → pre-commit (Python tool)
#   4. .githooks/                    → claude-pattern style
#   5. (fallback)                    → .git/hooks/pre-commit
#
# Idempotency: safe to re-run. Detects existing managed block by SENTINEL
# and replaces in-place. Other hook content is preserved.
#
# Reversibility: --remove deletes the managed block, leaves the rest of the
# hook intact. Empty hooks (no other content) get deleted.

set -u

SENTINEL_START="# >>> plan-w-team-skill-test-runner (managed) >>>"
SENTINEL_END="# <<< plan-w-team-skill-test-runner (managed) <<<"

REPO=""
RUNNER="tests/skill/run-scenarios.sh"
REMOVE=0
DRY_RUN=0

usage() {
    cat <<USAGE
Usage: $0 [options]

  --repo <path>     Target repo root (default: current directory)
  --runner <path>   Test runner path, relative to repo root
                    (default: tests/skill/run-scenarios.sh)
  --remove          Uninstall the managed block
  --dry-run         Show what would change, write nothing
  -h | --help       This help

Detects the repo's existing pre-commit hook system (husky / lefthook /
pre-commit / .githooks / native) and installs/removes the runner invocation
without clobbering other hooks.
USAGE
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        --repo)    REPO="$2"; shift 2 ;;
        --runner)  RUNNER="$2"; shift 2 ;;
        --remove)  REMOVE=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) usage ;;
        *)         echo "✗ unknown arg: $1" >&2; usage ;;
    esac
done

REPO="${REPO:-$PWD}"
[ -d "$REPO/.git" ] || { echo "✗ not a git repo: $REPO" >&2; exit 1; }
cd "$REPO" || exit 1

# ─── Detect hook system ──────────────────────────────────────────────────────
SYSTEM=""
if [ -d ".husky" ]; then
    SYSTEM="husky"
elif [ -f "lefthook.yml" ] || [ -f "lefthook.yaml" ] || [ -f ".lefthook.yml" ]; then
    SYSTEM="lefthook"
elif [ -f ".pre-commit-config.yaml" ] || [ -f ".pre-commit-config.yml" ]; then
    SYSTEM="pre-commit"
elif [ -d ".githooks" ]; then
    SYSTEM="githooks"
else
    SYSTEM="native"
fi

echo "→ detected hook system: $SYSTEM"
[ "$DRY_RUN" -eq 1 ] && echo "→ dry-run: no files will be modified"

# ─── Per-system install/remove helpers ───────────────────────────────────────
# All paths returned are RELATIVE to repo root.

resolve_hook_path() {
    case "$SYSTEM" in
        husky)      echo ".husky/pre-commit" ;;
        githooks)   echo ".githooks/pre-commit" ;;
        native)     echo ".git/hooks/pre-commit" ;;
        lefthook)   echo "lefthook.yml" ;;     # caller handles YAML mode
        pre-commit) echo ".pre-commit-config.yaml" ;;
    esac
}

# Block for SHELL hook files (husky, .githooks, native, hand-rolled)
shell_block() {
    cat <<BLOCK
$SENTINEL_START
# Auto-installed by .claude/scripts/skill-test-precommit-installer.sh
# Runs /plan-w-team skill E2E scenarios when relevant paths change.
#
# Two-layer guard:
#   (1) Runner present and executable — protects template repos pre-sync.
#   (2) bats binary present at tests/skill/.bats/bin/bats — protects sync
#       TARGET repos where the runner script was synced in but the bats
#       framework + scenario fixtures were not (sync only copies .claude/,
#       not tests/). The skill source-of-truth repo (claude-pattern) has
#       both. Without this guard, every sync commit in a consumer repo
#       triggers the runner, which then fails with "bats not bootstrapped"
#       and blocks the commit — a sync-tooling false positive.
if [ -x "$RUNNER" ] && [ -x "tests/skill/.bats/bin/bats" ]; then
    CHANGED=\$(git diff --cached --name-only 2>/dev/null)
    if printf '%s\n' "\$CHANGED" | grep -qE '^\.claude/(commands/plan-w-team|hooks/plan-w-team-|scripts/pwt-goal|scripts/plan-w-team-)'; then
        echo "→ /plan-w-team skill paths touched — running E2E scenarios..."
        if ! bash "$RUNNER"; then
            echo "✗ skill E2E scenarios failed — commit blocked."
            echo "  Bypass with: git commit --no-verify (NOT recommended)"
            exit 1
        fi
    fi
fi
$SENTINEL_END
BLOCK
}

# Block for lefthook YAML
lefthook_block() {
    cat <<BLOCK
  $SENTINEL_START
  skill-e2e-tests:
    glob: "{.claude/commands/plan-w-team*,.claude/hooks/plan-w-team-*,.claude/scripts/pwt-goal*,.claude/scripts/plan-w-team-*}"
    run: bash $RUNNER
  $SENTINEL_END
BLOCK
}

# Block for pre-commit (.pre-commit-config.yaml)
precommit_block() {
    cat <<BLOCK
  $SENTINEL_START
  - repo: local
    hooks:
      - id: plan-w-team-skill-e2e
        name: /plan-w-team skill E2E scenarios
        entry: bash $RUNNER
        language: system
        files: '^\.claude/(commands/plan-w-team|hooks/plan-w-team-|scripts/pwt-goal|scripts/plan-w-team-)'
        pass_filenames: false
  $SENTINEL_END
BLOCK
}

# ─── Install / Remove ─────────────────────────────────────────────────────────

install_into_shell_hook() {
    local hook_path
    hook_path=$(resolve_hook_path)

    # Native git: ensure parent exists
    if [ "$SYSTEM" = "githooks" ] || [ "$SYSTEM" = "native" ]; then
        if [ "$DRY_RUN" -eq 0 ]; then
            mkdir -p "$(dirname "$hook_path")"
        fi
    fi

    # Read existing content (empty if missing)
    local existing=""
    [ -f "$hook_path" ] && existing=$(cat "$hook_path")

    # Strip any prior managed block
    local stripped
    stripped=$(printf '%s\n' "$existing" | awk -v s="$SENTINEL_START" -v e="$SENTINEL_END" '
        $0 == s { skip = 1; next }
        $0 == e { skip = 0; next }
        !skip { print }
    ')

    # Build new content. Preserve shebang as first line if existing had one.
    local block new
    block=$(shell_block)

    if printf '%s' "$stripped" | head -1 | grep -q '^#!'; then
        # has shebang: insert block AFTER the shebang
        local shebang rest
        shebang=$(printf '%s' "$stripped" | head -1)
        rest=$(printf '%s' "$stripped" | tail -n +2)
        new=$(printf '%s\n%s\n\n%s' "$shebang" "$block" "$rest")
    elif [ -z "$(printf '%s' "$stripped" | tr -d '[:space:]')" ]; then
        # empty hook: add shebang + block
        new=$(printf '%s\n%s\n' "#!/bin/sh" "$block")
    else
        # no shebang, has content: prepend block + shebang
        new=$(printf '%s\n%s\n\n%s' "#!/bin/sh" "$block" "$stripped")
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        echo "→ would write $hook_path:"
        printf '%s\n' "$new" | sed 's/^/    /'
    else
        printf '%s\n' "$new" > "$hook_path"
        chmod +x "$hook_path"
        echo "✓ installed managed block into $hook_path"
    fi
}

remove_from_shell_hook() {
    local hook_path
    hook_path=$(resolve_hook_path)

    [ -f "$hook_path" ] || { echo "→ no $hook_path — nothing to remove"; return; }

    local stripped
    stripped=$(awk -v s="$SENTINEL_START" -v e="$SENTINEL_END" '
        $0 == s { skip = 1; next }
        $0 == e { skip = 0; next }
        !skip { print }
    ' "$hook_path")

    # If only shebang + whitespace remain, delete the file entirely
    local meat
    meat=$(printf '%s\n' "$stripped" | grep -vE '^(#!|\s*$)' | head -1)

    if [ "$DRY_RUN" -eq 1 ]; then
        if [ -z "$meat" ]; then
            echo "→ would delete $hook_path (empty after removal)"
        else
            echo "→ would update $hook_path (removed managed block):"
            printf '%s\n' "$stripped" | sed 's/^/    /'
        fi
    else
        if [ -z "$meat" ]; then
            rm -f "$hook_path"
            echo "✓ deleted $hook_path (empty after removal)"
        else
            printf '%s\n' "$stripped" > "$hook_path"
            echo "✓ removed managed block from $hook_path"
        fi
    fi
}

install_into_yaml() {
    local yaml_path
    yaml_path=$(resolve_hook_path)
    local block

    if [ "$SYSTEM" = "lefthook" ]; then
        block=$(lefthook_block)
        # lefthook YAML structure: pre-commit: \n  commands: \n    <name>:
        # We append at top-level pre-commit.commands. If pre-commit section
        # doesn't exist, create it. Idempotent via sentinel.
        if grep -q "$SENTINEL_START" "$yaml_path" 2>/dev/null; then
            echo "→ lefthook: managed block already present, replacing in-place"
            if [ "$DRY_RUN" -eq 0 ]; then
                awk -v s="$SENTINEL_START" -v e="$SENTINEL_END" '
                    $0 ~ s { skip = 1; next }
                    $0 ~ e { skip = 0; next }
                    !skip { print }
                ' "$yaml_path" > "$yaml_path.tmp" && mv "$yaml_path.tmp" "$yaml_path"
            fi
        fi
        echo "→ lefthook adapter: please append the following under pre-commit.commands manually,"
        echo "  or wire via your existing lefthook config layout:"
        echo ""
        echo "$block"
        echo ""
        echo "  (Lefthook YAML auto-merge isn't safe without a YAML parser. Will improve in a"
        echo "   future revision if needed. Current behavior: print block + sentinel for manual paste.)"

    elif [ "$SYSTEM" = "pre-commit" ]; then
        block=$(precommit_block)
        if grep -q "$SENTINEL_START" "$yaml_path" 2>/dev/null; then
            echo "→ pre-commit: managed block already present"
        fi
        echo "→ pre-commit adapter: please add to .pre-commit-config.yaml repos: list:"
        echo ""
        echo "$block"
        echo ""
        echo "  (See note above re: YAML auto-merge.)"
    fi
}

remove_from_yaml() {
    local yaml_path
    yaml_path=$(resolve_hook_path)
    [ -f "$yaml_path" ] || { echo "→ no $yaml_path — nothing to remove"; return; }

    if grep -q "$SENTINEL_START" "$yaml_path"; then
        if [ "$DRY_RUN" -eq 0 ]; then
            awk -v s="$SENTINEL_START" -v e="$SENTINEL_END" '
                $0 ~ s { skip = 1; next }
                $0 ~ e { skip = 0; next }
                !skip { print }
            ' "$yaml_path" > "$yaml_path.tmp" && mv "$yaml_path.tmp" "$yaml_path"
            echo "✓ removed managed block from $yaml_path"
        else
            echo "→ would remove managed block from $yaml_path"
        fi
    else
        echo "→ no managed block found in $yaml_path"
    fi
}

# ─── Dispatch ─────────────────────────────────────────────────────────────────
case "$SYSTEM" in
    husky|githooks|native)
        if [ "$REMOVE" -eq 1 ]; then remove_from_shell_hook; else install_into_shell_hook; fi
        ;;
    lefthook|pre-commit)
        if [ "$REMOVE" -eq 1 ]; then remove_from_yaml; else install_into_yaml; fi
        ;;
esac

# ─── Sanity reminder when relevant ────────────────────────────────────────────
if [ "$REMOVE" -eq 0 ] && [ ! -x "$RUNNER" ]; then
    echo ""
    echo "⚠ runner path '$RUNNER' is not executable yet (or missing)."
    echo "  The installed hook will silently skip until the runner is present."
    echo "  This is intentional — template repos without the framework still commit cleanly."
fi
