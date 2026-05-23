#!/bin/bash
# pwt-fair-share — cross-repo fair-share scheduler for /plan-w-team workers.
#
# Sits between the per-machine RAM gate (ram-budget.sh) and the spawn site
# (pwt-goal.sh). Reads the shared spawn-claims registry to enumerate which
# repos currently have active workers and computes a fair-share allocation
# so that one repo cannot monopolize machine capacity when others have
# demand.
#
# Output (always JSON to stdout; soft errors → fail-open with recommendation=null):
#
#   {
#     "repos_with_active_workers": {"repo-a": 2, "repo-b": 1},
#     "n_active_repos": 2,
#     "machine_capacity": 4,
#     "fair_share_per_repo": 2,
#     "my_repo": "repo-a",
#     "my_repo_current": 2,
#     "my_repo_allowed_max": 2,
#     "priority": "normal",
#     "recommendation": "SPAWN_OK" | "YIELD_TO_OTHER_REPO" | "AT_FAIR_SHARE" | "NO_CAPACITY"
#   }
#
# recommendation enum:
#   SPAWN_OK             → spawning is allowed under fair-share.
#   AT_FAIR_SHARE        → my_repo_current == my_repo_allowed_max; spawning would
#                          push this repo above its fair share. Refused under
#                          PWT_RUN_PRIORITY=normal; allowed under critical.
#   YIELD_TO_OTHER_REPO  → my repo is at fair share AND another repo has 0 workers
#                          but presumably needs capacity. Strongest refusal signal.
#   NO_CAPACITY          → machine_capacity == 0 (RAM gate would also refuse).
#   null                 → unrecoverable error; pwt-goal.sh treats as fail-open.
#
# Environment:
#   PWT_RUN_PRIORITY              critical | normal (default) | background
#   PWT_RAM_CLAIMS_PATH           registry path (canonical; new name)
#   PWT_RAM_CLAIMS_REGISTRY       legacy alias for the registry path
#   PWT_FAIR_SHARE_REGISTRY       legacy fair-share alias (default ~/.claude/state/pwt-ram-claims.jsonl)
#   PWT_FAIR_SHARE_MY_REPO        my repo name (default: basename of git toplevel)
#   PWT_FAIR_SHARE_CAPACITY       machine capacity override (default: derived from ram-budget.sh)
#   PWT_FAIR_SHARE_IDLE_THRESHOLD seconds of transcript silence before a claim is
#                                  considered idle and excluded from active counts.
#                                  Default 300 (5 min). 0 disables idle exclusion.
#
# Stubbing for tests:
#   PWT_FAIR_SHARE_STUB_REGISTRY  path used in place of $HOME/.claude/state/pwt-ram-claims.jsonl
#   PWT_FAIR_SHARE_STUB_CAPACITY  integer override for machine capacity
#   PWT_FAIR_SHARE_STUB_NOW       integer epoch override for idle calculations
#   PWT_FAIR_SHARE_STUB_TRANSCRIPT_MTIME  path-to-mtime mapping file (one per line:
#                                  "<sid> <epoch>") used in place of stat on
#                                  ~/.claude/projects/*/<sid>.jsonl
#
# See: .claude/commands/plan-w-team/shared/supervisor-protocol.md §FAIR SHARE CHECK
#      and docs/specs/pwt-cross-repo-fair-share.md

set -u

# ─── Configuration ──────────────────────────────────────────────────────────

PRIORITY="${PWT_RUN_PRIORITY:-normal}"
case "$PRIORITY" in
    critical|normal|background) ;;
    *)
        echo "WARN: unknown PWT_RUN_PRIORITY='$PRIORITY'; treating as 'normal'" >&2
        PRIORITY="normal"
        ;;
esac

IDLE_THRESHOLD="${PWT_FAIR_SHARE_IDLE_THRESHOLD:-300}"
[[ "$IDLE_THRESHOLD" =~ ^[0-9]+$ ]] || IDLE_THRESHOLD=300

# Env precedence (high → low):
#   1. PWT_FAIR_SHARE_STUB_REGISTRY  test-only stub (highest precedence — overrides everything)
#   2. PWT_RAM_CLAIMS_PATH           canonical user-facing override (preferred)
#   3. PWT_RAM_CLAIMS_REGISTRY       legacy alias (back-compat with older tests / scripts)
#   4. PWT_FAIR_SHARE_REGISTRY       legacy fair-share-specific alias (back-compat)
#   5. $HOME/.claude/state/pwt-ram-claims.jsonl   default
REGISTRY="${PWT_FAIR_SHARE_STUB_REGISTRY:-${PWT_RAM_CLAIMS_PATH:-${PWT_RAM_CLAIMS_REGISTRY:-${PWT_FAIR_SHARE_REGISTRY:-$HOME/.claude/state/pwt-ram-claims.jsonl}}}}"

# Auto-invoke registry cleanup (best-effort): remove orphan SIDs and
# test-pattern repo entries before evaluating fair-share. Failure is non-fatal
# — fair-share still proceeds with whatever the registry contains.
# Disabled when PWT_FAIR_SHARE_DISABLE_AUTO_CLEANUP=1 (used by bats tests that
# seed synthetic fake-SID entries which would otherwise be classified as
# orphans and removed).
if [ "${PWT_FAIR_SHARE_DISABLE_AUTO_CLEANUP:-0}" != "1" ]; then
    __pwt_fs_cleanup="$(dirname "$0")/pwt-claims-cleanup.sh"
    if [ -x "$__pwt_fs_cleanup" ]; then
        "$__pwt_fs_cleanup" --quiet 2>/dev/null || true
    fi
    unset __pwt_fs_cleanup
fi

# Resolve my_repo name
MY_REPO="${PWT_FAIR_SHARE_MY_REPO:-}"
if [ -z "$MY_REPO" ]; then
    TOPLEVEL=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
    if [ -n "$TOPLEVEL" ]; then
        # Worktrees: use the parent repo name, not the worktree path
        # e.g., .../claude-pattern/.claude/worktrees/foo → claude-pattern
        case "$TOPLEVEL" in
            */.claude/worktrees/*)
                MY_REPO=$(printf '%s' "$TOPLEVEL" | sed -E 's|/.claude/worktrees/.*$||' | xargs basename)
                ;;
            *)
                MY_REPO=$(basename "$TOPLEVEL")
                ;;
        esac
    else
        MY_REPO=$(basename "$PWD")
    fi
fi

NOW="${PWT_FAIR_SHARE_STUB_NOW:-$(date +%s)}"

# ─── Helpers ────────────────────────────────────────────────────────────────

emit_fail_open() {
    local reason="$1"
    cat <<EOF
{
  "repos_with_active_workers": {},
  "n_active_repos": 0,
  "machine_capacity": null,
  "fair_share_per_repo": null,
  "my_repo": "${MY_REPO}",
  "my_repo_current": 0,
  "my_repo_allowed_max": null,
  "priority": "${PRIORITY}",
  "recommendation": null,
  "note": "${reason}"
}
EOF
}

# Look up transcript mtime for a sid; returns epoch seconds or empty string.
# Tests can override via PWT_FAIR_SHARE_STUB_TRANSCRIPT_MTIME (file mapping).
transcript_mtime_for_sid() {
    local sid="$1"
    if [ -n "${PWT_FAIR_SHARE_STUB_TRANSCRIPT_MTIME:-}" ] \
            && [ -r "${PWT_FAIR_SHARE_STUB_TRANSCRIPT_MTIME}" ]; then
        awk -v s="$sid" '$1==s {print $2; found=1; exit} END{if(!found) exit 1}' \
            "${PWT_FAIR_SHARE_STUB_TRANSCRIPT_MTIME}"
        return $?
    fi
    # Real lookup: ~/.claude/projects/*/<sid>.jsonl
    local f
    for f in "$HOME"/.claude/projects/*/"${sid}".jsonl; do
        [ -e "$f" ] || continue
        # macOS stat: -f %m ; Linux stat: -c %Y
        local m
        m=$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null || echo "")
        if [ -n "$m" ]; then
            printf '%s\n' "$m"
            return 0
        fi
    done
    return 1
}

# Resolve machine capacity. Preferred source: PWT_FAIR_SHARE_STUB_CAPACITY (tests),
# then ram-budget.sh's capacity_for_new_sessions + count of CURRENT active claims
# (because claims already include the slots they hold).
#
# Note: ram-budget.sh's capacity_for_new_sessions reports REMAINING capacity, not
# total. To compute fair shares we need TOTAL machine slots = current_active + remaining.
resolve_machine_capacity() {
    if [ -n "${PWT_FAIR_SHARE_STUB_CAPACITY:-}" ]; then
        echo "${PWT_FAIR_SHARE_STUB_CAPACITY}"
        return
    fi
    local remaining=""
    local rb_script
    rb_script="$(dirname "$0")/ram-budget.sh"
    if [ -x "$rb_script" ]; then
        local json
        json=$("$rb_script" 2>/dev/null || echo "")
        if [ -n "$json" ]; then
            remaining=$(printf '%s' "$json" \
                | grep -oE '"capacity_for_new_sessions": *[^,}]*' \
                | head -1 | sed -E 's/.*: *//' | tr -d ' ')
        fi
    fi
    # If we couldn't get a number, return empty so caller can decide.
    [[ "$remaining" =~ ^[0-9]+$ ]] || { echo ""; return; }
    echo "$remaining"
}

# ─── Main ───────────────────────────────────────────────────────────────────

# Read registry → produce (repo, sid, started_at_epoch, est_gb, priority) rows.
# Tolerate malformed lines.
ACTIVE_TMP=$(mktemp -t pwt-fs-active.XXXXXX 2>/dev/null) || { emit_fail_open "mktemp_failed"; exit 0; }
trap "rm -f '$ACTIVE_TMP'" EXIT

if [ -r "$REGISTRY" ]; then
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        # Minimal grep-based extraction (no jq dependency in tests).
        repo=$(printf '%s' "$line" | grep -oE '"repo": *"[^"]+"'        | head -1 | sed -E 's/.*"([^"]+)"$/\1/')
        sid=$(printf '%s' "$line"  | grep -oE '"sid": *"[^"]+"'         | head -1 | sed -E 's/.*"([^"]+)"$/\1/')
        started=$(printf '%s' "$line" | grep -oE '"started_at": *"[^"]+"' | head -1 | sed -E 's/.*"([^"]+)"$/\1/')
        pri=$(printf '%s' "$line"  | grep -oE '"priority": *"[^"]+"'    | head -1 | sed -E 's/.*"([^"]+)"$/\1/')
        [ -z "$pri" ] && pri="normal"
        [ -z "$repo" ] && continue
        [ -z "$sid" ] && continue

        # Idle filter: if transcript is older than IDLE_THRESHOLD, this claim is
        # stale and excluded from active counts. The supervisor sweeper is the
        # entity that physically removes the line; this filter just keeps the
        # allocation math honest in the interim.
        if [ "$IDLE_THRESHOLD" -gt 0 ]; then
            mtime=$(transcript_mtime_for_sid "$sid" 2>/dev/null || echo "")
            if [ -n "$mtime" ] && [[ "$mtime" =~ ^[0-9]+$ ]]; then
                age=$(( NOW - mtime ))
                if [ "$age" -gt "$IDLE_THRESHOLD" ]; then
                    continue
                fi
            fi
        fi

        printf '%s\t%s\t%s\n' "$repo" "$sid" "$pri" >> "$ACTIVE_TMP"
    done < "$REGISTRY"
fi

# Aggregate per-repo counts. Bash 3.2-compatible (no associative arrays):
# sort the active rows by repo, then uniq -c to get counts.
COUNTS_TMP=$(mktemp -t pwt-fs-counts.XXXXXX 2>/dev/null) || { emit_fail_open "mktemp_failed"; exit 0; }
# extend the cleanup trap
trap "rm -f '$ACTIVE_TMP' '$COUNTS_TMP'" EXIT

MY_CURRENT=0
N_TOTAL_ACTIVE=0

# Extract just repos, sort, uniq -c → "  count repo" lines.
awk -F'\t' '{print $1}' "$ACTIVE_TMP" | sort | uniq -c > "$COUNTS_TMP" 2>/dev/null

REPOS_SEEN_LIST=""  # space-separated repo names, ordered as seen in counts file
REPOS_JSON="{"
first=1
N_ACTIVE_REPOS=0
while read -r count repo; do
    [ -z "$repo" ] && continue
    [ -z "$count" ] && continue
    if [ "$first" -eq 1 ]; then
        first=0
    else
        REPOS_JSON+=", "
    fi
    REPOS_JSON+="\"$repo\": $count"
    REPOS_SEEN_LIST="$REPOS_SEEN_LIST $repo:$count"
    N_TOTAL_ACTIVE=$(( N_TOTAL_ACTIVE + count ))
    N_ACTIVE_REPOS=$(( N_ACTIVE_REPOS + 1 ))
    if [ "$repo" = "$MY_REPO" ]; then
        MY_CURRENT=$count
    fi
done < "$COUNTS_TMP"
REPOS_JSON+="}"

# Helper: look up a repo's count from REPOS_SEEN_LIST. Bash 3.2-safe.
count_for_repo() {
    local target="$1"
    local pair
    for pair in $REPOS_SEEN_LIST; do
        case "$pair" in
            "${target}:"*) printf '%s' "${pair#*:}"; return 0 ;;
        esac
    done
    printf '0'
}

# Treat my own about-to-spawn repo as "active" for allocation, even if it has
# 0 claims yet — otherwise the first spawn of a new repo against a busy
# machine would compute fair_share = capacity/1 (everyone else) and immediately
# yield. The intent of fair-share is "if I'm asking, I'm active."
MY_REPO_IS_IN_SET=0
case " $(printf '%s' "$REPOS_SEEN_LIST" | sed 's/:[0-9]*//g') " in
    *" $MY_REPO "*) MY_REPO_IS_IN_SET=1 ;;
esac
if [ "$MY_REPO_IS_IN_SET" -eq 0 ]; then
    N_ACTIVE_REPOS=$(( N_ACTIVE_REPOS + 1 ))
fi

CAPACITY=$(resolve_machine_capacity)
# Machine TOTAL slots ≈ remaining capacity + currently-claimed active workers.
# If we couldn't read remaining, fall back to N_TOTAL_ACTIVE so allocation
# math at least divides among current claims.
if [[ "$CAPACITY" =~ ^[0-9]+$ ]]; then
    MACHINE_CAPACITY=$(( CAPACITY + N_TOTAL_ACTIVE ))
else
    MACHINE_CAPACITY=$N_TOTAL_ACTIVE
fi

if [ "$MACHINE_CAPACITY" -le 0 ]; then
    # Nothing to share. ram-budget would also block; surface NO_CAPACITY clearly.
    cat <<EOF
{
  "repos_with_active_workers": ${REPOS_JSON},
  "n_active_repos": ${N_ACTIVE_REPOS},
  "machine_capacity": ${MACHINE_CAPACITY},
  "fair_share_per_repo": 0,
  "my_repo": "${MY_REPO}",
  "my_repo_current": ${MY_CURRENT},
  "my_repo_allowed_max": 0,
  "priority": "${PRIORITY}",
  "recommendation": "NO_CAPACITY"
}
EOF
    exit 0
fi

if [ "$N_ACTIVE_REPOS" -le 0 ]; then
    N_ACTIVE_REPOS=1
fi

FAIR_SHARE=$(( MACHINE_CAPACITY / N_ACTIVE_REPOS ))
[ "$FAIR_SHARE" -lt 1 ] && FAIR_SHARE=1

MY_ALLOWED_MAX="$FAIR_SHARE"

# Determine recommendation
if [ "$PRIORITY" = "critical" ]; then
    # Critical bypasses fair-share; only NO_CAPACITY (handled above) can block.
    RECO="SPAWN_OK"
elif [ "$PRIORITY" = "background" ] && [ "$N_TOTAL_ACTIVE" -ge "$MACHINE_CAPACITY" ]; then
    # Background yields first under any contention.
    RECO="YIELD_TO_OTHER_REPO"
else
    if [ "$MY_CURRENT" -lt "$MY_ALLOWED_MAX" ]; then
        RECO="SPAWN_OK"
    else
        # I'm at or above my fair share. If any other repo is below its share,
        # that's YIELD_TO_OTHER_REPO. If everyone is at or above their share,
        # it's AT_FAIR_SHARE (whole machine is balanced).
        UNDERSERVED=0
        for pair in $REPOS_SEEN_LIST; do
            r="${pair%%:*}"
            c="${pair#*:}"
            [ -z "$r" ] && continue
            [ "$r" = "$MY_REPO" ] && continue
            if [ "$c" -lt "$FAIR_SHARE" ]; then
                UNDERSERVED=1
                break
            fi
        done
        # A new (not-yet-claimed) repo wanting a slot is also underserved by definition.
        # We already added it to N_ACTIVE_REPOS, but that's the asker's repo
        # itself. Other not-yet-claimed repos can't be observed here (they
        # haven't called us yet), so UNDERSERVED only flips for repos already
        # in the registry. That's fine — fair-share is reactive, not predictive.
        if [ "$UNDERSERVED" -eq 1 ]; then
            RECO="YIELD_TO_OTHER_REPO"
        else
            RECO="AT_FAIR_SHARE"
        fi
    fi
fi

cat <<EOF
{
  "repos_with_active_workers": ${REPOS_JSON},
  "n_active_repos": ${N_ACTIVE_REPOS},
  "machine_capacity": ${MACHINE_CAPACITY},
  "fair_share_per_repo": ${FAIR_SHARE},
  "my_repo": "${MY_REPO}",
  "my_repo_current": ${MY_CURRENT},
  "my_repo_allowed_max": ${MY_ALLOWED_MAX},
  "priority": "${PRIORITY}",
  "recommendation": "${RECO}"
}
EOF
