# Step 5: Fix-First Review

**Opus 4.7 tip**: Pass 1 (CRITICAL) benefits from deep adaptive thinking ("think carefully about security implications"). Pass 2 (INFORMATIONAL) benefits from terse thinking ("prioritize responding quickly — just list findings"). See `shared/opus-4-7-practices.md` §2.

After builders complete, worktrees are merged, and the evaluator loop (Step 4b) has run, perform a two-pass review on the full diff.

## Board Update (Auto)

Move the feature card to Review and add a review summary comment. Fire-and-forget — failures must NOT block the review.

```bash
scripts/board.sh move "<feature-name>" "Review" || true
```

After the review completes (Pass 1 + Pass 2), add findings as a comment:

```bash
scripts/board.sh comment "<feature-name>" "## Review Complete

### Pass 1 — Critical Findings
<list of blockers found and fixed, or 'None'>

### Pass 2 — Informational
<list of non-blocking observations, or 'None'>

### Auto-Fixed
<count> items auto-fixed (dead code, unused imports, etc.)

### Evaluator Report
<PASS | PASS with notes | ESCALATE | N/A>

**Reviewed:** $(date -u +%Y-%m-%dT%H:%M:%SZ)" || true
```

## 5-pre. Evaluator Report Input (if available)

If the evaluator loop ran in Step 4b, check task metadata for the evaluator report:

```
TaskGet -> metadata.evaluator_report
```

| Evaluator Outcome                                                     | Review Adjustment                                                                                                                                             |
| --------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **All PASS** (all criteria met)                                       | Lighten review — evaluator already validated functionality. Focus Pass 1 on security/race conditions only. Skip Pass 2 informational items unless suspicious. |
| **PASS with notes** (criteria met but evaluator flagged observations) | Standard review, but prioritize evaluator's flagged areas in Pass 1.                                                                                          |
| **ESCALATE** (evaluator couldn't get builder to pass)                 | Intensify review — read evaluator's failure report first. The failures it flagged are likely real issues. Present to user as ASK items.                       |
| **No report** (evaluator skipped or no contract)                      | Standard review — full Pass 1 + Pass 2 (backward compatible).                                                                                                 |

The evaluator report is an input to the review, not a replacement for it. The review still catches classes of issues the evaluator doesn't check (security, race conditions, one-way door validation).

## 5a. Fetch Latest Base and Compute Diff

```bash
git fetch origin <base> --quiet
git diff origin/<base>...HEAD
```

## 5b. Pass 1 — CRITICAL (blockers, must fix before ship)

| Check                    | What to Look For                                                                  |
| ------------------------ | --------------------------------------------------------------------------------- |
| SQL safety               | Raw string interpolation in queries, missing parameterization                     |
| Race conditions          | TOCTOU (time-of-check-time-of-use) patterns, shared mutable state                 |
| LLM trust boundaries     | User input passed directly to prompts without sanitization                        |
| Conditional side effects | Database writes, API calls, notifications buried in conditionals                  |
| Time window safety       | Operations assuming time relationships without handling timezone, clock skew, DST |
| One-way door validation  | Extra scrutiny for tasks tagged `door_type: "one-way"`                            |
| Error handling           | Catch-all handlers, swallowed errors, missing error types from Error & Rescue Map |

## 5c. Pass 2 — INFORMATIONAL (fix or note, not blockers)

| Check                  | What to Look For                                                         |
| ---------------------- | ------------------------------------------------------------------------ |
| Dead code              | New functions never called, unreachable branches introduced in this diff |
| Magic numbers          | Unexplained numeric literals                                             |
| Missing error handling | Unhappy paths not covered                                                |
| Stale comments         | Comments that no longer match the code                                   |
| N+1 queries            | Database queries in loops                                                |
| Unused imports         | Imports added but not used                                               |

## 5d. Fix-First Heuristic — Classify Each Finding

| Classification | Action                         | Examples                                                                                                             |
| -------------- | ------------------------------ | -------------------------------------------------------------------------------------------------------------------- |
| **AUTO-FIX**   | Fix immediately without asking | Dead code removal, unused imports, stale comments, missing error handling (mechanical), N+1 queries, missing indexes |
| **ASK**        | Present to user for decision   | Security policy decisions, race condition fixes that change behavior, architectural changes, design pattern changes  |

Auto-fix all AUTO-FIX items. Batch remaining ASK items and present them together.

### Spawning Fix Agents

When spawning parallel agents to fix review findings:

1. **Re-record BASE_SHA**: `BASE_SHA=$(git rev-parse HEAD)` — the main branch has moved since the original build phase. Fix agents MUST branch from the current HEAD, not the original base.
2. **Prune old worktrees first**: `git worktree prune` to remove any leftover build-phase worktrees.
3. **Assign shared files to ONE fix agent**: If multiple fixes touch the same file, group them into one agent. Do NOT split fixes for the same file across multiple agents — this was the #1 source of merge coordination pain in the factory-orchestrator retro.
4. **Prefer fixing on main directly** for small fixes (1-3 lines): spawning a worktree for a one-line fix adds overhead. Only use worktree isolation when the fix is substantial enough to benefit from parallel execution.

## 5e. Review Suppressions — Do NOT Flag These

1. Redundancy that aids readability (e.g., explicit type annotations TypeScript could infer)
2. Threshold comments that will rot ("TODO: adjust this threshold")
3. Consistency-only changes (changing something just to match style elsewhere with no functional benefit)
4. Test code style (tests can be verbose and repetitive for clarity)
5. Generated code style
6. Framework boilerplate
7. Import ordering preferences
8. Comment density preferences
9. Variable naming that follows existing codebase conventions

## 5f. Design Review Lite (conditional)

Only run if any task has `scope: "FRONTEND"`. Skip entirely for backend-only changes.

If the browse binary is available, read `shared/browser-qa.md` for browser-based visual testing instructions.

If triggered, check for AI Slop — these 10 anti-patterns indicate generic AI-generated design:

1. Purple gradients (the default "AI aesthetic")
2. 3-column feature grids (lazy landing page pattern)
3. Icons in colored circles (clip-art energy)
4. Centered everything (no visual hierarchy)
5. Uniform bubbly border-radius (looks like a toy)
6. Decorative blobs/shapes (filling space without purpose)
7. Emoji as design elements (substituting for real iconography)
8. Colored left-border cards (Bootstrap default)
9. Generic hero copy ("Welcome to the future of...")
10. Cookie-cutter section rhythm (alternating left-right layouts with identical spacing)

Use design critique vocabulary for findings:

- "I notice..." (observation, no judgment)
- "I wonder..." (question, opens exploration)
- "What if..." (suggestion, non-prescriptive)
- "I think...because..." (opinion with evidence)

## 5g. E2E Failure Blame Protocol

If any test fails during review, NEVER claim "not related to our changes" without proving it by running the same test on the base branch first. Confirmation bias is the enemy.
