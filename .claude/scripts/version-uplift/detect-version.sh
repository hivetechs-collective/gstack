#!/usr/bin/env bash
# detect-version.sh — detect Claude Code CLI version change.
#
# Reads $CLAUDE_CODE_VERSION env var if set, else runs `claude --version`.
# Compares against the persisted last-seen version in
# .claude/state/last-claude-version.json.
#
# Emits a single JSON object on stdout:
#   { "previous": "2.1.140" | null, "current": "2.1.148", "changed": true|false }
#
# Flags:
#   --state-file=PATH      Override default state-file path.
#   --force                Treat as changed even if previous == current.
#   --no-persist           Skip writing the updated state-file.
#   --mock-current=VERSION Inject a mock current version (testing).
#
# Exit codes:
#   0  success
#   2  claude CLI missing and no env var / mock provided
#   3  malformed flag

set -euo pipefail

STATE_FILE=".claude/state/last-claude-version.json"
FORCE=0
PERSIST=1
MOCK_CURRENT=""

for arg in "$@"; do
    case "$arg" in
        --state-file=*) STATE_FILE="${arg#*=}" ;;
        --force) FORCE=1 ;;
        --no-persist) PERSIST=0 ;;
        --mock-current=*) MOCK_CURRENT="${arg#*=}" ;;
        --help|-h)
            sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "detect-version.sh: unknown arg: $arg" >&2
            exit 3
            ;;
    esac
done

# --- detect current version ---
detect_current() {
    if [ -n "$MOCK_CURRENT" ]; then
        printf '%s\n' "$MOCK_CURRENT"
        return 0
    fi
    if [ -n "${CLAUDE_CODE_VERSION:-}" ]; then
        printf '%s\n' "$CLAUDE_CODE_VERSION"
        return 0
    fi
    if command -v claude >/dev/null 2>&1; then
        # `claude --version` prints e.g. "2.1.148 (Claude Code)"
        claude --version 2>/dev/null | awk '{print $1; exit}'
        return 0
    fi
    return 2
}

CURRENT=$(detect_current) || {
    echo "detect-version.sh: claude CLI not found in PATH and no \$CLAUDE_CODE_VERSION / --mock-current provided" >&2
    exit 2
}

if [ -z "$CURRENT" ]; then
    echo "detect-version.sh: could not determine current version" >&2
    exit 2
fi

# --- read previous version ---
PREVIOUS="null"
if [ -f "$STATE_FILE" ]; then
    # Try to parse the persisted "version" field. Robust to whitespace.
    PREV_RAW=$(grep -E '"version"[[:space:]]*:' "$STATE_FILE" 2>/dev/null \
        | head -1 \
        | sed -E 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/' || true)
    if [ -n "$PREV_RAW" ]; then
        PREVIOUS=$(printf '"%s"' "$PREV_RAW")
    fi
fi

# --- compare ---
PREV_VAL=""
if [ "$PREVIOUS" != "null" ]; then
    PREV_VAL=$(printf '%s' "$PREVIOUS" | sed -E 's/^"(.*)"$/\1/')
fi

CHANGED="false"
if [ "$FORCE" -eq 1 ]; then
    CHANGED="true"
elif [ "$PREV_VAL" != "$CURRENT" ]; then
    CHANGED="true"
fi

# --- persist updated state ---
if [ "$PERSIST" -eq 1 ]; then
    mkdir -p "$(dirname "$STATE_FILE")"
    NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    cat > "$STATE_FILE" <<JSON
{
  "version": "${CURRENT}",
  "last_run": "${NOW}"
}
JSON
fi

# --- emit result ---
printf '{"previous": %s, "current": "%s", "changed": %s}\n' \
    "$PREVIOUS" "$CURRENT" "$CHANGED"
