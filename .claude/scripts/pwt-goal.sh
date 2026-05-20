#!/bin/bash
# pwt-goal — natural-language → /goal command derivation helper
#
# Wraps a feature request into a properly-formatted Anthropic /goal command
# that drives an autonomous /plan-w-team run with explicit definition-of-done
# anchors and hard-gate escalations.
#
# No wall-clock or turn caps: the only stopping points are goal-success
# (terminal SUCCESS anchors) and hard-gate halts (push-ack, secret-scan-allow,
# scope-unlock-for-drift, 3-consecutive low-confidence).
#
# Workflow: run this in your terminal, copy the output, paste into a fresh
# `claude` session (or `claude -p "<paste>"`) to start an autonomous run.
#
# Usage:
#   pwt-goal.sh "ship payment API with stripe webhooks"
#   pwt-goal.sh -i "ship payment API"          # interactive: prompt for extra DoD
#   pwt-goal.sh --launch "ship payment API"    # auto-launches `claude -p` for you
#   pwt-goal.sh --type refactor "extract auth"  # variant template (refactor/bugfix/docs)
#   pwt-goal.sh -h                              # help
#
# Output: the /goal command string on stdout, ready to copy.

set -u

usage() {
    cat <<EOF
Usage: $0 [options] <request>

Wraps a natural-language feature request into a /goal command that drives an
autonomous /plan-w-team run with explicit done criteria and hard-gate exits.

Options:
  -i, --interactive    Prompt for additional DoD criteria beyond defaults
  -t, --type TYPE      Template variant: feature (default), refactor, bugfix, docs
      --launch         AUTO-LAUNCH: spawn 'claude --bg' with the derived /goal.
                       User monitors via 'claude agents'. Implies --auto-push.
      --auto-push      Auto-approve push-ack hard-gate during the run (sets
                       PLAN_W_TEAM_AUTO_APPROVE_PUSH=1 for child session).
                       Trades safety for autonomy — only push-ack auto-approves;
                       secret-scan-allow and scope-unlock-for-drift still halt.
      --no-auto-push   Explicit opt-out even with --launch (require push confirm)
  -h, --help           Show this help

Examples:
  $0 "ship payment API with stripe webhooks"
  $0 -i "refactor auth middleware to remove duplication"
  $0 --type refactor "extract notification service"
  $0 --launch "fix the login redirect bug"

Note: --hours / --turns flags accepted (warning) but no-op — /plan-w-team has
no wall-clock or turn caps by design. Only goal-success and hard-gate halts
are valid terminal states.

The output is a /goal command. Copy it and paste at the start of a fresh
Claude Code session, or use --launch to auto-invoke 'claude -p'.
EOF
}

# Defaults
INTERACTIVE=0
LAUNCH=0
AUTO_PUSH=0      # auto-approve push-ack hard-gate during autonomous run
TYPE="feature"
REQUEST=""

# Parse args
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        -i|--interactive) INTERACTIVE=1; shift ;;
        --launch) LAUNCH=1; AUTO_PUSH=1; shift ;;
        --auto-push) AUTO_PUSH=1; shift ;;
        --no-auto-push) AUTO_PUSH=0; shift ;;
        -t|--type) TYPE="$2"; shift 2 ;;
        --hours|--turns)
            echo "Note: $1 removed by design — /plan-w-team has no wall-clock or turn caps. Ignoring '$1 $2'." >&2
            shift 2 ;;
        --) shift; REQUEST="$*"; break ;;
        -*) echo "Unknown option: $1" >&2; usage; exit 1 ;;
        *) REQUEST="$*"; break ;;
    esac
done

if [ -z "$REQUEST" ]; then
    echo "Error: no request provided" >&2
    usage
    exit 1
fi

# Validate type
case "$TYPE" in
    feature|refactor|bugfix|docs) ;;
    *) echo "Unknown --type: $TYPE (allowed: feature, refactor, bugfix, docs)" >&2; exit 1 ;;
esac

# Type-specific done criteria
case "$TYPE" in
    feature)
        DONE_CRITERIA='  - stage="retro-complete" appears in transcript with workflow_lock="done"
  - every AC<N>: PASS line from the generated spec'\''s Acceptance Criteria contract appears in transcript
  - ship-readiness-gate verdict is PASS in a status block (Step 6)
  - test suite passes (Step 6 reports 100% of tests passing)'
        ;;
    refactor)
        DONE_CRITERIA='  - stage="retro-complete" with workflow_lock="done"
  - all existing tests still pass (no regression)
  - no behavior change (refactor only — code shape changes, contracts identical)
  - ship-readiness-gate PASS in Step 6 status block'
        ;;
    bugfix)
        DONE_CRITERIA='  - stage="retro-complete" with workflow_lock="done"
  - new regression test added that fails before the fix and passes after
  - existing tests still pass
  - ship-readiness-gate PASS in Step 6 status block'
        ;;
    docs)
        DONE_CRITERIA='  - stage="retro-complete" with workflow_lock="done"
  - docs cross-reference check passes in Step 7
  - no code changes (docs-only — verify diff scope)
  - CHANGELOG entry added if user-visible'
        ;;
esac

# Optional interactive DoD additions
EXTRA_DONE=""
if [ "$INTERACTIVE" = "1" ]; then
    echo "Enter additional done criteria, one per line. Empty line to finish:" >&2
    while IFS= read -r line; do
        [ -z "$line" ] && break
        EXTRA_DONE="${EXTRA_DONE}
  - ${line}"
    done
fi

# Build the /goal command
read -r -d '' GOAL_TEXT <<EOF || true
/goal Use /plan-w-team to ${REQUEST}.

Pipeline is complete when ALL of:
${DONE_CRITERIA}${EXTRA_DONE}

Halt and surface to user when ANY of:
  - push-ack pause site reached (irreversible push to remote)
  - secret-scan-allow pause site reached (security allowlist edit)
  - scope-unlock-for-drift pause site reached (mid-flight scope change)
  - 3 consecutive supervisor decisions log confidence=low (PWT-T4 escalation)

There is no wall-clock or turn cap by design: keep working until one of the
ALL-of completion conditions OR one of the halt conditions above fires.
On stop, state which terminal condition was reached and quote the transcript
line that demonstrates it.
EOF

if [ "$LAUNCH" = "1" ]; then
    # Auto-launch: spawn a NEW background claude session with the /goal active.
    # User watches it via `claude agents` dashboard. /goal indicator shows there.
    # Env vars propagate to the child session.
    LAUNCH_ENV=""
    if [ "$AUTO_PUSH" = "1" ]; then
        LAUNCH_ENV="PLAN_W_TEAM_AUTO_APPROVE_PUSH=1"
    fi

    echo "Launching: claude --bg \"<derived /goal>\"" >&2
    [ -n "$LAUNCH_ENV" ] && echo "  with env: $LAUNCH_ENV" >&2
    echo "" >&2
    echo "Monitor live state with: claude agents" >&2
    echo "" >&2

    if [ -n "$LAUNCH_ENV" ]; then
        env $LAUNCH_ENV claude --bg "$GOAL_TEXT"
    else
        claude --bg "$GOAL_TEXT"
    fi
    exit $?
fi

echo "$GOAL_TEXT"
