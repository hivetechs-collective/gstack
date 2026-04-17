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
