# Step 8: Retro (Optional but Recommended)

<!-- PWT-T2 Orchestrator Retrofit (2026-05-18)
     Pause sites in this file routed via .claude/scripts/plan-w-team-orchestrator-route.sh
     Classifier: shared/orchestrator-interception.md

     | Call-site label             | Verdict      | Original behavior                           |
     | --------------------------- | ------------ | ------------------------------------------- |
     | retro-friction-categorize   | orchestrator | Friction-log category assignment             |

     New section: §8j-bis Orchestrator Decision Health reads the per-SLUG JSONL
     decision log and scores orchestrator decision quality for the retro.

     Safe-fail: if router unavailable, falls through to AskUserQuestion.
     Kill switch: PLAN_W_TEAM_DISABLE_ORCHESTRATOR=1
-->

Quantitative retrospective on the shipped work. Run automatically for features that took >2 hours of builder time, or on demand with `--retro`.

## Board Comment (Auto)

Add a retro summary as the final comment on the board Issue — this closes the feature's story. Fire-and-forget.

```bash
scripts/board.sh comment "<feature-name>" "## Retrospective

**Commits:** <count> | **Lines:** +<added> / -<removed>
**Sessions:** <count> (<deep/medium/micro breakdown>)
**Fix ratio:** <fixes / total> (<healthy | warning>)
**Test quality:** ★★★/★★/★ across <count> modules
**Self-assessment:** <0-10>/10

### What went well
<1-2 bullet points>

### What to improve
<1-2 bullet points>

**Completed:** $(date -u +%Y-%m-%dT%H:%M:%SZ)" || true
```

## 8a. Gather Metrics

```bash
# Run these in parallel:
git log --oneline --since="<feature-start>" --until="now"
git diff --stat origin/<base>...HEAD
git log --format="%H %aI" --since="<feature-start>"
```

## 8b. Compute and Report

| Metric                  | How                                                                      |
| ----------------------- | ------------------------------------------------------------------------ |
| Commit count            | Count commits in feature range                                           |
| Lines added/removed/net | From diff stat                                                           |
| File churn              | Most-changed files (hotspot analysis)                                    |
| Commit type breakdown   | Count feat/fix/refactor/test/docs prefixes                               |
| Work session detection  | 45-minute gap between commits = new session boundary                     |
| Session classification  | Deep (50+ min), Medium (20-50), Micro (<20)                              |
| AI-assisted ratio       | Count commits with `Co-Authored-By` trailers vs total                    |
| Fix ratio               | fixes / total commits. Flag if >50% ("ship fast, fix fast" anti-pattern) |

## 8c. Quality Signals

| Signal                               | Threshold | Meaning                            |
| ------------------------------------ | --------- | ---------------------------------- |
| Fix ratio >50%                       | Warning   | Review process may have gaps       |
| WTF-likelihood hit >20% during build | Note      | Builder struggled, investigate why |
| >3 reverts during build              | Warning   | Spec may have been unclear         |
| Hotspot with >10 changes             | Note      | Consider refactoring this file     |

## 8d. Streak Tracking

Track across features (persists in task metadata). Read `shared/artifact-storage.md` for streak data format.

- Consecutive features shipped without P0 bugs
- Longest focus session (Deep work)
- Features shipped this week/month

## 8e. Parallel Execution Health

Track worktree and agent coordination metrics:

| Metric                           | How to Measure                            | Warning Threshold |
| -------------------------------- | ----------------------------------------- | ----------------- |
| Stale worktree incidents         | Agents that operated on outdated code     | Any > 0           |
| Shared file merge conflicts      | Manual merge coordination needed          | Any > 0           |
| Context compactions during build | `/compact` or auto-compact triggers       | > 1 per run       |
| Worktrees alive at peak          | Max concurrent worktrees during execution | > 6               |
| Fix agents that duplicated work  | Agents whose changes were superseded      | Any > 0           |
| Expired worktree builders        | Builders lost to context/session expiry   | Any > 0           |
| Sessions to complete             | `--resume` count + 1                      | > 2               |
| Formatter re-read cycles         | "File modified since read" errors         | Any > 0           |

A stale-worktree incident or shared-file conflict means Step 2's conflict detection was incomplete. Expired worktree builders mean the feature was too large for worktree strategy — should have used "lead implements directly" per Step 3. Formatter re-reads mean the pre-edit format sync was skipped.

## 8f. Hook Friction Log

Track PostToolUse hook interactions that caused workflow friction:

| Metric          | How to Measure                                                                          |
| --------------- | --------------------------------------------------------------------------------------- |
| TS6133 warnings | Count TS6133 "allowed" messages in hook output                                          |
| False blocks    | Edits blocked by hook that required workarounds (combined edits, Write instead of Edit) |
| Real catches    | Type errors the hook caught that would have been bugs                                   |

A high false-block count signals the hook needs tuning. A high real-catch count validates the hook's value. Track both to calibrate.

## 8g. Evaluator Iteration Health

Track evaluator-driven refinement outcomes from Step 4b:

| Metric                  | How to Measure                                | Warning Threshold         |
| ----------------------- | --------------------------------------------- | ------------------------- |
| Verdict                 | PASS / ITERATE (exhausted) / ESCALATE         | ESCALATE = builder stuck  |
| Iterations used         | Actual vs max_iterations from spec            | Hit max without PASS      |
| Functional pass rate    | functional_pass / functional_total            | < 100% at final iteration |
| Quality average         | Mean of quality_scores array                  | < 3 (below adequate)      |
| Failure categories      | Array of failure themes from evaluator report | Same category 2+ features |
| No-progress escalations | ESCALATE due to repeated same failures        | Any > 0                   |

An ESCALATE verdict means the evaluator detected the builder couldn't fix the issue alone — review the spec for unclear requirements or missing design guidance. Repeated failure categories across features signal a systemic gap — check if an instinct was created by `capture-learnings.sh` for compound learning.

## 8g-bis. Scope Stability

Step 2 wrote a scope-lock artifact at `.claude/state/plan-w-team-scope-lock-$SLUG.json`. Compute scope stability:

```bash
LOCK=".claude/state/plan-w-team-scope-lock-$SLUG.json"
UNLOCK=".claude/state/plan-w-team-scope-unlock-$SLUG"

if [ -f "$LOCK" ]; then
  LOCKED=$(jq -r '.task_count' "$LOCK")
  SHIPPED=$(TaskList by spec_path | wc -l)   # pseudocode — use your task tooling
  DRIFT=$((SHIPPED - LOCKED))
  UNLOCK_ACK=$([ -f "$UNLOCK" ] && echo true || echo false)

  # Score: 5 = no drift, 4 = drift with ack, 2 = drift without ack, 1 = lock missing mid-flight
  if [ "$DRIFT" -eq 0 ]; then SCORE=5
  elif [ "$UNLOCK_ACK" = "true" ]; then SCORE=4
  else SCORE=2
  fi
else
  SCORE="n/a"
fi
```

Report in retro: `Scope stability: <score>/5 (locked=<N>, shipped=<N>, drift=<D>, unlock_ack=<bool>)`.

A score <= 2 means tasks were added mid-flight without the user acknowledging scope expansion. This is a process smell — the spec was probably incomplete, or scope creep happened silently. Feeds into 8i self-assessment.

## 8g-ter. Writer↔Reader Symmetry

Step 5 runs `.claude/scripts/plan-w-team-symmetry-check.sh` as an enforcing gate. Re-run it at retro time to score how the run's governance artifacts held up:

```bash
if .claude/scripts/plan-w-team-symmetry-check.sh >/dev/null 2>&1; then
  SYMMETRY_SCORE=5
  SYMMETRY_NOTE="clean"
else
  code=$?
  case "$code" in
    1) SYMMETRY_SCORE=1; SYMMETRY_NOTE="orphan (enforcing artifact with no reader)" ;;
    2) SYMMETRY_SCORE=1; SYMMETRY_NOTE="stale (registry entry with no writer)" ;;
    3) SYMMETRY_SCORE=0; SYMMETRY_NOTE="checker env failure" ;;
    *) SYMMETRY_SCORE=0; SYMMETRY_NOTE="unknown exit $code" ;;
  esac
fi
```

Report in retro: `Writer↔reader symmetry: <SYMMETRY_SCORE>/5 (<SYMMETRY_NOTE>)`.

A score <4 means the run introduced a new state artifact without completing the writer↔reader contract — the exact defect class this gate exists to catch. Feeds §8i self-assessment with category `spec-gap`. Unlike scope-lock drift (where user ack is an escape hatch), symmetry is a pure code-governance property: an orphan is always a real defect, never a legitimate user choice.

## 8h. Untracked Hygiene

Score how well this run handled untracked files. Read the state file written by the Step 5 ship gate:

```bash
SLUG="<feature-slug>"
RETRO_STATE=".claude/state/plan-w-team-retro-$SLUG.json"
BASELINE=".claude/state/plan-w-team-untracked-baseline-$SLUG.txt"

# Degraded-mode sentinel: if the baseline never existed (e.g. --ship-only, --resume,
# or a run that skipped preflight), persist hygiene_skipped: true to the retro JSON
# so downstream readers (friction detector, dashboards) can distinguish "skipped" from
# "scored low". A score of 1 means the gate ran and failed; a missing-baseline run
# should score n/a, not 1.
#
# IMPORTANT: the write is unconditional — RETRO_STATE may not pre-exist on the
# --ship-only and --retro paths (no Step 5 ship-gate hygiene loop ran), and that
# is exactly the case the sentinel exists for. Round 1 had this guarded behind
# `[ -f "$RETRO_STATE" ]`, which silently no-op'd on the most common skip path.
if [ ! -f "$BASELINE" ]; then
  mkdir -p .claude/state
  TMP=$(mktemp "${RETRO_STATE}.tmp.XXXXXX")
  if [ -f "$RETRO_STATE" ]; then
    jq '.untracked_hygiene = {hygiene_skipped: true, reason: "baseline missing at retro time", score: null}' \
      "$RETRO_STATE" > "$TMP"
  else
    jq -n '{untracked_hygiene: {hygiene_skipped: true, reason: "baseline missing at retro time", score: null}}' \
      > "$TMP"
  fi
  mv "$TMP" "$RETRO_STATE"
  echo "Score: n/a (hygiene-skipped — no baseline)"
else
  # Normal path: read untracked_hygiene.resolved counts and deferrals[] from the file
  jq '.untracked_hygiene' "$RETRO_STATE"
fi
```

Report in the retro artifact using this format:

```markdown
### Untracked Hygiene

- Baseline size: <N>
- Classification set: <N> new files
- Resolved: <C> COMMIT / <I> IGNORE / <D> DISCARD / <F> DEFER
- Deferrals: <list each `{path, reason}` or "none">
- .gitignore edits: <count of patterns added, or "none">
- Score: <1-5>
```

Scoring anchors (full rubric in `shared/untracked-hygiene.md`):

| Score | Anchor                                                                                    |
| ----- | ----------------------------------------------------------------------------------------- |
| 1     | Many deferrals without clear reasons; gate skipped without justification                  |
| 2     | Most classified but several DEFER with vague reasons                                      |
| 3     | All classified; 1-2 DEFER with documented reasons; some IGNORE patterns too broad         |
| 4     | All classified; 0-1 DEFER; IGNORE patterns narrow and appropriate                         |
| 5     | Clean run (0 new untracked) OR all COMMIT/IGNORE/DISCARD with narrow, justified decisions |

A hygiene score <4 should feed into 8i self-assessment as a friction point — the workflow missed a classification opportunity or accumulated deferrals.

### Cleanup

At the end of a successful retro (artifact written, all sections complete), delete the baseline file:

```bash
rm -f ".claude/state/plan-w-team-untracked-baseline-$SLUG.txt"
```

Failed runs (retro aborted) leave the baseline intact so `--resume` can read it.

If the Step 5 gate ran in degraded mode (no baseline, e.g. `--ship-only` or `--resume`), report `Score: n/a (hygiene-skipped)` instead of scoring 1 — skipping is not the same as failing. The sentinel block above persists this distinction to `$RETRO_STATE.untracked_hygiene.hygiene_skipped` so the 3-in-30-days friction detector won't false-positive on legitimate skips.

## 8i. Self-Assessment

Rate the overall `/plan-w-team` experience for this feature 0-10. If below 10, note what friction points occurred — this feeds back into improving the workflow itself:

- Where did the spec miss something?
- Where did builders struggle?
- Where did review catch real issues vs generate noise?
- Where did hooks help vs create friction?
- Did untracked hygiene (8h) surface real classification work, or was it noise?
- What would you do differently next time?

Store self-assessment at the path defined in `shared/artifact-storage.md`.

### Trigger: scores below 8 feed back into the workflow

A self-assessment below 8 is not a vent — it is a signal that the workflow itself needs attention. When a score <8 is recorded:

1. **Append the friction point** to `.claude/state/plan-w-team-friction-log.jsonl`. Serialize concurrent retros with a portable mkdir-based atomic lock (flock is not available on macOS by default). Busy-wait because two parallel retros on different features legitimately race here and both must land:

   ```bash
   LOG=".claude/state/plan-w-team-friction-log.jsonl"
   LOCK_DIR=".claude/state/plan-w-team-friction-log.lock"
   mkdir -p .claude/state
   # Build the JSON line with jq to guarantee valid escaping.
   LINE=$(jq -cn \
     --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
     --arg feature "$SLUG" \
     --argjson score "$SELF_ASSESSMENT_SCORE" \
     --arg category "$FRICTION_CATEGORY" \
     --arg note "$FRICTION_NOTE" \
     '{timestamp:$ts, feature:$feature, score:$score, category:$category, note:$note}')
   # mkdir is atomic on POSIX filesystems. Serializes concurrent retros.
   while ! mkdir "$LOCK_DIR" 2>/dev/null; do sleep 0.1; done
   trap 'rm -f "$LOG.tmp.$$"; rmdir "$LOCK_DIR" 2>/dev/null' EXIT
   # Atomic write: build the full new file in a temp, then rename.
   # `>>` can leave a partial line if the process is killed mid-append; rename is atomic on the same filesystem.
   TMP="$LOG.tmp.$$"
   { [ -f "$LOG" ] && cat "$LOG"; printf '%s\n' "$LINE"; } > "$TMP" && mv "$TMP" "$LOG"
   rmdir "$LOCK_DIR"
   trap - EXIT
   ```

   **Why temp+rename instead of `>>`**: an append interrupted by SIGKILL can produce a half-written JSONL line, which silently corrupts every downstream `jq -s` read of the log. `mv` on the same filesystem is atomic — readers see either the old file or the new one, never a torn write.

   If a stale lock dir blocks retros (e.g. after a killed process), remove it: `rmdir .claude/state/plan-w-team-friction-log.lock`.

   `$FRICTION_CATEGORY` must be one of: `spec-gap|builder-struggle|review-noise|hook-friction|hygiene|orchestrator-quality|other`. Reject any other value before the append — unknown categories defeat the 3-in-30-days pattern detection.

   When the friction category is ambiguous, route through the orchestrator for classification:

   ```bash
   # snippet-lint: skip — illustrative orchestrator routing
   FRICTION_CATEGORY=$(route_orchestrator retro-friction-categorize "$SLUG" \
     "friction_note=$FRICTION_NOTE" \
     "score=$SELF_ASSESSMENT_SCORE" \
     "options=spec-gap,builder-struggle,review-noise,hook-friction,hygiene,orchestrator-quality,other" \
     2>/dev/null || echo "other")
   ```

   <!-- Original: Lead manually chose friction category. Orchestrator classifies
        based on the friction note content and taxonomy.
        Fall-through: default to "other" if router unavailable. -->

2. **After 3 entries in the same category** accumulate within 30 days, surface at the next `/plan-w-team` preflight:

   ```
   ⚠ Friction pattern detected: category=<X> (3+ entries in 30d).
     Review .claude/state/plan-w-team-friction-log.jsonl and consider updating
     the relevant stage file before continuing.
   ```

3. **The user can dismiss with `.claude/state/plan-w-team-friction-ack-<category>`** (touch a file with the category name) if the pattern is intentional or already addressed. Dismissals expire after 30 days — chronic friction resurfaces.

This turns "write-only retro prose" into a lightweight feedback loop that updates the workflow without requiring the user to manually cross-reference old retros.

## 8j-bis. Orchestrator Decision Health

Read the per-SLUG decision JSONL to score how well the orchestrator performed during this run. This section was added by PWT-T2 to close the feedback loop between orchestrator decisions and retro assessment.

```bash
SLUG="<feature-slug>"
RETRO_DECISIONS=".claude/state/plan-w-team-orchestrator-decisions-$SLUG.jsonl"

if [ ! -f "$RETRO_DECISIONS" ]; then
  echo "Score: n/a (no orchestrator decisions — likely pre-upgrade SLUG or PLAN_W_TEAM_DISABLE_ORCHESTRATOR=1)"
else
  DECISIONS_TOTAL=$(wc -l < "$RETRO_DECISIONS" | tr -d ' ')
  DECISIONS_ESCALATED=$(grep -c '"escalate-to-user"' "$RETRO_DECISIONS" 2>/dev/null || echo 0)
  DECISIONS_FALLBACK=$(grep -c '"-fallback"' "$RETRO_DECISIONS" 2>/dev/null || echo 0)
  LOW_CONFIDENCE=$(jq -r 'select(.decision.confidence == "low") | .call_site' "$RETRO_DECISIONS" 2>/dev/null | wc -l | tr -d ' ')

  # Per-stage distribution
  DECISIONS_PER_STAGE=$(jq -r '.call_site' "$RETRO_DECISIONS" 2>/dev/null | sort | uniq -c | sort -rn)

  cat <<EOF
### Orchestrator Decision Health

- Decisions total: $DECISIONS_TOTAL
- Decisions escalated to user: $DECISIONS_ESCALATED
- Parse-failure fallbacks: $DECISIONS_FALLBACK
- Low-confidence decisions: $LOW_CONFIDENCE
- Per-stage distribution:
$(echo "$DECISIONS_PER_STAGE" | sed 's/^/  /')

EOF

  # Score: 5 = all decisions made, no fallbacks, no low-confidence
  #        4 = 1-2 fallbacks or low-confidence
  #        3 = 3+ fallbacks or escalations > 30% of total
  #        2 = majority escalated or fallback
  #        1 = orchestrator effectively disabled (all fallback)
  if [ "$DECISIONS_FALLBACK" -eq 0 ] && [ "$LOW_CONFIDENCE" -eq 0 ]; then
    ORCH_SCORE=5
  elif [ "$DECISIONS_FALLBACK" -le 2 ] && [ "$LOW_CONFIDENCE" -le 2 ]; then
    ORCH_SCORE=4
  elif [ "$DECISIONS_ESCALATED" -gt $((DECISIONS_TOTAL / 3)) ]; then
    ORCH_SCORE=3
  elif [ "$DECISIONS_ESCALATED" -gt $((DECISIONS_TOTAL / 2)) ]; then
    ORCH_SCORE=2
  else
    ORCH_SCORE=3
  fi

  echo "Score: $ORCH_SCORE/5"

  # Feed low scores into friction log
  if [ "$ORCH_SCORE" -lt 4 ]; then
    echo "⚠ Orchestrator decision quality below threshold — feeding into friction log"
    # Category: orchestrator-quality
  fi
fi
```

Report in retro: `Orchestrator decision health: <ORCH_SCORE>/5 (total=<N>, escalated=<N>, fallback=<N>, low-confidence=<N>)`.

A score <4 feeds `§8i` friction log with category `orchestrator-quality`. Recurring low scores suggest the classifier table needs rebalancing — review the per-stage distribution to identify which call sites are producing low-confidence or fallback decisions.

## 8j-ter. Fleet Parallelism Health

Read the per-SLUG fleet log to score how well parallelism was achieved during execution. Added by PWT-T3 to close the feedback loop between Step 3-4 spawn decisions and retro assessment.

```bash
SLUG="<feature-slug>"
FLEET_LOG=".claude/state/plan-w-team-fleet-$SLUG.jsonl"
FLEET_INTENT=".claude/state/plan-w-team-fleet-intent-$SLUG.jsonl"

if [ ! -f "$FLEET_LOG" ]; then
  echo "Score: n/a (no fleet log — likely lead-implements-directly run or PLAN_W_TEAM_FLEET_DISABLE=1)"
else
  SUMMARY=$(.claude/scripts/plan-w-team-fleet-query.sh summary "$SLUG")
  SPAWNED=$(echo "$SUMMARY" | jq -r '.spawned')
  COMPLETED=$(echo "$SUMMARY" | jq -r '.completed')
  FAILED=$(echo "$SUMMARY" | jq -r '.failed')
  MAX_CONCURRENT=$(echo "$SUMMARY" | jq -r '.max_concurrent')

  # Total wall-clock seconds from first spawn to last complete event
  FIRST_TS=$(jq -r 'select(.event=="spawn") | .ts' "$FLEET_LOG" | sort | head -1)
  LAST_TS=$(jq -r 'select(.event=="complete") | .ts' "$FLEET_LOG" | sort | tail -1)
  if [ -n "$FIRST_TS" ] && [ -n "$LAST_TS" ]; then
    DURATION_S=$(( $(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$LAST_TS" +%s) - $(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$FIRST_TS" +%s) ))
  else
    DURATION_S=0
  fi

  # Parallelism efficiency: max_concurrent / spawned approximates how
  # batched-vs-streamed the dispatch was. Proper time-weighted ∫concurrent dt
  # would need a finer-grained calculation; this is the MVP heuristic.
  if [ "$SPAWNED" -gt 0 ]; then
    PCT=$(( MAX_CONCURRENT * 100 / SPAWNED ))
  else
    PCT=0
  fi

  cat <<EOF
### Fleet Parallelism Health

- Agents spawned: $SPAWNED
- Agents completed: $COMPLETED
- Errors (hook-detected payload gaps): $FAILED
- Max concurrent: $MAX_CONCURRENT
- Wall-clock duration: ${DURATION_S}s
- Parallelism heuristic: $PCT% (max_concurrent / spawned)

EOF

  # Score: 5 = max_concurrent == spawned (perfect parallel)
  #        4 = >= 75% parallelism
  #        3 = 50-74%
  #        2 = 25-49% (mostly serial)
  #        1 = <25% (batch-wait heavy)
  if [ "$PCT" -ge 95 ]; then
    FLEET_SCORE=5
  elif [ "$PCT" -ge 75 ]; then
    FLEET_SCORE=4
  elif [ "$PCT" -ge 50 ]; then
    FLEET_SCORE=3
  elif [ "$PCT" -ge 25 ]; then
    FLEET_SCORE=2
  else
    FLEET_SCORE=1
  fi

  echo "Score: $FLEET_SCORE/5"

  # Identify tasks that could have spawned earlier (intent-aware analysis,
  # only available when the lead used Pattern B continuous dispatch in 03-execute)
  if [ -f "$FLEET_INTENT" ]; then
    LATE_SPAWNS=$(jq -s '[.[] | select(.event != null)] | length' "$FLEET_INTENT" 2>/dev/null || echo 0)
    [ "$LATE_SPAWNS" -gt 0 ] && echo "Intent sidecar present: $LATE_SPAWNS dispatched tasks (full timing analysis available)"
  fi

  if [ "$FLEET_SCORE" -lt 3 ]; then
    echo "⚠ Parallelism below 50% — consider Pattern B continuous dispatch in 03-execute.md for future runs"
  fi
fi

# Cleanup on successful retro completion (mirrors baseline-file cleanup)
if [ "${RETRO_SUCCESS:-0}" = "1" ]; then
  rm -f "$FLEET_LOG" "$FLEET_INTENT"
fi
```

Report in retro: `Fleet parallelism health: <FLEET_SCORE>/5 (spawned=<N>, max_concurrent=<N>, duration=<N>s)`.

A score <3 suggests batch-fan-out waste. The retro recommendation is Pattern B continuous dispatch (`shared/fleet-manager.md` §Query Subcommand Reference). For lead-implements-directly runs or runs with `PLAN_W_TEAM_FLEET_DISABLE=1`, this section is n/a — no parallelism to measure.

## 8j-quater. Supervisor Decision Health

Read the per-SLUG supervisor-actions JSONL to score how well the persistent supervisor (PWT-T4) performed during this run. Added by PWT-T4 to close the feedback loop between supervisor dispatch decisions and retro assessment. Mirrors §8j-bis (orchestrator) and §8j-ter (fleet) scoring patterns.

```bash
SLUG="<feature-slug>"
SUP_LOG=".claude/state/plan-w-team-supervisor-actions-$SLUG.jsonl"

if [ ! -f "$SUP_LOG" ]; then
  echo "Score: n/a (no supervisor invocation — PLAN_W_TEAM_SUPERVISOR was off or kill switch was on)"
else
  SUP_TOTAL=$(wc -l < "$SUP_LOG" | tr -d ' ')
  SPAWN_DECISIONS=$(grep -c '"event":"spawn_decision"' "$SUP_LOG" 2>/dev/null || echo 0)
  ROUTE_DELEGATIONS=$(grep -c '"event":"route_delegation"' "$SUP_LOG" 2>/dev/null || echo 0)
  ESCALATIONS=$(grep -c '"event":"escalation"' "$SUP_LOG" 2>/dev/null || echo 0)
  LOW_CONFIDENCE_ROUTES=$(jq -r 'select(.event == "route_delegation" and .router_confidence == "low") | .call_site' "$SUP_LOG" 2>/dev/null | wc -l | tr -d ' ')

  STOP_REASON=$(jq -r 'select(.event == "supervisor_stop") | .reason' "$SUP_LOG" 2>/dev/null | tail -1)
  DURATION_S=$(jq -r 'select(.event == "supervisor_stop") | .duration_s' "$SUP_LOG" 2>/dev/null | tail -1)

  cat <<EOF
### Supervisor Decision Health

- Total supervisor actions: $SUP_TOTAL
- Spawn decisions: $SPAWN_DECISIONS
- Route delegations: $ROUTE_DELEGATIONS
- Hard-gate escalations: $ESCALATIONS
- Low-confidence router decisions: $LOW_CONFIDENCE_ROUTES
- Stop reason: $STOP_REASON
- Duration: ${DURATION_S}s

EOF

  # Score: 5 = supervisor ran clean (all-tasks-complete stop, no low-confidence routes,
  #            escalations only on documented hard-gate sites)
  #        4 = 1-2 low-confidence routes; otherwise clean
  #        3 = escalation count > 1 (multiple hard-gates hit in one run) OR 3+ low-confidence
  #        2 = supervisor stopped on error reason
  #        1 = supervisor effectively non-functional (no spawn_decision rows at all)
  if [ "$SPAWN_DECISIONS" -eq 0 ]; then
    SUP_SCORE=1
  elif [[ "$STOP_REASON" == error:* ]]; then
    SUP_SCORE=2
  elif [ "$ESCALATIONS" -gt 1 ] || [ "$LOW_CONFIDENCE_ROUTES" -gt 2 ]; then
    SUP_SCORE=3
  elif [ "$LOW_CONFIDENCE_ROUTES" -ge 1 ]; then
    SUP_SCORE=4
  else
    SUP_SCORE=5
  fi

  echo "Score: $SUP_SCORE/5"

  if [ "$SUP_SCORE" -lt 4 ]; then
    echo "⚠ Supervisor decision quality below threshold — feeding into friction log"
    # Category: supervisor-quality
  fi
fi

# Cleanup on successful retro (mirrors §8j-ter fleet cleanup)
if [ "${RETRO_SUCCESS:-0}" = "1" ]; then
  rm -f "$SUP_LOG"
fi
```

Report in retro: `Supervisor decision health: <SUP_SCORE>/5 (spawns=<N>, delegations=<N>, escalations=<N>, stop=<reason>)`.

A score <4 feeds friction log with category `supervisor-quality`. Recurring low scores suggest the supervisor's system prompt needs refinement — review the action log to identify whether dispatch logic, delegation discipline, or escalation classification was the issue.

## 8j-quinquies. `/goal` Evaluator Health

When `/plan-w-team` was opened with `/goal` at the top (PWT-T5; default unless `PLAN_W_TEAM_DISABLE_GOAL=1`), score how well the evaluator drove the pipeline to a terminal state. Mirrors §8j-bis / §8j-ter / §8j-quater scoring patterns.

```bash
SLUG="<feature-slug>"

# /goal is session-scoped — its state is read via the /goal status command
# or surfaced in the conversation transcript. There is no persistent on-disk
# log; the retro reads the most recent evaluator outcome from the transcript
# (cite the terminal-state block emitted by the helper or supervisor).
#
# If /goal was disabled (PLAN_W_TEAM_DISABLE_GOAL=1) or unavailable
# (pre-2.1.139 Claude Code), report n/a.

if [ "${PLAN_W_TEAM_DISABLE_GOAL:-}" = "1" ]; then
  echo "Score: n/a (PLAN_W_TEAM_DISABLE_GOAL=1 — /goal wrapper skipped)"
else
  # Terminal state is one of: SUCCESS, USER_ESCALATION_HALT, LOW_CONFIDENCE_STREAK, TIME_OR_TURN_CAP
  # The lead surfaces the terminal reason at retro time by quoting /goal's final reason text.

  cat <<EOF
### /goal Evaluator Health

- Terminal state: <SUCCESS|USER_ESCALATION_HALT|LOW_CONFIDENCE_STREAK|TIME_OR_TURN_CAP|n/a>
- Turns evaluated: <N>
- Evaluator reason on terminal turn: <short quote from /goal's "yes" message>
- Pipeline duration: <wall-clock>

EOF

  # Score: 5 = SUCCESS in <100 turns (clean autonomous run)
  #        4 = SUCCESS but >100 turns (verbose evaluator dialog)
  #        3 = USER_ESCALATION_HALT (expected hard-gate; not a failure)
  #        2 = TIME_OR_TURN_CAP (pipeline ran out of budget without finishing)
  #        1 = LOW_CONFIDENCE_STREAK (supervisor was confused, evaluator halted)
  #
  # The lead sets GOAL_SCORE manually after reading the terminal reason.
  # Future enhancement: parse /goal's structured output if Anthropic exposes it.

  echo "Score: <GOAL_SCORE>/5"

  if [ "${GOAL_SCORE:-5}" -lt 4 ]; then
    echo "⚠ /goal evaluator health below threshold — feeding into friction log"
    # Category: goal-evaluator-quality
  fi
fi
```

Report in retro: `/goal evaluator health: <GOAL_SCORE>/5 (terminal=<state>, turns=<N>)`.

A score <4 feeds friction log with category `goal-evaluator-quality`. Recurring low scores suggest either:

- The terminal condition in `shared/goal-conditions.md` is too strict (false negatives — evaluator never says yes even when pipeline is done)
- The transcript-surfacing helpers (status block + supervisor summary block) aren't emitting the anchors the condition looks for
- The pipeline is genuinely stuck (real failures the supervisor should have escalated)

Investigate by reading the most recent supervisor-actions log and the final few `status` / `summary` blocks the helper emitted.

## 8j. Auto-Memory Hints (advisory)

Claude Code 2.1.x ships **Auto Memory** — a per-project memory store at `~/.claude/projects/<project>/memory/` that Claude's memory module manages on its own. The module reads conversation context and decides what's worth persisting. /plan-w-team does **not** write to memory files directly — Claude owns that decision.

What the retro _can_ do is **surface candidate patterns** worth remembering, in the conversation flow that Claude's memory module reads. This sub-step emits 1-2 lines of memory-candidate prose; the module then chooses whether to persist.

### What qualifies as a memory candidate

Pull from §8c quality signals, §8f friction log, §8g evaluator iteration health, and §8i self-assessment notes. The good candidates are **non-obvious, durable, and cross-feature applicable**:

- ✅ A recurring friction mode (e.g., "PostToolUse formatter races with mid-edit reads — Read before re-Edit when the formatter is active") — survives across features.
- ✅ A surprising heuristic that worked (e.g., "Splitting 5 similar implementations into 2 /plan-w-team runs of 2-3 each beat 1 run of 5 every time") — informs future scope decisions.
- ✅ A subtle constraint discovered during build (e.g., "Agent tool's `model` parameter only accepts aliases — full IDs go in agent frontmatter") — easy to forget, costly to relearn.
- ❌ Feature-specific implementation detail (e.g., "the new alerting service uses Redis"). That's in the code and git history.
- ❌ Routine successes ("build passed, tests green"). Not memorable.
- ❌ Anything already documented in CLAUDE.md or a shared/ file. Memory is for what isn't already written down.

### Emission format

Append to the retro narrative — a paragraph headed `### Memory candidates`:

```markdown
### Memory candidates

- **<one-line pattern>** — Why: <reason this pattern emerged>. How to apply: <where this matters next time>.
- **<one-line pattern>** — Why: <…>. How to apply: <…>.
```

Two bullets is the cap. If nothing rises above the bar, write `_(none worth memorializing this run)_` and move on. Pattern-fishing produces noise; the memory module rejects noise on its own, but it wastes the surface.

### Why advisory, not prescriptive

The skill cannot reliably know what is or isn't already in memory — the `~/.claude/projects/<project>/memory/MEMORY.md` index is per-user, not per-repo. Even if the skill could read it, deciding what's worth saving is judgment work the memory module is designed for. /plan-w-team's role is to **surface the signal**; the module decides. If the module ignores the hint, no harm done — the friction log (§8i) and BOARD.md (§Board Comment Auto) remain the skill's authoritative retro outputs.

This sub-step adds zero state files and no enforcement gates. It is pure prose appended to the retro section.

## End-of-Stage Status Block (PWT-T5)

The final action of the retro stage emits the terminal status block — its presence with `stage="retro-complete"` and `workflow_lock="done"` is the SUCCESS anchor the `/goal` evaluator's terminal condition looks for (see `shared/goal-conditions.md` §Terminal-State Reference).

```bash
.claude/scripts/plan-w-team-surface-status.sh "$SLUG" "retro-complete"
```

When this block appears in the transcript, `/goal` evaluator's next turn should return "yes" with `SUCCESS` as the terminal state and clear the goal.

Skip this block entirely when `PLAN_W_TEAM_DISABLE_GOAL=1` (kill switch).
