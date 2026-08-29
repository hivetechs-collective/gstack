#!/usr/bin/env bash
# plan-w-team-dirty-ignore-lib.sh
#
# SINGLE definition site for the worktree-dirtiness policy shared by every
# /plan-w-team cleanup path. SOURCE this file; it has no main flow and is safe
# to source repeatedly.
#
# Consumers:
#   .claude/scripts/plan-w-team-worktree-gc.sh        (periodic sweep)
#   .claude/scripts/plan-w-team-worktree-on-merge.sh  (Step 6 ship, per-merge)
#
# ─── WHY THIS FILE EXISTS ────────────────────────────────────────────────────
# Every consumer answers the same question — "may this worktree be destroyed?"
# — and each one that answers it with its OWN copy of the policy is a fork
# waiting to drift. That is not hypothetical: 1.41.0 had to patch the SAME leak
# twice because the dirtiness decision and the backup decision each carried
# their own ignore set, and the 2026-06-08 audit (WT-2) then found a THIRD
# answer in on-merge.sh, which tested raw porcelain with no filter at all and so
# leaked at ship time exactly the worktrees the periodic GC would have reaped.
#
# So: the policy lives here, once. A consumer that needs a dirtiness verdict
# sources this file. Adding a fourth private copy re-opens the same class of bug
# and is asserted against by plan-w-team-dirty-ignore-lib.test.sh.
#
# ─── THE CONTRACT (all three parts are load-bearing) ─────────────────────────
# A caller deciding whether a worktree may be destroyed MUST apply all three:
#
#   1. __pwt_tracked_dirty   — VETO. Any TRACKED modification is authored work
#                              and vetoes removal in ANY path, ignore set
#                              included. Pure shell: evaluable even when
#                              python3 is broken.
#   2. __pwt_dirty_ignore_filter — LOOSENS. Untracked churn confined to the
#                              ignore set is machine noise, not work, and must
#                              not pin a worktree forever.
#   3. preserve_then_reap    — BACKSTOPS. Untracked AUTHORED files under the
#                              classify-ignored prefixes are copied out before
#                              the destructive removal.
#
# Applying (2) without (1) and (3) converts a leaked worktree into destroyed
# authored work — strictly worse. Never port the filter alone.
#
# ─── FAIL-SAFE RULE ──────────────────────────────────────────────────────────
# (2) is implemented in python3. A missing/broken interpreter makes the filter
# emit nothing, which reads as "no real dirt" — i.e. an UNEVALUATED guard that
# looks satisfied. That is the GC's VETO-0 data-loss class. Callers MUST probe
# __pwt_python_ok first and treat a false result as "cannot evaluate ⇒ keep",
# never as "clean".
#
# Tests: .claude/scripts/plan-w-team-dirty-ignore-lib.test.sh
# Docs:  docs/operations/worktree-lifecycle.md

# Idempotent source guard — consumers may source this more than once.
if [ -n "${__PWT_DIRTY_IGNORE_LIB_LOADED:-}" ]; then
    return 0 2>/dev/null || true
fi
__PWT_DIRTY_IGNORE_LIB_LOADED=1

# ─── dirty-ignore policy (SHARED) ────────────────────────────────────────────
# Dirtiness confined to these paths is policy churn, not real work.
# Tokens are either:
#   • PREFIX tokens (contain "/" e.g. ".claude/", "ios/Pods/"): match by
#     equality or startswith (anchored at the worktree root).
#   • SEGMENT tokens (bare name, no "/", e.g. "node_modules", "build", "dist",
#     "DerivedData", ".expo"): match if the name appears as ANY path segment
#     (covers monorepo nesting like apps/web/build/, packages/x/node_modules/).
#
# AC2 (push-not-merge hardening, 2026-06-06): the default set is BROADENED
# beyond ".claude/state/" because repo policy is to NEVER commit the synced
# tooling layer (.claude/* identical across every checkout) nor regenerable
# build trees. Without this, a pushed-but-unmerged worktree shows
# "dirty = 48-52 files" (all .claude/*) forever and pins itself UNSAFE-KEEP.
# "tests/skill/" and "docs/operations/" are the rest of the claude-pattern-SYNCED
# tooling layer: like .claude/, a consumer receives them by sync (never develops
# them), so a merged/pushed worktree whose ONLY dirt is synced .bats/test/doc
# files would otherwise be pinned UNSAFE-KEEP forever (2026-06-08 leak).
#
# PWT_WORKTREE_GC_DIRTY_IGNORE overrides — it REPLACES the whole set (empty
# disables ignoring, restoring strict any-dirty=keep). Note the `-` (not `:-`)
# parameter expansion at every read site, so an explicitly-empty value is
# honored rather than falling back to the default.
# bash 3.2 + zsh safe (no arrays in the shell path; the matcher runs in python).
PWT_DIRTY_IGNORE_DEFAULT=".claude/:tests/skill/:docs/operations/:node_modules:ios/Pods/:android/.gradle/:build:DerivedData:.expo:dist"

# BACKUP-only ignore set (preserve_then_reap). Deliberately NARROWER than the
# classify set: it drops `.claude/`, `tests/skill/` and `docs/operations/` so an
# untracked authored file under those prefixes is still copied into the backup
# before a reap, and keeps only regenerable build trees plus machine-written
# runtime state (`.claude/state/`). See the rationale block in preserve_then_reap.
# Override with PWT_WORKTREE_GC_PRESERVE_IGNORE (empty = preserve everything).
PWT_PRESERVE_IGNORE_DEFAULT=".claude/state/:node_modules:ios/Pods/:android/.gradle/:build:DerivedData:.expo:dist"

# Shared ignore matcher (python source), used in TWO input modes so the token
# semantics above have exactly one implementation. Contract at EVERY call site:
#   stdin:  porcelain lines (FILTER_MODE=porcelain, the default) OR bare paths
#           (FILTER_MODE=path)
#   env:    IGNORE_PREFIXES = colon-separated ignore tokens (as above)
#           FILTER_MODE     = "porcelain" | "path"
#           FILTER_INVERT   = "1" → emit the IGNORED lines instead of the real ones
#   stdout: only the REAL (non-ignored) input lines survive — or, under
#           FILTER_INVERT=1, only the IGNORED ones (the exact complement)
#
# FILTER_INVERT exists for the untracked SWEEP (third consumer,
# plan-w-team-worktree-untracked-sweep.sh), which needs the opposite half of the
# same partition: the forward mode answers "what is REAL work?", the inverted mode
# answers "what is provably NOT?". Implemented as a flag on THIS source rather than
# a second matcher on purpose — a sweep carrying its own copy of the prefix/segment
# semantics is precisely the fourth-private-copy defect this module exists to
# prevent, and it would be the most dangerous copy of the four, because this one
# decides what to DELETE. Forward ∪ inverted == input, and Forward ∩ inverted == ∅,
# by construction (one `ignored()` call, one branch).
PWT_DIRTY_FILTER_PY='
import sys, os
toks = [p for p in os.environ.get("IGNORE_PREFIXES", "").split(":") if p]
prefixes = [t for t in toks if "/" in t]                 # anchored path-prefix tokens
segments = [t.strip("/") for t in toks if "/" not in t]  # any-depth segment tokens
mode = os.environ.get("FILTER_MODE", "porcelain")
invert = os.environ.get("FILTER_INVERT", "") == "1"
q = chr(34)
def ignored(path):
    for pre in prefixes:                                 # prefix: eq or startswith at root
        if path == pre.rstrip("/") or path.startswith(pre):
            return True
    if segments:                                         # segment: name at any depth
        parts = path.split("/")
        for seg in segments:
            if seg in parts:
                return True
    return False
for line in sys.stdin:
    line = line.rstrip(chr(10))
    if not line.strip():
        continue
    if mode == "path":
        path = line[2:] if line.startswith("./") else line
    else:
        path = line[3:] if len(line) > 3 else ""
        if " -> " in path:           # renamed: take destination
            path = path.split(" -> ", 1)[1]
    path = path.strip()
    if len(path) >= 2 and path[0] == q and path[-1] == q:
        path = path[1:-1]            # unquote paths with special chars
    if ignored(path) != invert:      # forward: drop ignored. inverted: keep only ignored.
        continue
    print(line)                      # the surviving half of the partition
'

__pwt_dirty_ignore_filter() {
    # $1 = ignore set (colon-separated); porcelain on stdin → REAL lines on stdout.
    IGNORE_PREFIXES="$1" FILTER_MODE=porcelain python3 -c "$PWT_DIRTY_FILTER_PY" 2>/dev/null
}

__pwt_path_ignore_filter() {
    # $1 = ignore set (colon-separated); bare paths on stdin → REAL paths on stdout.
    IGNORE_PREFIXES="$1" FILTER_MODE=path python3 -c "$PWT_DIRTY_FILTER_PY" 2>/dev/null
}

__pwt_path_discard_filter() {
    # $1 = ignore set (colon-separated); bare paths on stdin → the IGNORED paths on
    # stdout. The exact complement of __pwt_path_ignore_filter over the same input.
    #
    # SAFETY NOTE FOR CALLERS. This function names paths a caller may DELETE, so read
    # its failure mode before using it: like every arm of this module it runs in
    # python3, and a broken interpreter makes it emit NOTHING. For the forward filter
    # "nothing" reads as the dangerous "clean"; here "nothing" reads as "delete
    # nothing", which is the SAFE direction — but callers must still probe
    # __pwt_python_ok first, because a caller that treats an empty result as a
    # completed sweep will report success for a pass that never ran.
    #
    # Which ignore set to pass is the whole safety argument. Pass the BACKUP set
    # ($PWT_PRESERVE_IGNORE_DEFAULT): what preserve_then_reap declines to back up is,
    # by that function's own contract, regenerable or machine-written. Passing the
    # CLASSIFY set ($PWT_DIRTY_IGNORE_DEFAULT) would be a data-loss bug — it covers
    # `.claude/`, `tests/skill/` and `docs/operations/`, exactly where a /plan-w-team
    # tooling lane authors new files, and "ignorable for the reap decision" has never
    # meant "worthless" (measured 2026-07-30; see the preserve_then_reap rationale).
    IGNORE_PREFIXES="$1" FILTER_MODE=path FILTER_INVERT=1 python3 -c "$PWT_DIRTY_FILTER_PY" 2>/dev/null
}

# ─── python3 availability probe (fail-safe precondition) ─────────────────────
# Returns 0 when python3 can actually execute. Callers MUST consult this BEFORE
# trusting __pwt_dirty_ignore_filter: with a broken interpreter the filter emits
# nothing, which is indistinguishable from "clean" — an unevaluated guard that
# reads as satisfied. See the FAIL-SAFE RULE header and the GC's VETO 0.
__pwt_python_ok() {
    command -v python3 >/dev/null 2>&1 && python3 -c 'pass' >/dev/null 2>&1
}

# ─── VETO: tracked-file dirtiness (ignore set does NOT apply) ────────────────
# Consumes `git status --porcelain` on stdin; exits 0 when at least one TRACKED
# change is present.
#
# Scoped to TRACKED changes on purpose. Making *all* dirt an absolute veto would
# revert the 2026-06-08 leak fix — hooks rewrite `.claude/state/*` into every
# worktree, so "any dirt pins forever" is what fed the 2026-05-29 67-worktree /
# 64 GB ENOSPC pileup. `git status --porcelain` gives the exact discriminator:
# `??` is untracked (machine churn — stays ignorable), `!!` is ignored, and every
# other XY code means a tracked, committed file was deliberately
# edited/staged/deleted/renamed. That is authored work in every case, and no
# ignore prefix may override it.
#
# This is the gap that made the 2026-07-29 incident lossy: /plan-w-team tooling
# lanes do their work under `.claude/`, `tests/skill/` and `docs/operations/`,
# which the ignore set (correctly, for its own purpose) filters out — so the
# dirty check read 0 while five hand-edited hook files sat in the tree.
#
# Pure shell (grep) BY DESIGN: this veto must stay evaluable when python3 is
# unavailable, precisely the situation in which the python filter cannot be.
__pwt_tracked_dirty() {
    local tracked_lines
    tracked_lines="$(grep -v '^??' | grep -v '^!!' | grep -v '^[[:space:]]*$' || true)"
    [ -n "$tracked_lines" ]
}

# ─── preserve-then-reap: back up real deltas BEFORE a destructive removal ────
# Reads the caller-set global $MAIN_CHECKOUT (backup root). Returns non-zero to
# mean "backup failed — do NOT remove"; every caller must honor that.
preserve_then_reap() {
    local wt_path="$1"
    local name backup_dir ts stamp
    name="$(basename "$wt_path")"
    backup_dir="$MAIN_CHECKOUT/.claude/state/hygiene-backups"
    ts="$(date -u +%Y%m%dT%H%M%SZ)"
    stamp="$backup_dir/${name}-${ts}"

    # Resolve the worktree's own toplevel (empty / != wt_path means NOT its own git WT)
    local wt_top real_wt
    wt_top="$(git -C "$wt_path" rev-parse --show-toplevel 2>/dev/null || echo "")"
    real_wt="$(realpath "$wt_path" 2>/dev/null || echo "$wt_path")"
    [ -n "$wt_top" ] && wt_top="$(realpath "$wt_top" 2>/dev/null || echo "$wt_top")"

    # The CLASSIFY ignore set answers "may this worktree be reaped?"; the BACKUP
    # ignore set answers "what must survive if it is?". Those are different
    # questions and using one set for both lost data (measured 2026-07-30):
    #   • a TRACKED modification under `.claude/` IS captured, because
    #     `git diff HEAD` ignores the prefix filter entirely — verified.
    #   • an UNTRACKED authored file under `.claude/` (a brand-new script, spec,
    #     or test — the normal shape of a /plan-w-team tooling lane) is invisible
    #     to `git diff HEAD` AND filtered out of `real_dirty` by the `.claude/`
    #     prefix, so both arms of the guard below saw "nothing real to preserve"
    #     and the file was destroyed with no backup at all.
    # So the backup path uses a deliberately NARROWER set: only genuinely
    # regenerable trees and machine-written runtime state. Widening what we
    # preserve costs a few KB of patch; narrowing it costs authored work.
    local ignore_set="${PWT_WORKTREE_GC_PRESERVE_IGNORE-$PWT_PRESERVE_IGNORE_DEFAULT}"

    if [ -n "$wt_top" ] && [ "$wt_top" = "$real_wt" ]; then
        # Genuine worktree → diff + untracked list, filtered to non-ignored paths.
        local diff_out porcelain real_dirty untracked_real
        diff_out="$(git -C "$wt_path" diff HEAD 2>/dev/null || echo "")"
        porcelain="$(git -C "$wt_path" -c core.quotePath=false status --porcelain 2>/dev/null || echo "")"
        real_dirty="$(printf '%s\n' "$porcelain" | __pwt_dirty_ignore_filter "$ignore_set")"

        # UNTRACKED authored files, enumerated as FILES rather than read off the
        # porcelain. `git status --porcelain` collapses a wholly-untracked
        # directory to a single `?? dir/` entry, so the porcelain list alone
        # records the DIRECTORY name and nothing about what was inside it — the
        # patch would say `?? .claude/` and the contents would be destroyed with
        # the worktree. `ls-files --others` expands to the individual paths, which
        # is what makes a content backup possible at all.
        #
        # `core.quotePath=false` is REQUIRED, not cosmetic: with git's default,
        # a path containing non-ASCII bytes comes back double-quoted with octal
        # escapes (`".claude/hooks/caf\303\251.sh"`). That string names no file
        # on disk, so the copy below fails, preserve_then_reap returns non-zero,
        # and the caller correctly skips the removal — i.e. ONE accented
        # filename anywhere in the worktree would silently re-open the very leak
        # this module exists to close. Fails safe, but still wrong.
        untracked_real="$(git -C "$wt_path" -c core.quotePath=false \
            ls-files --others --exclude-standard 2>/dev/null \
            | __pwt_path_ignore_filter "$ignore_set")"

        if [ -z "$diff_out" ] && [ -z "$real_dirty" ] && [ -z "$untracked_real" ]; then
            return 0   # clean (or only policy churn) — nothing real to preserve
        fi
        mkdir -p "$backup_dir" 2>/dev/null || { echo "[preserve] FAILED to mkdir $backup_dir — skipping rm of $name" >&2; return 1; }
        {
            printf '# preserve-then-reap %s\n# worktree: %s\n# at: %s\n\n## git diff HEAD\n' "$name" "$wt_path" "$ts"
            printf '%s\n' "$diff_out"
            printf '\n## untracked/modified (non-ignored)\n%s\n' "$real_dirty"
            printf '\n## untracked files copied to %s.files/\n%s\n' "${name}-${ts}" "$untracked_real"
        } > "${stamp}.patch" 2>/dev/null || { echo "[preserve] FAILED to write ${stamp}.patch — skipping rm of $name" >&2; return 1; }

        # Copy the untracked authored CONTENT, not just its name. `git diff HEAD`
        # covers tracked modifications; nothing else covers these.
        if [ -n "$untracked_real" ]; then
            if ! __pwt_copy_files "$wt_path" "${stamp}.files" "$untracked_real" "$name"; then
                return 1
            fi
            echo "[preserve] copied untracked authored files of $name → ${stamp}.files/" >&2
        fi
        echo "[preserve] backed up real delta of $name → ${stamp}.patch" >&2
        return 0
    fi

    # Non-git orphan dir: manifest + copy of NON-ignored files only. The path
    # filter is the SHARED matcher (it used to be a fourth private copy of the
    # prefix/segment logic inlined right here).
    local manifest
    manifest="$(cd "$wt_path" 2>/dev/null && find . -type f 2>/dev/null | __pwt_path_ignore_filter "$ignore_set")"
    if [ -z "$manifest" ]; then
        return 0   # only ignored content (node_modules, etc) — nothing real to preserve
    fi
    mkdir -p "${stamp}.files" 2>/dev/null || { echo "[preserve] FAILED to mkdir ${stamp}.files — skipping rm of $name" >&2; return 1; }
    printf '%s\n' "$manifest" > "${stamp}.manifest.txt" 2>/dev/null || { echo "[preserve] FAILED to write manifest — skipping rm of $name" >&2; return 1; }
    __pwt_copy_files "$wt_path" "${stamp}.files" "$manifest" "$name" || return 1
    echo "[preserve] backed up orphan-dir files of $name → ${stamp}.files/ (manifest: ${stamp}.manifest.txt)" >&2
    return 0
}

# ─── copy a newline-separated file list, preserving relative structure ───────
# $1=source root  $2=destination root  $3=newline-separated relative paths
# $4=worktree name (for messages)
# Fail-safe: ANY mkdir/copy failure returns non-zero so the caller skips the
# removal — a partial backup must never authorize a destructive reap.
__pwt_copy_files() {
    local src_root="$1" dest_root="$2" file_list="$3" name="$4"
    local f rel dest
    mkdir -p "$dest_root" 2>/dev/null || { echo "[preserve] FAILED to mkdir $dest_root — skipping rm of $name" >&2; return 1; }
    while IFS= read -r f; do
        [ -z "$f" ] && continue
        rel="${f#./}"
        dest="$dest_root/$rel"
        mkdir -p "$(dirname "$dest")" 2>/dev/null || { echo "[preserve] FAILED dir for $rel — skipping rm of $name" >&2; return 1; }
        cp -p "$src_root/$rel" "$dest" 2>/dev/null || { echo "[preserve] FAILED copy $rel — skipping rm of $name" >&2; return 1; }
    done <<EOF_FILE_LIST
$file_list
EOF_FILE_LIST
    return 0
}
