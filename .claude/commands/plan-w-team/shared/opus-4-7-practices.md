# Opus 4.7 Best Practices (Condensed from Cherny, 2026)

Condensed lessons from Boris Cherny's "Best Practices for Using Claude Opus 4.7 with Claude Code". This file is a local condensation, not a verbatim reproduction of the source — when in doubt, defer to the original guidance. Read this file at the start of any Brain-tier stage (Step 0 scope, Step 1 spec, Step 3-4 execute, Step 5 review) and apply the patterns that match the current task.

## 1. Front-Load Task Specification

**Rule**: Give Opus 4.7 the full task shape at the start — intent, constraints, acceptance criteria, file locations — instead of revealing requirements progressively.

**Why**: 4.7 reasons better when it can plan the whole problem upfront. Progressive reveal wastes tokens on rework and breaks the plan/execute separation.

**How to apply**:

- When spawning a builder, put all constraints in the initial prompt. Don't drip-feed via SendMessage.
- When writing a spec (Step 1), include the Error & Rescue Map, Shadow Paths, and acceptance criteria in the first draft — these are the constraints 4.7 needs.

## 2. Adaptive Thinking (Don't Fix the Budget)

**Rule**: 4.7 decides when to think. You guide _intent_, not token budget.

- For hard problems: "think carefully step-by-step" or "think harder about edge cases".
- For overthinking failure modes: "prioritize responding quickly" or "do not over-plan — start with the simplest change".

**Why**: Fixed thinking budgets from older models don't transfer. 4.7 optimizes thinking naturally if you signal intent.

**How to apply**:

- Scope Challenge (Step 0): default to terse thinking — it's a gate, not a design session.
- Fix-First Review (Step 5): signal deep thinking for Pass 1 CRITICAL checks; signal quick response for Pass 2 informational items.

## 3. Deliberate Subagent Spawning

**Rule**: 4.7 is _more judicious_ than 4.5/4.6 about spawning subagents. If you want parallelism, say so explicitly.

**Why**: Prior Opus generations over-delegated. 4.7 defaults to doing the work itself unless the prompt signals the work is independent/fan-out-able.

**How to apply**:

- In Step 3 execution, use the phrase "spawn N parallel builders" (not "you may want to parallelize").
- For independent file operations, state "these tasks are fully independent — fan out".
- For tightly-coupled work, say "implement sequentially — do not spawn subagents".

## 4. Auto Mode + Completion Hooks

**Rule**: Auto mode is the default for Steps 3-4 when full context is supplied. Pair with completion notifications so you aren't polling.

**Why**: 4.7 with full upfront context runs reliably without permission prompts. Polling wastes your attention budget.

**How to apply**:

- `/plan-w-team` sets `mode: "auto"` for builders by default (already present).
- For long runs, wire desktop notifications via the existing `.claude/hooks/desktop-notify.sh` hook — no manual polling.
- Use `run_in_background: true` for evaluator/builder spawns and rely on completion notifications.

## 5. Effort Levels: Default High, Drop Deliberately

**Rule**: Default effort to `high` (or `xhigh` where the runtime exposes it). Drop to `medium`/`low` only for cost/latency-sensitive narrow tasks.

**Why**: 4.7 balances autonomy and intelligence at high effort without token runaway. Low effort on complex work produces shallow output.

**How to apply**:

- Brain-tier work (scope challenge, spec, review, evaluator) → `high`.
- Hands-tier mechanical work (sync scripts, changelog bump, retro metrics) → `medium`.
- One-off triage, log parsing, trivial grep → `low` or Haiku 4.5.

## 6. Delegate Like an Engineer, Not a Pair

**Rule**: Opus 4.7 is a _capable engineer_, not a line-by-line pair. Hand off outcomes, not instructions.

**Why**: Micromanaging a 4.7 agent suppresses its planning ability. Describing outcomes lets it choose the right path.

**How to apply**:

- Bad: "Add import on line 5, then call the function on line 42, then update the test on line 100."
- Good: "Wire the new `X` service into the signup flow. Acceptance: signup creates an `X` record, verified by the existing `signup.test.ts`. Update any tests that break."

## 7. Cross-References

| Lifecycle Stage        | Applied Practices                                  |
| ---------------------- | -------------------------------------------------- |
| Step 0 (Scope)         | §2 adaptive thinking (terse mode)                  |
| Step 1 (Spec)          | §1 front-load, §6 outcome-oriented AC              |
| Step 3-4 (Execute)     | §3 explicit parallelism, §4 auto mode, §6 delegate |
| Step 4b (Evaluator)    | §1 front-load criteria, §2 think carefully         |
| Step 5 (Review)        | §2 deep-think Pass 1, quick Pass 2                 |
| Step 6-7 (Ship / Docs) | §5 medium effort, Hands tier                       |

## 8. What Stays the Same from 4.6

- Context isolation for evaluator (still critical — 4.7 is not immune to bias from builder reasoning)
- Worktree isolation for parallel builders (not a model issue, it's a git hygiene issue)
- WTF-likelihood scoring and fix caps (self-regulation rules apply to all Opus generations)
- PostToolUse validator tolerance (TS6133, no-unused-vars — model-agnostic)
