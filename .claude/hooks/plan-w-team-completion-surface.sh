#!/usr/bin/env bash
# plan-w-team-completion-surface.sh
#
# UserPromptSubmit hook that surfaces /plan-w-team run completion into the main
# chat. There are TWO complementary inputs:
#
#   1. Completion-summary markdown files written by the outer-supervisor:
#        .claude/state/pwt-completion-summary-<sid|slug>.md
#      These get emitted then archived to .claude/state/archive/.
#
#   2. Goal state JSON files written by the goal-evaluator Stop hook
#      (or by the user when manually halting):
#        .claude/state/plan-w-team-goal-<SLUG>.json
#      Surfaced when terminal_state != null AND surfaced != true. After
#      emission the file is updated in-place (surfaced=true, surfaced_at=<ts>)
#      to prevent re-surfacing on subsequent prompts. NOT archived — the file
#      is the source of truth for the run's terminal state and may be read by
#      other tooling (retro, supervisor) later.
#
# Both inputs are combined into a single emission so the user never sees a
# double-fire across prompts.
#
# === FAIL-OPEN CONTRACT ===
# This hook MUST NEVER block the user. On any internal error (missing tool,
# malformed JSON, write failure, etc.) exit 0 silently.

set -u

fail_open() { exit 0; }
trap fail_open ERR

PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)}"
[ -z "$PROJECT_ROOT" ] && exit 0

STATE_DIR="$PROJECT_ROOT/.claude/state"
[ -d "$STATE_DIR" ] || exit 0

# Drain stdin so the hook contract is honored (some Claude Code versions
# pipe-close if we don't read).
INPUT=$(cat 2>/dev/null || echo '{}')
: "$INPUT"  # silence unused warning under set -u

# ─── Collect markdown completion summaries ──────────────────────────────────
shopt -s nullglob
MD_SUMMARIES=("$STATE_DIR"/pwt-completion-summary-*.md)
GOAL_FILES=("$STATE_DIR"/plan-w-team-goal-*.json)
shopt -u nullglob

# Use python3 for all JSON parsing/composition — keeps quoting safe and avoids
# jq dependency. If python3 itself is missing, exit silently (fail-open).
command -v python3 >/dev/null 2>&1 || exit 0

ARCHIVE_DIR="$STATE_DIR/archive"
TS=$(date -u +%Y%m%dT%H%M%SZ)
TS_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)

COMBINED_CONTENT=""
COUNT=0

# ─── Stream 1: markdown summary files ──────────────────────────────────────
if [ "${#MD_SUMMARIES[@]}" -gt 0 ]; then
    mkdir -p "$ARCHIVE_DIR" 2>/dev/null || true
    for summary_file in "${MD_SUMMARIES[@]}"; do
        [ -f "$summary_file" ] || continue
        name=$(basename "$summary_file")
        content=$(cat "$summary_file" 2>/dev/null || echo "")
        [ -z "$content" ] && continue

        if [ -n "$COMBINED_CONTENT" ]; then
            COMBINED_CONTENT+=$'\n\n---\n\n'
        fi
        COMBINED_CONTENT+="### $name"$'\n\n'"$content"
        COUNT=$((COUNT+1))

        archived_path="$ARCHIVE_DIR/${name%.md}.${TS}.md"
        mv "$summary_file" "$archived_path" 2>/dev/null || rm -f "$summary_file" 2>/dev/null
    done
fi

# ─── Stream 2: goal-state JSON files with terminal state ───────────────────
# For each goal file with terminal_state != null and surfaced != true, render a
# structured summary section, then mark surfaced=true in-place.
if [ "${#GOAL_FILES[@]}" -gt 0 ]; then
    for goal_file in "${GOAL_FILES[@]}"; do
        [ -f "$goal_file" ] || continue
        # Render section via python (fail-open per-file on JSON errors)
        SECTION=$(GOAL_FILE_PATH="$goal_file" python3 - <<'PYEOF' 2>/dev/null || true
import json, os, sys
path = os.environ.get("GOAL_FILE_PATH", "")
try:
    with open(path, "r") as f:
        d = json.load(f)
except Exception:
    sys.exit(0)

terminal = d.get("terminal_state")
if terminal is None or terminal == "":
    sys.exit(0)
if d.get("surfaced") is True:
    sys.exit(0)

slug = d.get("slug") or os.path.basename(path)
reason = d.get("terminal_reason") or "(no reason recorded)"
terminated_at = d.get("terminated_at") or "(unknown)"

# Optional extended fields
ac = d.get("ac_counts")
if isinstance(ac, dict) and "passed" in ac and "total" in ac:
    ac_line = f"{ac['passed']}/{ac['total']} passed"
    if ac.get("failed"):
        ac_line += f" ({ac['failed']} failed)"
else:
    ac_line = "n/a"

files = d.get("files_touched")
if isinstance(files, list) and files:
    if len(files) <= 6:
        files_line = ", ".join(files)
    else:
        files_line = ", ".join(files[:6]) + f", ... ({len(files)} files)"
else:
    files_line = "n/a"

next_action = d.get("next_action") or "n/a"

section = (
    f"### Goal state: {slug}\n\n"
    f"- **slug:** {slug}\n"
    f"- **terminal_state:** {terminal}\n"
    f"- **terminal_reason:** {reason}\n"
    f"- **terminated_at:** {terminated_at}\n"
    f"- **ac_counts:** {ac_line}\n"
    f"- **files_touched:** {files_line}\n"
    f"- **next_action:** {next_action}\n"
)
print(section)
PYEOF
)

        if [ -n "$SECTION" ]; then
            if [ -n "$COMBINED_CONTENT" ]; then
                COMBINED_CONTENT+=$'\n\n---\n\n'
            fi
            COMBINED_CONTENT+="$SECTION"
            COUNT=$((COUNT+1))

            # Mark surfaced=true in-place (atomic via tmpfile + mv)
            GOAL_FILE_PATH="$goal_file" SURFACED_AT="$TS_ISO" python3 - <<'PYEOF' 2>/dev/null || true
import json, os, sys, tempfile
path = os.environ.get("GOAL_FILE_PATH", "")
ts = os.environ.get("SURFACED_AT", "")
try:
    with open(path, "r") as f:
        d = json.load(f)
except Exception:
    sys.exit(0)
d["surfaced"] = True
d["surfaced_at"] = ts
dirn = os.path.dirname(path) or "."
fd, tmp = tempfile.mkstemp(prefix=".surface-", dir=dirn)
try:
    with os.fdopen(fd, "w") as f:
        json.dump(d, f, indent=2)
        f.write("\n")
    os.replace(tmp, path)
except Exception:
    try: os.unlink(tmp)
    except Exception: pass
    sys.exit(0)
PYEOF
        fi
    done
fi

[ "$COUNT" -eq 0 ] && exit 0

# ─── Emit JSON output via python3 for safe escaping ─────────────────────────
COMBINED="$COMBINED_CONTENT" COUNT="$COUNT" python3 - <<'PYEOF' 2>/dev/null || exit 0
import json, os, sys
combined = os.environ.get("COMBINED", "")
count = int(os.environ.get("COUNT", "0") or "0")

if not combined:
    sys.exit(0)

if count == 1:
    header = "✅ /plan-w-team run completed — 1 completion record ready"
else:
    header = f"✅ /plan-w-team runs completed — {count} completion records"

sysmsg = f"{header}\n\n{combined}"

out = {
    "additionalContext": combined,
    "systemMessage": sysmsg,
}
print(json.dumps(out))
PYEOF

exit 0
