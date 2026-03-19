# Parallel Agents Orchestration Command

Execute parallel Task agents with context guardrails and file conflict
prevention.

## Pre-Flight Checks

Before spawning parallel agents, verify:

1. **Context Budget**: Check `/context` - need 60%+ remaining for parallel work
2. **File Assignments**: Each agent must have non-overlapping file assignments
3. **Agent Count**: Maximum 5 agents (3 for large tasks)

## Guardrail Enforcement

### Context Thresholds (Optimized Dec 2025)

| Usage  | Status   | Action                              |
| ------ | -------- | ----------------------------------- |
| 0-30%  | OPTIMAL  | Aggressive: spawn 5-7 agents        |
| 30-50% | NORMAL   | Safe to spawn 3-5 agents            |
| 50-65% | MODERATE | Limit to 2-3 agents                 |
| 65-75% | WARN     | Single agent only, plan wrap-up     |
| 75-85% | CRITICAL | Complete current work, prepare commit |
| 85%+   | STOP     | No new agents, /compact immediately |

### File Assignment Protocol

When orchestrating parallel work:

1. **List all files** to be modified before spawning
2. **Assign non-overlapping** file sets to each agent
3. **Include in Task prompt**:

   ```
   ASSIGNED FILES (exclusive to this agent):
   - path/to/file1.ts
   - path/to/file2.ts

   DO NOT MODIFY (assigned to other agents):
   - path/to/other.ts
   ```

### Agent Prompt Template

```markdown
[TASK DESCRIPTION]

## File Assignments

ASSIGNED FILES (exclusive to this agent):

- [file1.ts]
- [file2.ts]

DO NOT MODIFY (assigned to other agents):

- [other-file.ts]

## Output Format

Return:

1. Implementation for assigned files only
2. Any required type/interface changes
3. Test suggestions (but don't write tests - assigned to test agent)

## Context Efficiency

- Reference CLAUDE.md for patterns (don't re-read architecture docs)
- Use Grep/Glob/Read tools (NOT bash)
- Return focused, concise output
```

## Execution Pattern

### Step 1: Plan Assignments

Before spawning, plan which agent handles which files:

```
Agent 1 (Database): packages/db/src/schema/*.ts
Agent 2 (API): apps/api/src/routes/*.ts
Agent 3 (Validation): packages/validation/src/*.ts
Agent 4 (Tests): tests/**/*.test.ts
```

### Step 2: Check Context

```
/context
```

If < 60% remaining, reduce agent count or complete current work first.

### Step 3: Spawn Agents

Use Task tool with parallel execution (all in single message):

```
Task 1: Database schema agent
Task 2: API routes agent
Task 3: Validation schemas agent
```

### Step 4: Wait for Completion

**Do not continue** until all agents return.

### Step 5: Integrate & Verify

1. Review each agent's output
2. Check for conflicts
3. Run tests/compile
4. Commit incrementally

## Anti-Patterns to Avoid

### Context Overload

```
WRONG:
- Spawn 10+ agents at once
- Each re-reads full docs
- Main agent runs out of context

RIGHT:
- Spawn 5-7 agents max at low context
- Spawn 3-5 at moderate context
- Provide focused context in prompt
- Reserve 35% for main agent
```

### File Conflicts

```
WRONG:
Agent 1: "Implement auth in routes/auth.ts"
Agent 2: "Add validation to routes/auth.ts"

RIGHT:
Agent 1: "Implement auth in routes/auth.ts"
Agent 2: "Add validation in validation/auth.ts"
```

### No State Preservation

```
WRONG:
- Work until auto-compact
- Lose task context

RIGHT:
- Check /context regularly
- Manual /compact at 70%
- State preserved
```

## Quick Reference

```
┌─────────────────────────────────────────────────┐
│ PARALLEL AGENTS - QUICK CHECKLIST (Dec 2025)    │
├─────────────────────────────────────────────────┤
│                                                 │
│ BEFORE SPAWNING:                                │
│   [ ] /context shows 50%+ remaining             │
│   [ ] Files assigned with no overlaps           │
│   [ ] Max 7 agents at 0-30% context             │
│   [ ] Max 5 agents at 30-50% context            │
│   [ ] Max 3 agents at 50-65% context            │
│                                                 │
│ TASK BATCHING:                                  │
│   [ ] Analyzed first 10 tasks from @fix_plan   │
│   [ ] Grouped by file (same file = sequential) │
│   [ ] Identified parallelizable batch          │
│                                                 │
│ IN EACH TASK PROMPT:                            │
│   [ ] Clear task description                    │
│   [ ] ASSIGNED FILES listed                     │
│   [ ] DO NOT MODIFY list included               │
│   [ ] Output format specified                   │
│                                                 │
│ AFTER COMPLETION:                               │
│   [ ] All agents returned                       │
│   [ ] No file conflicts                         │
│   [ ] Tests/compile pass                        │
│   [ ] Committed as batch                        │
│                                                 │
└─────────────────────────────────────────────────┘
```

---

_Command created: December 23, 2025_ _Use: /parallel-agents before multi-agent
orchestration_
