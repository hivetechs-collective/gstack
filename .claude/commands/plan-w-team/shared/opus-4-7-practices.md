# Opus 4.7 → 5.5 Best Practices (Condensed from Cherny, 2026)

Condensed lessons from Boris Cherny's "Best Practices for Using Claude Opus 4.7 with Claude Code". This file is a local condensation, not a verbatim reproduction of the source — when in doubt, defer to the original guidance. Read this file at the start of any Brain-tier stage (Step 0 scope, Step 1 spec, Step 3-4 execute, Step 5 review) and apply the patterns that match the current task.

> **Opus 4.8 update (2026-05-28, v2.1.154):** The Brain tier is now **Opus 4.8** (full model ID in the skill manifest's canonical Model Strategy table). Every pattern below still applies. Two deltas: (1) Opus 4.8 **defaults to high effort** and `/effort xhigh` is reachable from the CLI for the hardest tasks — see §5. (2) Opus 4.8 works independently for longer and is more honest about its own progress (flags uncertainty, fewer unsupported claims) — lean into delegate-outcomes (§6). Use its self-reports as **non-terminal corroboration only**: an objective, user-verifiable metric (commits, AC-pass count, open PRs) still governs the STALL-ALERT decision per the durable anti-gaming rule in `supervisor-protocol.md` §"Progress Check" ("measured objectively, never self-reported"). A self-reported blocker informs your read; it never overrides the objective verdict at the terminal force-action point. The filename keeps the `-4-7-` slug for backward-compatible references across the skill.

> **Opus 5.5 update (2026-09-22, skill 2.50.0, Model Tiering v8 → v9) — READ FIRST.** The Brain tier is now **Opus 5.5** (`claude-opus-5-5`); Opus 5 (`claude-opus-5`, exactly) stays forbidden. The Opus 5 banner below remains the prompting baseline — Anthropic's migration guide says Opus 5 patterns carry over. Deltas that matter to this pipeline:
>
> - **Effort: the API default is `medium`; automated work here runs `high`** (Model Tiering v9, operator ruling 2026-09-22; v8's `xhigh` retired) — the synced `effortLevel`, bg `PWT_BG_EFFORT`, and every team-agent frontmatter pin. 5.5 thinks _more_ per level than Opus 5 (most at `xhigh`/`max`), and 5.5 at `medium` already matches Opus 5 at `high` on coding (§5). Interactive sessions are the operator's own (ultracode).
> - **Thinking cannot be disabled** (400) and forced `tool_choice` `any`/`tool` returns 400 — the pipeline uses neither.
> - **Text between tool calls arrives as progress-update thinking blocks** — do not parse inter-tool assistant text as a status channel.
> - **Unattended runs may end a turn with a progress report instead of finishing.** A text-only `end_turn` is a report, not completion — the evaluator's rule already treats it that way; supervisors auto-continue (Anthropic suggests 2–3 continuations).
> - **Time-budget signals** ("you have ~N minutes") speed multi-agent work; stating the budget in a spawn prompt is legitimate.
> - **Prompt-injection resistance is stronger with delimited untrusted input** — wrap pasted/external content (issue bodies, web text) in a clearly tagged block.
> - **No Fable (v9).** Fable 5.1 is retired from every role and fallback; a bg lane that loses Opus 5.5 steps down `claude-opus-4-8,claude-sonnet-5`. The server-side fallback does **not** retry `reasoning_extraction` refusals.

> **Opus 5 update (2026-07-25) — READ BEFORE §3, §5 AND §7.** The Brain tier rolled to **Opus 5** in skill 1.58.0. Treat the 4.8 banner above as history: its tiering _rationale_ still holds, but its blanket claim that "every pattern below still applies" does **not**. Anthropic's published Opus 5 prompting guidance inverts three of them:
>
> - **§3 delegation is INVERTED — §3 has been rewritten below.** Opus 4.7/4.8 under-delegated and needed an explicit push to fan out. Opus 5 delegates _more_ readily and must be **bounded**, not encouraged.
> - **§5 effort — REVISED 2026-07-26.** Now says: start `xhigh` for coding/agentic and `high` elsewhere, then sweep _downward_ against evals. `low`/`medium` are unusually strong on Opus 5 and are the primary cost/latency control. The old 4.7-scoped under-thinking warning is gone.
> - **§7 length — REVISED 2026-07-26.** Now says: an explicit length instruction is a legitimate instrument (a positive exemplar is an addition, not a substitute), written deliverables need their own calibration separate from conversational output, and `effort` does **not** reliably shorten visible output.
>
> Opus 5 also **self-verifies without being asked**: do not add "double-check your work", "re-verify before responding", or a verify-with-a-subagent step to any stage prompt — on this model they compound with the behavior and buy nothing. This does **not** touch deterministic gates (test suites, `tsc --noEmit`, the ship gate's exit code): those are not model self-verification and stay exactly as they are.

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

## 3. Bounding Subagent Spawning (INVERTED on Opus 5)

**Rule**: Opus 5 delegates readily on its own. Your job is to **bound** delegation, not to encourage it. Spawn only when the work is genuinely independent and sizeable; otherwise do it inline.

**Why**: This reverses what this section said for 4.7/4.8. Those generations under-delegated, so the old advice was to say "spawn N parallel builders" explicitly. On Opus 5 that same phrasing pushes an already-eager delegator into fan-out for work it could finish in a handful of tool calls — and every subagent re-establishes context, re-explores, reports back, and then costs the lead another read to absorb the report.

**How to apply**:

- **Warrant test — delegate only when all three hold**: (1) the tracks touch disjoint files with no shared state, (2) each track is more than a handful of tool calls, (3) the results don't have to be read together to make sense.
- **Prefer one subagent over several.** If one agent can do the job, use one. Keep spawn counts low.
- **Never delegate verification of your own work.** Opus 5 self-verifies, so a verify-subagent is pure duplicated cost. Structurally independent review is a _different thing and stays_: the Step-5 reviewer fan-out is valuable precisely because those reviewers never saw the builder's reasoning.
- **For tightly-coupled work, say "implement sequentially — do not spawn subagents".** This half of the original guidance is unchanged and still worth stating explicitly.
- Treat the deterministic caps as a backstop, not a target: the `03-execute.md` batch cap, the `shared/deep-audit.md` fan-out cap, the `agents/team/supervisor.md` ceiling, and the `--bg` worker caps in `.claude/scripts/pwt-goal.sh`. Sitting at the cap by default is the failure mode this section now exists to prevent.

## 4. Auto Mode + Completion Hooks

**Rule**: Auto mode is the default for Steps 3-4 when full context is supplied. Pair with completion notifications so you aren't polling.

**Why**: 4.7 with full upfront context runs reliably without permission prompts. Polling wastes your attention budget.

**How to apply**:

- `/plan-w-team` builders run uninterrupted via the session `defaultMode: bypassPermissions`. The Agent-tool `mode:` parameter that previously expressed this is **deprecated and ignored** as of CLI 2.1.212 — do not pass it.
- For long runs, wire desktop notifications via the existing `.claude/hooks/desktop-notify.sh` hook — no manual polling.
- Use `run_in_background: true` for evaluator/builder spawns and rely on completion notifications.

## 5. Effort Levels: Start High, Then Sweep DOWN (revised for Opus 5)

**Rule**: Start at `xhigh` for coding and agentic work and `high` elsewhere, then **sweep downward against your own evals**. On Opus 5, `low` and `medium` are unusually strong — they are the primary cost and latency control, not a quality risk to be avoided. `/effort xhigh` is reachable from the CLI; `max` exists for genuinely hard, latency-insensitive work and can overthink simpler tasks.

**Why**: this reverses the 4.7-era framing that used to sit here. On 4.7 the effort calibration was strict enough that `low`/`medium` scoped to exactly what was asked, so dropping effort carried real under-thinking risk and the safe move was to stay high. Opus 5 raises the floor: lower effort often matches what a prior generation produced at `xhigh`. Treating `high` as an unexamined default now overspends the weekly Max budget for no measured gain — and effort defaults inherited from a previous model are rarely the right setting after a generation rollover.

**Note the one thing effort does NOT do**: it does not reliably shorten _visible_ output on Opus 5. Length is a prompting problem (§7), not an effort dial.

**How to apply**:

- **In this pipeline (Model Tiering v9, operator ruling 2026-09-22): every automated lane runs `high`** — Brain-tier Opus 5.5 and the Sonnet 5 Hands lanes alike; `xhigh`/`max` are for the attended interactive lead only (the operator overrides per session). The generic Rule above still decides where to sweep *down* from `high`: keep the lowest level your evals still pass.
- **Run the sweep at every model rollover.** Opus 5.5 arrived in skill 2.50.0; v8 raised the pins to `xhigh` and v9 set them back to `high`, both by operator order, not by a sweep — treat `high` as the ceiling to sweep down from. Sweep the cheapest stages first (Step 0 scope challenge, Step 8 retro) where a wrong call is visible and harmless, and record per-stage results so the next rollover starts from evidence rather than habit.
- The evaluator runs `high` like every automated lane — a throughput-sensitive per-iteration loop, so it is the first place to try `medium` in a sweep, never the place to spend `xhigh`.
- Structural pins (skill 1.52.2/1.52.3 onward; `high` since 2.50.0 / Model Tiering v9): `effort: high` in frontmatter on the team pipeline agents (builder, builder-opus, evaluator, validator, supervisor, silent-failure-hunter) plus the two named Hands specialists. These insulate them from session-level effort bleed in **both** directions — a `max` lead cannot silently escalate them, and a `low` lead cannot silently degrade them. Change a pin deliberately in claude-pattern; the sweep above is how you decide to. Roster-specialist-routed tasks still inherit session effort (documented residual — manifest pinning item 3).
- Hands-tier mechanical work (sync scripts, changelog bump, retro metrics) → `medium`, and try `low`.
- One-off triage, log parsing, trivial grep → `low` or Haiku 4.5.
- If you observe shallow reasoning, **raise effort one rung** — do not prompt around it with more scaffolding. But check the next bullet first, because raising effort is the wrong lever for the more common failure.
- **Effort fixes trying-harder failures only** (skipped files, unrun tests, bailed refactors). If the model had full context, clearly tried, and was still _confidently wrong_, raise the **model** (hard lane / Brain tier), not the effort — more effort on the same model buys a more elaborate wrong answer. See the escalation diagnostic in `04-fix-first-review.md` (Anthropic, "knowing more vs. trying harder").

## 6. Delegate Like an Engineer, Not a Pair

**Rule**: Opus 4.7 is a _capable engineer_, not a line-by-line pair. Hand off outcomes, not instructions.

**Why**: Micromanaging a 4.7 agent suppresses its planning ability. Describing outcomes lets it choose the right path.

**How to apply**:

- Bad: "Add import on line 5, then call the function on line 42, then update the test on line 100."
- Good: "Wire the new `X` service into the signup flow. Acceptance: signup creates an `X` record, verified by the existing `signup.test.ts`. Update any tests that break."

## 7. Response Length & Tone Calibration

**Rule**: On Opus 5, an **explicit** length instruction is a legitimate and effective instrument. State the target directly; a positive exemplar is a useful _addition_, not a substitute. Two separate dimensions need steering, and the second is the one this repo keeps getting wrong:

1. **Conversational output** — what the model says back. Prompting cuts it materially.
2. **Written deliverables** — files the model writes to disk (specs, retros, changelogs, docs). Opus 5 pads these by default with filler sections, redundant summaries and boilerplate. This dimension needs its own instruction; the conversational one does not cover it.

**Why**: this supersedes the 4.7-era advice that used to sit here ("use a positive exemplar _rather than_ saying 'be concise'"). That was right when literalism made negative instructions brittle. On Opus 5 a direct conciseness instruction works, and withholding one just leaves the default verbosity in place. Critically, **`effort` does not reliably shorten visible output** — reaching for a lower effort level to get shorter prose changes thinking spend without changing length. Length is a prompting problem.

**How to apply**:

- Tool-call prompts (builder, evaluator): already structured — no action. The machine-fenced verdict block in Step 4b is the right shape.
- Free-form prose prompts: state the target plainly, and add a short positive exemplar alongside it if the shape matters. Both, not either.
- **Long stage prompts need a tail reminder.** A conciseness instruction near the top of a long prompt gets diluted; repeat it in one line near the END.
- **Calibrate written deliverables explicitly** — see `06-post-ship.md` §7a for the worked pattern (match the replaced section's length, no unrequested summary/overview/further-reading sections). Apply the same to `01-specification.md` overview sections and the `07-retro.md` narrative.
- Structured scaffolding still helps: "Provide a report with sections X/Y/Z" is fine and should not be stripped. Only _forced_ verbosity ("write at least 500 words") is a liability.

## 8. Tokenization Awareness (~1x–1.35x tokens on 4.7)

**Rule**: 4.7 uses a new tokenizer that may produce up to ~35% more tokens than 4.6 for the same text. Treat existing context-percentage thresholds as _approximate_ — they were calibrated on 4.6 tokenization.

**Why**: Our compaction triggers (`03-execute.md` "finish merging current batch… before spawning new agents" at >60%, evaluator skip at >60%) were tuned pre-4.7. On 4.7, 60% measured context may represent materially more "real text" than the same percentage did on 4.6. The thresholds remain safe (conservative direction), but planners should not treat them as tight budgets.

**How to apply**:

- Keep the existing 60% thresholds in `03-execute.md` — they are conservative on 4.7, not reckless.
- When `max_tokens` or output caps are exposed (SDK callers, not Claude Code Max), set them ≥64k when running intelligence-sensitive work. Claude Code on Max does not expose this; no action there.
- When estimating "will this fit in context" for a long spec or retro, add a ~25% buffer vs. prior mental models.
- If you observe compaction firing earlier than expected on 4.7, that is tokenization, not a bug. Tighten the trigger to 50% only if it starts causing real loss; do not preemptively tighten.

## 9. Cross-References

| Lifecycle Stage        | Applied Practices                                                                |
| ---------------------- | -------------------------------------------------------------------------------- |
| Step 0 (Scope)         | §2 adaptive thinking (terse mode)                                                |
| Step 1 (Spec)          | §1 front-load, §6 outcome-oriented AC, §7 prose                                  |
| Step 3-4 (Execute)     | §3 **bounded** parallelism (warrant test), §4 auto mode, §6 delegate             |
| Step 4b (Evaluator)    | §1 front-load criteria, §2 think carefully, §7 form                              |
| Step 5 (Review)        | §2 deep-think Pass 1, quick Pass 2                                               |
| Step 6-7 (Ship / Docs) | §5 medium effort, lead session (Hands delegation optional), §7 prose calibration |
| Any long-context stage | §8 tokenization buffer                                                           |

## 10. What Stays the Same from 4.6

- Context isolation for evaluator (still critical — 4.7 is not immune to bias from builder reasoning)
- Worktree isolation for parallel builders (not a model issue, it's a git hygiene issue)
- WTF-likelihood scoring and fix caps (self-regulation rules apply to all Opus generations)
- PostToolUse validator tolerance (TS6133, no-unused-vars — model-agnostic)
