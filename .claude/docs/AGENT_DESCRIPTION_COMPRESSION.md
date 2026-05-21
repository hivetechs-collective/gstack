# Agent Description Compression (2026-05-21)

## Summary

Stripped `<example>...</example>` blocks and `Examples:` preamble from the
`description:` frontmatter field of every agent under `.claude/agents/`.

Cumulative description bytes dropped from **~81k bytes (~20k tokens)** to
**~17k bytes (~4.3k tokens)** — an 80% reduction, well under the 15k-token
warning threshold and below the 10k headroom target.

## Why

The original 154-agent library was authored for an `orchestrator` agent that
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

## Future passes

Candidates for follow-up (NOT done in this pass):

- Remove agents not referenced in `agent-roster.md`:
  `claude-code-docs-updater`, `meta-agent`, `mlops-specialist`,
  `opencode-expert`, `skills-expert` (keep `supervisor` — used by /plan-w-team)
- Audit which agents are NEVER spawned by /plan-w-team builders (`stagehand-expert`,
  `whisper-transcription-specialist`, niche-platform specialists)
- Consider tiering the agent catalog into a small "core" set surfaced by
  default and a larger "extended" set loaded on demand via MCP / a tool
  registry.
