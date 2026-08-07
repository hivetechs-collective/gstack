# Agent Description Compression (2026-05-21)

> **SUPERSEDED by the agent-roster restructure (2026-08-06).** This is a historical
> record of a token-budget fix, kept for its reasoning, not as a description of the
> current tree. Every roster number below — the library size, the "91 top-level agent
> files" — describes the pre-restructure repo. `.claude/agents/` now holds **33**
> definitions (`find .claude/agents -mindepth 2 -maxdepth 2 -name '*.md' | wc -l`), and
> the specialist knowledge that made the catalog expensive lives in **16** skill
> directories under `.claude/skills/`, which load progressively instead of at session
> start.
>
> The compression pass attacked the standing description tax by making each of ~150
> descriptions smaller. The restructure attacked it by deleting most of them: a skill's
> trigger description is the only thing that loads until the skill fires. Both were
> aimed at the same cost; the second one subsumes the first.
>
> Current roster: `.claude/commands/plan-w-team/shared/agent-roster.md`.
> Rationale for the agent-vs-skill split:
> `docs/specs/restructure-the-claude-agents-roster-per-anthropic-s-current-subagents-vs-skills-d6f25286.md`.

## Summary

Stripped `<example>...</example>` blocks and `Examples:` preamble from the
`description:` frontmatter field of every agent under `.claude/agents/`.

Cumulative description bytes dropped from **~81k bytes (~20k tokens)** to
**~17k bytes (~4.3k tokens)** — an 80% reduction, well under the 15k-token
warning threshold and below the 10k headroom target.

## Why

The original library — 154 files at the time — was authored for an `orchestrator` that
predated `/plan-w-team`. Each agent file carried 2-3 multi-paragraph
`<example>` blocks inside the YAML `description:` block-scalar. These blocks
served the old orchestrator's natural-language routing — but the agent catalog
loaded at every session start surfaces the entire `description:` field, so the
examples cost ~16k tokens of context per session for routing fidelity that
`/plan-w-team`'s explicit `agent-roster.md` already provides.

## What changed

- All `<example>` / `</example>` / `<commentary>` blocks removed from
  description frontmatter
- Leading `Examples:` lines removed
- Description prose summary preserved (the single paragraph describing the
  agent's domain and when to use it)
- Block-scalar (`description: |`) descriptions kept their block form
- Single-line / inline descriptions kept theirs
- Body content below frontmatter untouched
- `version:` fields preserved unchanged (intentionally — not bumping for a
  mechanical doc-only change)

## What did NOT change

- **No agent files removed.** 91 top-level agent files remain.
- **Core /plan-w-team agents untouched**: `.claude/agents/team/{builder,evaluator,supervisor,validator}.md`
- **Mechanical agents untouched**: `.claude/agents/mechanical/{build-runner,file-scanner,log-parser}.md`
- **Agent roster** (`shared/agent-roster.md`) untouched — every `subagent_type`
  still resolves to an existing file with a non-empty description.
- **Sync script** (`.claude/scripts/sync-to-project.sh`) untouched — the
  `agents/` directory is already in the always-synced set.

## Routing fidelity

The model selecting `subagent_type` for `Agent` tool calls now sees the
one-paragraph prose summary instead of the prose + 2-3 contrived examples.
The summary itself was authored by Anthropic's agent-meta tooling and is
self-contained ("Use this agent when you need to ... Specializes in ...").
No regression expected in supervisor / orchestrator / builder / evaluator /
validator routing because:

1. `/plan-w-team` reads `shared/agent-roster.md` for the canonical
   `subagent_type` table — that file is authoritative for routing.
2. The catalog-loaded descriptions are now closer to a one-line index entry,
   which is what Anthropic's `/agents` UI and the Agent tool's selection
   prompt actually need.

## Script

`.claude/scripts/strip-agent-examples.py` — idempotent. Running it again is a
no-op (no `<example>` blocks remain). Kept in tree as the reference
implementation if future agents reintroduce the pattern.

## Future passes — all three were executed by the 2026-08-06 restructure

Recorded here as candidates in May; closed in August. Disposition:

- _"Remove agents not referenced in `agent-roster.md`"_ — resolved by re-deriving the
  roster from first principles rather than by pruning stragglers.
  `claude-code-docs-updater`, `meta-agent`, and `supervisor` were **kept** (each is
  mandated by a synced stage file). `mlops-specialist`, `opencode-expert`, and
  `skills-expert` became references inside the `ai-engineering` skill.
- _"Audit which agents are NEVER spawned by /plan-w-team builders"_ — done as the
  KEEP/CONVERT/RETIRE classification. `stagehand-expert` was **kept** (it carries a
  binding `tools:` restriction and the UI-TDD writer mandate);
  `whisper-transcription-specialist` became a `media-processing` reference; the
  niche-platform specialists became `native-platforms`, `mobile`, and
  `microsoft-ecosystem` references.
- _"Tier the catalog into a small core surfaced by default and an extended set loaded on
  demand"_ — this is exactly what shipped, using the platform's own mechanism rather
  than MCP or a custom registry: the 33-agent keep tier is the always-loaded core, and
  skills are the on-demand extended set.
