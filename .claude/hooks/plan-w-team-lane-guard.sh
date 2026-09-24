#!/bin/bash
# plan-w-team Lane Guard — PreToolUse hook (Bash|Write|Edit|MultiEdit)
#
# PWT-LANE1 (2026-08-09, cleanscale incident): while a /goal-spawned
# /plan-w-team worker holds a lane, NOTHING at the tool layer stopped the
# supervising session from implementing the work itself. The Stop-hook
# evaluator gates termination — never behavior — and after a compaction the
# supervisor role ("observe and steer, never implement") is exactly the kind
# of procedural scaffolding a summary drops while keeping the objective. The
# result: the origin chat edited product code in the main checkout while the
# lane's worker ran in its worktree, forking the work and corrupting the run.
#
# This hook makes the lane BINDING instead of advisory:
#   1. The owning WORKER (session SID prefix == goal's worker_sid) is never
#      restricted — the pipeline's own gates govern it.
#   2. A SUPERVISOR session bound to a live lane is denied mutating tool calls
#      against the repo the lane owns: Edit/Write/MultiEdit anywhere in the
#      main checkout outside .claude/state/, git write-subcommands, file
#      mutators with provable repo targets, build/test runners, and shell
#      redirects into the repo. Its legitimate duties — reading, state
#      bookkeeping under .claude/state/, running .claude/scripts/ helpers,
#      steering via stop/resume — all pass untouched.
#   3. ANY non-worker session (bound or not) is denied writes into the lane's
#      worktree and denied forging the artifacts the Stop evaluator trusts
#      (plan-w-team-ship-verdict-<slug>.json, plan-w-team-test-green-<slug>.json).
#      A BOUND session is additionally denied tampering with the lane's
#      goal-state file and the release valve itself.
#
# Every deny RE-TEACHES the role in its message, so the first violating call
# after a compaction restores the contract the summary dropped — enforcement
# doubles as context restoration.
#
# Binding sources for "this session supervises lane L":
#   a. PLAN_W_TEAM_SUPERVISOR_SESSION=1 (bg supervisor launch env; workers get
#      an explicit =0 forced by pwt-goal.sh, so this can never mark a worker)
#   b. goal-state supervisor_sid == this session (seeded by pwt-goal.sh)
#   c. pwt-launches.jsonl row: this session spawned the lane's worker
#
# Lane liveness = goal-state exists, terminal_state null, mtime younger than
# PWT_GOAL_STALE_HOURS (default 24h; matches the evaluator's stale-skip), and
# no release file. Release valve (USER-only, written outside the bound
# session): .claude/state/plan-w-team-lane-release-<slug>.json.
#
# HOOK ENFORCEMENT CONTRACT (block-protected-paths.sh precedent):
#   exit 0 → allow.  exit 2 + reason on stderr → BLOCK.
# Fail-open on every infrastructure error (no jq, unreadable state, no SID):
# a guard that bricks sessions is worse than one that under-detects. Denies
# are only ever issued on POSITIVE evidence.
#
# RESOLVED-TARGET RULE (2.15.0): a bound supervisor's git writes and in-place
# edits are decided by the RESOLVED TARGET, not the command class. A supervisor
# committing in a DIFFERENT repo (`git -C /abs/other commit`) or editing an
# absolute file outside the lane repo (`sed -i '' … /abs/other/f`) is not doing
# the lane's work — it is ALLOWED (with an audit row). The SAME work in the lane
# repo or any of its worktrees still DENIES. One predicate, __target_is_foreign,
# is shared by the Edit/Write path AND the two Bash classes so D1–D4 cannot
# diverge again. DELIBERATE fail-closed vs fail-open asymmetry on "unresolvable":
#   • git-write / in-place edit → FAIL-CLOSED. ALLOW only on positive proof the
#     target resolves (symlinks followed) OUTSIDE MAIN_ROOT and all worktrees;
#     relative / $var / glob / .. / ~ / symlink-into-repo → DENY (reason names
#     "unresolvable" where it applies). The operator's time-boxed allowance file
#     (plan-w-team-lane-guard-allow-<sid8>.json, scope "outside-repo") relaxes
#     ONLY this unresolvable branch — never a provably-inside target.
#   • rm/mv/cp mutator + redirect/tee → FAIL-OPEN (unchanged). Deny only on a
#     provable in-repo target; $vars pass — the file-tool wall is the hard one.
#
# Kill switch: PLAN_W_TEAM_DISABLE_LANE_GUARD=1
# Audit trail: .claude/state/plan-w-team-lane-guard-audit.jsonl (denies only)
# Spec: docs/operations/lane-enforcement.md

set -u

[ "${PLAN_W_TEAM_DISABLE_LANE_GUARD:-}" = "1" ] && exit 0

INPUT=$(cat 2>/dev/null || echo '{}')
command -v jq >/dev/null 2>&1 || exit 0

SELF_SID=$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
SELF8="${SELF_SID:0:8}"
TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null)
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // ""' 2>/dev/null)
[ -n "$CWD" ] || CWD="$PWD"

# Nothing to evaluate for non-mutating tools (defensive; settings.json should
# only wire us to Bash/Write/Edit/MultiEdit).
case "$TOOL" in
    Bash|Write|Edit|MultiEdit|NotebookEdit) : ;;
    *) exit 0 ;;
esac

# ── MAIN-checkout resolution (same idiom as plan-w-team-goal-evaluator.sh) ───
# PWT_PROJECT_ROOT_OVERRIDE wins (hermetic test contract); else the common git
# dir of the session's cwd; else CLAUDE_PROJECT_DIR's. A worktree's git file
# points at the common dir, so this lands on the MAIN checkout either way.
__main_root_of() {
    local from="$1" cdir
    cdir=$(git -C "$from" rev-parse --git-common-dir 2>/dev/null || echo "")
    case "$cdir" in
        "") echo "" ;;
        /*) (cd "$(dirname "$cdir")" 2>/dev/null && pwd) || echo "" ;;
        *)  (cd "$from/$(dirname "$cdir")" 2>/dev/null && pwd) || echo "" ;;
    esac
}
MAIN_ROOT=""
if [ -n "${PWT_PROJECT_ROOT_OVERRIDE:-}" ]; then
    MAIN_ROOT="$PWT_PROJECT_ROOT_OVERRIDE"
else
    MAIN_ROOT=$(__main_root_of "$CWD")
    [ -z "$MAIN_ROOT" ] && [ -n "${CLAUDE_PROJECT_DIR:-}" ] && MAIN_ROOT=$(__main_root_of "$CLAUDE_PROJECT_DIR")
fi
[ -n "$MAIN_ROOT" ] && [ -d "$MAIN_ROOT" ] || exit 0
# Canonicalize through cd+pwd so prefix comparisons use the same spelling as
# __abs_path's output. Without this, a MAIN_ROOT carrying a double slash (macOS
# TMPDIR ends with "/", so mktemp-derived roots do) never prefix-matches the
# normalized file path and every path-scoped deny silently allows.
MAIN_ROOT=$(cd "$MAIN_ROOT" 2>/dev/null && pwd) || exit 0
STATE_DIR="$MAIN_ROOT/.claude/state"
[ -d "$STATE_DIR" ] || exit 0

# ── Tool-input extraction ────────────────────────────────────────────────────
FILE_PATH=""
CMD=""
if [ "$TOOL" = "Bash" ]; then
    CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""' 2>/dev/null)
    [ -n "$CMD" ] || exit 0
else
    FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // .tool_input.notebook_path // ""' 2>/dev/null)
    [ -n "$FILE_PATH" ] || exit 0
fi

# Absolutize + normalize a path (bash-3.2-safe; no readlink -f on macOS).
# Prefers `cd dirname && pwd` (parent almost always exists, even for a new
# file); falls back to python3 normpath; else a crude join. A path we cannot
# resolve returns empty — callers treat that as "no positive evidence".
__abs_path() {
    local p="$1" d b
    case "$p" in /*) : ;; *) p="$CWD/$p" ;; esac
    d=$(dirname "$p"); b=$(basename "$p")
    if [ -d "$d" ]; then
        printf '%s/%s' "$(cd "$d" 2>/dev/null && pwd)" "$b"
    elif command -v python3 >/dev/null 2>&1; then
        python3 -c 'import os,sys; print(os.path.normpath(sys.argv[1]))' "$p" 2>/dev/null
    else
        case "$p" in *..*) echo "" ;; *) printf '%s' "$p" ;; esac
    fi
}

__under() {  # $1=path  $2=dir  → 0 if path is dir or inside dir
    case "$1" in "$2"|"$2"/*) return 0 ;; esac
    return 1
}

FILE_ABS=""
[ -n "$FILE_PATH" ] && FILE_ABS=$(__abs_path "$FILE_PATH")

# ── F4 hygiene subsystem toggle ─────────────────────────────────────────────
# PWT_DISABLE_LANE_GUARD_HYGIENE=1 reverts to the pre-2026-08-19 pure-deny
# guard: no shell masking, no git-tag exemption, no host-hygiene ALLOW class,
# deny-only auditing — and no per-segment in-place scanner (retest-8). The
# trusted-artifact in-place check falls back to the 2.51.0 whole-token form
# (FAM_INPLACE_WT_RE: a command-word sed/perl carrying an in-place option TOKEN)
# ANDed with an anchored family member anywhere in the command — strict, never
# looser than the scanner, and a plain `sed -n 1p <family>.json` read still passes.
# A kill switch that only half-reverts is not a revert.
HYGIENE=1
[ "${PWT_DISABLE_LANE_GUARD_HYGIENE:-0}" = "1" ] && HYGIENE=0

# ── Shell-text masking (F4a — the shared root of two false positives) ───────
# The guard classifies a Bash command by grepping its TEXT. Twice on 2026-08-19
# that read text the shell would never have executed:
#
#   awk '$3 > 50'              the `>` is inside single quotes — an awk body,
#                              not a redirect. __redirect_targets extracted the
#                              target "50'", resolved it against cwd, found it
#                              under the repo, and DENIED an inspection command.
#
#   mv "$(command -v ccusage)" $HOME/x
#                              the mutator scan whitespace-tokenizes the command,
#                              so the substitution shed the fragment `ccusage)"`,
#                              which also resolved under the repo and DENIED the
#                              one remediation the incident actually needed.
#
# Both are the same bug: shell text read as if it were shell structure. Mask it
# once, before any extraction, so every classifier sees only real structure:
#
#   inside ANY quotes  → the shell operators > < ; | & are LITERAL TEXT; blank
#                        them. Path characters are PRESERVED, so a legitimately
#                        quoted repo path ('/repo/src') still resolves and still
#                        denies — masking must never widen the permit set.
#   inside $( ) or ` ` → unresolvable by definition; blank EVERYTHING, which
#                        also stops fragments from becoming candidate targets.
__mask_shell_text() {
    printf '%s' "$1" | awk '
    {
      n = length($0); out = ""; i = 1
      mode = "N"     # N=normal S=single D=double C=substitution
      ret  = "N"     # where C returns to
      depth = 0      # $( ) nesting; -1 marks a backtick span
      while (i <= n) {
        c = substr($0, i, 1)
        nx = (i < n) ? substr($0, i + 1, 1) : ""
        if (mode == "N") {
          if (c == "\"")                 { mode = "D"; out = out c; i++; continue }
          if (c == "'"'"'")              { mode = "S"; out = out c; i++; continue }
          if (c == "$" && nx == "(")     { mode = "C"; ret = "N"; depth = 1; out = out "$("; i += 2; continue }
          if (c == "`")                  { mode = "C"; ret = "N"; depth = -1; out = out c; i++; continue }
          out = out c; i++; continue
        }
        if (mode == "S" || mode == "D") {
          if (mode == "D" && c == "\\")  { out = out "__"; i += 2; continue }
          if (mode == "D" && c == "\"")  { mode = "N"; out = out c; i++; continue }
          if (mode == "S" && c == "'"'"'") { mode = "N"; out = out c; i++; continue }
          if (mode == "D" && c == "$" && nx == "(") { mode = "C"; ret = "D"; depth = 1; out = out "$("; i += 2; continue }
          if (mode == "D" && c == "`")   { mode = "C"; ret = "D"; depth = -1; out = out c; i++; continue }
          # A backtick reaching here is inside SINGLE quotes (D-mode backticks were
          # consumed just above) — the shell does NO substitution there, so it is
          # literal prose. Blank it like the other operators so `${SEP}` cannot read
          # `` `git commit …` `` inside quoted text as a command boundary (D9).
          if (c == ">" || c == "<" || c == ";" || c == "|" || c == "&" || c == "`") { out = out "_"; i++; continue }
          out = out c; i++; continue
        }
        # mode == "C": inside a command substitution.
        if (depth == -1) {
          if (c == "`") { mode = ret; depth = 0; out = out c } else { out = out "_" }
          i++; continue
        }
        if (c == "(") depth++
        else if (c == ")") {
          depth--
          if (depth == 0) { mode = ret; out = out ")"; i++; continue }
        }
        out = out "_"; i++; continue
      }
      print out
    }' 2>/dev/null
}

# CMD_SCAN is what every classifier below reads. CMD stays intact for messages —
# an operator must see what they actually typed, not our normalized view.
#
# Computed LAZILY, on first use inside the live-lane loop. This hook fires on
# every Bash call in every session on the machine, and the overwhelming majority
# of those have no live lane at all — masking them would add an awk spawn per
# tool call to the whole host. That is precisely the per-call spawn cost this
# release exists to remove; paying it here to fix a classifier would be an
# unusually literal own goal.
# D11 (2026-08-29): heredoc BODIES are not shell structure — a `>`/`<`/`;` in a heredoc payload
# (e.g. a markdown `> Method note:` line inside a `<<'EOF' … EOF` brief) is prose, but
# __redirect_targets read the `>` as a redirect whose target (`Method`) resolved under the repo →
# a deny naming a token the operator never typed as a path. Blank heredoc bodies (the lines between
# a `<<[-]?["']?WORD` opener and the WORD terminator) BEFORE any classifier. The opener line — with
# any REAL redirect (`cat > repo/x <<EOF`) — and the terminator are preserved, so a real in-repo
# redirect on the opener line still DENIES. Residual (documented, drift-not-adversary threat model):
# a `<<WORD` inside a quoted string on a line with unbalanced quotes before it is skipped by the
# quote-parity guard; a crafted fake opener remains a theoretical over-blank the file-tool wall backstops.
__strip_heredocs() {
    printf '%s' "$1" | awk '
    {
      line = $0
      if (inhd) {
        t = line; sub(/^\t+/, "", t)
        if (t == term) { inhd = 0; print line; next }
        print "_"          # body line → neutralized
        next
      }
      if (match(line, /<<[-]?[ \t]*["'"'"']?[A-Za-z_][A-Za-z0-9_]*/)) {
        before = substr(line, 1, RSTART - 1)
        nq = gsub(/["'"'"']/, "&", before)       # quote count before the << (parity guard)
        if (nq % 2 == 0) {
          w = substr(line, RSTART, RLENGTH)
          sub(/^<<[-]?[ \t]*["'"'"']?/, "", w)   # strip << [-] [quote] → WORD
          term = w; inhd = 1
        }
      }
      print line
    }' 2>/dev/null
}

CMD_SCAN=""
CMD_SCAN_READY=0
__ensure_cmd_scan() {
    [ "$CMD_SCAN_READY" = "1" ] && return 0
    CMD_SCAN="$CMD"
    if [ "$HYGIENE" = "1" ] && [ -n "$CMD" ]; then
        # D11: strip heredoc bodies first, THEN mask quotes/substitutions.
        HDSTRIP=$(__strip_heredocs "$CMD")
        [ -n "$HDSTRIP" ] || HDSTRIP="$CMD"
        MASKED=$(__mask_shell_text "$HDSTRIP")
        # Fail CLOSED to the unmasked text: if awk is missing or errors, we keep
        # today's (over-strict) behavior rather than silently classifying nothing.
        [ -n "$MASKED" ] && CMD_SCAN="$MASKED"
    fi
    CMD_SCAN_READY=1
}

# ── Worktree set (F4c) ──────────────────────────────────────────────────────
# "Outside the repo" must mean outside the repo AND all of its worktrees. Ones
# under MAIN_ROOT are already covered by the prefix test; this catches a
# worktree mounted elsewhere. Failure to enumerate only makes us stricter.
ALL_WORKTREES=""
if [ "$HYGIENE" = "1" ]; then
    # D10 (2026-08-29): `git worktree list` lists the MAIN checkout FIRST. Including it here
    # made __under_any_worktree short-circuit every in-repo Bash target to DENY *before* the
    # STATE_DIR allowance (:__bash_target_denied), so a bound supervisor could `cat > … .claude/state/…`
    # NOWHERE via Bash even though the file-tool path (Write) allows it — and the deny message's own
    # advice ("write a brief under .claude/state/ (allowed)") was false for Bash. The set is for a
    # worktree "mounted elsewhere"; the main checkout is covered by the MAIN_ROOT prefix test. Drop it.
    # Canonicalize each (cd+pwd) so a /private symlink spelling still matches MAIN_ROOT.
    __lg_raw_wts=$(git -C "$MAIN_ROOT" worktree list --porcelain 2>/dev/null \
        | awk '/^worktree /{ $1=""; sub(/^ /,""); print }' || echo "")
    while IFS= read -r __lg_w; do
        [ -n "$__lg_w" ] || continue
        __lg_wc=$(cd "$__lg_w" 2>/dev/null && pwd) || __lg_wc="$__lg_w"
        [ "$__lg_wc" = "$MAIN_ROOT" ] && continue
        ALL_WORKTREES="${ALL_WORKTREES}${ALL_WORKTREES:+
}${__lg_wc}"
    done <<EOF_LG_RAWWT
$__lg_raw_wts
EOF_LG_RAWWT
fi
__under_any_worktree() {  # $1 = absolute path
    local w
    [ -n "$ALL_WORKTREES" ] || return 1
    while IFS= read -r w; do
        [ -n "$w" ] || continue
        __under "$1" "$w" && return 0
    done <<EOF_WTALL
$ALL_WORKTREES
EOF_WTALL
    return 1
}

# ── Shared resolved-target predicate (2.15.0) ────────────────────────────────
# Canonicalize a candidate target to a LOGICAL absolute path with the FINAL
# component's symlink FOLLOWED, or empty when the token cannot be statically
# resolved. Empty = "no positive proof of location" (fail-closed for the
# git-write/in-place classes). Logical `cd+pwd` (never `pwd -P`) so a resolved
# target compares apples-to-apples with MAIN_ROOT / WT (both canonicalized
# logically at :99 / :417). bash 3.2: no `readlink -f`; a bounded readlink loop
# follows a symlinked final component, python3 realpath is the last backstop.
__realpath_target() {  # $1 = raw token → canonical abs path or "" (unresolvable)
    local t="$1" d b link i=0
    t="${t%\"}"; t="${t#\"}"; t="${t%\'}"; t="${t#\'}"
    case "$t" in
        ''|*'$'*|*'`'*|*'*'*|*'?'*|*'['*|'~'*) return 0 ;;   # var/sub/glob/~ → unresolvable
        /*) : ;;
        *) return 0 ;;                                       # relative → unresolvable (fail-closed)
    esac
    case "$t" in *'/../'*|*'/..'|'../'*) return 0 ;; esac    # .. → unresolvable
    d=$(dirname "$t"); b=$(basename "$t")
    while [ -L "$d/$b" ] && [ "$i" -lt 40 ]; do
        link=$(readlink "$d/$b" 2>/dev/null) || break
        case "$link" in
            /*) d=$(dirname "$link"); b=$(basename "$link") ;;
            *)  d=$(cd "$d" 2>/dev/null && cd "$(dirname "$link")" 2>/dev/null && pwd) || return 0
                b=$(basename "$link") ;;
        esac
        [ -n "$d" ] || return 0
        i=$((i + 1))
    done
    if [ -d "$d" ]; then
        printf '%s/%s' "$(cd "$d" 2>/dev/null && pwd)" "$b"
    elif command -v python3 >/dev/null 2>&1; then
        python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$t" 2>/dev/null
    else
        printf '%s/%s' "$d" "$b"   # absolute, ..-free, glob-free lexical fallback
    fi
}

# in-repo = under MAIN_ROOT OR under any worktree (the deny zone).
__path_in_repo() {  # $1 = absolute path
    __under "$1" "$MAIN_ROOT" && return 0
    __under_any_worktree "$1" && return 0
    return 1
}

# THE shared predicate: 0 (true) iff the token PROVABLY resolves to a FOREIGN
# path — outside MAIN_ROOT and every worktree. Used by Edit/Write AND the
# git-write / in-place Bash classes.
__target_is_foreign() {  # $1 = raw token
    local real
    real=$(__realpath_target "$1")
    [ -n "$real" ] || return 1          # unresolvable → not provably foreign
    __path_in_repo "$real" && return 1  # resolves in-repo → not foreign
    return 0
}

# ISO-8601 (…Z) → epoch seconds, or "" (portable: BSD date, GNU date, python3).
__iso_to_epoch() {  # $1 = "YYYY-MM-DDTHH:MM:SSZ"
    local iso="$1" e
    e=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$iso" +%s 2>/dev/null) && { printf '%s' "$e"; return 0; }
    e=$(date -u -d "$iso" +%s 2>/dev/null) && { printf '%s' "$e"; return 0; }
    if command -v python3 >/dev/null 2>&1; then
        python3 -c 'import sys,calendar,time; print(calendar.timegm(time.strptime(sys.argv[1],"%Y-%m-%dT%H:%M:%SZ")))' "$iso" 2>/dev/null && return 0
    fi
    printf ''
}

# Operator's time-boxed allowance (§3.4). Relaxes ONLY the fail-closed
# UNRESOLVABLE branch of git-write/in-place — NEVER a provably-inside target.
# Written from OUTSIDE the bound session (like the release valve):
#   .claude/state/plan-w-team-lane-guard-allow-<self-sid8>.json
#   {"until":"<iso>","scope":"outside-repo"}
__outside_repo_allowance_active() {  # 0 = a valid, in-scope, unexpired allowance exists
    [ "$HYGIENE" = "1" ] || return 1
    [ -n "$SELF8" ] || return 1
    local f="$STATE_DIR/plan-w-team-lane-guard-allow-${SELF8}.json" scope until now exp
    [ -f "$f" ] || return 1
    jq -e . "$f" >/dev/null 2>&1 || return 1
    scope=$(jq -r '.scope // ""' "$f" 2>/dev/null)
    [ "$scope" = "outside-repo" ] || return 1
    until=$(jq -r '.until // ""' "$f" 2>/dev/null)
    [ -n "$until" ] || return 1
    exp=$(__iso_to_epoch "$until")
    [ -n "$exp" ] || return 1
    now=$(date -u +%s)
    [ "$now" -lt "$exp" ] 2>/dev/null || return 1
    return 0
}

# For the FAIL-CLOSED classes (git-write, in-place). 0 = ALLOW this target,
# 1 = DENY. A provably-inside target ALWAYS denies (the allowance never covers
# it); a provably-outside target always allows; an UNRESOLVABLE target denies
# unless the operator's allowance is active.
__write_target_ok() {  # $1 = raw token
    local real
    real=$(__realpath_target "$1")
    if [ -n "$real" ]; then
        __path_in_repo "$real" && return 1   # provably inside → DENY
        return 0                              # provably outside → ALLOW
    fi
    __outside_repo_allowance_active && return 0
    return 1                                  # unresolvable, no allowance → DENY
}

# ── Deny plumbing ────────────────────────────────────────────────────────────
AUDIT="$STATE_DIR/plan-w-team-lane-guard-audit.jsonl"
# Every verdict the guard REACHES is recorded — denies as before, plus the
# positively-classified host-hygiene ALLOWs and classifier exemptions the F4
# scope adds. Deliberately NOT logged: the "no live lane applies" path. That is
# not a verdict, and a row per Bash call in every session on the machine is a
# disk-exhaustion vector, not an audit trail. Bound documented in
# docs/operations/host-load-protection.md.
__audit() {  # $1=decision $2=kind $3=slug $4=target $5=reason
    jq -cn --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg sid "$SELF8" \
        --arg tool "$TOOL" --arg decision "$1" --arg kind "$2" --arg slug "$3" \
        --arg target "$4" --arg reason "${5:-}" \
        '{ts:$ts, sid:$sid, tool:$tool, decision:$decision, kind:$kind, slug:$slug, target:$target, reason:$reason}' \
        >> "$AUDIT" 2>/dev/null || true
}

__deny_role() {  # $1=slug $2=worker8 $3=worktree $4=target
    __audit "deny" "supervisor-implementing" "$1" "$4"
    cat >&2 <<MSGEOF
⛔ LANE GUARD (PWT-LANE1): this session is the SUPERVISOR of live /plan-w-team lane '$1' (worker ${2}, worktree: ${3:-main checkout}). Supervisors observe and steer — they NEVER implement, run builds, or commit. This $TOOL call (${4}) is the lane's work and is denied.

Do instead:
  • Inspect the lane:  .claude/scripts/pwt-status.sh  /  .claude/scripts/plan-w-team-fleet-query.sh
  • Steer the worker:  stop it and resume by session UUID from inside its worktree with revised instructions (see docs/operations/ + memory: bg-worker steering) — never do its work in parallel
  • Queue follow-ups:  write a brief under .claude/state/ (allowed) for the worker/retro to drain
  • Lane truly wedged: escalate to the user; only the USER releases a lane (.claude/state/plan-w-team-lane-release-$1.json, written outside this session)

A supervisor that implements while its lane is live forks the work and corrupts the run (2026-08-09 cleanscale incident). This block IS your role contract — if a compaction dropped it, you have it back now. Operator kill switch: PLAN_W_TEAM_DISABLE_LANE_GUARD=1.
MSGEOF
    exit 2
}

__deny_worktree() {  # $1=slug $2=worker8 $3=worktree $4=target
    __audit "deny" "foreign-worktree-write" "$1" "$4"
    cat >&2 <<MSGEOF
⛔ LANE GUARD (PWT-LANE1): ${4} is inside the worktree of live /plan-w-team lane '$1', owned by worker ${2} — and this session (${SELF8:-unknown}) is not that worker. Two writers in one lane worktree corrupt the run. Steer the owning worker instead (stop + resume with instructions), or escalate to the user.
MSGEOF
    exit 2
}

__deny_artifact() {  # $1=slug $2=basename $3=why
    __audit "deny" "trusted-artifact-tamper" "$1" "$2"
    cat >&2 <<MSGEOF
⛔ LANE GUARD (PWT-LANE1): ${2} is a terminal-decision artifact for live lane '$1' — the Stop evaluator TRUSTS it, so only the pipeline may produce it (${3}). Hand-building it would mark the goal done without the work being done. If the run must end: escalate to the user; only the USER releases or halts a lane from outside the supervising session.
MSGEOF
    exit 2
}

# ── C4 (phase 2): the delegated-approver DECISION file is off-limits to the lane ──
# A <slug>.<gate>.decision.json is the GOVERNOR's delegated approval — written by an
# out-of-band governor, NEVER by the lane's own worker or bound supervisor. Either of
# them writing one would SELF-APPROVE a hard gate (push-ack / secret-scan-allow /
# scope-unlock-for-drift). The REQUEST file (<slug>.<gate>.request.json) is the run's
# to write; only the DECISION is denied. Basename-only (the approver dir is
# governor-configurable) — the family name is the discriminant; no legitimate file matches.
__deny_decision() {  # $1=slug $2=worker8
    __audit "deny" "self-approval-decision" "$1" "${FILE_ABS:-Bash: ${CMD:0:120}}"
    cat >&2 <<MSGEOF
⛔ LANE GUARD (C4 delegated approver): a <slug>.<gate>.decision.json for live lane '$1' is the GOVERNOR's delegated-approval artifact — written by the out-of-band governor, NEVER by the lane's own worker or bound supervisor. Writing your own decision would self-approve a hard gate (push-ack / secret-scan-allow / scope-unlock-for-drift). Denied. The request file (<slug>.<gate>.request.json) is yours to write; the DECISION is the governor's. If the gate must be answered from inside this lane, escalate to the user. Kill switch: PLAN_W_TEAM_DISABLE_LANE_GUARD=1.
MSGEOF
    exit 2
}
# Does THIS tool call WRITE a <slug>.<gate>.decision.json? File tools: the resolved
# FILE_ABS basename — this is the HARD wall (a Write/Edit naming the decision file is
# reliably denied). Bash: a redirect/tee target or a write-verb operand, gated behind a
# cheap `.decision.json` substring pre-filter — this is BEST-EFFORT, exactly like the
# guard's existing ship-verdict/test-green forgery classifiers (:822): it catches natural
# drift, not an adversary constructing the filename indirectly (a variable fragment, a
# python3/dd writer, a symlink). That is an accepted limitation — the file-tool path is the
# guarantee, and the operator gate-files a decision would produce are themselves not in the
# protected set, so the exempt worker can already touch them directly (see governor-contract.md
# phase-2 §"Self-approval — what the lane guard does and does not guarantee").
__decision_file_target() {  # $1=slug → 0 if this call targets a decision file for the slug
    local slug="$1" base tgt
    if [ "$TOOL" != "Bash" ]; then
        [ -n "${FILE_ABS:-}" ] || return 1
        base=$(basename "$FILE_ABS")
        case "$base" in "$slug".*.decision.json) return 0 ;; esac
        return 1
    fi
    case "${CMD:-}" in *".decision.json"*) : ;; *) return 1 ;; esac
    __ensure_cmd_scan
    # Targets are dequoted (tr, linear — B1) so `> "$D/<slug>".push.decision.json` resolves; the
    # slug may also sit in a brace list (`{<slug>,x}`) or a `${VAR:-<slug>}` default (B4).
    while IFS= read -r tgt; do
        [ -n "$tgt" ] || continue
        base=${tgt##*/}
        case "$base" in
            "$slug".*.decision.json|*[\{,]"$slug"[\},]*.decision.json|*:-"$slug"\}*.decision.json) return 0 ;;
        esac
    done <<EOF_DECTGT
$( { __redirect_targets; __tee_targets; } | LC_ALL=C tr -d "\"'\\\\")
EOF_DECTGT
    # confirm-8 anchor: the slug must be a whole path component prefix, `<slug>.<…>.decision.json`
    # (the file-tool branch's `"$slug".*.decision.json`). Unanchored, lane fix-6090 also matched
    # sibling fix-6090-2's and hotfix-6090's decision files — a C4 deny that binds even the worker.
    # Round 2: the verb is matched on CMD_SCAN WITH its quotes (B2) — stripping them first turned
    # the worker's own `grep 'cp' <slug>.push.decision.json` read into a `cp`. Quote chars and the
    # closers `}` `)` may sit between the slug and `.`; the slug may follow `:-` (a `${V:-<slug>}`
    # default) or open a brace list (`{<slug>,x}`); `g?` + `install` add gcp/gmv/grm/ginstall (B4).
    printf '%s' "$CMD_SCAN" | grep -qE "(^|[^[:alnum:]_-])g?(mv|cp|rm|touch|tee|install)[[:space:]]([^;|&]*([^[:alnum:]_.;|&-]|:-))?${slug}(,[^};|&[:space:]]*)?[\"'}),]*\.[^;|&[:space:]/]*\.decision\.json" && return 0
    return 1
}

# ── Bash command classifiers (bound-supervisor policy) ───────────────────────
# Separators before a command word: start, ;, &, |, $( or backtick. Deliberate
# scope: catch the natural drift shapes, not an adversary — the file-tool path
# is hard-denied and these close the common Bash long tail.
SEP='(^|[;&|]|\$\(|`)[[:space:]]*(sudo[[:space:]]+)?'
GIT_WRITE_RE="${SEP}git([[:space:]]+(-C|-c|--git-dir(=[^[:space:]]+)?|--work-tree(=[^[:space:]]+)?)([[:space:]]+[^[:space:]]+)?)*[[:space:]]+(add|commit|merge|rebase|cherry-pick|apply|am|revert|reset|restore|checkout|switch|stash|push|pull|mv|rm|clean|tag|worktree)([[:space:]]|$)"
BUILDER_RE="${SEP}(make|gradle|gradlew|\./gradlew|mvn|\./mvnw|xcodebuild|cargo|npm|npx|pnpm|yarn|bun|dotnet|tsc|jest|vitest|pytest|bats|flutter|fastlane)([[:space:]]|$)"
GO_BUILD_RE="${SEP}go[[:space:]]+(build|run|test|install|get|generate)([[:space:]]|$)"
SKILL_SUITE_RE="tests/skill/run(-scenarios)?\.sh"
MUTATOR_RE="${SEP}(rm|mv|cp|ln|truncate|dd|rsync|shred|unlink|install)([[:space:]]|$)"
# KI-6 (v2.25.0): copy-family verbs (cp/rsync/ln/install) only WRITE their
# DESTINATION operand — a source inside the repo is a READ. Destructive verbs
# (rm/mv/truncate/dd/shred/unlink) mutate EVERY operand (mv deletes its source).
# The mutator token-check uses this split to skip in-repo SOURCE operands of a
# PURE copy-family command; see the mutator block for the fail-safe conditions.
COPY_FAMILY_RE="${SEP}(cp|rsync|ln|install)([[:space:]]|$)"
DESTRUCTIVE_MUTATOR_RE="${SEP}(rm|mv|truncate|dd|shred|unlink)([[:space:]]|$)"
EXEC_MUTATOR_RE="-(exec|execdir)[[:space:]]+(rm|mv|cp)([[:space:]]|;)|xargs([[:space:]]+-[^[:space:]]+)*[[:space:]]+(rm|mv|cp)([[:space:]]|$)"
# ${SEP}-anchored like its siblings (D8, 2026-08-29): the literal words "sed -i"
# inside a quoted string argument are prose, not a command — only a real in-place
# edit at a command-word boundary classifies. Both alternatives sit INSIDE the
# group so the anchor applies to each.
INPLACE_RE="${SEP}(sed[[:space:]]+(-[a-zA-Z]*i|--in-place)|perl[[:space:]]+[^|;&]*-[a-zA-Z]*i([[:space:]]|$))"
# Trusted-artifact family variant (2.51.0; reworked LANEGUARD retest-8 / confirm-8): a
# COARSE gate only — "an editor word, then anything, then something shaped like an
# in-place option". It runs on CMD_DEQ (raw text minus quotes/backslashes, newlines as
# spaces) so it is a SUPERSET of every shape the precise per-segment scanner below
# (__inplace_family_segment) can flag: `LC_ALL=C sed`, `xargs perl`, `"-i"`, `/usr/bin/sed`,
# a `\`-continued option line. The 2.51.0 whole-command form it replaces false-denied a
# harmless READ whenever ANY sed/perl in the command carried an i-ish option token
# (`sed -i … other.txt && sed -n 1p <family>.log`, `perl -Mstrict -ne … <family>.log`,
# the `-fi` inside a `fix-it` slug); this gate only decides whether the scanner runs.
FAM_INPLACE_RE='(^|[^[:alnum:]_.-])(g?sed|perl[0-9.]*)[[:space:]].*(-[[:alnum:]]*[iI]|--i)'
# PWT_DISABLE_LANE_GUARD_HYGIENE=1 form (LANEGUARD round 2, B3): the 2.51.0 whole-token
# regex, verbatim — a COMMAND-WORD sed/perl followed by an option TOKEN that starts `-…i`
# or `--in-place`. Round 1 routed the switch through the coarse gate above instead, whose
# `.*-[[:alnum:]]*i` matches the `-fi` of `…-guard-fixture` / the `-verdi` of
# `…-ship-verdict-…` inside the family name itself — so under the switch EVERY
# `sed -n 1p <family>.json` read denied, a kill switch stricter than the code it disables.
# The caller ANDs this with an anchored family member (__fam_member_named), not HEAD's
# bare substring, so the confirm-8 sibling fix holds with the switch set too.
FAM_INPLACE_WT_RE="${SEP}(g?sed|perl)[[:space:]]+([^|;&]*[[:space:]])?(-[a-zA-Z]*i[^[:space:]]*|--in-place[^[:space:]]*)([[:space:]]|$)"
# Family anchor (confirm-8): a family prefix names a MEMBER only when the next byte is `.`
# (`.json` `.log` `.manifest`) or `--` (`--retest.*`) — or an expansion/glob metachar,
# optionally after one `-`, that could expand to a member (`${FAM}*`, `${FAM}-*`, `$EXT`,
# `{.log,.json}`). Slugs are kebab `[a-z0-9-]` without `--`, so lane fix-6090's prefix is
# no longer "named" by sibling lane fix-6090-2's `…-fix-6090-2.log`. ERE form for the
# write-verb greps; __fam_member_named is the same rule as a bash `case` (no spawn); the
# awk scanner's META is the same set. Round 2 (B4) adds the CLOSERS `}` `)` — the family
# name ends a `${VAR:-…/<family>}.log` default or a `$(… <family>).log` substitution and the
# member suffix follows it — plus `,` (a `{<family>,…}` brace list) and `\` (an escaped
# `\.log`). KEEP THE THREE IN SYNC: FAM_ANCHOR_ERE, the __fam_member_named case, awk META.
FAM_ANCHOR_ERE='(\.|--|-?[*?[{$`}),\\])'
__fam_member_named() {  # $1=ALREADY-DEQUOTED text $2=family prefix → 0 if text names a member
    # No stripping here (B1): callers pass the tr-built CMD_DEQ/CMD_DEQB or a dequoted target.
    case "$1" in
        *"$2".*|*"$2"--*|*"$2"[\*\?\[\{\$\`\}\),\\]*|*"$2"-[\*\?\[\{\$\`\}\),\\]*) return 0 ;;
    esac
    return 1
}
# B1 (LANEGUARD round 2): the dequoted forms of the command are built ONCE per hook call with
# LINEAR tools and shared by every live lane. Round 1 stripped with bash `${v//pat/}` — three
# substitutions per string, per lane, per family — and that is QUADRATIC in bash 3.2, the
# interpreter production runs (settings.json invokes the hook by its #!/bin/bash shebang, with
# no timeout): a 12 KB heredoc brief cost seconds on EVERY Bash call while two lanes were live.
# CMD_DEQ  = raw text minus " ' and \ , newlines → spaces (the round-1 CMD_DEQ, minus the cost)
# CMD_DEQB = the same with backslashes KEPT (a `\.log`/`\x2elog` still reads as anchored)
# Both come from the RAW command (heredoc bodies included), so the substring pre-filter stays a
# superset of every anchored check after it. LC_ALL=C: macOS tr rejects non-UTF-8 bytes otherwise.
# Fail CLOSED: an empty tr result on a non-empty command falls back to the raw text.
FAM_TEXT_READY=0
CMD_DEQ=""
CMD_DEQB=""
__ensure_fam_text() {
    [ "$FAM_TEXT_READY" = "1" ] && return 0
    __ensure_cmd_scan
    FAM_TEXT_READY=1
    # Nothing to strip (the common one-liner) → no spawn; the result is identical.
    case "$CMD" in
        *[\"\'\\]*|*$'\n'*) : ;;
        *) CMD_DEQB="$CMD"; CMD_DEQ="$CMD"; return 0 ;;
    esac
    CMD_DEQB=$(printf '%s' "$CMD" | LC_ALL=C tr -d "\"'" | LC_ALL=C tr '\n' ' ')
    CMD_DEQ=$(printf '%s' "$CMD_DEQB" | LC_ALL=C tr -d '\\')
    [ -n "$CMD_DEQB" ] || CMD_DEQB="$CMD"
    [ -n "$CMD_DEQ" ] || CMD_DEQ="$CMD_DEQB"
    FAM_TEXT_READY=1
}
# Deny-message label (round 2): name the member the command actually touched — `…-<slug>.log`,
# `…--retest.list` — not always `<family>.json`. $1 = the text that matched (a redirect target,
# the write-verb match, the scanner's offending word), $2 = family prefix. A closer right after
# the family (`${…/<family>}.log`, `$(… <family>).log`) is dropped so the label reads as the
# file. No anchored member found → `<family>.json` (the round-1 label).
__fam_member_label() {
    local lbl
    lbl=$(printf '%s' "$1" | LC_ALL=C tr -d "\"'\\\\" \
        | LC_ALL=C grep -oE "${2}${FAM_ANCHOR_ERE}[^[:space:];|&<>()'\"\`]*" 2>/dev/null | head -n 1)
    case "$lbl" in
        "$2"[\}\)\`]*) lbl="$2${lbl#"$2"?}" ;;
        "$2",*\}*) lbl="$2${lbl#*\}}" ;;
    esac
    [ -n "$lbl" ] || lbl="${2}.json"
    printf '%s' "$lbl"
}
# Precise in-place classifier (retest-8): ONE pass over the heredoc-stripped RAW text with
# real shell quote state, so the "which segment" correlation holds by construction — the
# masked text is not length-preserving (heredoc bodies, D-mode `\x` → `__`, awk-vs-bash
# character offsets under UTF-8), so mapping offsets between CMD_SCAN and CMD is unsound.
# Words are dequoted as the shell would (a quoted `;` is word text, never a boundary);
# segments end at unquoted `;` `&` `|` newline `(` `)` and at `$(`/backtick open and close
# (a substitution is its own segment; its text is also appended to the enclosing word so
# `sed -i x $(ls <family>.log)` still correlates). A segment DENIES only when its COMMAND
# word (past assignments, `!`/`{`/if/then/do/…, and prefix commands such as sudo/env/xargs/
# timeout with their option arguments; also the command after find -exec/-ok) is sed/gsed/
# perl, its options say in-place, AND one of its own words names a family member (anchor
# above) — or, when its command runs through `xargs`, an EARLIER segment of the same pipeline
# does (`find … -name '<family>*' | xargs sed -i …`, the bulk-edit idiom the 2.51.0 form also
# missed; it over-reaches only for `cat <family>.list | xargs sed -i`, which edits the files the
# list NAMES — a non-worker editing the lane's rerun set is worth a deny anyway).
# Options: sed — `i`/`I` in a short cluster before an argument-taking e/f (l takes only
# digits), or a long option that is a prefix of `--in-place`; perl — `i` in a cluster, `0`
# eats octal/hex digits, `l` eats octal digits, and M m I x d D F V e E C take the rest of
# the token (so `-Mstrict`, `-MList::Util=sum`, `-Ilib`, `-ne` are not in-place). Both keep
# scanning past operands (GNU sed permutes; perl reads switches after `-e CODE`) — the
# conservative direction. Prints `OK`, or `DENY <word>` naming the offending word (the deny
# message's label); the caller treats anything but OK (awk missing, a crash) as DENY.
# Round 2 (LANEGUARD): (a) VARIABLE CARRY — a simple assignment (`NAME=…`, or after
# export/local/readonly/declare/typeset) whose value names a member, or a `for NAME in …`
# whose list does, carries NAME forward; a LATER segment of the same command that references
# `$NAME`/`${NAME}` counts as naming the member (`f=<family>.log; sed -i '' 1d "$f"`,
# `for f in <family>*; do sed -i … "$f"; done`). A carried name is never un-carried by a
# later reassignment (conservative). (B4) a closed substitution re-enters its word as
# `$(…)`/`` `…` `` without trailing blanks, so `$(… <family>).log` meets the `)` anchor, and
# ANSI-C `$'…'` decodes `\xHH` / `\NNN` (a non-printable or `\u`/`\c` code becomes `$`, a
# metachar — conservative). Residual, same threat model as the rest of the guard (natural
# drift, not an adversary): a `bash -c`/eval string, a script fed on a heredoc, a
# `while read f` loop, a value assembled from pieces (`f=$D/$NAME$EXT`); the file-tool deny
# is the hard wall.
__inplace_family_segment() {  # $1=family prefix → prints `DENY <word>` or OK
    printf '%s\n' "${HDSTRIP:-$CMD}" | PWT_LG_FAM="$1" awk -v SQ="'" '
    function bname(w) { sub(/.*\//, "", w); return w }
    function addc(c) { CW[d] = CW[d] c; INW[d] = 1; if (d) FTX[d] = FTX[d] c }
    function endword() {
      if (INW[d]) { NW[d]++; W[d, NW[d]] = CW[d] }
      CW[d] = ""; INW[d] = 0; if (d) FTX[d] = FTX[d] " "
    }
    function endseg(p) { endword(); evalseg(d, p); NW[d] = 0 }
    function push(t) { d++; FT[d] = t; QS[d] = ""; PD[d] = 0; CW[d] = ""; INW[d] = 0; NW[d] = 0; FTX[d] = ""; PF[d] = 0; PFW[d] = "" }
    function pop(   s, t) {
      endseg(0); t = FTX[d]; sub(/[ ]+$/, "", t)
      s = (FT[d] == "$(") ? "$(" t ")" : "`" t "`"
      d--; CW[d] = CW[d] s; INW[d] = 1; FTX[d] = FTX[d] s
    }
    function fammatch(w,   p, c1, c2) {
      while ((p = index(w, FAM)) > 0) {
        c1 = substr(w, p + length(FAM), 1); c2 = substr(w, p + length(FAM) + 1, 1)
        if (c1 == "." || (c1 == "-" && c2 == "-")) return 1
        if (c1 != "" && index(META, c1)) return 1
        if (c1 == "-" && c2 != "" && index(META, c2)) return 1
        w = substr(w, p + 1)
      }
      return 0
    }
    function hasref(w, nm,   p, r, c, L) {   # w references $nm or ${nm… (whole name)
      L = length(nm); r = w
      while ((p = index(r, "$" nm)) > 0) {
        c = substr(r, p + 1 + L, 1); if (c !~ /[A-Za-z0-9_]/) return 1; r = substr(r, p + 1)
      }
      r = w
      while ((p = index(r, "${" nm)) > 0) {
        c = substr(r, p + 2 + L, 1); if (c !~ /[A-Za-z0-9_]/) return 1; r = substr(r, p + 1)
      }
      return 0
    }
    function subref(w, nm, val,   p, r, L, out) {   # w with whole-name $nm / ${nm} replaced by val
      out = ""; L = length(nm)
      while ((p = index(w, "$")) > 0) {
        out = out substr(w, 1, p - 1); r = substr(w, p)
        if (substr(r, 2, L + 2) == "{" nm "}") { out = out val; w = substr(r, L + 4); continue }
        if (substr(r, 2, L) == nm && substr(r, L + 2, 1) !~ /[A-Za-z0-9_]/) { out = out val; w = substr(r, L + 2); continue }
        out = out "$"; w = substr(r, 2)
      }
      return out w
    }
    function named(w,   nm, x) {   # sets NMW to the text that names the member
      if (fammatch(w)) { NMW = w; return 1 }
      if (NV) for (nm in VARS) {
        if (nm in VPRE) { x = subref(w, nm, FAM); if (x != w && fammatch(x)) { NMW = x; return 1 } }
        else if (hasref(w, nm)) { NMW = VARS[nm]; return 1 }
      }
      return 0
    }
    function endfam(v) { return length(v) >= length(FAM) && substr(v, length(v) - length(FAM) + 1) == FAM }
    function carry(dd, m,   k, j, w, nm, st, v) {
      k = 1; while (k <= m && (W[dd, k] in KW)) k++
      if (W[dd, k] == "for" && k + 2 <= m && W[dd, k + 2] == "in") {
        for (j = k + 3; j <= m; j++) if (named(W[dd, j])) { if (!(W[dd, k + 1] in VARS)) NV++; VARS[W[dd, k + 1]] = NMW; break }
        return
      }
      st = (W[dd, k] ~ /^(export|local|readonly|declare|typeset)$/); if (st) k++
      for (; k <= m; k++) {
        w = W[dd, k]
        if (w !~ /^[A-Za-z_][A-Za-z0-9_]*\+?=/) { if (st) continue; break }
        nm = w; sub(/\+?=.*/, "", nm); v = substr(w, index(w, "=") + 1)
        if (named(v)) { if (!(nm in VARS)) NV++; VARS[nm] = NMW; delete VPRE[nm] }
        else if (endfam(v) && !(nm in VARS)) { NV++; VARS[nm] = v; VPRE[nm] = 1 }   # the bare family PREFIX: `TG=$S/<family>; … "$TG.log"`
      }
    }
    function hexv(h,   k, v) { v = 0; h = tolower(h); for (k = 1; k <= length(h); k++) v = v * 16 + index("0123456789abcdef", substr(h, k, 1)) - 1; return v }
    function octv(o,   k, v) { v = 0; for (k = 1; k <= length(o); k++) v = v * 8 + substr(o, k, 1); return v }
    function chrv(v) { return (v in CHR) ? CHR[v] : "$" }
    function cmdpos(dd, s, e,   k, w, b, ao, dur) {
      k = s
      while (k <= e) {
        w = W[dd, k]; b = bname(w)
        if (w ~ /^[A-Za-z_][A-Za-z0-9_]*\+?=/ || (w in KW)) { k++; continue }
        if (w == "time") { k++; while (k <= e && W[dd, k] ~ /^-/) k++; continue }
        if (!(b in PFX)) return k
        if (b == "xargs") VIAX = 1
        ao = PFX[b]; dur = (b ~ /timeout$/); k++
        while (k <= e) {
          w = W[dd, k]
          if (w == "--") { k++; break }
          if (w ~ /^--/) {
            if (index(w, "=") == 0 && k < e && bname(W[dd, k + 1]) !~ EDRE && !(bname(W[dd, k + 1]) in PFX)) k++
            k++; continue
          }
          if (w ~ /^-./) { if (ao != "" && index(ao, substr(w, length(w), 1)) && k < e) k++; k++; continue }
          if (b == "env" && w ~ /^[A-Za-z_][A-Za-z0-9_]*=/) { k++; continue }
          if (dur) { dur = 0; k++; continue }
          break
        }
      }
      return 0
    }
    function sedscan(dd, s, e,   k, a, c, L, ch, nm, skip) {
      skip = 0
      for (k = s; k <= e; k++) {
        a = W[dd, k]
        if (skip) { skip = 0; continue }
        if (a == "--") return 0
        if (a ~ /^--./) {
          nm = substr(a, 3); if (index(nm, "=")) nm = substr(nm, 1, index(nm, "=") - 1)
          if (index("in-place", nm) == 1) return 1
          if (index(a, "=") == 0 && (index("expression", nm) == 1 || (length(nm) > 1 && index("file", nm) == 1) || index("line-length", nm) == 1)) skip = 1
          continue
        }
        if (a !~ /^-./) continue
        L = length(a)
        for (c = 2; c <= L; c++) {
          ch = substr(a, c, 1)
          if (ch == "i" || ch == "I") return 1
          if (ch == "e" || ch == "f") { if (c == L) skip = 1; break }
          if (ch == "l") {
            if (substr(a, c + 1) ~ /^[0-9]+$/) break
            if (c == L && k < e && W[dd, k + 1] ~ /^[0-9]+$/) skip = 1
          }
        }
      }
      return 0
    }
    function perlscan(dd, s, e,   k, a, c, L, ch, skip) {
      skip = 0
      for (k = s; k <= e; k++) {
        a = W[dd, k]
        if (skip) { skip = 0; continue }
        if (a == "--" || a == "-") return 0
        if (a !~ /^-[^-]/) continue
        L = length(a); c = 2
        while (c <= L) {
          ch = substr(a, c, 1)
          if (ch == "i") return 1
          if (ch == "0") {
            c++
            if (substr(a, c, 1) == "x") { c++; while (c <= L && substr(a, c, 1) ~ /[0-9A-Fa-f]/) c++ }
            else while (c <= L && substr(a, c, 1) ~ /[0-7]/) c++
            continue
          }
          if (ch == "l") { c++; while (c <= L && substr(a, c, 1) ~ /[0-7]/) c++; continue }
          if (index("MmIxdDFVeEC", ch)) { if (c == L && index("eEI", ch)) skip = 1; break }
          c++
        }
      }
      return 0
    }
    function edscan(dd, ci, e,   b, k, x, ci2) {
      b = bname(W[dd, ci])
      if (b ~ EDRE) return (b ~ /sed$/) ? sedscan(dd, ci + 1, e) : perlscan(dd, ci + 1, e)
      if (b != "find") return 0
      for (k = ci + 1; k <= e; k++) {
        if (W[dd, k] !~ /^-(exec|execdir|ok|okdir)$/) continue
        for (x = k + 1; x <= e && W[dd, x] != ";" && W[dd, x] != "+"; x++) ;
        ci2 = cmdpos(dd, k + 1, x - 1)
        if (ci2 > 0 && edscan(dd, ci2, x - 1)) return 1
        k = x
      }
      return 0
    }
    function evalseg(dd, p,   k, m, ci, fh, fw) {
      m = NW[dd]; fh = 0; fw = ""
      if (m == 0) return
      for (k = 1; k <= m; k++) if (named(W[dd, k])) { fh = 1; fw = NMW; break }
      if (fh || PF[dd]) {
        VIAX = 0; ci = cmdpos(dd, 1, m)
        if (ci > 0 && (fh || VIAX) && edscan(dd, ci, m) && !FOUND) { FOUND = 1; FW = fh ? fw : PFW[dd] }
      }
      carry(dd, m)
      if (p) { if (fh && !PF[dd]) PFW[dd] = fw; PF[dd] = (PF[dd] || fh) } else { PF[dd] = 0; PFW[dd] = "" }
    }
    { T = (NR == 1) ? $0 : T "\n" $0 }
    END {
      FAM = ENVIRON["PWT_LG_FAM"]; META = "*?[{$`}),"; EDRE = "^(g?sed|perl[0-9.]*)$"
      if (FAM == "") { print "DENY"; exit }
      for (k = 32; k < 127; k++) CHR[k] = sprintf("%c", k)
      split("! { } if then else elif do while until", kw, " "); for (k in kw) KW[kw[k]] = 1
      PFX["sudo"] = "CDghpRrtTUu"; PFX["doas"] = "uC"; PFX["env"] = "uCPS"; PFX["command"] = ""
      PFX["exec"] = "a"; PFX["nohup"] = ""; PFX["nice"] = "n"; PFX["timeout"] = "sk"
      PFX["gtimeout"] = "sk"; PFX["xargs"] = "IJLnPsEdaRS"; PFX["stdbuf"] = "ioe"; PFX["caffeinate"] = "tw"
      d = 0; FT[0] = ""; QS[0] = ""; PD[0] = 0; CW[0] = ""; INW[0] = 0; NW[0] = 0; FTX[0] = ""; PF[0] = 0; PFW[0] = ""
      NV = 0; FOUND = 0; FW = ""
      n = length(T); i = 1
      while (i <= n) {
        c = substr(T, i, 1); nx = substr(T, i + 1, 1)
        if (QS[d] == "S") {   # a single-quoted run is inert: copy it in one chunk (linear on long payloads)
          j = index(substr(T, i), SQ)
          if (j == 0) { addc(substr(T, i)); i = n + 1 } else { if (j > 1) addc(substr(T, i, j - 1)); QS[d] = ""; i += j }
          continue
        }
        if (QS[d] == "A") {
          if (c == "\\") {   # ANSI-C escapes: decode \xHH and \NNN so $'"'"'…\x2elog'"'"' still anchors
            if (nx == "x" && substr(T, i + 2, 1) ~ /[0-9A-Fa-f]/) {
              j = i + 2; h = ""; while (length(h) < 2 && substr(T, j, 1) ~ /[0-9A-Fa-f]/) { h = h substr(T, j, 1); j++ }
              addc(chrv(hexv(h))); i = j; continue
            }
            if (nx ~ /^[0-7]$/) {
              j = i + 1; h = ""; while (length(h) < 3 && substr(T, j, 1) ~ /[0-7]/) { h = h substr(T, j, 1); j++ }
              addc(chrv(octv(h))); i = j; continue
            }
            if (nx == "u" || nx == "U" || nx == "c") { addc("$"); i += 2; continue }
            addc(nx); i += 2; continue
          }
          if (c == SQ) QS[d] = ""; else addc(c)
          i++; continue
        }
        if (QS[d] == "D") {
          if (c == "\"") { QS[d] = ""; i++; continue }
          if (c == "\\") { if (nx != "\n") addc(nx); i += 2; continue }
          if (c == "$" && nx == "(") { push("$("); i += 2; continue }
          if (c == "`") { if (FT[d] == "`") pop(); else push("`"); i++; continue }
          addc(c); i++; continue
        }
        if (c == "\\") { if (nx != "\n") addc(nx); i += 2; continue }
        if (c == SQ) { QS[d] = "S"; INW[d] = 1; i++; continue }
        if (c == "\"") { QS[d] = "D"; INW[d] = 1; i++; continue }
        if (c == "$" && nx == SQ) { QS[d] = "A"; INW[d] = 1; i += 2; continue }
        if (c == "$" && nx == "(") { push("$("); i += 2; continue }
        if (c == "$" && nx == "{") {
          j = i + 2; lvl = 1
          while (j <= n && lvl > 0) { cc = substr(T, j, 1); if (cc == "{") lvl++; else if (cc == "}") lvl--; j++ }
          for (k = i; k < j; k++) addc(substr(T, k, 1))
          i = j; continue
        }
        if (c == "`") { if (FT[d] == "`") pop(); else push("`"); i++; continue }
        if (c == "#" && !INW[d]) { while (i <= n && substr(T, i, 1) != "\n") i++; continue }
        if (c == " " || c == "\t") { endword(); i++; continue }
        if (c == ">" || c == "<" || (c == "&" && nx == ">")) {
          endword(); i++
          while (i <= n && index("<>&|", substr(T, i, 1))) i++
          continue
        }
        if (c == "|") {
          if (nx == "|") { endseg(0); i += 2 } else { endseg(1); i += (nx == "&") ? 2 : 1 }
          continue
        }
        if (c == "\n" || c == ";" || c == "&") { endseg(0); i++; continue }
        if (c == "(") { PD[d]++; endseg(0); i++; continue }
        if (c == ")") {
          if (PD[d] > 0) { PD[d]--; endseg(0) } else if (FT[d] == "$(") pop(); else endseg(0)
          i++; continue
        }
        addc(c); i++
      }
      while (d > 0) pop()
      endseg(0)
      if (FOUND) { gsub(/[\n\t]/, " ", FW); print "DENY " FW } else print "OK"
    }' 2>/dev/null
}
# Host hygiene (F4c): process control is not lane work. These were never denied
# — the incident's `pkill` was allowed — so this class adds EVIDENCE, not
# authority: a supervisor that kills its own lane is now provable after the fact.
HYGIENE_PROC_RE="${SEP}(kill|pkill|killall|renice)([[:space:]]|$)"

# Read-only LISTING forms of write-subcommands are inspection, not writes.
# GIT_WRITE_RE lists `tag`/`worktree`/`stash` as write subcommands with no
# exemption, so `git tag -l`, `git worktree list`, `git stash list|show` — all
# read-only — were denied (2026-08-19 tag remediation; D7/D9 2026-08-29 for the
# worktree/stash forms, incl. a backtick-quoted `` `git worktree list` `` inside
# prose). Strip only the read-only FORM from a WORKING COPY before the write
# test, so `git tag v1` / `git worktree add …` still deny, and
# `git worktree list && git commit -m x` still denies on the surviving commit.
__git_write_text() {
    # Single source for the read-only-listing strip is __strip_readonly_git
    # (defined with the git-write resolver); this keeps the tag/worktree/stash
    # list patterns from drifting between two copies.
    printf '%s' "$CMD_SCAN" | __strip_readonly_git
}

# A redirect / tee / mutator target is ALLOWED when it provably lands outside
# the main checkout (tmp, /dev, $HOME dotfiles, other repos) or inside
# .claude/state/ minus the trusted-artifact families. Only PROVABLE repo
# targets deny — variables and unresolvable tokens pass (fail-open; the
# file-tool layer is the hard wall).
__protected_basename() {  # $1=basename $2=slug → 0 if trusted family for slug
    case "$1" in
        "plan-w-team-ship-verdict-$2.json"|"plan-w-team-test-green-$2.json"|\
        "plan-w-team-test-green-$2--retest.json"|"plan-w-team-test-green-$2.manifest"|\
        "plan-w-team-test-green-$2--retest.manifest"|"plan-w-team-test-green-$2.log"|\
        "plan-w-team-test-green-$2--retest.log"|"plan-w-team-test-green-$2--retest.list"|\
        "plan-w-team-test-green-$2.subject-manifest"|"plan-w-team-test-green-$2--retest.subject-manifest"|\
        "plan-w-team-goal-$2.json"|"plan-w-team-lane-release-$2.json"|\
        "pwt-lane-alive-memo-$2.json") return 0 ;;
        # The confirmed-dead memo AUTHORISES a lane release (this hook reads it, and exit 1 releases
        # the binding). A non-owner Bash write could forge {"verdict":1,…} to drop the guard on a
        # live lane, so it is protected exactly like the evaluator-trusted artifacts. The hook writes
        # the memo IN-PROCESS (not via a tool call), so it is unaffected by its own PreToolUse gate.
    esac
    return 1
}
__bash_target_denied() {  # $1=raw target token  $2=slug → 0 if deny
    local t="$1" abs base
    # Strip simple quoting; a token still carrying $ or backticks — or a leading
    # `~` the guard cannot expand (the shell would, to $HOME, outside the repo) —
    # is unresolvable → allow (no positive evidence). Without the `~` arm a
    # `>> ~/…/file` redirect resolves against CWD, lands under the repo, and
    # falsely denies (D9, 2026-08-29).
    t="${t%\"}"; t="${t#\"}"; t="${t%\'}"; t="${t#\'}"
    case "$t" in ''|*'$'*|*'`'*|'~'*) return 1 ;; esac
    case "$t" in /dev/*) return 1 ;; esac
    abs=$(__abs_path "$t")
    [ -n "$abs" ] || return 1
    # A worktree mounted OUTSIDE the main checkout is still the repo. Checked
    # before the MAIN_ROOT prefix test so "outside the repo" can never be read
    # as "outside MAIN_ROOT" alone.
    if [ "$HYGIENE" = "1" ] && __under_any_worktree "$abs"; then return 0; fi
    __under "$abs" "$MAIN_ROOT" || return 1
    if __under "$abs" "$STATE_DIR"; then
        base=$(basename "$abs")
        __protected_basename "$base" "$2" && return 0
        # The operator allowance valve is operator-written (from OUTSIDE the bound
        # session, like the release valve); a bound supervisor writing its own
        # would self-authorize the fail-closed branch (a relative in-repo `sed -i`
        # would then pass). This function runs only for the bound supervisor, so
        # denying here never blocks the operator.
        case "$base" in plan-w-team-lane-guard-allow-*.json) return 0 ;; esac
        return 1
    fi
    return 0
}
# Extract redirect targets (skips fd-dups like 2>&1 — & can't start a target).
# Both read CMD_SCAN, not CMD: a `>` inside quotes has already been blanked, so
# an awk/grep body can no longer masquerade as a redirect.
__redirect_targets() {
    printf '%s' "$CMD_SCAN" | grep -oE '[0-9]*>>?[[:space:]]*[^[:space:]<>;&|)]+' 2>/dev/null \
        | sed -E 's/^[0-9]*>>?[[:space:]]*//'
}
__tee_targets() {
    printf '%s' "$CMD_SCAN" | grep -oE 'tee[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*[^;&|<>]+' 2>/dev/null \
        | sed -E 's/^tee[[:space:]]+//; s/-[a-zA-Z]+[[:space:]]+//g'
}

# ── Resolved-target decision for git-write (FAIL-CLOSED; 2.15.0 review fix) ──
# git resolves its git-dir and work-tree INDEPENDENTLY. `-C <p>` and a literal
# `cd <p>` move BOTH (git runs as if started in <p>); `--git-dir=<g>` moves ONLY
# the git-dir (the work-tree then defaults to CWD); `--work-tree=<w>` moves ONLY
# the work-tree (the git-dir is still DISCOVERED from CWD). So a lone foreign
# `--work-tree` on `git push` — whose refs land in the CWD-discovered (lane)
# git-dir — is NOT a foreign write, and neither is a lone foreign `--git-dir` on
# `git checkout`, whose files land in the CWD (lane) work-tree. The pre-review
# code treated ANY foreign anchor as whole-command proof, which let a bound
# supervisor push/reset the lane by attaching a throwaway anchor. Fix: walk the
# command's segments tracking the cd-established base, and require BOTH the
# effective git-dir AND the effective work-tree of EVERY git-write to be foreign.
__strip_readonly_git() {   # stdin → read-only listing forms neutralized (raw under HYGIENE=0)
    if [ "$HYGIENE" = "0" ]; then cat; return 0; fi
    sed -E \
        -e 's/git[[:space:]]+tag[[:space:]]+(-[a-zA-Z]*l[a-zA-Z]*|--list)/git-tag-list-readonly/g' \
        -e 's/git[[:space:]]+worktree[[:space:]]+list/git-worktree-list-readonly/g' \
        -e 's/git[[:space:]]+stash[[:space:]]+(list|show)/git-stash-list-readonly/g' 2>/dev/null
}
__git_write_targets_foreign() {   # 0 = ALLOW, 1 = DENY
    local seg trimmed cur_base="$CWD" cval gdval wtval inv_base gitdir worktree
    while IFS= read -r seg; do
        trimmed=$(printf '%s' "$seg" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
        [ -n "$trimmed" ] || continue
        # A `cd` segment re-bases every later command. Bare `cd` (→ $HOME) and a
        # variable/relative target are unresolvable → force the base unresolvable
        # so a later git-write anchored on it denies (fail-closed).
        case "$trimmed" in
            cd|cd[[:space:]]*)
                cval=$(printf '%s' "$trimmed" | sed -E 's/^cd[[:space:]]*//; s/[[:space:]].*//')
                if [ -n "$cval" ]; then cur_base="$cval"; else cur_base='~unresolvable~'; fi
                continue
                ;;
        esac
        # Is this segment a git-write? (read-only listing forms neutralized first.)
        printf '%s' "$trimmed" | __strip_readonly_git | grep -qE "$GIT_WRITE_RE" || continue
        cval=$(printf '%s' "$trimmed" | grep -oE '(^|[[:space:]])-C[[:space:]]+[^[:space:]]+' 2>/dev/null | head -1 | sed -E 's/.*-C[[:space:]]+//')
        gdval=$(printf '%s' "$trimmed" | grep -oE '[-][-]git-dir[= ][^[:space:]]+' 2>/dev/null | head -1 | sed -E 's/^--git-dir[= ]//')
        wtval=$(printf '%s' "$trimmed" | grep -oE '[-][-]work-tree[= ][^[:space:]]+' 2>/dev/null | head -1 | sed -E 's/^--work-tree[= ]//')
        # -C (and a preceding cd) set the BASE that git-dir/work-tree default to;
        # --git-dir/--work-tree override ONLY their own location. Require both.
        if [ -n "$cval" ]; then inv_base="$cval"; else inv_base="$cur_base"; fi
        gitdir="${gdval:-$inv_base}"
        worktree="${wtval:-$inv_base}"
        __write_target_ok "$gitdir" || return 1
        __write_target_ok "$worktree" || return 1
    done <<EOF_SEGS
$(printf '%s' "$CMD_SCAN" | awk '{ gsub(/&&|\|\|/, "\n"); gsub(/[;&|]/, "\n"); print }')
EOF_SEGS
    return 0
}

# Quote-aware tokenizer over the MASKED command. Emits one line per token whose
# FIRST char is Q (the token was quoted) or P (plain), then the unquoted token.
# Quoting is what tells a sed/perl SCRIPT (quoted, e.g. 's/a b/c/') from a
# relative-path OPERAND (plain, e.g. src/app.ts), and it keeps a quoted script
# with internal spaces as ONE token. SQ is passed via -v so no literal single
# quote appears in the awk program.
__masked_tokens() {
    printf '%s' "$CMD_SCAN" | awk -v SQ="'" '
    {
      n = length($0); i = 1
      while (i <= n) {
        c = substr($0, i, 1)
        if (c == " " || c == "\t") { i++; continue }
        tok = ""; q = "P"
        while (i <= n) {
          c = substr($0, i, 1)
          if (c == " " || c == "\t") break
          if (c == SQ)  { q = "Q"; i++; while (i <= n) { c = substr($0, i, 1); i++; if (c == SQ) break; tok = tok c }; continue }
          if (c == "\"") { q = "Q"; i++; while (i <= n) { c = substr($0, i, 1); i++; if (c == "\"") break; tok = tok c }; continue }
          tok = tok c; i++
        }
        print q tok
      }
    }' 2>/dev/null
}
# 0 = ALLOW (every in-place file operand provably foreign), 1 = DENY. Fail-closed:
# no absolute operand, a plain relative/glob/var operand, or an in-repo/unresolvable
# absolute operand → DENY. A quoted non-absolute token is the sed/perl script → ignored.
__inplace_targets_foreign() {
    local line q tok had_abs=0
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        q="${line%"${line#?}"}"; tok="${line#?}"
        case "$tok" in
            /*) had_abs=1; __write_target_ok "$tok" || return 1 ;;
            -*) : ;;
            *)
                if [ "$q" = "P" ]; then
                    case "$tok" in
                        */*|*'*'*|*'?'*|*'['*|'~'*|*'$'*) return 1 ;;
                    esac
                fi
                ;;
        esac
    done <<EOF_TOK
$(__masked_tokens)
EOF_TOK
    [ "$had_abs" = "1" ] && return 0
    return 1
}

# ── Confirmed-dead lane release helper (BRIEF §4.4, Surprise 4) ──────────────
# The ONE liveness truth, memoized per goal-mtime + TTL (this hook runs on every Bash call).
# Echoes 0 alive / 1 confirmed-dead / 2 cannot-determine. Defaults to 2 (HOLD) on ANY error, so
# a broken/absent predicate can NEVER release a lane. Seam: PWT_LANE_ALIVE_BIN.
__lg_mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0; }
__lg_lane_alive_verdict() {   # $1=slug $2=goal_file → 0/1/2
    local slug="$1" gf="$2"
    local bin="${PWT_LANE_ALIVE_BIN:-$MAIN_ROOT/.claude/scripts/pwt-lane-alive.sh}"
    [ -x "$bin" ] || { echo 2; return 0; }
    local memo="$STATE_DIR/pwt-lane-alive-memo-${slug}.json"
    local gm now ttl="${PWT_LANE_ALIVE_MEMO_TTL_S:-30}" m_gm m_ts m_v
    gm=$(__lg_mtime "$gf"); now=$(date +%s 2>/dev/null || echo 0)
    if [ -f "$memo" ]; then
        m_gm=$(jq -r '.goal_mtime // ""' "$memo" 2>/dev/null || echo "")
        m_ts=$(jq -r '.ts // 0' "$memo" 2>/dev/null || echo 0)
        m_v=$(jq -r '.verdict // ""' "$memo" 2>/dev/null || echo "")
        if [ "$m_gm" = "$gm" ] && [ -n "$m_v" ] && [ $((now - m_ts)) -lt "$ttl" ] 2>/dev/null; then
            echo "$m_v"; return 0
        fi
    fi
    "$bin" "$slug" >/dev/null 2>&1; local v=$?
    case "$v" in 0|1|2) : ;; *) v=2 ;; esac
    jq -cn --arg gm "$gm" --argjson ts "$now" --argjson v "$v" \
       '{goal_mtime:$gm, ts:$ts, verdict:$v}' > "$memo.tmp.$$" 2>/dev/null && mv "$memo.tmp.$$" "$memo" 2>/dev/null || true
    echo "$v"
}

# ── Evaluate each live lane ──────────────────────────────────────────────────
shopt -s nullglob
for GF in "$STATE_DIR"/plan-w-team-goal-*.json; do
    jq -e . "$GF" >/dev/null 2>&1 || continue
    [ -n "$(jq -r '.terminal_state // ""' "$GF" 2>/dev/null)" ] && continue

    # Stale lanes never restrict anyone (mirrors evaluator PWT-STALE-SKIP; a
    # dead worker's lane is auto-released on the next Stop via DEAD propagation,
    # and this age gate is the backstop when that never fires).
    MTIME=$(stat -f %m "$GF" 2>/dev/null || stat -c %Y "$GF" 2>/dev/null || echo "")
    if [ -n "$MTIME" ] && [ "$MTIME" -gt 0 ] 2>/dev/null; then
        AGE=$(( $(date -u +%s) - MTIME ))
        [ "$AGE" -ge $(( ${PWT_GOAL_STALE_HOURS:-24} * 3600 )) ] 2>/dev/null && continue
    fi

    SLUG=$(jq -r '.slug // ""' "$GF" 2>/dev/null)
    [ -n "$SLUG" ] || continue
    [ -f "$STATE_DIR/plan-w-team-lane-release-${SLUG}.json" ] && continue

    WSID=$(jq -r '.worker_sid // ""' "$GF" 2>/dev/null | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
    case "$WSID" in
        [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) : ;;
        *) continue ;;   # no provable worker → no lane split → guard N/A
    esac
    W8="${WSID:0:8}"

    # The owning worker is never restricted by its own lane — EXCEPT it may not write
    # its own gate DECISION (C4 self-approval). Checked BEFORE the exemption so the
    # exemption cannot bypass it; the worker still writes the REQUEST file freely.
    if [ -n "$SELF8" ] && [ "$SELF8" = "$W8" ]; then
        __decision_file_target "$SLUG" && __deny_decision "$SLUG" "$W8"
        continue
    fi

    # Confirmed-dead lane release (BRIEF §4.4): a worker the ONE liveness truth confirms dead
    # (exit 1 — ESRCH + no pgrep) no longer binds anyone; exit 0 (alive) / 2 (cannot-determine)
    # HOLDS the binding (fail-CLOSED — never release on uncertainty). Kill switch below.
    if [ "${PWT_DISABLE_LANE_ALIVE_RELEASE:-0}" != "1" ]; then
        [ "$(__lg_lane_alive_verdict "$SLUG" "$GF")" = "1" ] && continue
    fi

    # SID-less harness (old Claude Code): we cannot prove this session is NOT
    # the worker, so per-session rules would misfire on the worker itself.
    # Only the env-flagged bg supervisor (which pwt-goal.sh guarantees is
    # never a worker) keeps its policy; everything else fails open.
    if [ -z "$SELF8" ] && [ "${PLAN_W_TEAM_SUPERVISOR_SESSION:-0}" != "1" ]; then
        continue
    fi

    # Lane worktree (manifest is authoritative; always in the main checkout).
    WT=$(jq -r '.worktree_path // ""' "$STATE_DIR/plan-w-team-manifest-${SLUG}.json" 2>/dev/null)
    # Same canonicalization as MAIN_ROOT — prefix tests need one spelling.
    if [ -n "$WT" ] && [ -d "$WT" ]; then
        WT=$(cd "$WT" 2>/dev/null && pwd) || WT=""
    fi
    [ "$WT" = "$MAIN_ROOT" ] && WT=""   # main-checkout runs have no separate zone

    # Is THIS session bound to the lane as its supervisor?
    BOUND=0
    [ "${PLAN_W_TEAM_SUPERVISOR_SESSION:-0}" = "1" ] && BOUND=1
    if [ "$BOUND" = "0" ] && [ -n "$SELF8" ]; then
        SSID=$(jq -r '.supervisor_sid // ""' "$GF" 2>/dev/null | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
        [ -n "$SSID" ] && [ "${SSID:0:8}" = "$SELF8" ] && BOUND=1
    fi
    if [ "$BOUND" = "0" ] && [ -n "$SELF8" ] && [ -f "$STATE_DIR/pwt-launches.jsonl" ]; then
        if jq -r --arg w "$W8" 'select(((.sid // "") | ascii_downcase | startswith($w))) | (.parent_sid // "")' \
             "$STATE_DIR/pwt-launches.jsonl" 2>/dev/null \
             | tr '[:upper:]' '[:lower:]' | cut -c1-8 | grep -qFx "$SELF8"; then
            BOUND=1
        fi
    fi

    # C4: a BOUND supervisor may not write a gate DECISION either (self-approval).
    # An out-of-band GOVERNOR (neither worker nor bound → BOUND=0) reaches here and is
    # NOT denied — that is exactly the delegated-approval path the contract enables.
    if [ "$BOUND" = "1" ] && __decision_file_target "$SLUG"; then
        __deny_decision "$SLUG" "$W8"
    fi

    if [ "$TOOL" != "Bash" ]; then
        [ -n "$FILE_ABS" ] || continue
        BASE=$(basename "$FILE_ABS")
        # (1) Any non-worker session: hands off the lane's worktree.
        if [ -n "$WT" ] && __under "$FILE_ABS" "$WT"; then
            __deny_worktree "$SLUG" "$W8" "$WT" "$FILE_ABS"
        fi
        # (2) Any non-worker session: never forge the evaluator's evidence.
        case "$BASE" in
            "plan-w-team-ship-verdict-${SLUG}.json")
                __deny_artifact "$SLUG" "$BASE" "Step 6 writes it only after every §6 ENFORCING gate passes" ;;
            "plan-w-team-test-green-${SLUG}.json")
                __deny_artifact "$SLUG" "$BASE" "plan-w-team-test-green.sh writes it from a real suite run" ;;
            # 2.51.0: the retest verdict the commit gate accepts, the manifests that
            # prove what each verdict's tree_digest hashed, and the suite logs + rerun
            # list — the gate rebuilds a retest's rerun set from the BASE LOG's
            # SUITE_FAILED rows and reads RETEST_RAN from the retest log, so an edited
            # log is a forged verdict (docs/operations/test-green-retest.md). Both logs
            # are also sha256-bound in their json, which is the hard wall; this is the
            # lane-scoped tool-layer wall in front of it. The `.subject-manifest` pair
            # (2.53.0: the frozen subject list each verdict's subject_digest is
            # recomputed over) belongs to the same family — same forgery, same wall.
            "plan-w-team-test-green-${SLUG}--retest.json"|"plan-w-team-test-green-${SLUG}.manifest"|\
            "plan-w-team-test-green-${SLUG}--retest.manifest"|"plan-w-team-test-green-${SLUG}.log"|\
            "plan-w-team-test-green-${SLUG}--retest.log"|"plan-w-team-test-green-${SLUG}--retest.list"|\
            "plan-w-team-test-green-${SLUG}.subject-manifest"|"plan-w-team-test-green-${SLUG}--retest.subject-manifest")
                __deny_artifact "$SLUG" "$BASE" "plan-w-team-test-green.sh writes it from a real suite run" ;;
        esac
        # (3) Bound supervisor: goal-state + release valve are also off-limits,
        #     and so is the rest of the repo outside .claude/state/.
        if [ "$BOUND" = "1" ]; then
            case "$BASE" in
                "plan-w-team-goal-${SLUG}.json")
                    __deny_artifact "$SLUG" "$BASE" "the Stop evaluator owns terminal_state; a supervisor writing it is self-termination spoofing" ;;
                "plan-w-team-lane-release-${SLUG}.json")
                    __deny_artifact "$SLUG" "$BASE" "the release valve is USER-only; a supervisor releasing its own lane defeats the guard" ;;
                plan-w-team-lane-guard-allow-*.json)
                    __deny_artifact "$SLUG" "$BASE" "the operator allowance valve is written from OUTSIDE the bound session; a supervisor writing its own would self-authorize the guard's fail-closed branch" ;;
            esac
            if __under "$FILE_ABS" "$STATE_DIR"; then
                : # .claude/state/ bookkeeping stays allowed
            elif [ "$HYGIENE" = "1" ]; then
                # Share the resolved-target predicate with the Bash classes so the
                # SAME file cannot be Edit-allowed but git/sed-denied. A symlink
                # whose real target is in-repo denies (realpath); a provably
                # foreign file is allowed + audited.
                FILE_REAL=$(__realpath_target "$FILE_ABS"); [ -n "$FILE_REAL" ] || FILE_REAL="$FILE_ABS"
                if __path_in_repo "$FILE_REAL"; then
                    __deny_role "$SLUG" "$W8" "$WT" "$FILE_ABS"
                else
                    __audit "allow" "outside-repo-edit" "$SLUG" "$FILE_ABS" \
                        "file resolves outside the lane repo and all worktrees"
                fi
            elif __under "$FILE_ABS" "$MAIN_ROOT"; then
                __deny_role "$SLUG" "$W8" "$WT" "$FILE_ABS"
            fi
        fi
    else
        # A live lane applies and the tool is Bash — NOW the masking is worth its
        # spawn. Memoized, so a second live lane in the same call is free.
        __ensure_cmd_scan
        # (2') Any non-worker session: Bash that WRITES a trusted artifact for
        # this lane is forgery. Reading it (cat/jq, even with 2>/dev/null fd
        # redirects) stays legal — only a redirect TARGET naming the family, or
        # a write-verb followed by it, denies.
        # confirm-8: every family test below is ANCHORED (FAM_ANCHOR_ERE) — the bare
        # substring made lane fix-6090 "own" sibling lane fix-6090-2's files.
        # Round 2 (B1): the dequoted text is built ONCE (tr, linear) for every lane; a
        # command whose dequoted text does not even CONTAIN a family prefix skips the
        # block on a bash `case` — a plain substring, a superset of every anchored test
        # below, so the pre-filter can only admit, never excuse.
        __ensure_fam_text
        for FAM in "plan-w-team-ship-verdict-${SLUG}" "plan-w-team-test-green-${SLUG}"; do
            case "$CMD_DEQ" in *"$FAM"*) : ;; *) continue ;; esac
            FORGE=0; FHIT=""
            while IFS= read -r TGT; do
                [ -n "$TGT" ] || continue
                __fam_member_named "$TGT" "$FAM" && { FORGE=1; FHIT="$TGT"; break; }
            done <<EOF_FAMR
$(__redirect_targets | LC_ALL=C tr -d "\"'")
EOF_FAMR
            # The verb needs a left word boundary: unanchored, `grep confirm <family>.log`
            # and `transform …` read as `rm`. Round 2 (B2): matched on CMD_SCAN WITH its
            # quotes — round 1 stripped them first, which turned the READ `grep -c 'rm'
            # <family>.log` / `jq '.tee' <family>.json` into an `rm`/`tee`. Instead quote chars
            # (and a `\`) may sit between the family and its anchor, so `cp x "$D/<family>".json`
            # still meets it; `g?` keeps GNU coreutils' gcp/gmv/grm.
            if [ "$FORGE" = "0" ]; then
                FHIT=$(printf '%s' "$CMD_SCAN" | LC_ALL=C grep -oE "(^|[^[:alnum:]_-])g?(mv|cp|rm|touch|tee)[[:space:]][^;|&]*${FAM}[\"'\\\\]*${FAM_ANCHOR_ERE}[^[:space:];|&<>]*" 2>/dev/null | head -n 1)
                [ -n "$FHIT" ] && FORGE=1
            fi
            # 2.51.0: an in-place editor (`sed -i`, `perl -pi`) rewrites a family file
            # without any verb or redirect above — the retest-gate forgery was exactly
            # `sed -i` deleting a SUITE_FAILED row from the base log. retest-8: the verdict
            # is PER SEGMENT — the one segment that runs the in-place editor must itself
            # name a family member (__inplace_family_segment, raw text, real quote state:
            # a quoted "sed -i" is prose, a quoted path is still a path). The coarse
            # FAM_INPLACE_RE only decides whether that scanner runs; scanner failure → DENY.
            # Under PWT_DISABLE_LANE_GUARD_HYGIENE=1 (the guard's "no text analysis" switch)
            # the scanner is skipped and the 2.51.0 WHOLE-TOKEN form decides (round 2, B3):
            # a command-word sed/perl carrying an in-place option token, ANDed with an
            # anchored family member anywhere in the command — the strict 2.51.0 posture,
            # never a looser one, and never stricter than it either (round 1's coarse
            # `.*-…i` matched the family NAME, so the switch denied every `sed -n 1p` read).
            if [ "$FORGE" = "0" ]; then
                if [ "$HYGIENE" = "1" ]; then
                    if printf '%s' "$CMD_DEQ" | grep -qE "$FAM_INPLACE_RE"; then
                        FSEG=$(__inplace_family_segment "$FAM")
                        case "$FSEG" in OK) : ;; *) FORGE=1; FHIT="${FSEG#DENY}" ;; esac
                    fi
                # "Named" here also admits the BARE prefix at a word end (`TG=$S/<family>;
                # sed -i … "$TG.log"` — HEAD's substring caught it; there is no scanner
                # under the switch to carry the variable). A sibling's `<family>-2` is
                # still not named: `-` then a digit is neither an anchor nor a word end.
                elif printf '%s' "$CMD" | grep -qE "$FAM_INPLACE_WT_RE" \
                     && { __fam_member_named "$CMD_DEQ" "$FAM" || __fam_member_named "$CMD_DEQB" "$FAM" \
                          || case "$CMD_DEQ " in *"$FAM"[\ \;\&\|]*) true ;; *) false ;; esac; }; then
                    FORGE=1; FHIT="$CMD_DEQ"
                fi
            fi
            [ "$FORGE" = "1" ] && __deny_artifact "$SLUG" "$(__fam_member_label "$FHIT" "$FAM")" "only the pipeline's own gates may produce it"
        done
        # (1') Any non-worker session: mutating Bash aimed into the lane's
        # worktree — a git-write/mutator naming its literal path, or a redirect
        # whose target lands inside it. Reads (tail/cat with fd redirects) pass.
        if [ -n "$WT" ]; then
            if printf '%s' "$CMD_SCAN" | grep -qF "$WT" \
               && printf '%s' "$(__git_write_text)" | grep -qE "$GIT_WRITE_RE|$MUTATOR_RE"; then
                __deny_worktree "$SLUG" "$W8" "$WT" "Bash: ${CMD:0:120}"
            fi
            while IFS= read -r TGT; do
                [ -n "$TGT" ] || continue
                T_ABS=$(__abs_path "$TGT")
                if [ -n "$T_ABS" ] && __under "$T_ABS" "$WT"; then
                    __deny_worktree "$SLUG" "$W8" "$WT" "Bash redirect → $TGT"
                fi
            done <<EOF_WTREDIR
$(__redirect_targets | grep -v '[$`]' || true)
EOF_WTREDIR
        fi
        # (3') Bound supervisor: implementing/building/shipping shapes.
        if [ "$BOUND" = "1" ]; then
            # Host hygiene (F4c) — ALLOW + audit, before any deny test can see
            # it. Process control is not lane work: the supervisor's job during
            # a host-distress event is exactly to kill or renice whatever is
            # starving the lane. This grants no NEW authority (kill/pkill were
            # never in a deny regex); it records the decision so the next
            # incident is diagnosable, and it documents the scope.
            if [ "$HYGIENE" = "1" ] && printf '%s' "$CMD_SCAN" | grep -qE "$HYGIENE_PROC_RE"; then
                __audit "allow" "host-hygiene-process" "$SLUG" "${CMD:0:160}" \
                    "process control is host hygiene, not lane work"
            fi
            if printf '%s' "$(__git_write_text)" | grep -qE "$GIT_WRITE_RE"; then
                if [ "$HYGIENE" = "1" ] && __git_write_targets_foreign; then
                    __audit "allow" "outside-repo-git-write" "$SLUG" "${CMD:0:160}" \
                        "every git-write target resolves outside the lane repo and all worktrees"
                else
                    __deny_role "$SLUG" "$W8" "$WT" \
                        "Bash git-write (target in lane repo/worktree or unresolvable — use an absolute -C path): ${CMD:0:120}"
                fi
            fi
            # A command that ONLY listed refs reached here as an allow: record
            # the exemption so "why was this permitted?" is answerable on disk.
            if [ "$HYGIENE" = "1" ] \
               && printf '%s' "$CMD_SCAN" | grep -qE "${SEP}git[[:space:]]+(tag[[:space:]]+(-[a-zA-Z]*l[a-zA-Z]*|--list)|worktree[[:space:]]+list|stash[[:space:]]+(list|show))"; then
                __audit "allow" "classifier-exemption" "$SLUG" "${CMD:0:160}" \
                    "git tag -l / worktree list / stash list|show are read-only, not git-writes"
            fi
            if printf '%s' "$CMD_SCAN" | grep -qE "$BUILDER_RE|$GO_BUILD_RE|$SKILL_SUITE_RE"; then
                __deny_role "$SLUG" "$W8" "$WT" "Bash build/test: ${CMD:0:120}"
            fi
            if printf '%s' "$CMD_SCAN" | grep -qE "$INPLACE_RE"; then
                if [ "$HYGIENE" = "1" ] && __inplace_targets_foreign; then
                    __audit "allow" "outside-repo-edit" "$SLUG" "${CMD:0:160}" \
                        "every in-place file operand resolves outside the lane repo and all worktrees"
                else
                    __deny_role "$SLUG" "$W8" "$WT" \
                        "Bash in-place edit (target in lane repo/worktree or unresolvable — use an absolute path): ${CMD:0:120}"
                fi
            fi
            if printf '%s' "$CMD_SCAN" | grep -qE "$MUTATOR_RE|$EXEC_MUTATOR_RE"; then
                # Deny on a provable repo/worktree target; fail open on $vars.
                # RESOLVED counts tokens we could prove are OUTSIDE, so an
                # all-outside mutation (the `mv "$(command -v ccusage)"` the
                # incident needed) is an ALLOW we can audit rather than a
                # silent pass. One in-repo target still denies the whole call.
                DENIED=0
                RESOLVED_OUT=0
                # KI-6: a PURE copy-family command only WRITES its destination, so a
                # source operand inside the repo is a READ and must not deny (the
                # "rsync"/"cp $REPO/src /tmp" false-positive). Relax ONLY the
                # provably-safe shape — a lone copy-family verb with NO destructive
                # verb, NO -t/--target-directory, and NO command separator / pipe /
                # substitution — where the destination is unambiguously the FINAL
                # operand. EVERY other shape (destructive verb, the -t target-dir
                # form, any chain/pipe/subshell, find|xargs -exec) keeps the
                # all-operand check, so copying INTO the repo still denies and no
                # chain can hide a repo write behind an outside final token.
                COPY_ONLY=0
                COPY_DEST=""
                if printf '%s' "$CMD_SCAN" | grep -qE "$COPY_FAMILY_RE" \
                   && ! printf '%s' "$CMD_SCAN" | grep -qE "$DESTRUCTIVE_MUTATOR_RE" \
                   && ! printf '%s' "$CMD_SCAN" | grep -qE "(^|[[:space:]])(-t|--target-directory)([[:space:]=]|$)" \
                   && ! printf '%s' "$CMD_SCAN" | grep -qE '[;&|]|\$\(|`'; then
                    COPY_ONLY=1
                    while IFS= read -r TOK; do
                        [ -n "$TOK" ] || continue
                        case "$TOK" in -*) continue ;; esac
                        COPY_DEST="$TOK"
                    done <<EOF_DEST
$(printf '%s' "$CMD_SCAN" | tr ' ' '\n' | grep -vE '^(sudo|rm|mv|cp|ln|truncate|dd|rsync|shred|unlink|install|xargs|find)$' | head -40)
EOF_DEST
                fi
                while IFS= read -r TOK; do
                    [ -n "$TOK" ] || continue
                    case "$TOK" in -*) continue ;; esac
                    # KI-6: for a pure copy-family command, skip source operands —
                    # only the destination (final operand) is a write target.
                    if [ "$COPY_ONLY" = "1" ] && [ "$TOK" != "$COPY_DEST" ]; then continue; fi
                    if __bash_target_denied "$TOK" "$SLUG"; then DENIED=1; break; fi
                    case "$TOK" in
                        ''|*'$'*|*'`'*) : ;;   # unresolvable — proves nothing
                        /*) RESOLVED_OUT=$((RESOLVED_OUT + 1)) ;;
                    esac
                done <<EOF_TOKENS
$(printf '%s' "$CMD_SCAN" | tr ' ' '\n' | grep -vE '^(sudo|rm|mv|cp|ln|truncate|dd|rsync|shred|unlink|install|xargs|find)$' | head -40)
EOF_TOKENS
                [ "$DENIED" = "1" ] && __deny_role "$SLUG" "$W8" "$WT" "Bash mutator: ${CMD:0:120}"
                if [ "$HYGIENE" = "1" ] && [ "$RESOLVED_OUT" -gt 0 ]; then
                    __audit "allow" "host-hygiene-mutation" "$SLUG" "${CMD:0:160}" \
                        "every resolvable target is outside the repo and all its worktrees"
                fi
            fi
            # Redirect / tee targets that provably land in the repo.
            while IFS= read -r TGT; do
                [ -n "$TGT" ] || continue
                if __bash_target_denied "$TGT" "$SLUG"; then
                    __deny_role "$SLUG" "$W8" "$WT" "Bash redirect → $TGT"
                fi
            done <<EOF_REDIR
$(__redirect_targets)
EOF_REDIR
            while IFS= read -r TGT; do
                [ -n "$TGT" ] || continue
                for ONE in $TGT; do
                    if __bash_target_denied "$ONE" "$SLUG"; then
                        __deny_role "$SLUG" "$W8" "$WT" "Bash tee → $ONE"
                    fi
                done
            done <<EOF_TEE
$(__tee_targets)
EOF_TEE
        fi
    fi
done
shopt -u nullglob

exit 0
