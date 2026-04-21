# Skill Permission Convention

Every skill under `.claude/commands/<skill>/` or `.claude/skills/<skill>/` SHOULD document the tools and path patterns it needs, so the allow-list in `.claude/settings.json` can be audited against actual usage.

## Why this exists

Before this convention: multi-agent skills like `/plan-w-team`, `/qa-scaffold`, `/qa-backfill` spawned subagents that touched new file patterns (`.claude/state/**`, fixture dirs, writing Playwright specs), generating permission prompts at the lead agent view. Users clicked "Yes, always" many times per session. The prompts were noise, not safety — every path was legitimately in-scope for the skill.

After this convention: each skill declares what it needs. The base `settings.json` ships a broad allow-list that subsumes every documented need. When a new skill is added or an existing skill's scope changes, the declaration in the skill's README is the single source of truth for "what does this skill touch."

## Declaration format

Add a `## Tool Permissions` section near the top of the skill's top-level `README.md` (or equivalent entry file like `SKILL.md`):

```markdown
## Tool Permissions

This skill requires the following tools. All are covered by the base allow-list in
`.claude/settings.json` — no per-project `settings.local.json` configuration needed.

| Tool category | Specific use                                           |
| ------------- | ------------------------------------------------------ |
| `Read`        | Read `.claude/qa-profile.json`, route files, templates |
| `Write`       | Emit specs, page objects, state files                  |
| `Edit`        | Update existing files when `--overwrite` is passed     |
| `Glob`        | Enumerate route files across `app/routes/**`           |
| `Grep`        | Find existing tests to avoid duplication               |
| `Bash`        | `mkdir -p`, `find`, `shasum`, `jq`, `rsync`            |
| `Agent`       | Spawn builder agents in worktree-isolated teams        |

**State & output paths touched:**

- `.claude/state/<skill-name>-*.json` — stage outputs, idempotence markers
- `<test_dir>/backfilled/**` — generated specs (if applicable)
- `<test_dir>/pages/backfilled/**` — generated page objects (if applicable)
```

Keep the table concise — the point is an inventory, not an essay.

## Base allow-list coverage

The base `.claude/settings.json` shipped by `claude-pattern` covers all common skill needs:

| Category      | Allow-list entries                                                                                                                     |
| ------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| File tools    | `Read(*)`, `Write(*)`, `Edit(*)`, `Glob(*)`, `Grep(*)`                                                                                 |
| Shell (build) | `Bash(pnpm *)`, `Bash(npm *)`, `Bash(npx *)`, `Bash(turbo *)`, `Bash(cargo *)`, `Bash(tsx *)`, `Bash(tsc *)`, `Bash(prettier *)`, etc. |
| Shell (fs)    | `Bash(mkdir *)`, `Bash(find *)`, `Bash(ls *)`, `Bash(cp *)`, `Bash(mv *)`, `Bash(chmod *)`, `Bash(cat *)`                              |
| Shell (data)  | `Bash(awk *)`, `Bash(sed *)`, `Bash(jq *)`, `Bash(shasum *)`                                                                           |
| Shell (git)   | `Bash(git *)`, `Bash(gh *)`                                                                                                            |
| Agent tools   | `Agent(*)`, `TeamCreate`, `TeamDelete`, `TaskCreate`, `TaskList`, `TaskGet`, `TaskUpdate`, `TaskStop`, `SendMessage`                   |
| Catch-all     | `Bash(*)` — broad safety net; `PreToolUse` hooks (damage-control, pre-commit-quality, block-protected-paths) still fire as guardrails  |

`PermissionRequest` hooks also auto-approve `Read/Write/Edit/Glob/Grep/Bash/Agent(*)` as a second-layer safety net in case Claude Code's built-in sensitive-path classifier would otherwise prompt.

## Safety is in the hooks, not the allow-list

The broad allow-list is safe because `PreToolUse` hooks still run on every tool invocation:

- **`damage-control.sh`** blocks destructive git commands (`force push`, `reset --hard`, `checkout .`), recursive deletes in protected paths, and 18 secret patterns (AWS, GitHub, OpenAI, Anthropic, Stripe, Slack, JWT, private keys, etc.)
- **`pre-commit-quality.sh`** blocks commits containing `debugger` statements, hardcoded secrets, or unreviewed API keys
- **`block-protected-paths.sh`** reads `.claude/project.json` governance rules and refuses writes to paths marked protected or to blocked-feature paths
- **`config-protection.sh`** refuses edits to linter/formatter configs (`.eslintrc*`, `prettier.config.*`, `biome.json`) without explicit override

These hooks fire regardless of allow-list status. Broad allow-list = "don't prompt." It does not mean "no safety check."

## When a skill needs something NOT in the base allow-list

Rare. But if it happens:

1. **Document it** in the skill's `## Tool Permissions` section with an explanation.
2. **Do NOT add to `settings.json`** casually — every addition flows to every downstream repo via sync. Prefer per-project `settings.local.json` for one-off needs.
3. **Propose a base-settings change** only when 2+ skills need the same permission or when the usage is universal (e.g., a new shell command category).

## Authoring checklist for new skills

- [ ] Top-level README (or SKILL.md) includes a `## Tool Permissions` section
- [ ] Listed tools are all covered by the base allow-list (verify against the table above)
- [ ] State/output paths documented so future audits can trace file writes
- [ ] Skill's PreToolUse hook interactions documented if any (e.g., "commits are blocked by `pre-commit-quality` — use `/stub` format for TODOs")
- [ ] Tested that the skill runs in a fresh claude-pattern-synced project without permission prompts

## Audit

To audit a project's actual permission usage:

```bash
# Find prompts fired in the last session
grep -i "permission" .claude/logs/*.log 2>/dev/null

# Check which tools a skill invoked
grep -E "(Bash|Write|Edit|Read|Glob|Grep)\(" .claude/logs/session-*.jsonl | sort -u
```

If prompts fire for a pattern not in the base allow-list, either:

- The base list is missing coverage → propose an addition and sync.
- The skill needs an exotic permission → document in its `## Tool Permissions` and scope via `settings.local.json`.

## Reference skills (examples of this convention in use)

- `.claude/commands/qa-scaffold/README.md` — one-time install skill
- `.claude/commands/qa-backfill/README.md` — stub generator with `--overwrite` idempotence
- `.claude/commands/plan-w-team/` — multi-agent orchestration (permissions implicit via the broad base list; subagents inherit the lead's allow-list)
