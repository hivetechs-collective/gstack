#!/usr/bin/env bash
# pwt-live-process-cwds.sh — emit the cwd of every LIVE OS process whose working
# directory is at or under a given root. Companion to pwt-live-session-cwds.sh.
#
# WHY (2026-09-08 finding): the worktree GC's in-use probe only saw sessions that
# `claude agents --json` reports. A plain bash lane process (dispatch-lane.sh,
# plan-usage.sh, a `claude -p` child, a test runner…) executing with its cwd
# INSIDE a worktree is invisible to that probe, so an actively-used worktree could
# classify SAFE-PRUNE-* and be reaped from under a running process. This helper
# closes that blind spot at the OS level: if ANY process has its cwd inside the
# worktree, the worktree is in use — regardless of who spawned it.
#
# CONTRACT:
#   argv[1]  optional root — only cwds equal to or under it are emitted (the GC
#            passes its worktrees dir). Empty/absent = emit every process cwd.
#   stdout   one absolute cwd per line, deduplicated; nothing on failure.
#   exit     0 ALWAYS.
#   posture  ADDITIVE protection only. This helper NEVER emits __QUERY_FAILED__
#            and callers must NEVER treat its silence as "no owner": a missing
#            lsof, a timeout, or a permission-limited process table simply adds
#            nothing. The claude-session probe (pwt-live-session-cwds.sh) remains
#            the fail-closed authority. Strictly an improvement over the blind
#            spot above — never a regression.
#
# Portability: bash 3.2 + zsh safe; `lsof -d cwd -Fn` is available on macOS and
# Linux (field output: `p<pid>` / `fcwd` / `n<path>` triplets — only the `n`
# records are consumed). GNU `timeout` / Homebrew `gtimeout` bound the call when
# present; absent, lsof runs unbounded (it completes in ~0.1s with `-d cwd`).
#
# Test seams:
#   PWT_LIVE_PROCESS_CWDS_OVERRIDE  newline-separated cwds to emit instead of
#                                   querying lsof (still root-filtered + deduped)
#   PWT_LSOF_BIN                    lsof binary to run (default: lsof on PATH)
#   PWT_LIVE_PROCESS_TIMEOUT        seconds for the timeout wrapper (default 10)
set -u

ROOT="${1:-}"
REAL_ROOT=""
if [ -n "$ROOT" ]; then
    REAL_ROOT="$(realpath "$ROOT" 2>/dev/null)" \
        || REAL_ROOT="$(cd "$ROOT" 2>/dev/null && pwd -P)" \
        || REAL_ROOT="$ROOT"
fi

# Filter + dedupe. Paths are emitted RAW (not realpath'd) — the consumer realpaths
# both sides of its comparison, and realpath'ing every process cwd here would
# cost a syscall per process for no gain. The root is compared both as given and
# as resolved so a symlinked worktrees dir still matches either spelling.
emit_filtered() {
    awk -v root="$ROOT" -v real_root="$REAL_ROOT" '
        function under(p, r) { return r == "" || p == r || index(p, r "/") == 1 }
        /^\// {
            if (under($0, root) || under($0, real_root)) {
                if (!seen[$0]++) print $0
            }
        }'
}

if [ -n "${PWT_LIVE_PROCESS_CWDS_OVERRIDE:-}" ]; then
    printf '%s\n' "$PWT_LIVE_PROCESS_CWDS_OVERRIDE" | emit_filtered
    exit 0
fi

LSOF_BIN="${PWT_LSOF_BIN:-lsof}"
if ! command -v "$LSOF_BIN" >/dev/null 2>&1; then
    # No lsof → nothing to add. NOT a failure token by contract (additive only).
    exit 0
fi

TIMEOUT_CMD=""
if command -v timeout >/dev/null 2>&1; then
    TIMEOUT_CMD="timeout"
elif command -v gtimeout >/dev/null 2>&1; then
    TIMEOUT_CMD="gtimeout"
fi
TIMEOUT_S="${PWT_LIVE_PROCESS_TIMEOUT:-10}"

# `-Fn` restricts field output to pid/fd/name records; `-d cwd` restricts the
# scan to cwd descriptors so the call stays cheap even on busy hosts. Only the
# `n<path>` records matter — strip the leading `n` and hand the paths to the filter.
if [ -n "$TIMEOUT_CMD" ]; then
    "$TIMEOUT_CMD" "$TIMEOUT_S" "$LSOF_BIN" -d cwd -Fn 2>/dev/null
else
    "$LSOF_BIN" -d cwd -Fn 2>/dev/null
fi | awk '/^n\//{print substr($0, 2)}' | emit_filtered

exit 0
