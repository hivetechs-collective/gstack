# Step 8: Retro (Optional but Recommended)

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

## 8h. Untracked Hygiene

Score how well this run handled untracked files. Read the state file written by the Step 5 ship gate:

```bash
SLUG="<feature-slug>"
RETRO_STATE=".claude/state/plan-w-team-retro-$SLUG.json"
# Read untracked_hygiene.resolved counts and deferrals[] from the file
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

If the Step 5 gate ran in degraded mode (no baseline, e.g. `--ship-only` or `--resume`), report `Score: n/a (hygiene-skipped)` instead of scoring 1 — skipping is not the same as failing.

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

1. **Append the friction point** to `.claude/state/plan-w-team-friction-log.jsonl`. Use `flock` because this file is **global** across features — concurrent `/plan-w-team` retros on different features will race on append otherwise:

   ```bash
   LOG=".claude/state/plan-w-team-friction-log.jsonl"
   mkdir -p .claude/state
   # Build the JSON line with jq to guarantee valid escaping, then append under flock.
   LINE=$(jq -cn \
     --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
     --arg feature "$SLUG" \
     --argjson score "$SELF_ASSESSMENT_SCORE" \
     --arg category "$FRICTION_CATEGORY" \
     --arg note "$FRICTION_NOTE" \
     '{timestamp:$ts, feature:$feature, score:$score, category:$category, note:$note}')
   (
     flock -x 9
     printf '%s\n' "$LINE" >> "$LOG"
   ) 9>> "$LOG.lock"
   ```

   `$FRICTION_CATEGORY` must be one of: `spec-gap|builder-struggle|review-noise|hook-friction|hygiene|other`. Reject any other value before the append — unknown categories defeat the 3-in-30-days pattern detection.

2. **After 3 entries in the same category** accumulate within 30 days, surface at the next `/plan-w-team` preflight:

   ```
   ⚠ Friction pattern detected: category=<X> (3+ entries in 30d).
     Review .claude/state/plan-w-team-friction-log.jsonl and consider updating
     the relevant stage file before continuing.
   ```

3. **The user can dismiss with `.claude/state/plan-w-team-friction-ack-<category>`** (touch a file with the category name) if the pattern is intentional or already addressed. Dismissals expire after 30 days — chronic friction resurfaces.

This turns "write-only retro prose" into a lightweight feedback loop that updates the workflow without requiring the user to manually cross-reference old retros.
