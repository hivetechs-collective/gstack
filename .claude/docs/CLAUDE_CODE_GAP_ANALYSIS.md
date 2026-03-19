# Claude Code Documentation Gap Analysis

**Generated**: 2026-02-24
**Agent**: claude-code-docs-updater
**Purpose**: Comprehensive gap analysis of local Claude Code documentation against current (February 2026) state

---

## Executive Summary

This analysis identifies **documentation gaps** between the local configuration files in `~/.claude/` and `/Users/veronelazio/Developer/Private/claude-pattern/.claude/` versus the current Claude Code state (v2.1.52 as of February 2026).

### Critical Findings

| Category                          | Status                 | Priority     |
| --------------------------------- | ---------------------- | ------------ |
| TodoWrite References              | **361 files affected** | HIGH         |
| Deprecated Model Names            | **~120+ references**   | HIGH         |
| SDK Rename (Code → Agent)         | Partially updated      | MEDIUM       |
| MCP Transport (SSE deprecated)    | No local references    | LOW          |
| New Features (Checkpoints/Rewind) | Partially documented   | MEDIUM       |
| Task Tool Documentation           | ~~Minimal coverage~~   | DONE ✅      |
| Agent Teams Documentation         | Not documented         | HIGH (NEW)   |
| Sandboxing Documentation          | Not documented         | MEDIUM (NEW) |
| Plugins System Documentation      | Not documented         | MEDIUM (NEW) |

---

## 1. TodoWrite → TaskCreate/TaskUpdate/TaskList Migration

### Current State

**TodoWrite** and **TodoRead** are still referenced throughout the documentation, but Claude Code now uses a **Task-based system** with:

- `TaskCreate` - Create new tasks
- `TaskList` - List all tasks
- `TaskGet` - Retrieve task by ID
- `TaskUpdate` - Update task status/details
- `Task` - Launch specialized sub-agents

**Note**: Both systems coexist. TodoWrite is still available for session-level task tracking, while Task tools enable multi-session persistence and sub-agent coordination.

### Files Requiring Updates

**Global CLAUDE.md** (`~/.claude/CLAUDE.md`):

- References "TodoWrite Usage" section
- **Action**: Add TaskCreate/TaskUpdate/TaskList documentation alongside TodoWrite

**Agents with TodoWrite in tools list** (need Task tool addition):

| File                                                        | Line    | Current       |
| ----------------------------------------------------------- | ------- | ------------- |
| `.claude/agents/coordination/orchestrator.md`               | 43      | `- TodoWrite` |
| `.claude/agents/coordination/release-orchestrator.md`       | 48      | `- TodoWrite` |
| `.claude/agents/research-planning/claude-sdk-expert.md`     | 55      | `- TodoWrite` |
| `.claude/agents/research-planning/aws-specialist.md`        | 34      | `- TodoWrite` |
| `.claude/agents/research-planning/kubernetes-specialist.md` | 46      | `- TodoWrite` |
| (60+ more agents)                                           | Various | `- TodoWrite` |

**Commands referencing TodoWrite**:

| File                                    | Lines                                        | Issue                                         |
| --------------------------------------- | -------------------------------------------- | --------------------------------------------- |
| `.claude/commands/develop.md`           | 276, 307, 319, 322, 331, 536, 845, 970, etc. | Extensive TodoWrite usage                     |
| `.claude/commands/dev/design-app.md`    | 2, 240, 288, 293                             | `allowed-tools: Task, Read, Write, TodoWrite` |
| `.claude/commands/dev/implement-app.md` | 2                                            | `allowed-tools: ...TodoWrite`                 |

### Migration Recommendation

```yaml
# Current (still valid for session-level tracking)
tools:
  - TodoWrite     # Session-level task list

# Recommended Addition (for multi-session and sub-agents)
tools:
  - TaskCreate    # Create persistent tasks
  - TaskList      # List all tasks
  - TaskGet       # Get task details
  - TaskUpdate    # Update task status
  - Task          # Launch sub-agents
```

---

## 2. Model Name Updates

### Current Model Lineup (February 2026)

| Model             | ID                          | Alias               | Status                   |
| ----------------- | --------------------------- | ------------------- | ------------------------ |
| Claude Opus 4.6   | `claude-opus-4-6`           | `claude-opus-4-6`   | Current, Best for coding |
| Claude Sonnet 4.6 | `claude-sonnet-4-6`         | `claude-sonnet-4-6` | Current, Default         |
| Claude Haiku 4.5  | `claude-haiku-4-5-20251001` | `claude-haiku-4-5`  | Current                  |

### Deprecated Model References Found

**Files with Claude 3.x references (DEPRECATED)**:

| File                                                                               | Line(s)                                          | Deprecated Reference                                                                 |
| ---------------------------------------------------------------------------------- | ------------------------------------------------ | ------------------------------------------------------------------------------------ |
| `.claude/agents/research-planning/claude-sdk-expert.md`                            | 567, 605, 644, 689, 717, 740                     | `claude-3-5-sonnet-20241022`                                                         |
| `.claude/agents/research-planning/skills-expert/docs/official/skills-api-guide.md` | 56, 138, 152, 172, 183, 290, 320, 345            | `claude-3-5-sonnet-20241022`                                                         |
| `.claude/agents/research-planning/openrouter-expert.md`                            | 337, 340, 373, 435, 436, 522, 529, 570, 688, 743 | `anthropic/claude-3-opus`, `anthropic/claude-3-sonnet`                               |
| `.claude/skills/hive/hive-consensus-engine/SKILL.md`                               | 62, 81, 106, 178, 180, 184, 186, 214, 284, 286   | `claude-3.5-sonnet`, `claude-3-haiku`                                                |
| `.claude/skills/hive/hive-openrouter-integration/SKILL.md`                         | 75, 86, 92, 98, 104, 227-229, 407-410, 467       | `anthropic/claude-3.5-sonnet`, `anthropic/claude-3-haiku`, `anthropic/claude-3-opus` |
| `.claude/skills/hive/hive-testing-strategy/SKILL.md`                               | 120, 122, 346                                    | `claude-3.5-sonnet`                                                                  |
| `.claude/skills/hive/hive-performance-benchmarks/SKILL.md`                         | 214                                              | `claude-3-haiku`, `claude-3.5-sonnet`                                                |
| `.claude/skills/hive/hive-python-bundling/SKILL.md`                                | 343                                              | `claude-3-5-sonnet-20241022`                                                         |

**Files with Claude 4.5 references (NOW DEPRECATED)**:

Many files still reference `claude-opus-4-5` and `claude-sonnet-4-5` which have been superseded by 4.6 versions.

### Migration Table

| Deprecated                   | Replace With                | Notes                          |
| ---------------------------- | --------------------------- | ------------------------------ |
| `claude-opus-4-5-20251101`   | `claude-opus-4-6`           | Latest Opus                    |
| `claude-opus-4-5`            | `claude-opus-4-6`           | Latest Opus                    |
| `claude-sonnet-4-5-20250929` | `claude-sonnet-4-6`         | Latest Sonnet                  |
| `claude-sonnet-4-5`          | `claude-sonnet-4-6`         | Latest Sonnet                  |
| `claude-3-sonnet-*`          | `claude-sonnet-4-6`         | Three generations behind       |
| `claude-3-5-sonnet-*`        | `claude-sonnet-4-6`         | Two generations behind         |
| `claude-3-haiku-*`           | `claude-haiku-4-5`          | Haiku 4.5 remains current      |
| `claude-3-opus-*`            | `claude-opus-4-6`           | **RECOMMENDED for all coding** |
| `anthropic/claude-3-*`       | `anthropic/claude-opus-4-6` | OpenRouter format              |

---

## 3. SDK Rename: Claude Code SDK → Claude Agent SDK

### Current Documentation State

The rename is **partially documented** in:

- `.claude/agents/research-planning/claude-sdk-expert/docs/migration-guide.md`
- `.claude/agents/research-planning/claude-sdk-expert/docs/overview.md`
- `.claude/agents/research-planning/claude-sdk-expert/docs/2025-UPDATE.md`

### Files Still Referencing "Claude Code SDK"

| File                                                                           | Line | Reference                          |
| ------------------------------------------------------------------------------ | ---- | ---------------------------------- |
| `.claude/agents/research-planning/claude-sdk-expert/docs/migration-guide.md`   | 17   | `claude-code-sdk` (Python package) |
| `.claude/agents/research-planning/claude-sdk-expert/docs/migration-guide.md`   | 53   | `pip uninstall claude-code-sdk`    |
| `.claude/agents/research-planning/claude-sdk-expert/docs/2025-10-30-UPDATE.md` | 191  | `Python: claude-code-sdk`          |

### Migration

```bash
# Old
pip install claude-code-sdk
from claude_code_sdk import query

# New
pip install claude-agent-sdk
from claude_agent_sdk import query
```

---

## 4. Deprecated Configuration Options

### `.claude.json` Deprecations

The following options have been **removed** from `.claude.json` and should be configured in `settings.json`:

| Deprecated Option    | New Location                                          | Notes                     |
| -------------------- | ----------------------------------------------------- | ------------------------- |
| `allowedTools`       | `settings.json` → `permissions.allow`                 | See settings.json example |
| `ignorePatterns`     | `settings.json` → deny permissions in `localSettings` | Migrated                  |
| `env`                | `settings.json` or `.env` files                       | Environment-specific      |
| `todoFeatureEnabled` | `settings.json`                                       | Feature flag              |

### Current settings.json Structure

```json
{
  "permissions": {
    "allow": ["Bash(git *)", "Bash(npm *)"],
    "deny": ["Bash(rm -rf /*)"]
  },
  "statusLine": { ... },
  "hooks": { ... }
}
```

---

## 5. MCP Server Configuration Updates

### Current State (February 2026)

- **SSE transport is DEPRECATED** - Use HTTP transport instead
- HTTP transport is recommended for remote MCP servers
- stdio transport remains for local servers
- **MCP Tool Search** is production-ready and auto-enabled

### Local Configuration Review

Current `.claude/.mcp.json` uses **stdio transport** (correct for local servers). **No SSE references found** - configuration is up to date.

### MCP Features Documentation Status

| Feature              | Description                               | Documentation Status     |
| -------------------- | ----------------------------------------- | ------------------------ |
| MCP Tool Search      | Lazy loading for tools (134k → 5k tokens) | ✅ Documented in CLI ref |
| Wildcard permissions | `mcp__server__*` syntax                   | ✅ Documented in CLI ref |
| HTTP transport       | `claude mcp add --transport http`         | ✅ Documented in CLI ref |
| MCP_TIMEOUT          | Environment variable for startup timeout  | ✅ Documented in CLI ref |
| Tool Annotations     | readOnlyHint, destructiveHint, etc.       | ✅ Documented in CLI ref |
| Strict config        | `--strict-mcp-config` flag                | ✅ Documented in CLI ref |

---

## 6. Hook System Updates

### Current Hook Events (Complete List - February 2026)

| Event               | Matcher Support | Description                              | Doc Status |
| ------------------- | --------------- | ---------------------------------------- | ---------- |
| `PreToolUse`        | Yes             | Before tool execution (can block/modify) | ✅         |
| `PostToolUse`       | Yes             | After successful execution               | ✅         |
| `UserPromptSubmit`  | No              | Before processing user input             | ✅         |
| `Notification`      | No              | When Claude sends an alert               | ✅         |
| `Stop`              | No              | When agent finishes response             | ✅         |
| `SubagentStart`     | Yes             | When sub-agent starts                    | ✅         |
| `SubagentStop`      | Yes             | When sub-agent finishes                  | ✅         |
| `SessionStart`      | No              | When session starts                      | ✅         |
| `SessionEnd`        | No              | When session ends                        | ✅         |
| `PreCompact`        | No              | Before context compaction                | ✅         |
| `Setup`             | No              | With --init/--maintenance flags          | ✅         |
| `PermissionRequest` | Yes             | Permission modal trigger                 | ✅         |
| `TeammateIdle`      | No              | When a teammate goes idle                | ✅ NEW     |
| `TaskCompleted`     | No              | When a task is marked completed          | ✅ NEW     |
| `WorktreeCreate`    | No              | When a git worktree is created           | ✅ NEW     |
| `WorktreeRemove`    | No              | When a git worktree is removed           | ✅ NEW     |
| `ConfigChange`      | No              | When settings/config changes             | ✅ NEW     |

---

## 7. New Features Documentation Status

### ✅ Completed (February 2026 Update)

| Feature                     | Status                             |
| --------------------------- | ---------------------------------- |
| CLI Reference rewrite       | ✅ Complete at v2.1.52             |
| Task tools documentation    | ✅ Full coverage in CLI ref        |
| Models updated to 4.6       | ✅ Opus 4.6, Sonnet 4.6 documented |
| Hook events expanded        | ✅ 17 events documented            |
| MCP features                | ✅ Tool Search, annotations        |
| Keyboard shortcuts          | ✅ Full matrix documented          |
| Environment variables       | ✅ 40+ variables documented        |
| Permission system           | ✅ Patterns and hierarchy          |
| Agent Teams                 | ✅ Documented in CLI ref           |
| Subagent frontmatter fields | ✅ All new fields documented       |
| Slash commands expanded     | ✅ 35+ commands documented         |
| CLI flags                   | ✅ Complete reference              |

### Remaining Gaps

| Feature                   | Status         | Priority |
| ------------------------- | -------------- | -------- |
| Agent Teams deep guide    | Needs tutorial | MEDIUM   |
| Sandboxing configuration  | Preview only   | LOW      |
| Plugins system            | Needs guide    | MEDIUM   |
| `.claude/rules/` patterns | Needs examples | LOW      |
| Remote control patterns   | Needs examples | LOW      |

---

## 8. Breaking Changes Summary

### Must Address Immediately

1. **Opus 4.5 → Opus 4.6** - All `claude-opus-4-5` references need updating
2. **Sonnet 4.5 → Sonnet 4.6** - All `claude-sonnet-4-5` references need updating
3. **Claude 3.x fully deprecated** - All `claude-3-*` references will error
4. **SDK package rename** - `claude-code-sdk` → `claude-agent-sdk`

### Should Address Soon

1. **TodoWrite/Task tool relationship** - Clarify usage patterns in agent definitions
2. **Model name updates across 120+ files** - Bulk search-and-replace needed
3. **Agent definitions** - Add new frontmatter fields (memory, isolation, maxTurns)

### Nice to Have

1. **Plugins system documentation** - Growing feature
2. **Agent Teams tutorial** - Complex workflow coordination
3. **Sandboxing guide** - Preview feature documentation

---

## 9. Recommended Migration Steps

### Phase 1: Critical (Complete) ✅

1. ~~Update CLI reference~~ → Done (February 2026)
2. ~~Update model references in core docs~~ → Done
3. ~~Document new hook events~~ → Done
4. ~~Fix settings.json statusLine position~~ → Done

### Phase 2: Important (In Progress)

1. **Update model references in all agent files** (120+ files):

   ```bash
   # Search and replace
   grep -rl "claude-opus-4-5" .claude/ | xargs sed -i '' 's/claude-opus-4-5/claude-opus-4-6/g'
   grep -rl "claude-sonnet-4-5" .claude/ | xargs sed -i '' 's/claude-sonnet-4-5/claude-sonnet-4-6/g'
   ```

2. **Update SDK package references**:

   ```bash
   grep -rl "claude-code-sdk" .claude/ | xargs sed -i '' 's/claude-code-sdk/claude-agent-sdk/g'
   ```

3. **Add Task tools to agent definitions** alongside TodoWrite

4. **Update MCP usage guide** with Tool Search and annotations

### Phase 3: Enhancement (Planned)

1. Create Agent Teams tutorial/guide
2. Document Plugins system
3. Create Sandboxing configuration guide
4. Add `.claude/rules/` pattern examples
5. Remote control workflow documentation

---

## 10. Files Requiring Updates (By Priority)

### HIGH Priority

| File                                                    | Changes Needed                                 |
| ------------------------------------------------------- | ---------------------------------------------- |
| `~/.claude/CLAUDE.md`                                   | Update model refs to 4.6, add Agent Teams info |
| `.claude/agents/coordination/orchestrator.md`           | Update model references to 4.6                 |
| `.claude/commands/develop.md`                           | Add Task tool patterns alongside TodoWrite     |
| `.claude/agents/research-planning/claude-sdk-expert.md` | Update all model references, SDK rename        |

### MEDIUM Priority

| File                                      | Changes Needed                    |
| ----------------------------------------- | --------------------------------- |
| All agents in `agents/research-planning/` | Add Task tools, update models     |
| All agents in `agents/implementation/`    | Verify model selection            |
| `.claude/skills/hive/*`                   | Update all model references       |
| `.claude/docs/MCP_USAGE_GUIDE.md`         | Add Tool Search, HTTP transport   |
| `.claude/docs/SETTINGS_BEST_PRACTICES.md` | Update for current settings shape |

### LOW Priority

| File                     | Changes Needed              |
| ------------------------ | --------------------------- |
| `.claude/templates/*.md` | Update for current patterns |
| Plugin documentation     | Update for current API      |

---

## 11. Validation Checklist

After full migration, verify:

- [ ] No `claude-3-sonnet-*` references remain
- [ ] No `claude-3-5-sonnet-20241022` references remain
- [ ] No `claude-opus-4-5` references remain (except in deprecation tables)
- [ ] No `claude-sonnet-4-5` references remain (except in deprecation tables)
- [ ] No `claude-code-sdk` package references remain
- [ ] Task tools documented alongside TodoWrite
- [ ] `/rewind` documented (no `/checkpoints` references)
- [ ] MCP Tool Search behavior documented
- [ ] Model hierarchy documented: Opus 4.6 > Sonnet 4.6 > Haiku 4.5
- [ ] All 17 hook events documented
- [ ] Agent Teams documented
- [ ] New subagent frontmatter fields documented

---

## Sources

- [Claude Code CHANGELOG](https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md)
- [Claude Code Releases](https://github.com/anthropics/claude-code/releases)
- [Claude Code Official Docs](https://docs.anthropic.com/en/docs/claude-code/overview)
- [Claude Code Hooks Reference](https://docs.anthropic.com/en/docs/claude-code/hooks)
- [MCP Server Configuration](https://docs.anthropic.com/en/docs/claude-code/mcp)
- [Models Overview](https://docs.anthropic.com/en/docs/about-claude/models)
- [Claude Agent SDK](https://docs.anthropic.com/en/docs/claude-code/sub-agents)
