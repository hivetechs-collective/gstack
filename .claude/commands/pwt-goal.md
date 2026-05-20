---
description: Derive a structured /goal command from a natural-language request that uses /plan-w-team as the executor. Output is ready to copy-paste at the start of a fresh Claude Code session for autonomous multi-hour runs.
argument-hint: <natural language request> [--type feature|refactor|bugfix|docs] [--hours N] [--turns N] [-i] [--launch]
allowed-tools: Bash, Read
---

# /pwt-goal — Natural-Language → Structured /goal Derivation

Wrap a feature request into a properly-formatted Anthropic `/goal` command that drives an autonomous `/plan-w-team` run with explicit definition-of-done anchors, hard-gate escalations, and time/turn caps.

## What this does

Takes your natural-language description of what you want done and outputs the exact `/goal` command string to paste at the start of a fresh `claude` session (or invokes `claude -p` for you with `--launch`).

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

If the user supplied `--type`, `--hours`, `--turns`, `-i`, or `--launch` flags, pass them through. If the user used natural language, infer `--type` from cues:

| Cue in user message                           | Inferred `--type`   |
| --------------------------------------------- | ------------------- |
| "refactor", "extract", "rename", "reorganize" | `refactor`          |
| "fix the bug", "broken", "regression"         | `bugfix`            |
| "update docs", "document", "README"           | `docs`              |
| (anything else)                               | `feature` (default) |

The script outputs the `/goal` command to stdout. Present it to the user verbatim in a code block, labeled clearly so they know to copy and paste.

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
of a fresh `claude` session (or run via `claude -p "<paste>"`):

```
/goal Use /plan-w-team to ...
[full derived directive]
```

The Haiku evaluator behind /goal will judge the condition each turn; our
self-hosted T5b hook also fires per turn for belt-and-braces autonomy.
You'll get pinged at hard-gate sites (push-ack, secret-scan-allow,
scope-unlock-for-drift) — those intentionally require your confirmation.
````

If `--launch` was specified, run `claude -p "<derived goal>"` directly instead of printing.

## See also

- `.claude/scripts/pwt-goal.sh` — the underlying derivation script
- `shared/goal-conditions.md` §Quick-start — workflow documentation
- `shared/architecture-layers.md` — how /goal + /plan-w-team + supervisor + T5b compose
- `plan-w-team.md` §Autonomous Multi-Hour Runs — cross-reference
