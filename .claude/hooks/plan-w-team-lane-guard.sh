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
# deny-only auditing. A kill switch that only half-reverts is not a revert.
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
    while IFS= read -r tgt; do
        [ -n "$tgt" ] || continue
        base=$(basename "$tgt")
        case "$base" in "$slug".*.decision.json) return 0 ;; esac
    done <<EOF_DECTGT
$(__redirect_targets)
$(__tee_targets)
EOF_DECTGT
    printf '%s' "$CMD_SCAN" | grep -qE "(mv|cp|rm|touch|tee|install)[[:space:]][^;|&]*${slug}[^;|&]*\.decision\.json" && return 0
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
        for FAM in "plan-w-team-ship-verdict-${SLUG}" "plan-w-team-test-green-${SLUG}"; do
            FORGE=0
            while IFS= read -r TGT; do
                case "$TGT" in *"$FAM"*) FORGE=1; break ;; esac
            done <<EOF_FAMR
$(__redirect_targets)
EOF_FAMR
            if [ "$FORGE" = "0" ] \
               && printf '%s' "$CMD_SCAN" | grep -qE "(mv|cp|rm|touch|tee)[[:space:]][^;|&]*${FAM}"; then
                FORGE=1
            fi
            [ "$FORGE" = "1" ] && __deny_artifact "$SLUG" "${FAM}.json" "only the pipeline's own gates may produce it"
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
