#!/usr/bin/env bash
# damage-control.test.sh — installable guard for rm -rf (build-artifact-preservation, 1.28.0).
#
# Verifies the reactive layer: an rm -rf whose target CONTAINS (or IS) a final
# installable (*.app/*.ipa/*.apk/*.aab) is NO LONGER blanket-allowed by the
# safe_rm_targets short-circuit — it requires confirmation (ask) even for
# build/dist/target. The kept-artifacts home is hard-blocked. A pure-intermediate
# rm -rf (no installable) is still ALLOWED (GB-reclaim path not regressed).
set -u

SCRIPT="$(cd "$(dirname "$0")" && pwd)/damage-control.sh"
[ -x "$SCRIPT" ] || { echo "FAIL: damage-control.sh not executable"; exit 1; }

PASS=0; FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }

TR=$(mktemp -d); trap 'rm -rf "$TR"' EXIT

# Feed a Bash-tool PreToolUse payload to the hook; capture stdout in OUT, exit in RC.
# (The hook reads JSON from stdin: {"tool_name":"Bash","tool_input":{"command":"..."}}.)
DC_OUT=""; DC_RC=0
run_dc() {
    local cmd="$1"
    DC_OUT=$(printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$cmd" | bash "$SCRIPT")
    DC_RC=$?
}

echo "── damage-control installable-guard tests ──"

# [1] rm -rf of a dir CONTAINING a .app → ask (not silent allow), even though
#     'build' is on the safe_rm_targets allowlist. (AC3)
mkdir -p "$TR/build/Debug/My.app/Contents"; echo bin > "$TR/build/Debug/My.app/Contents/My"
run_dc "rm -rf $TR/build"
echo "$DC_OUT" | grep -q '"decision": *"ask"' \
  && ok "[AC3] rm -rf <build dir containing .app> → ask (safe_rm short-circuit bypassed)" \
  || bad "[AC3] .app-containing rm -rf was silently allowed (BUG): out='$DC_OUT' rc=$DC_RC"

# [2] rm -rf of a dir containing .ipa/.apk/.aab → ask (AC3)
mkdir -p "$TR/dist/out"; echo i > "$TR/dist/out/app.ipa"; echo a > "$TR/dist/out/app.apk"; echo b > "$TR/dist/out/app.aab"
run_dc "rm -rf $TR/dist"
echo "$DC_OUT" | grep -q '"decision": *"ask"' \
  && ok "[AC3] rm -rf <dist dir containing .ipa/.apk/.aab> → ask" \
  || bad "[AC3] .ipa/.apk/.aab-containing rm -rf silently allowed (BUG): out='$DC_OUT'"

# [3] rm -rf of a direct installable path → ask
mkdir -p "$TR/x/My.app"; echo z > "$TR/x/My.app/z"
run_dc "rm -rf $TR/x/My.app"
echo "$DC_OUT" | grep -q '"decision": *"ask"' \
  && ok "rm -rf <path that IS a .app> → ask" \
  || bad "direct .app deletion silently allowed (BUG): out='$DC_OUT'"

# [4] rm -rf of a PURE-INTERMEDIATE dir (no installable) → ALLOWED (exit 0, no decision).
#     This is the GB-reclaim path; it must NOT regress to a false-positive block/ask. (AC4)
mkdir -p "$TR/node_modules/pkg"; echo dep > "$TR/node_modules/pkg/index.js"
run_dc "rm -rf $TR/node_modules"
{ [ "$DC_RC" -eq 0 ] && ! echo "$DC_OUT" | grep -q '"decision"'; } \
  && ok "[AC4] rm -rf <pure-intermediate node_modules> → allowed (no false positive)" \
  || bad "[AC4] pure-intermediate cleanup was blocked/asked (REGRESSION): out='$DC_OUT' rc=$DC_RC"

# [4b] rm -rf of a Rust target/ with only intermediates → still allowed (AC4)
mkdir -p "$TR/target/release/deps"; echo o > "$TR/target/release/deps/lib.rlib"
run_dc "rm -rf $TR/target"
{ [ "$DC_RC" -eq 0 ] && ! echo "$DC_OUT" | grep -q '"decision"'; } \
  && ok "[AC4] rm -rf <target/ intermediates only> → allowed" \
  || bad "[AC4] target/ cleanup blocked/asked (REGRESSION): out='$DC_OUT' rc=$DC_RC"

# [5] rm -rf of the protected kept-artifacts home → BLOCK (exit 2). (AC5)
mkdir -p "$TR/.playwright-mcp/kept-build-artifacts"
run_dc "rm -rf $TR/.playwright-mcp"
{ echo "$DC_OUT" | grep -q '"decision": *"block"' && [ "$DC_RC" -eq 2 ]; } \
  && ok "[AC5] rm -rf <kept-artifacts home> → block (exit 2)" \
  || bad "[AC5] kept-artifacts home deletion not blocked (BUG): out='$DC_OUT' rc=$DC_RC"

# [6] kept-home block honors PWT_KEPT_ARTIFACTS_HOME override basename
mkdir -p "$TR/demo-keep"
DC_OUT=$(printf '{"tool_name":"Bash","tool_input":{"command":"rm -rf %s/demo-keep"}}' "$TR" | PWT_KEPT_ARTIFACTS_HOME="demo-keep" bash "$SCRIPT"); DC_RC=$?
{ echo "$DC_OUT" | grep -q '"decision": *"block"' && [ "$DC_RC" -eq 2 ]; } \
  && ok "kept-home block honors PWT_KEPT_ARTIFACTS_HOME override" \
  || bad "override kept-home not blocked: out='$DC_OUT' rc=$DC_RC"

# [7] a NON-rm command mentioning an installable path is untouched (no false trigger)
run_dc "ls $TR/build"
{ [ "$DC_RC" -eq 0 ] && ! echo "$DC_OUT" | grep -q '"decision"'; } \
  && ok "non-rm command near an installable is not flagged" \
  || bad "non-rm command false-triggered the guard: out='$DC_OUT'"

# [8] FAIL CLOSED: if find cannot scan the target (unreadable subdir), the guard
# must NOT fall through to the safe_rm allow — it asks. (skip as root: no perms.)
if [ "$(id -u)" != "0" ]; then
  mkdir -p "$TR/build2/locked"; echo x > "$TR/build2/locked/secret"; chmod 000 "$TR/build2/locked"
  run_dc "rm -rf $TR/build2"
  echo "$DC_OUT" | grep -q '"decision": *"ask"' \
    && ok "find-error scanning target → ask (fail-closed, no silent allow)" \
    || bad "find-error fell through to allow (fail-OPEN): out='$DC_OUT'"
  chmod 755 "$TR/build2/locked" 2>/dev/null
else
  ok "find-error fail-closed (skipped — running as root)"
fi

# [9] a RELATIVE rm target is resolved against the payload cwd and still scanned;
# a relative 'build' containing a .app → ask (not a silent allow against hook CWD).
mkdir -p "$TR/relcwd/build/My.app/Contents"; echo z > "$TR/relcwd/build/My.app/Contents/z"
DC_OUT=$(printf '{"tool_name":"Bash","tool_input":{"command":"rm -rf build"},"cwd":"%s"}' "$TR/relcwd" | bash "$SCRIPT"); DC_RC=$?
echo "$DC_OUT" | grep -q '"decision": *"ask"' \
  && ok "relative target resolved against payload cwd → ask" \
  || bad "relative target + cwd not resolved (silent allow): out='$DC_OUT'"

echo ""
echo "── results: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ]
