# Create Agent Command

Create a new Claude Code agent definition using the meta-agent.

## Usage

```
/create-agent [description of the agent you want]
```

## Gate 0: Should this be a skill instead? (MANDATORY, answer first)

Most requests that arrive here are not agents. Answer this before anything else,
and say the answer out loud in your response:

| What the request is really made of                                                                          | Build a…  |
| ----------------------------------------------------------------------------------------------------------- | --------- |
| Knowledge about a technology, framework, provider, or domain                                                | **skill** |
| Procedures, checklists, conventions, worked examples                                                        | **skill** |
| Reference material someone will need _while already doing something else_                                   | **skill** |
| Work that must run in an **isolated context** (a reviewer that must not see the writer's reasoning)         | agent     |
| Work that needs a **binding tool restriction** (read-only auditor; a writer limited to `tools: Read,Write`) | agent     |
| Work that needs a **model or effort pin** different from the session's                                      | agent     |
| A slot a stage file spawns **by name**                                                                      | agent     |

**The test**: if the only thing the new definition adds is _knowing more about X_, it
is a skill — an agent would pay a separate session's context for knowledge that a
skill loads for free inside the session already doing the work. Agents exist for
session boundaries, not for expertise.

If the answer is "skill", stop here and author
`.claude/skills/<domain>/SKILL.md` (add a `references/<topic>.md` if the material is
long) instead of invoking the meta-agent. Check first whether one of the 16 existing
domain skills already covers it — extending a skill beats adding one.

## Gate 1: The keep list is deliberate

`.claude/agents/` holds exactly 33 definitions, and that set is asserted by
`tests/skill/cases/agent-roster-keep-list.bats`. Adding an agent **fails that test
until you edit the keep list**. That is the design, not an obstacle: it makes roster
growth an explicit decision rather than a drift. If you genuinely need a 34th agent,
edit the keep list in the same commit and say why in the commit message.

## Process

1. Pass Gate 0 — state which of the four agent reasons applies.
2. The meta-agent analyzes your request.
3. Search existing agents AND the 16 domain skills for duplicates or near-matches.
4. Generate a properly formatted agent definition.
5. Place it in the correct `.claude/agents/` subdirectory.
6. Edit `tests/skill/cases/agent-roster-keep-list.bats` to admit the new name.
7. Report the created file path and the keep-list edit.

## Examples

```
/create-agent A read-only reviewer that audits migrations without write access
/create-agent A Haiku-pinned agent that only tails and filters build logs
```

Counter-examples — these are **skills**, and `/create-agent` should refuse them:

```
/create-agent A Python testing specialist that writes pytest tests
    → knowledge; unit-testing-specialist already owns test-first work
/create-agent A Kubernetes deployment agent for managing Helm charts
    → knowledge; extend the devops-delivery skill
/create-agent A performance profiling agent for Node.js applications
    → knowledge; performance-testing-specialist owns the domain
```

## Notes

- All agents are created with proper YAML frontmatter
- Model defaults to `claude-opus-4-8` (explicit id; never the bare `opus` alias, which resolves to Opus 5) unless specified otherwise
- Disallowed tools are set based on the agent's intended role — and if there is no
  restriction to express, that is a signal it should have been a skill
- The meta-agent checks for existing similar agents **and skills** before creating
