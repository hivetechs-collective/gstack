#!/usr/bin/env bash
# plan-w-team-companion-gc.test.sh
#
# Tests for plan-w-team-companion-gc.sh. Drives the classifier with a canned
# `ps` table (PWT_COMPANION_GC_TEST_PS) and injected live-sid list
# (PWT_COMPANION_GC_TEST_LIVE_SIDS) so no real processes are signalled. Kill is
# suppressed via PWT_COMPANION_GC_TEST_NO_KILL=1 (classification-only).
#
# Run: bash .claude/scripts/plan-w-team-companion-gc.test.sh
# Exit 0 = all pass.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GC="$SCRIPT_DIR/plan-w-team-companion-gc.sh"

PASS=0; FAIL=0; ROOTS=()
pass() { echo "  ✓ $1"; PASS=$((PASS+1)); }
fail() { echo "  ✗ $1"; echo "    $2"; FAIL=$((FAIL+1)); }
assert_eq() { [ "$2" = "$3" ] && pass "$1" || fail "$1" "expected=[$2] actual=[$3]"; }
cleanup() { for r in "${ROOTS[@]:-}"; do [ -n "${r:-}" ] && rm -rf "$r"; done; }
trap cleanup EXIT

MY_UID="$(id -u)"
OTHER_UID=$(( MY_UID + 1 ))

new_repo() {
    local root; root="$(mktemp -d -t pwt-cgc.XXXXXX)"; ROOTS+=("$root")
    git -C "$root" init -q -b main
    git -C "$root" config user.email t@t.t; git -C "$root" config user.name t
    echo seed > "$root/seed.txt"; git -C "$root" add -A; git -C "$root" commit -qm seed
    mkdir -p "$root/.claude/worktrees" "$root/.claude/state"
    echo "$root"
}

# Build a canned ps file. Each line: "<pid> <uid> <args>"
ps_line() { printf '%s %s %s\n' "$1" "$2" "$3"; }

# action_of <json> <pid>
action_of() {
    python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
for c in d["companions"]:
    if str(c["pid"])==sys.argv[2]: print(c["action"]); break
else: print("absent")
' "$1" "$2"
}

run_gc() { # root psfile [extra args...] — JSON, classification-only
    local root="$1" psf="$2"; shift 2
    ( cd "$root" && \
      PWT_COMPANION_GC_TEST_PS="$psf" \
      PWT_COMPANION_GC_TEST_NO_KILL=1 \
      PWT_COMPANION_GC_AGENTS_EXTENDED=/nonexistent \
      "$@" bash "$GC" --json 2>/dev/null )
}

echo "── plan-w-team-companion-gc tests ──"

# [1] orphan pane-display.py (worktree gone) → would-kill
echo "[1] orphan pane-display (worktree gone) → would-kill"
R=$(new_repo); PS="$R/ps1.txt"
# agent-dead has NO worktree dir → terminal → orphan
ps_line 1001 "$MY_UID" "python3 $R/.claude/hooks/utils/pane-display.py agent-dead bg fg /x/agent-dead/t.jsonl" > "$PS"
JSON=$(run_gc "$R" "$PS"); echo "$JSON" > "$R/out1.json"
assert_eq "orphan pane-display would-kill" "would-kill" "$(action_of "$R/out1.json" 1001)"

# [2] pane-display whose agent worktree EXISTS + fresh transcript → keep
echo "[2] live pane-display (worktree present, fresh) → keep"
R=$(new_repo); PS="$R/ps2.txt"
mkdir -p "$R/.claude/worktrees/agent-live"
# point CLAUDE_PROJECTS_DIR at an empty dir so no meta/jsonl found, but worktree EXISTS
mkdir -p "$R/projects-empty"
ps_line 1002 "$MY_UID" "python3 $R/.claude/hooks/utils/pane-display.py agent-live bg fg /x/agent-live/t.jsonl" > "$PS"
JSON=$( cd "$R" && PWT_COMPANION_GC_TEST_PS="$PS" PWT_COMPANION_GC_TEST_NO_KILL=1 \
        PWT_COMPANION_GC_AGENTS_EXTENDED=/nonexistent CLAUDE_PROJECTS_DIR="$R/projects-empty" \
        SUBAGENT_FRESHNESS_SEC=99999 bash "$GC" --json 2>/dev/null )
echo "$JSON" > "$R/out2.json"
# worktree exists + no transcript → agent_is_terminal returns 1 only if jsonl absent...
# With worktree present and no meta and no jsonl, fallback returns terminal(0). To make
# it "live" we need worktree present AND a fresh jsonl. Create one:
R=$(new_repo); PS="$R/ps2.txt"
mkdir -p "$R/.claude/worktrees/agent-live2" "$R/projects/sub"
echo '{}' > "$R/projects/sub/agent-live2-xyz.jsonl"   # fresh transcript, no meta
ps_line 1012 "$MY_UID" "python3 $R/.claude/hooks/utils/pane-display.py agent-live2 bg fg /x/agent-live2/t.jsonl" > "$PS"
JSON=$( cd "$R" && PWT_COMPANION_GC_TEST_PS="$PS" PWT_COMPANION_GC_TEST_NO_KILL=1 \
        PWT_COMPANION_GC_AGENTS_EXTENDED=/nonexistent CLAUDE_PROJECTS_DIR="$R/projects" \
        SUBAGENT_FRESHNESS_SEC=99999 bash "$GC" --json 2>/dev/null )
echo "$JSON" > "$R/out2.json"
assert_eq "live pane-display kept" "keep" "$(action_of "$R/out2.json" 1012)"

# [3] orphan pwt-watch.sh (sid not live) → would-kill
echo "[3] orphan pwt-watch (sid dead) → would-kill"
R=$(new_repo); PS="$R/ps3.txt"
ps_line 1003 "$MY_UID" "bash $R/.claude/scripts/pwt-watch.sh deadsid01 30 720" > "$PS"
JSON=$( cd "$R" && PWT_COMPANION_GC_TEST_PS="$PS" PWT_COMPANION_GC_TEST_NO_KILL=1 \
        PWT_COMPANION_GC_TEST_LIVE_SIDS="othersid" bash "$GC" --json 2>/dev/null )
echo "$JSON" > "$R/out3.json"
assert_eq "orphan pwt-watch would-kill" "would-kill" "$(action_of "$R/out3.json" 1003)"

# [4] live pwt-watch.sh (sid live) → keep
echo "[4] live pwt-watch (sid live) → keep"
R=$(new_repo); PS="$R/ps4.txt"
ps_line 1004 "$MY_UID" "bash $R/.claude/scripts/pwt-watch.sh livesid99 30 720" > "$PS"
JSON=$( cd "$R" && PWT_COMPANION_GC_TEST_PS="$PS" PWT_COMPANION_GC_TEST_NO_KILL=1 \
        PWT_COMPANION_GC_TEST_LIVE_SIDS="livesid99" bash "$GC" --json 2>/dev/null )
echo "$JSON" > "$R/out4.json"
assert_eq "live pwt-watch kept" "keep" "$(action_of "$R/out4.json" 1004)"

# [5] SAFETY: non-whitelisted process never touched (not even listed)
echo "[5] non-whitelisted process ignored"
R=$(new_repo); PS="$R/ps5.txt"
{
  ps_line 2001 "$MY_UID" "python3 /usr/local/bin/some-other-script.py"
  ps_line 2002 "$MY_UID" "node server.js"
  ps_line 2003 "$MY_UID" "bash /home/x/deploy.sh"
} > "$PS"
JSON=$(run_gc "$R" "$PS"); echo "$JSON" > "$R/out5.json"
N=$(python3 -c 'import json;print(len(json.load(open("'"$R"'/out5.json"))["companions"]))')
assert_eq "non-whitelisted processes never enumerated" "0" "$N"

# [6] SAFETY: same-binary but DIFFERENT uid → keep (never signal other users)
echo "[6] different-uid companion → keep"
R=$(new_repo); PS="$R/ps6.txt"
ps_line 3001 "$OTHER_UID" "python3 $R/.claude/hooks/utils/pane-display.py agent-foreign bg fg /x/agent-foreign/t.jsonl" > "$PS"
JSON=$(run_gc "$R" "$PS"); echo "$JSON" > "$R/out6.json"
assert_eq "other-uid companion → keep" "keep" "$(action_of "$R/out6.json" 3001)"
REASON=$(python3 -c 'import json;d=json.load(open("'"$R"'/out6.json"));print(d["companions"][0]["reason"] if d["companions"] else "none")')
assert_eq "other-uid reason mentions uid" "yes" "$(echo "$REASON" | grep -qi uid && echo yes || echo no)"

# [7] idempotency / empty → no-op, exit 0
echo "[7] empty ps → no-op exit 0"
R=$(new_repo); PS="$R/ps7.txt"; : > "$PS"
JSON=$(run_gc "$R" "$PS"); RC=$?
echo "$JSON" > "$R/out7.json"
assert_eq "empty exit 0" "0" "$RC"
assert_eq "empty totals scanned 0" "0" "$(python3 -c 'import json;print(json.load(open("'"$R"'/out7.json"))["totals"]["scanned"])')"

# [8] --sid scope restricts to one agent
echo "[8] --sid scope restricts"
R=$(new_repo); PS="$R/ps8.txt"
{
  ps_line 4001 "$MY_UID" "python3 $R/.claude/hooks/utils/pane-display.py agent-aaa bg fg /x/agent-aaa/t.jsonl"
  ps_line 4002 "$MY_UID" "python3 $R/.claude/hooks/utils/pane-display.py agent-bbb bg fg /x/agent-bbb/t.jsonl"
} > "$PS"
JSON=$( cd "$R" && PWT_COMPANION_GC_TEST_PS="$PS" PWT_COMPANION_GC_TEST_NO_KILL=1 \
        PWT_COMPANION_GC_AGENTS_EXTENDED=/nonexistent bash "$GC" --sid aaa --json 2>/dev/null )
echo "$JSON" > "$R/out8.json"
N=$(python3 -c 'import json;print(len(json.load(open("'"$R"'/out8.json"))["companions"]))')
assert_eq "--sid scope lists only matching agent" "1" "$N"
assert_eq "scoped companion is aaa" "aaa" "$(python3 -c 'import json;d=json.load(open("'"$R"'/out8.json"));print(d["companions"][0]["id"] if d["companions"] else "none")')"

# [9] disable kill-switch
echo "[9] PWT_COMPANION_GC_DISABLE=1 → no-op"
R=$(new_repo)
OUT=$( cd "$R" && PWT_COMPANION_GC_DISABLE=1 bash "$GC" --json 2>/dev/null )
assert_eq "disable skipped:true" "True" "$(python3 -c 'import json,sys;print(json.loads(sys.argv[1]).get("skipped"))' "$OUT")"

# Track real spawned pids so we never leak sleepers if an assert fails mid-test.
SPAWNED_PIDS=()
spawned_cleanup() {
    for p in "${SPAWNED_PIDS[@]:-}"; do
        [ -n "${p:-}" ] && kill "$p" 2>/dev/null || true
    done
    cleanup
}
trap spawned_cleanup EXIT

# [10] REAL KILL: --execute actually kills a same-uid orphan watcher pid.
# Spawn a real, harmless `sleep` we own; inject its pid as a dead-sid pwt-watch
# orphan; assert it is gone after --execute. Proves the kill path fires on a
# real pid we own (not just dry-run classification).
echo "[10] --execute kills a real same-uid orphan pid"
R=$(new_repo); PS="$R/ps10.txt"
sleep 120 & REAL_PID=$!
SPAWNED_PIDS+=("$REAL_PID")
ps_line "$REAL_PID" "$MY_UID" "bash $R/.claude/scripts/pwt-watch.sh orphanreal 30 720" > "$PS"
( cd "$R" && PWT_COMPANION_GC_TEST_PS="$PS" PWT_COMPANION_GC_TEST_LIVE_SIDS="somethingelse" \
  bash "$GC" --execute --json 2>/dev/null ) >/dev/null
sleep 1
if kill -0 "$REAL_PID" 2>/dev/null; then
    fail "real orphan killed by --execute" "pid $REAL_PID still alive"
    kill "$REAL_PID" 2>/dev/null || true
else
    pass "real orphan killed by --execute"
fi

# [11] REAL KILL GUARD: --execute must NOT kill a non-whitelisted same-uid proc.
echo "[11] --execute leaves non-whitelisted same-uid process alive"
R=$(new_repo); PS="$R/ps11.txt"
sleep 120 & SAFE_PID=$!
SPAWNED_PIDS+=("$SAFE_PID")
ps_line "$SAFE_PID" "$MY_UID" "python3 /home/me/important_prod_daemon.py --serve" > "$PS"
( cd "$R" && PWT_COMPANION_GC_TEST_PS="$PS" bash "$GC" --execute --json 2>/dev/null ) >/dev/null
sleep 1
if kill -0 "$SAFE_PID" 2>/dev/null; then
    pass "non-whitelisted process survives --execute"
    kill "$SAFE_PID" 2>/dev/null || true
else
    fail "non-whitelisted process survives --execute" "pid $SAFE_PID killed — WHITELIST VIOLATION"
fi

# [12] REAL KILL GUARD: --execute must NOT kill a LIVE companion (sid still live).
echo "[12] --execute leaves a live-sid companion alive"
R=$(new_repo); PS="$R/ps12.txt"
sleep 120 & LIVE_PID=$!
SPAWNED_PIDS+=("$LIVE_PID")
ps_line "$LIVE_PID" "$MY_UID" "bash $R/.claude/scripts/pwt-watch.sh stillalive 30 720" > "$PS"
( cd "$R" && PWT_COMPANION_GC_TEST_PS="$PS" PWT_COMPANION_GC_TEST_LIVE_SIDS="stillalive" \
  bash "$GC" --execute --json 2>/dev/null ) >/dev/null
sleep 1
if kill -0 "$LIVE_PID" 2>/dev/null; then
    pass "live-sid companion survives --execute"
    kill "$LIVE_PID" 2>/dev/null || true
else
    fail "live-sid companion survives --execute" "pid $LIVE_PID killed — live target must be kept"
fi

# ── AC5a: leaked build-daemon reaping (esbuild/Metro/vite/...) ──────────────
# [B1] esbuild whose cwd is under a DEAD (gone) worktree dir → would-kill
echo "[B1] AC5a: build daemon under a gone worktree dir → would-kill"
R=$(new_repo); RR=$(cd "$R" && pwd -P); PS="$R/psb1.txt"; CWDMAP="$R/cwdb1.txt"
ps_line 5001 "$MY_UID" "node /opt/node_modules/esbuild/bin/esbuild --service=0.19 --ping" > "$PS"
printf '5001 %s\n' "$RR/.claude/worktrees/ghostwt/node_modules/esbuild" > "$CWDMAP"
JSON=$( cd "$R" && PWT_COMPANION_GC_TEST_PS="$PS" PWT_COMPANION_GC_TEST_NO_KILL=1 \
        PWT_COMPANION_GC_TEST_CWD_MAP="$CWDMAP" PWT_COMPANION_GC_AGENTS_EXTENDED=/nonexistent \
        bash "$GC" --json 2>/dev/null )
echo "$JSON" > "$R/outb1.json"
assert_eq "build daemon under gone worktree → would-kill" "would-kill" "$(action_of "$R/outb1.json" 5001)"
assert_eq "build daemon kind is build-daemon" "build-daemon" "$(python3 -c 'import json;d=json.load(open("'"$R"'/outb1.json"));print(d["companions"][0]["kind"] if d["companions"] else "none")')"

# [B2] esbuild whose cwd is under a LIVE (registered) worktree → keep
echo "[B2] AC5a: build daemon under a live registered worktree → keep"
R=$(new_repo); RR=$(cd "$R" && pwd -P); PS="$R/psb2.txt"; CWDMAP="$R/cwdb2.txt"; REGWT="$R/regwt.txt"
mkdir -p "$R/.claude/worktrees/livewt/node_modules/esbuild"
printf 'worktree %s/.claude/worktrees/livewt\nbranch refs/heads/x\n\n' "$RR" > "$REGWT"
ps_line 5002 "$MY_UID" "node /opt/node_modules/esbuild/bin/esbuild --service=0.19 --ping" > "$PS"
printf '5002 %s\n' "$RR/.claude/worktrees/livewt/node_modules/esbuild" > "$CWDMAP"
JSON=$( cd "$R" && PWT_COMPANION_GC_TEST_PS="$PS" PWT_COMPANION_GC_TEST_NO_KILL=1 \
        PWT_COMPANION_GC_TEST_CWD_MAP="$CWDMAP" PWT_COMPANION_GC_TEST_REGISTERED_WT="$REGWT" \
        PWT_COMPANION_GC_AGENTS_EXTENDED=/nonexistent bash "$GC" --json 2>/dev/null )
echo "$JSON" > "$R/outb2.json"
assert_eq "build daemon under live worktree → keep" "keep" "$(action_of "$R/outb2.json" 5002)"

# [B3] esbuild whose cwd is the MAIN checkout (not under worktrees) → keep
echo "[B3] AC5a: build daemon in main checkout → keep (never touched)"
R=$(new_repo); RR=$(cd "$R" && pwd -P); PS="$R/psb3.txt"; CWDMAP="$R/cwdb3.txt"
ps_line 5003 "$MY_UID" "node /opt/node_modules/esbuild/bin/esbuild --service=0.19 --ping" > "$PS"
printf '5003 %s\n' "$RR/apps/web" > "$CWDMAP"
JSON=$( cd "$R" && PWT_COMPANION_GC_TEST_PS="$PS" PWT_COMPANION_GC_TEST_NO_KILL=1 \
        PWT_COMPANION_GC_TEST_CWD_MAP="$CWDMAP" PWT_COMPANION_GC_AGENTS_EXTENDED=/nonexistent \
        bash "$GC" --json 2>/dev/null )
echo "$JSON" > "$R/outb3.json"
assert_eq "build daemon in main checkout → keep" "keep" "$(action_of "$R/outb3.json" 5003)"

# [B4] SAME-UID guard still applies to build daemons (different uid → keep)
echo "[B4] AC5a: different-uid build daemon under dead worktree → keep"
R=$(new_repo); RR=$(cd "$R" && pwd -P); PS="$R/psb4.txt"; CWDMAP="$R/cwdb4.txt"
ps_line 5004 "$OTHER_UID" "node /opt/node_modules/esbuild/bin/esbuild --service=0.19 --ping" > "$PS"
printf '5004 %s\n' "$RR/.claude/worktrees/ghostwt2/node_modules" > "$CWDMAP"
JSON=$( cd "$R" && PWT_COMPANION_GC_TEST_PS="$PS" PWT_COMPANION_GC_TEST_NO_KILL=1 \
        PWT_COMPANION_GC_TEST_CWD_MAP="$CWDMAP" PWT_COMPANION_GC_AGENTS_EXTENDED=/nonexistent \
        bash "$GC" --json 2>/dev/null )
echo "$JSON" > "$R/outb4.json"
assert_eq "other-uid build daemon → keep" "keep" "$(action_of "$R/outb4.json" 5004)"

# [13] bash 3.2 compatibility (macOS /bin/bash; mac-mini deployment) ──────────
# Runtime guard against bash-4 constructs (declare -A etc.) that `bash -n` misses.
echo "[13] runs clean under bash 3.2 (/bin/bash on macOS)"
if [ -x /bin/bash ] && /bin/bash --version 2>/dev/null | head -1 | grep -q 'version 3\.'; then
    R=$(new_repo); PS="$R/ps-b32.txt"; ERRF="$R/b32.err"
    ps_line 1999 "$MY_UID" "python3 $R/.claude/hooks/utils/pane-display.py agent-b32 bg fg /x/agent-b32/t.jsonl" > "$PS"
    OUT=$( cd "$R" && PWT_COMPANION_GC_TEST_PS="$PS" PWT_COMPANION_GC_TEST_NO_KILL=1 \
           PWT_COMPANION_GC_AGENTS_EXTENDED=/nonexistent /bin/bash "$GC" --json 2>"$ERRF" ); RC=$?
    ERR=$(cat "$ERRF" 2>/dev/null)
    case "$ERR" in
        *"invalid option"*|*"declare:"*|*"unbound variable"*|*"bad substitution"*) E32=1 ;;
        *) E32=0 ;;
    esac
    VALID=$(printf '%s' "$OUT" | python3 -c 'import json,sys; json.loads(sys.stdin.read()); print("ok")' 2>/dev/null || echo bad)
    assert_eq "bash 3.2: no bash-4 error signature" "0" "$E32"
    assert_eq "bash 3.2: exits 0" "0" "$RC"
    assert_eq "bash 3.2: emits valid companion JSON" "ok" "$VALID"
else
    echo "  ⊘ skipped (no bash 3.2 at /bin/bash — not the regression-risk host)"
fi

echo ""
echo "── results: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ]
