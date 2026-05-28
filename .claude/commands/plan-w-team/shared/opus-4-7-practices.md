# Opus 4.7/4.8 Best Practices (Condensed from Cherny, 2026)

Condensed lessons from Boris Cherny's "Best Practices for Using Claude Opus 4.7 with Claude Code". This file is a local condensation, not a verbatim reproduction of the source — when in doubt, defer to the original guidance. Read this file at the start of any Brain-tier stage (Step 0 scope, Step 1 spec, Step 3-4 execute, Step 5 review) and apply the patterns that match the current task.

> **Opus 4.8 update (2026-05-28, v2.1.154):** The Brain tier is now **Opus 4.8** (`claude-opus-4-8`). Every pattern below still applies. Two deltas: (1) Opus 4.8 **defaults to high effort** and `/effort xhigh` is reachable from the CLI for the hardest tasks — see §5. (2) Opus 4.8 works independently for longer and is more honest about its own progress (flags uncertainty, fewer unsupported claims) — lean into delegate-outcomes (§6) and trust its self-reported blockers in autonomous `/goal` runs. The filename keeps the `-4-7-` slug for backward-compatible references across the skill.

## 1. Front-Load Task Specification

**Rule**: Give Opus 4.7 the full task shape at the start — intent, constraints, acceptance criteria, file locations — instead of revealing requirements progressively.

**Why**: 4.7 reasons better when it can plan the whole problem upfront. Progressive reveal wastes tokens on rework and breaks the plan/execute separation.

**How to apply**:

- When spawning a builder, put all constraints in the initial prompt. Don't drip-feed via SendMessage.
- When writing a spec (Step 1), include the Error & Rescue Map, Shadow Paths, and acceptance criteria in the first draft — these are the constraints 4.7 needs.
- **Front-load the spec, NOT the tools**: Tool Search (Claude Code 2.1.x) defers MCP tool schemas until needed. Builders and reviewers should call `ToolSearch` to load MCP toolsets just-in-time, not eagerly. See `shared/browser-qa.md` "Tool Search: Load Playwright MCP On-Demand" for the canonical pattern. Loading the full Playwright MCP toolset eagerly costs ~5k tokens of schema text per turn — wasted in stages that don't run browser QA (Step 0, 1, 2).

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

**Rule**: Default effort to `high` (Opus 4.8 already defaults to high). On **Opus 4.8** (v2.1.154+), `/effort xhigh` IS reachable from the Claude Code CLI for the hardest Brain-tier tasks — use it for one-way-door reviews and gnarly specs. The earlier limitation (xhigh API-only / unreachable on Max, pre-4.8) is lifted. When xhigh is unavailable (older model, non-CLI host), substitute with prompt-level phrasing per §2 ("think very carefully, consider all edge cases"). Drop to `medium`/`low` only for cost/latency-sensitive narrow tasks.

**Why**: 4.7 balances autonomy and intelligence at high effort without token runaway. Low effort on complex work produces shallow output, and on 4.7 the effort calibration is _stricter_ than 4.6 — `low`/`medium` now scope to exactly what was asked, so under-thinking risk on complex tasks is higher than on prior generations.

**How to apply**:

- Brain-tier work (scope challenge, spec, review, evaluator) → `high` + "think carefully" prompt phrasing to approximate `xhigh`.
- Hands-tier mechanical work (sync scripts, changelog bump, retro metrics) → `medium`.
- One-off triage, log parsing, trivial grep → `low` or Haiku 4.5.
- If you observe shallow reasoning at `high`, **raise effort (or add "think harder")** — do not try to prompt around it with more scaffolding.

## 6. Delegate Like an Engineer, Not a Pair

**Rule**: Opus 4.7 is a _capable engineer_, not a line-by-line pair. Hand off outcomes, not instructions.

**Why**: Micromanaging a 4.7 agent suppresses its planning ability. Describing outcomes lets it choose the right path.

**How to apply**:

- Bad: "Add import on line 5, then call the function on line 42, then update the test on line 100."
- Good: "Wire the new `X` service into the signup flow. Acceptance: signup creates an `X` record, verified by the existing `signup.test.ts`. Update any tests that break."

## 7. Response Length & Tone Calibration

**Rule**: 4.7 calibrates response length to judged task complexity, and produces more direct / less validation-forward prose than 4.6. When you need to steer either dimension, use _positive_ examples (show the desired shape) rather than negative instructions (forbid the undesired shape).

**Why**: 4.7's literalism makes negative instructions brittle — it follows "don't do X" as exactly "don't do X" and may still do X-adjacent. A single positive exemplar ("respond like this: ...") calibrates verbosity and tone in one shot. 4.7 prose is also more direct and less warm by default, which will surface in free-form outputs (retros, ship notes, spec narratives) even when you did not change the prompt.

**How to apply**:

- Tool-call prompts (builder, evaluator): already structured — no action. The machine-fenced verdict block in Step 4b is exactly the positive-exemplar pattern 4.7 wants.
- Free-form prose prompts (`07-retro.md` narrative, `01-specification.md` overview sections, `06-post-ship.md` changelog): if a prior output voice felt too warm or too long, add one short positive exemplar inline rather than adding "be concise" or "avoid enthusiasm".
- If a stage prompt currently says "Provide a detailed report with sections X/Y/Z", that already works. Do not strip it — structured scaffolding is still helpful; only _forced verbosity_ ("write at least 500 words") is now a liability.

## 8. Tokenization Awareness (~1x–1.35x tokens on 4.7)

**Rule**: 4.7 uses a new tokenizer that may produce up to ~35% more tokens than 4.6 for the same text. Treat existing context-percentage thresholds as _approximate_ — they were calibrated on 4.6 tokenization.

**Why**: Our compaction triggers (`03-execute.md` "finish merging current batch… before spawning new agents" at >60%, evaluator skip at >60%) were tuned pre-4.7. On 4.7, 60% measured context may represent materially more "real text" than the same percentage did on 4.6. The thresholds remain safe (conservative direction), but planners should not treat them as tight budgets.

**How to apply**:

- Keep the existing 60% thresholds in `03-execute.md` — they are conservative on 4.7, not reckless.
- When `max_tokens` or output caps are exposed (SDK callers, not Claude Code Max), set them ≥64k when running intelligence-sensitive work. Claude Code on Max does not expose this; no action there.
- When estimating "will this fit in context" for a long spec or retro, add a ~25% buffer vs. prior mental models.
- If you observe compaction firing earlier than expected on 4.7, that is tokenization, not a bug. Tighten the trigger to 50% only if it starts causing real loss; do not preemptively tighten.

## 9. Cross-References

| Lifecycle Stage        | Applied Practices                                   |
| ---------------------- | --------------------------------------------------- |
| Step 0 (Scope)         | §2 adaptive thinking (terse mode)                   |
| Step 1 (Spec)          | §1 front-load, §6 outcome-oriented AC, §7 prose     |
| Step 3-4 (Execute)     | §3 explicit parallelism, §4 auto mode, §6 delegate  |
| Step 4b (Evaluator)    | §1 front-load criteria, §2 think carefully, §7 form |
| Step 5 (Review)        | §2 deep-think Pass 1, quick Pass 2                  |
| Step 6-7 (Ship / Docs) | §5 medium effort, Hands tier, §7 prose calibration  |
| Any long-context stage | §8 tokenization buffer                              |

## 10. What Stays the Same from 4.6

- Context isolation for evaluator (still critical — 4.7 is not immune to bias from builder reasoning)
- Worktree isolation for parallel builders (not a model issue, it's a git hygiene issue)
- WTF-likelihood scoring and fix caps (self-regulation rules apply to all Opus generations)
- PostToolUse validator tolerance (TS6133, no-unused-vars — model-agnostic)
