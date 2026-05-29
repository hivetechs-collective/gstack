#!/usr/bin/env bash
# plan-w-team-orphan-session-reaper.test.sh — orphaned bg-session reaper safety.
# Fully stubbed: stub agents JSON, stub projects dir, fake stop command. Never
# touches real sessions / ~/.claude.
set -u

SCRIPT="$(cd "$(dirname "$0")" && pwd)/plan-w-team-orphan-session-reaper.sh"
[ -x "$SCRIPT" ] || { echo "FAIL: reaper not executable"; exit 1; }

PASS=0; FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
REPO="$T/repo"; PROJ="$T/projects"; mkdir -p "$REPO/.claude/worktrees/wt" "$PROJ/enc"
NOW=$(date +%s)

# transcript for $1 with mtime $2 minutes ago (python = portable mtime control)
mk_tx() { local f="$PROJ/enc/$1.jsonl"; echo '{}' > "$f"; python3 -c "import os,sys; t=$NOW-$2*60; os.utime('$f',(t,t))"; }
mk_tx orphanidle1 60      # this-repo (worktree) idle 60m → REAP
mk_tx recentwork1 2       # this-repo idle 2m       → skip (active)
mk_tx busyone1   90       # this-repo idle-mtime but status busy → skip (busy)
mk_tx selfsess1  90       # this-repo, but is the current session → skip (self)
mk_tx otherrepo1 90       # idle but other repo     → skip (other-repo)
# (notranscript1 has NO transcript → skip unverifiable)

cat > "$T/agents.json" <<JSON
[
 {"kind":"background","sessionId":"orphanidle1","cwd":"$REPO/.claude/worktrees/wt","status":"idle"},
 {"kind":"background","sessionId":"recentwork1","cwd":"$REPO","status":"idle"},
 {"kind":"background","sessionId":"busyone1","cwd":"$REPO","status":"busy"},
 {"kind":"background","sessionId":"selfsess1","cwd":"$REPO","status":"idle"},
 {"kind":"background","sessionId":"otherrepo1","cwd":"/somewhere/else/repo","status":"idle"},
 {"kind":"background","sessionId":"notranscript1","cwd":"$REPO","status":"idle"},
 {"kind":"interactive","sessionId":"interactive1","cwd":"$REPO","status":"idle"}
]
JSON

STOPLOG="$T/stops"
cat > "$T/fakestop" <<EOF
#!/bin/bash
echo "\$1" >> "$STOPLOG"
EOF
chmod +x "$T/fakestop"

run() { PWT_PROJECT_ROOT_OVERRIDE="$REPO" CLAUDE_PROJECTS_DIR="$PROJ" CLAUDE_AGENTS_JSON_STUB="$T/agents.json" \
        CLAUDE_CODE_SESSION_ID=selfsess1 ORPHAN_REAPER_STOP_CMD="$T/fakestop" bash "$SCRIPT" "$@"; }
field() { printf '%s' "$1" | python3 -c "import sys,json;print(json.load(sys.stdin).get('$2'))" 2>/dev/null; }

echo "── orphan-session-reaper tests ──"

# [1] dry-run finds exactly 1 orphan, stops nothing
OUT=$(run --json)
{ [ "$(field "$OUT" orphans_found)" = "1" ] && [ "$(field "$OUT" stopped)" = "0" ] && [ ! -f "$STOPLOG" ]; } \
  && ok "dry-run: 1 orphan found, 0 stopped" || bad "dry-run wrong: $OUT"

# [2] execute stops exactly the one orphan
OUT=$(run --execute --json)
[ "$(field "$OUT" stopped)" = "1" ] && ok "execute: stopped exactly 1" || bad "execute stopped wrong count: $OUT"

# [3] the stopped sid is orphanidle1 (8-char) and ONLY it
STOPPED=$(cat "$STOPLOG" 2>/dev/null | tr '\n' ' ')
{ printf '%s' "$STOPPED" | grep -q "orphani" && [ "$(cat "$STOPLOG" | wc -l | tr -d ' ')" = "1" ]; } \
  && ok "stopped ONLY the orphan (orphanidle1)" || bad "stopped wrong sids: [$STOPPED]"

# [4] safety: never stopped busy / self / other-repo / active / no-transcript
for forbidden in recentwork recentwork1 busyone selfsess otherrepo notranscript; do
  grep -q "$forbidden" "$STOPLOG" 2>/dev/null && bad "STOPPED a protected session ($forbidden)!" && break
done
grep -qE "recentwork|busyone|selfsess|otherrepo|notranscript" "$STOPLOG" 2>/dev/null \
  || ok "never stopped busy/self/other-repo/active/no-transcript"

# [5] skipped count = 5 (recent, busy, self, other-repo, no-transcript)
[ "$(field "$OUT" skipped)" = "5" ] && ok "skipped 5 protected sessions" || bad "skipped count wrong: $(field "$OUT" skipped)"

# [6] PWT_ORPHAN_REAPER_DISABLE=1 → no-op exit 0
PWT_ORPHAN_REAPER_DISABLE=1 PWT_PROJECT_ROOT_OVERRIDE="$REPO" CLAUDE_PROJECTS_DIR="$PROJ" \
  CLAUDE_AGENTS_JSON_STUB="$T/agents.json" ORPHAN_REAPER_STOP_CMD="$T/fakestop" bash "$SCRIPT" --execute >/dev/null 2>&1
[ "$?" -eq 0 ] && ok "PWT_ORPHAN_REAPER_DISABLE=1 → no-op exit 0" || bad "disable knob failed"

# [7] empty agents list → 0 orphans, exit 0 (fail-open)
echo '[]' > "$T/empty.json"
OUT=$(PWT_PROJECT_ROOT_OVERRIDE="$REPO" CLAUDE_PROJECTS_DIR="$PROJ" CLAUDE_AGENTS_JSON_STUB="$T/empty.json" bash "$SCRIPT" --json); rc=$?
{ [ "$rc" -eq 0 ] && [ "$(field "$OUT" orphans_found)" = "0" ]; } && ok "empty agent list → 0 orphans, exit 0" || bad "empty-list wrong (rc=$rc)"

# [8] raised idle threshold spares the 60m orphan (PWT_ORPHAN_IDLE_MIN=120)
rm -f "$STOPLOG"
OUT=$(PWT_ORPHAN_IDLE_MIN=120 run --execute --json)
[ "$(field "$OUT" stopped)" = "0" ] && ok "PWT_ORPHAN_IDLE_MIN=120 spares the 60m session" || bad "threshold not honored: $OUT"

echo ""
echo "── results: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ]
