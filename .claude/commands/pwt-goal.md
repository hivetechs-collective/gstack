---
description: Derive a structured /goal command from a natural-language request that uses /plan-w-team as the executor. Output is ready to copy-paste at the start of a fresh Claude Code session for autonomous multi-hour runs.
argument-hint: <natural language request> [--type feature|refactor|bugfix|docs] [-i] [--launch]
allowed-tools: Bash, Read
---

# /pwt-goal — Natural-Language → Structured /goal Derivation

Wrap a feature request into a properly-formatted Anthropic `/goal` command that drives an autonomous `/plan-w-team` run with explicit definition-of-done anchors and hard-gate escalations. **No wall-clock or turn caps** — the only stopping points are goal-success and hard-gate halts.

## What this does

Takes your natural-language description of what you want done and outputs the exact `/goal` command string to paste at the start of a fresh `claude` session (or spawns a `claude --bg` worker for you with `--launch`).

The pattern this enables:

```
You: /pwt-goal create a one-page website for a pressure washing service, deploy to cloudflare workers

Agent: [outputs the structured /goal command]

You: copy → open new claude session → paste → walk away for 24h
```

## How to invoke

**Explicit slash command:**

```
/pwt-goal create a website for a pressure washing service. Definition of done: one-page site deployed to cloudflare workers with contact form.
```

**Natural language (auto-detected — see Pattern Recognition below):**

```
use /plan-w-team to create a website for a pressure washing service.
The definition of done is: full functional one page website hosted on cloudflare.
```

When the agent recognizes one of those patterns, it derives the structured `/goal` and outputs it for you to copy. It does NOT immediately invoke `/plan-w-team` — derivation is the goal of this skill.

## Execution

Run the derivation script with the user's natural-language request as the argument:

```bash
.claude/scripts/pwt-goal.sh "<the user's request>"
```

If the user supplied `--type`, `-i`, or `--launch` flags, pass them through. If the user used natural language, infer `--type` from cues:

| Cue in user message                                        | Inferred `--type`                       |
| ---------------------------------------------------------- | --------------------------------------- |
| "refactor", "extract", "rename", "reorganize"              | `refactor`                              |
| "fix the bug", "broken", "regression"                      | `bugfix`                                |
| "update docs", "document", "README"                        | `docs`                                  |
| "continue", "keep going on", "pick up", "resume", "finish" | `continue` (see Continuation Awareness) |
| "what's left", "what remains", "ready for beta/go-live?"   | `status` (see Continuation Awareness)   |
| (anything else)                                            | `feature` (default)                     |

The script outputs the `/goal` command to stdout. Present it to the user verbatim in a code block, labeled clearly so they know to copy and paste.

## Continuation Awareness (Run-State Router Item 4)

Before deriving, run the deterministic run-state detector so a "continue X" request
re-enters the EXISTING run instead of minting a fresh duplicate slug/spec/worktree:

```bash
.claude/scripts/plan-w-team-run-state.sh --topic "<the user's request>" --json
```

Consume the top candidate's `verdict`:

- **`live-now`** → **STAND DOWN**. A worker is already running this slug. Do NOT derive a
  new `/goal`, do NOT spawn — surface the live run to the user (memory:
  concurrent-duplicate-run stand-down). The PWT-WT2 seed guard
  (`pwt-goal.sh --seed-guard-check --goal-file <goal.json> --worker-sid <sid>`) enforces
  this at the process level: exit 0 = permit the seed, exit 3 = refuse (the target is a
  live run owned by another worker). It refuses to clobber a goal-state whose
  `terminal_state` is null unless `--worker-sid` matches the owning worker (idempotent
  re-seed) or `PLAN_W_TEAM_FORCE_SEED=1` is set.
- **matched non-`complete`, non-`live-now`** (`specd`/`mid-execution`/`built-unreviewed`/
  `shipped-unretroed`) → **REUSE that slug** (no fresh hash-slug), anchor the derived
  `feature_specific_done_criteria` to the EXISTING spec's ac-snapshot
  (`.claude/state/plan-w-team-ac-snapshot-<slug>.md`), and route the worker to the
  Step -1 entry stage for that verdict (see `plan-w-team.md` Step -1 table).
- **`complete`, same topic + a NEW ask** → a **delta-spec** run (Step 0/1 scoped to the
  delta; amend or supersede the existing spec).
- **`no-prior`** → brand-new derivation (the pre-feature path, unchanged).

**Seed guard (HARD):** the PWT-WT2 goal-state seed must NEVER clobber a goal-state whose
`terminal_state` is null (a live run) — `__pwt_seed_guard_ok` refuses with a stand-down
message (`PLAN_W_TEAM_FORCE_SEED=1` overrides only when you are certain the run is dead).

**Idempotence:** directive-hash idempotence is preserved; dedup additionally treats a
fuzzy-slug match to an existing non-complete run as "reuse", not "new".

**HARD CONSTRAINT — zero route-hook behavior change:** the detector is invoked from THIS
derivation skill and the manifest Step -1 ONLY. `plan-w-team-route-prompt.sh` NL trigger
detection is untouched — unanchored triggers, no clarifying questions, auto-launch, and
the "/"-prefix skip are all preserved.

## Pattern Recognition (auto-trigger from natural language)

When the user's message matches any of these patterns, route here BEFORE invoking `/plan-w-team` directly:

- `use /plan-w-team to ...`
- `using /plan-w-team ...`
- `with /plan-w-team ...`
- `kick off /plan-w-team for ...`
- `start a /plan-w-team run to ...`
- Any message that says "definition of done" or "done when" alongside `/plan-w-team`

In these cases, the user is describing what they want THE AUTONOMOUS LOOP to do, not asking the agent to run /plan-w-team in this session. The right response is to derive the `/goal` command and present it for copy-paste, not to invoke the skill in-session.

**Exception**: if the user says "use /plan-w-team to **do this right now**" or "invoke /plan-w-team **in this session**" or otherwise clearly wants in-session execution, invoke the Skill tool with skill="plan-w-team" instead.

## Output format

Present the derived command in a fenced code block with clear copy instructions:

````
Here's the /goal command for an autonomous run. Copy and paste at the start
of a fresh `claude` session (or run via `claude --bg "<paste>"`):

```
/goal Use /plan-w-team to ...
[full derived directive]
```

The Haiku evaluator behind /goal will judge the condition each turn; our
self-hosted T5b hook also fires per turn for belt-and-braces autonomy.
You'll get pinged at hard-gate sites (push-ack, secret-scan-allow,
scope-unlock-for-drift) — those intentionally require your confirmation.
````

If `--launch` was specified, the script spawns `claude --bg "<derived goal>"` itself instead of printing — do not also invoke `claude` manually.

## See also

- `.claude/scripts/pwt-goal.sh` — the underlying derivation script
- `shared/goal-conditions.md` §Quick-start — workflow documentation
- `shared/architecture-layers.md` — how /goal + /plan-w-team + supervisor + T5b compose
- `plan-w-team.md` §Autonomous Multi-Hour Runs — cross-reference
