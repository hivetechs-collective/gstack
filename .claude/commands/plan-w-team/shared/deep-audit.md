# Deep Audit — Agent()-Fan-Out Breadth Analyzer (opt-in)

A read-only breadth sweep the lead may run for breadth-heavy work (codebase-scale
review, exhaustive feature/changelog sweeps, security surface enumeration) within
a `/plan-w-team` run. It fans out read-only analyzer subagents **via the Agent
tool**, collects their findings into one advisory artifact, and lets Step-8 retro
score whether the sweep earned its cost.

## Tier scope (READ FIRST)

- **Tier-1 (this file) = the Agent tool ONLY.** It MUST NOT use the dynamic-workflow
  tool / `/workflows`, and MUST NOT spawn a second orchestrator or supervisor — the
  lead (or the existing supervisor) remains the sole spawner. This preserves the
  DISPATCH INVARIANT and keeps the RAM-gate / fair-share / conflict-detector gates
  authoritative.
- **Tier-2 (deferred)** — driving this sweep with the Workflow tool — stays deferred
  to `/workflows` GA, per the "Dynamic Workflows vs /plan-w-team" note in
  `plan-w-team.md` and `docs/operations/workflow-tool-leverage-evaluation.md`. Do
  NOT add a Workflow-tool engine path here.

## Activation

- Gated by `PLAN_W_TEAM_DEEP_AUDIT=1`. **Default OFF**: when unset (or `!= 1`), the
  lead never reads this file, never spawns the sweep, and the §8e retro reader
  no-ops on the absent artifact — behavior is byte-for-byte unchanged.
- Width clamp: `PLAN_W_TEAM_DEEP_AUDIT_MAX_AGENTS` (default 8). The sweep is still
  subject to the normal RAM-gate / fair-share gates; the clamp is an additional cap.

## Agent roster

Spawn read-only analyzer subagents (Agent tool, `run_in_background: true`), each on
a distinct breadth angle. Use `subagent_type` values that exist in
`shared/agent-roster.md`: `code-review-expert`, `security-expert`,
`documentation-expert`. They read and report only — they do not edit code.

## Output (advisory artifact)

Append one JSON line per finding to `.claude/state/plan-w-team-deep-audit-$SLUG.jsonl`:

```json
{
  "surface": "<area>",
  "agent_type": "<reviewer>",
  "severity": "info|warn|critical",
  "finding": "<one line>"
}
```

The lead may act on findings within the current run, but the artifact's primary
purpose is the §8e retro cost/value score. If a deep-audit sweep ever spawns a
registered child session (rare — it normally uses in-session Agent subagents),
register it via `plan-w-team-register-spawn.sh <sid> deep-audit-spawn <slug>` so
retro cleanup reclaims it.

## Retro

`07-retro.md` §8e ("Deep-Audit Cost") reads `plan-w-team-deep-audit-$SLUG.jsonl`
and reports findings × surfaces × agents, scoring whether the breadth sweep was
worth its token cost. n/a when the sweep did not run (the default).
