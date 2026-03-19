#!/bin/bash
# Setup hook - runs on --init, --init-only, or --maintenance flags (v2.1.9+)
# Use for one-time initialization tasks

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
STATE_DIR="$PROJECT_ROOT/.claude/state"

mkdir -p "$STATE_DIR"

echo "═══════════════════════════════════════════════════════════════"
echo "  CLAUDE CODE SETUP MODE"
echo "═══════════════════════════════════════════════════════════════"
echo ""

# Check for required dependencies
check_dependency() {
    if command -v "$1" &> /dev/null; then
        echo "  ✓ $1"
        return 0
    else
        echo "  ✗ $1 (not found)"
        return 1
    fi
}

# Auto-install helper (installs if missing, skips if present)
auto_install() {
    local name="$1"
    local install_cmd="$2"
    local check_cmd="${3:-$1}"

    if command -v "$check_cmd" &> /dev/null; then
        echo "  ✓ $name"
        return 0
    else
        echo "  ⚙ $name (installing...)"
        if eval "$install_cmd" &> /dev/null; then
            echo "  ✓ $name (installed)"
            return 0
        else
            echo "  ✗ $name (install failed — run manually: $install_cmd)"
            return 1
        fi
    fi
}

# ── Core dependencies ──────────────────────────────────────────
echo "📦 Core dependencies..."
check_dependency "git"
check_dependency "node"
check_dependency "python3"

# ── /plan-w-team dependencies ──────────────────────────────────
echo ""
echo "📦 /plan-w-team dependencies..."
auto_install "gh (GitHub CLI)" "brew install gh" "gh"
auto_install "tsx" "npm install -g tsx" "tsx"
auto_install "bun" "curl -fsSL https://bun.sh/install | bash" "bun"
auto_install "pytest" "uv tool install pytest" "pytest"

# Browse binary (optional — for browser QA)
BROWSE_BIN="$HOME/.claude/skills/gstack/browse/dist/browse"
if [ -x "$BROWSE_BIN" ]; then
    echo "  ✓ browse (gstack browser QA)"
else
    echo "  ○ browse (optional — see shared/browser-qa.md for install)"
fi

# ── /plan-w-team stage files ──────────────────────────────────
echo ""
echo "📁 /plan-w-team stage files..."
PLAN_DIR="$PROJECT_ROOT/.claude/commands/plan-w-team"
MISSING_STAGES=0
for stage in 00-scope-challenge 01-specification 02-task-breakdown 03-execute 04-fix-first-review 05-ship 06-post-ship 07-retro; do
    if [ -f "$PLAN_DIR/$stage.md" ]; then
        echo "  ✓ $stage.md"
    else
        echo "  ✗ $stage.md (missing)"
        MISSING_STAGES=$((MISSING_STAGES + 1))
    fi
done
for shared in self-regulation cognitive-frameworks artifact-storage browser-qa; do
    if [ -f "$PLAN_DIR/shared/$shared.md" ]; then
        echo "  ✓ shared/$shared.md"
    else
        echo "  ✗ shared/$shared.md (missing)"
        MISSING_STAGES=$((MISSING_STAGES + 1))
    fi
done
if [ "$MISSING_STAGES" -gt 0 ]; then
    echo "  ⚠ $MISSING_STAGES stage file(s) missing — sync from claude-pattern"
fi

# ── Permissions check ──────────────────────────────────────────
echo ""
echo "🔑 Settings permissions..."
SETTINGS="$PROJECT_ROOT/.claude/settings.json"
if [ -f "$SETTINGS" ]; then
    REQUIRED_PERMS=("Agent(*)" "TeamCreate" "TeamDelete" "TaskCreate" "TaskList" "TaskGet" "TaskUpdate" "TaskStop" "SendMessage")
    MISSING_PERMS=0
    for perm in "${REQUIRED_PERMS[@]}"; do
        if grep -q "\"$perm\"" "$SETTINGS" 2>/dev/null; then
            echo "  ✓ $perm"
        else
            echo "  ✗ $perm (missing — add to settings.json permissions.allow)"
            MISSING_PERMS=$((MISSING_PERMS + 1))
        fi
    done
    if [ "$MISSING_PERMS" -gt 0 ]; then
        echo "  ⚠ $MISSING_PERMS permission(s) missing for /plan-w-team parallel builders"
    fi
else
    echo "  ✗ settings.json not found"
fi

# ── .claude structure ──────────────────────────────────────────
echo ""
echo "📁 Verifying .claude structure..."
[ -d "$PROJECT_ROOT/.claude/agents" ] && echo "  ✓ agents/" || echo "  ✗ agents/ missing"
[ -d "$PROJECT_ROOT/.claude/hooks" ] && echo "  ✓ hooks/" || echo "  ✗ hooks/ missing"
[ -d "$PROJECT_ROOT/.claude/commands" ] && echo "  ✓ commands/" || echo "  ✗ commands/ missing"
[ -f "$PROJECT_ROOT/.claude/settings.json" ] && echo "  ✓ settings.json" || echo "  ✗ settings.json missing"

# ── Context initialization ─────────────────────────────────────
echo ""
INIT_SCRIPT="$PROJECT_ROOT/scripts/init-project-context.ts"
if [ -f "$INIT_SCRIPT" ]; then
    echo "🧠 Initializing project context..."
    tsx "$INIT_SCRIPT" --update >/dev/null 2>&1 && echo "  ✓ CLAUDE.md updated" || echo "  ⚠ Context init skipped"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  Setup complete. Run 'claude' to start a session."
echo "═══════════════════════════════════════════════════════════════"
