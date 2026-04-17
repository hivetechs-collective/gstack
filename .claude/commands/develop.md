---
description: Execute CleanScale development workflow with autonomous parallel agents. Use when implementing features, fixing bugs, running continuous development, or building ANY part of the project. Supports --continuous mode for multi-batch autonomous development. ALL features are unblocked - build EVERYTHING until explicitly stopped.
argument-hint: [--continuous] [--batch N] [task identifier]
allowed-tools: Task, Bash, Read, Write, Edit, Grep, Glob, TaskCreate, TaskUpdate, TaskList, TaskGet, Skill
---

# CleanScale Development Workflow

Execute systematic, parallel development following project documentation and
governance.

---

## 🔧 AUTOMATIC HOOKS (100% RELIABLE - NO ACTION NEEDED)

**The following hooks run AUTOMATICALLY by Claude Code - you don't invoke
them:**

| Hook                       | Event               | What It Does                                   |
| -------------------------- | ------------------- | ---------------------------------------------- |
| `session-start.sh`         | Every session start | Detects uncommitted work + CI failures         |
| `post-git-push.sh`         | After `git push`    | Auto-checks CI status, shows run ID            |
| `pre-compact.sh`           | Before compaction   | Saves session state, warns of uncommitted work |
| `context-checkpoint.sh`    | Before compaction   | Creates detailed checkpoint for recovery       |
| `block-protected-paths.sh` | Before Write/Edit   | Blocks writes to protected paths               |

**Why hooks matter:**

- Hooks = 100% execution guarantee (deterministic)
- Skills = 50-84% activation rate (LLM-driven)
- Auto-compact triggers at ~75% context usage
- Critical enforcement moved to hooks for reliability

**Your job:** Read and act on hook output, don't duplicate their work.

---

## ⛔ CONTEXT EXHAUSTION PREVENTION (READ FIRST)

**This command has caused session death from context exhaustion.** The following
guidelines help prevent session failure:

### 🚨 CRITICAL: NEVER EXIT - ALWAYS /compact

**When context gets high, you MUST /compact and CONTINUE. NEVER exit.**

```
FORBIDDEN:
❌ "Context is high, I'll summarize for next session"
❌ "Given context usage, ending gracefully"
❌ Exiting the loop due to context
❌ Waiting for user to restart

REQUIRED:
✅ At 70% context: /compact → continue working
✅ At 80% context: EMERGENCY /compact → continue working
✅ After /compact: Read session-state.md → resume from fix_plan.md
✅ Loop runs INDEFINITELY until user Ctrl+C or fix_plan.md is empty
```

**The autonomous pipeline runs until the project is FINISHED, not until context
is used. /compact exists to handle context. USE IT.**

### Anti-Patterns to Avoid

```
⚠️ Spawning 5+ agents at session start (high context cost)
⚠️ Deploying orchestrator without checking context first
⚠️ Reading entire TODO.md (3000+ lines) in one go
⚠️ Spawning agents that spawn more agents (exponential growth)
⚠️ Continuing to spawn when context > 70%
⚠️ Not committing before context reaches 80%
```

### Recommended Workflow

```
1. /context → Check percentage FIRST
2. IF > 70%: Work directly, no agents
3. IF > 55%: Single task only, haiku agents
4. IF ≤ 55%: Limited parallel agents (max 3)
5. AFTER each agent: Check context again
6. AT 70%: Commit pending work, run /compact, CONTINUE
7. AT 80%: EMERGENCY /compact → CONTINUE (never exit)
```

### 📊 PROGRESS TRACKING (CRITICAL)

**Progress is ONLY tracked when you mark tasks [x] in fix_plan.md!**

```
EVERY COMPLETED TASK REQUIRES THIS EDIT:

1. Note the task ID you just completed: [ID:xxxxxxxx]
2. Use Edit tool on fix_plan.md:

   old_string: "- [ ] [ID:xxxxxxxx] Task description..."
   new_string: "- [x] [ID:xxxxxxxx] Task description..."

3. This updates the dashboard progress counter
4. Without this step, your work is NOT tracked!
```

**⚠️ STRICT TASK DISCIPLINE (MANDATORY):**

1. **ONLY work on tasks from fix_plan.md** - no "bonus" work
2. **Include [ID:xxxxxxxx] in EVERY commit message** - links work to tasks
3. **Mark task complete IMMEDIATELY after committing** - don't batch completions
4. **Don't create new work** - if you discover issues, note them but stay on task

```
❌ WRONG: Do extra work not in fix_plan.md
   Commit: "docs(security): add WAF guide" (no task ID)
   Result: Progress counter stays at 24/67

✅ RIGHT: Only work on queued tasks
   Commit: "docs(security): add WAF guide [ID:ca47b218]"
   Then: Edit fix_plan.md to mark [ID:ca47b218] as [x]
   Result: Progress counter increases to 25/67
```

**Task Picking Order:**

1. Read fix_plan.md for prioritized task list
2. Pick FIRST `- [ ]` item (ignore Priority 5: USER ACTION)
3. Complete the task
4. Include [ID:xxxxxxxx] in commit message
5. Mark `- [x]` using Edit tool
6. Move to next `- [ ]` item

### R9: Creative Drift Prevention (MANDATORY)

**All work MUST validate against source of truth documents:**

1. **UNIFIED_ARCHITECTURE.md** - Technical patterns and standards
2. **PRD.md** - Product features and requirements
3. **SDD.md** - Technical specifications
4. **BUDGET.md** - Cost constraints
5. **AUTONOMOUS_PIPELINE.md** - Pipeline rules
6. **TODO.md** - Approved implementation tasks

**Pre-Implementation Validation (REQUIRED):**

Before implementing ANY task, validate:

```
- [ ] Task exists in fix_plan.md? If no → STOP
- [ ] Feature in PRD.md? If no → Add to IDEAS_BACKLOG.md, STOP
- [ ] Pattern in UNIFIED_ARCHITECTURE.md? If no → STOP
- [ ] Cost within BUDGET.md limits? If exceeds → STOP
- [ ] Commit will include [ID:xxxxxxxx]? If no → STOP
```

**If you discover ideas outside source documents:**

1. **DO NOT implement** - this is creative drift
2. **Add to** `/docs/governance/IDEAS_BACKLOG.md` using the template
3. **Continue** with fix_plan.md tasks
4. Ideas are reviewed weekly for approval

**Creative Drift Categories:**

| Category          | Example                         | Action                  |
| ----------------- | ------------------------------- | ----------------------- |
| Approved Feature  | Listed in PRD + TODO            | ✅ Implement            |
| Enhancement       | Improves approved feature       | ⚠️ Validate against SDD |
| New Idea          | Not in any source doc           | ❌ Log to IDEAS_BACKLOG |
| Pattern Deviation | Different from UNIFIED_ARCH     | ❌ Requires review      |
| Scope Creep       | Extends beyond PRD requirements | ❌ Log to IDEAS_BACKLOG |

**See:** `/docs/governance/COMPLIANCE_RULES.md` R9 for full details.

### Session Budget Philosophy

**Treat context like money. Once it's gone, session dies.**

- Each agent costs ~5,000-15,000 tokens
- Each large file read costs ~2,000-5,000 tokens
- Background agents accumulate costs silently
- Session has ~200,000 tokens total (Claude Max)
- Auto-compact triggers at ~75% (150K tokens used)
- At 80%, you have ~40,000 tokens left (2 agents max)

---

## 🚨 PARALLEL AGENT LIMITS (Optimized Dec 2025)

**Optimized for Opus 4.7 with stable context management:**

| Task Type                      | Max Agents | Token Cost | Reason                     |
| ------------------------------ | ---------- | ---------- | -------------------------- |
| **File I/O** (read/write/grep) | **3-5**    | High       | Each file = 100-500 tokens |
| **Code generation**            | **3-5**    | High       | Outputs are long           |
| **Testing/QA**                 | 5-7        | Medium     | Test output verbose        |
| **Validation/linting**         | 7-10       | Low        | Minimal I/O                |
| **Lightweight checks**         | 10-12      | Low        | Simple validation          |

### Agent Spawning Rules

```
✅ ALLOWED:
   - 3-5 agents for file-heavy work (reading, editing, searching)
   - Each agent returns <2,000 token summary
   - Spawn in parallel when context < 50%
   - Batch related tasks into single orchestrator run

❌ FORBIDDEN:
   - Agents spawning sub-agents (exponential growth)
   - Agents returning full file contents (compress to summaries)
   - Spawning when context > 65%
```

### Before Spawning Agents, Ask:

```
1. What is current context %? (run /context)
2. Will these agents read many files?
3. Can I do this work directly instead?
4. Will outputs fit in remaining context?
```

### Emergency Recovery

If context exceeds 70%:

1. **STOP** spawning new agents
2. **WAIT** for running agents to complete
3. **COMMIT** all changes immediately
4. **COMPACT** manually: `/compact`

---

## 🚀 CONTINUOUS DEVELOPMENT MODE

The `/develop` skill supports two modes:

| Mode           | Invocation              | Behavior                           |
| -------------- | ----------------------- | ---------------------------------- |
| **Standard**   | `/develop`              | Single batch, manual progression   |
| **Continuous** | `/develop --continuous` | Autonomous multi-batch with agents |

---

## ⚠️ CRITICAL: STEP 0 — CONTEXT BUDGET GUIDELINES

> **Note:** This is a **slash command** (user-invoked via `/develop`), not a
> model-invoked skill. These guidelines help prevent context exhaustion. Actual
> enforcement is done by Claude Code's built-in context monitoring system.

### Recommended Context-Aware Workflow

**Before spawning agents, consider:**

```
1. Check /context → Get current percentage
2. Estimate remaining token budget
3. Estimate task token cost
4. Spawn only if budget allows
5. Track spawned agents via TaskCreate for persistent visibility
```

### Agent Budget Guidelines (Optimized Dec 2025)

| Context % | Max NEW Agents | Max TOTAL Active | Token Budget/Agent | Action                       |
| --------- | -------------- | ---------------- | ------------------ | ---------------------------- |
| 0-30%     | 5 parallel     | 7 total          | 15,000 tokens      | **Aggressive parallelism**   |
| 30-50%    | 3 parallel     | 5 total          | 12,000 tokens      | Full parallel allowed        |
| 50-65%    | 2 parallel     | 3 total          | 8,000 tokens       | Moderate parallelism         |
| 65-75%    | 1 sequential   | 2 total          | 5,000 tokens       | Sequential only, small tasks |
| 75-85%    | 0 new          | 1 (current)      | 2,000 tokens       | Complete current task ONLY   |
| 85%+      | 0              | 0                | 0                  | STOP. Commit. /compact NOW   |

### Pre-Spawn Checklist (Recommended)

```
□ Check /context → Get current percentage
□ Count active agents (run TaskList)
□ Estimate if budget allows this agent
□ Keep task scope small (1-2 files per agent)
□ Use haiku model for simple tasks
```

### Task Size Guidelines

| Task Type          | Max Files | Max Lines | Recommended Model |
| ------------------ | --------- | --------- | ----------------- |
| File search        | N/A       | N/A       | haiku             |
| Simple edit        | 1         | 50        | haiku             |
| Component creation | 1-2       | 200       | haiku             |
| Feature impl       | 2-3       | 500       | sonnet            |
| Complex refactor   | 3-5       | 1000      | sonnet            |

**Caution**: Spawning too many agents may exhaust context. Monitor `/context`
regularly.

### Emergency Protocols (Suggested)

```
AT 70% CONTEXT:
  → STOP spawning new agents
  → Complete current agent's work only
  → Prepare commit message with continuation point
  → DO NOT start new features

AT 75% CONTEXT:
  → Immediately commit all pending work
  → Save state to .claude/state/session-state.md
  → TaskUpdate all in_progress tasks with checkpoint info
  → Run: git add . && git commit -m "wip: [current task] - context limit"

AT 80% CONTEXT:
  → EMERGENCY STOP
  → Do NOT spawn any more tools
  → Output: "⚠️ CONTEXT CRITICAL - Triggering /compact"
  → Run /compact immediately
```

### Agent Tracking (Persistent via Task Tools)

**Create persistent tasks for each spawned agent:**

```
TaskCreate({
  subject: "Implement customer routes [ID:xxxxxxxx]",
  description: "Build CRUD endpoints for customer management in apps/api/src/routes/customers.ts",
  activeForm: "Implementing customer routes"
})

TaskCreate({
  subject: "Add invoice validation [ID:yyyyyyyy]",
  description: "Add Zod schemas for invoice creation/update in packages/validation/src/invoice.ts",
  activeForm: "Adding invoice validation"
})
```

**When an agent starts work:**

```
TaskUpdate({ taskId: "1", status: "in_progress" })
```

**When an agent completes:**

```
TaskUpdate({ taskId: "1", status: "completed" })
```

**Before spawning, count active agents:**

- Run `TaskList()` → count tasks with status `in_progress`
- DO NOT exceed Max TOTAL Active from budget table

---

## 📋 TASK TOOLS INTEGRATION (Persistent Tracking)

**Task tools (`TaskCreate`, `TaskUpdate`, `TaskList`, `TaskGet`) provide persistent
task tracking that survives compaction. Use them as the PRIMARY execution tracker.**

### When to Use Task Tools vs fix_plan.md

| Purpose                       | Tool                                                   | Why                                |
| ----------------------------- | ------------------------------------------------------ | ---------------------------------- |
| **WHAT to work on**           | `fix_plan.md`                                          | Source of truth for task selection |
| **HOW execution is tracked**  | Task tools (`TaskCreate`, `TaskUpdate`, `TaskList`)    | Persistent state across compaction |
| **Recovery after compaction** | `TaskList()` (primary), `session-state.md` (secondary) | Task tools survive compaction      |
| **Marking tasks done**        | `Edit fix_plan.md` to `[x]`                            | Updates dashboard progress counter |

### Task Lifecycle

```
fix_plan.md item "- [ ] [ID:xxxxxxxx] Implement customer routes"
    ↓
TaskCreate({
  subject: "Implement customer routes [ID:xxxxxxxx]",
  description: "Build CRUD endpoints in apps/api/src/routes/customers.ts\nFollows UNIFIED_ARCHITECTURE.md patterns",
  activeForm: "Implementing customer routes"
})
    ↓
TaskUpdate({ taskId: "1", status: "in_progress" })  ← agent starts work
    ↓
TaskUpdate({ taskId: "1", status: "completed" })     ← agent finishes
    ↓
Edit fix_plan.md: "- [ ]" → "- [x]"                ← mark progress
```

### Batch Creation for Parallel Agents

```
# Create tasks for parallelizable batch, then set dependencies
TaskCreate({ subject: "Customer routes [ID:aaaa1111]", description: "...", activeForm: "..." })  # → task #1
TaskCreate({ subject: "Invoice validation [ID:bbbb2222]", description: "...", activeForm: "..." }) # → task #2
TaskCreate({ subject: "Dashboard layout [ID:cccc3333]", description: "...", activeForm: "..." })  # → task #3
TaskCreate({ subject: "Customer tests [ID:dddd4444]", description: "...", activeForm: "..." })    # → task #4

# Task #4 depends on task #1 (same file)
TaskUpdate({ taskId: "4", addBlockedBy: ["1"] })

# Spawn agents for #1, #2, #3 simultaneously (different files)
# After #1 completes, #4 is automatically unblocked
```

### Compaction Recovery (Primary Method)

```
AFTER RESUMING FROM COMPACT:
1. TaskList()                            ← PRIMARY: find interrupted work
2. For each in_progress task:
   TaskGet({ taskId: "N" })              ← read checkpoint info
3. session-state.md                      ← SECONDARY: backup context
4. git log --oneline -5                  ← verify last commits
5. Resume from exact checkpoint
```

### Owner Assignment for Multi-Agent Tracking

```
# Assign owner when spawning agent for a task
TaskUpdate({ taskId: "1", owner: "customer-routes-agent" })
TaskUpdate({ taskId: "2", owner: "invoice-validation-agent" })

# After agent completes, mark done
TaskUpdate({ taskId: "1", status: "completed" })
```

---

## 🤖 AUTONOMOUS OPERATION MODE

**This command is designed for autonomous operation. Prefer these patterns:**

```
Patterns to Avoid (when running continuously):
- "Would you like me to..." (breaks autonomous flow)
- "Should I proceed with..." (unnecessary confirmation)
- "Do you want me to..." (reduces throughput)

Preferred Autonomous Patterns:
- Search source documents for answers
- Deploy Documentation Oracle agent for ambiguity
- Apply TODO Resolution Protocol
- Make decisions based on source of truth
- Continue with orchestrator deployment
```

**Autonomous Decision Tree:**

```
┌─────────────────────────────────────────────────────────────────────────┐
│                      QUESTION/AMBIGUITY DETECTED                         │
│                                   │                                      │
│                                   ▼                                      │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │ 1. Search Source Documents (UNIFIED_ARCHITECTURE, SDD, PRD)     │   │
│  └──────────────────────────────┬──────────────────────────────────┘   │
│                                 │                                        │
│              ┌──────────────────┼──────────────────┐                    │
│              ▼                  ▼                  ▼                    │
│     ┌──────────────┐   ┌──────────────┐   ┌──────────────┐             │
│     │   ANSWER     │   │   SILENT     │   │   CONFLICT   │             │
│     │   FOUND      │   │   (No Docs)  │   │   DETECTED   │             │
│     └──────┬───────┘   └──────┬───────┘   └──────┬───────┘             │
│            │                  │                  │                      │
│            ▼                  ▼                  ▼                      │
│     Use documented      Use 2025/2026      Source docs                  │
│     pattern exactly     best practices     ALWAYS win                   │
│                                                                          │
│  2. Deploy Documentation Oracle if still ambiguous                      │
│  3. Make decision and PROCEED — never wait for user input               │
│  4. Document decision in commit message with @source citation           │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 📋 TOKEN-EFFICIENT TODO SCANNING

**⚠️ DO NOT read entire TODO.md (3000+ lines = context killer)**

### Smart TODO Scanning Protocol

```bash
# Step 1: Use Grep to find unchecked items (MUCH cheaper than full read)
Grep pattern="^- \[ \]" path="docs/TODO.md" output_mode="content" head_limit=50

# Step 2: Find current phase marker
Grep pattern="^## P1\." path="docs/TODO.md" output_mode="content"

# Step 3: Read ONLY the current phase section (~100-200 lines)
# First find line number of current phase
Grep pattern="^## P1.15" path="docs/TODO.md" -n output_mode="content"
# Then read just that section
Read /docs/TODO.md offset=[line_number] limit=200

# Step 4: Quick inventory check (summary only)
Read /docs/governance/CODE_INVENTORY.md offset=0 limit=100
```

### Context Cost Comparison

| Method               | Token Cost | Recommended        |
| -------------------- | ---------- | ------------------ |
| Read entire TODO.md  | ~15,000    | ❌ NEVER           |
| Grep + targeted read | ~2,000     | ✅ ALWAYS          |
| Read CODE_INVENTORY  | ~3,000     | ⚠️ First 100 lines |

### What to Look For (Prioritized)

1. **Current phase unchecked boxes** `- [ ]` in active P1.X section
2. **Blocking items** that prevent other work
3. **Items from recent commits** (check git log)
4. **Design docs without implementation** (Glob docs/design/\*.md)

### DO NOT

```
❌ Read entire TODO.md
❌ Read entire CODE_INVENTORY.md
❌ Spawn agent just to scan TODO
❌ Read multiple large docs at session start
```

---

## 🤖 AUTO-DEPLOY ORCHESTRATOR (BUDGET-AWARE)

**After identifying tasks, deploy a LEAN orchestrator:**

### Orchestrator Budget Protocol

```
BEFORE DEPLOYING ORCHESTRATOR:
1. Run /context → Get exact percentage
2. If context > 70%: DO NOT deploy orchestrator, work directly
3. If context > 55%: Deploy SINGLE-TASK orchestrator only
4. If context ≤ 55%: Deploy multi-task orchestrator with limits
```

### Single-Task Orchestrator (55-70% context)

```
Task(subagent_type="orchestrator", model="haiku"):
"You are a LEAN CleanScale Orchestrator. Context is limited.

SINGLE TASK FOCUS:
[One specific task from TODO.md]

BUDGET CONSTRAINTS:
- You may spawn MAX 1 additional agent
- Use haiku model for that agent
- Complete task in <5,000 tokens total
- Commit immediately when done
- DO NOT scan for more tasks

If task needs >1 agent: Break into smaller piece, do that only.
Signal TASK_COMPLETE when done. Main agent handles next task."
```

### Task Batching Protocol (NEW - Dec 2025)

**Before deploying orchestrator, analyze fix_plan.md for parallelizable tasks:**

```
TASK BATCHING ANALYSIS:
1. Read first 10 `- [ ]` items from fix_plan.md
2. Group by file/module (tasks touching same files = SEQUENTIAL)
3. Tasks touching different files = PARALLELIZABLE
4. Spawn agents for parallelizable group simultaneously

EXAMPLE:
  Task A: Update apps/api/src/routes/customers.ts    ─┐
  Task B: Update apps/api/src/routes/invoices.ts      │ PARALLELIZABLE
  Task C: Update apps/web/app/routes/dashboard.tsx    │ (different files)
  Task D: Add tests for customers.ts                 ─┘
  Task E: Fix bug in customers.ts                    ─── SEQUENTIAL with A

  → Spawn Agents for A, B, C simultaneously
  → After A completes, spawn agent for E
  → D can run parallel with E (different file type)
```

**File Conflict Detection:**

```typescript
// Simple heuristic: extract file paths from task descriptions
const tasks = fixPlanTasks.slice(0, 10);
const fileGroups = groupByFilePath(tasks);

// Tasks in same fileGroup = must be sequential
// Tasks in different fileGroups = can be parallel
```

### Multi-Task Orchestrator (≤50% context)

```
Task(subagent_type="orchestrator"):
"You are the CleanScale Development Orchestrator.

⚠️ CONTEXT BUDGET RULES (Optimized Dec 2025):
- Check /context BEFORE spawning any agent
- At 0-30%: Spawn up to 5 parallel agents
- At 30-50%: Max 3 parallel agents, 12k tokens each
- At 50-65%: Max 2 parallel agents, 8k tokens each
- At 65-75%: Max 1 sequential agent, 5k tokens
- At 75%+: STOP spawning, complete current work only
- At 85%+: EMERGENCY - commit and signal CONTEXT_CRITICAL

🚀 TASK BATCHING (REQUIRED):
Before spawning, analyze fix_plan.md:
1. Read first 10 unchecked tasks
2. Identify file paths in each task
3. Group tasks by file (same file = sequential)
4. Spawn agents for NON-OVERLAPPING tasks simultaneously

EXAMPLE BATCH:
- Agent 1: 'Update customer routes' (apps/api/routes/customers.ts)
- Agent 2: 'Add invoice validation' (packages/validation/invoice.ts)
- Agent 3: 'Fix dashboard layout' (apps/web/routes/dashboard.tsx)
All 3 spawn simultaneously because they touch different files.

IDENTIFIED TASKS (prioritized):
[List 5-7 highest priority unchecked items]
[Mark which can run in parallel]

AGENT SPAWNING PROTOCOL:
1. Check context % first
2. Identify parallelizable task batch (3-5 tasks)
3. Spawn all parallelizable agents in SINGLE message
4. TaskCreate for each task with [ID:xxxxxxxx] in subject
5. Set dependencies via TaskUpdate addBlockedBy
6. Wait for all to complete, then commit

AGENT PROMPT TEMPLATE:
'You are a [specialist]. Complete this task:
[specific task, 1-2 files max]
ASSIGNED FILES: [list files this agent owns]
DO NOT MODIFY: [list files other agents own]
When done, output AGENT_COMPLETE and summary.'

AUTONOMOUS OPERATION:
- Do NOT ask user questions
- Resolve ambiguity with docs
- Commit after each completed batch
- Monitor context between batches
- Signal CONTEXT_WARNING at 70%
- Signal CONTEXT_CRITICAL at 85%"
```

### Direct Work Mode (>70% context)

**When context is high, DO NOT deploy orchestrator. Work directly:**

```
IF context > 70%:
  1. Pick single highest-priority task
  2. Implement directly (no agent spawning)
  3. Use only Read, Edit, Write, Bash tools
  4. Commit immediately
  5. Check context again
  6. If still high: Save state, /compact
```

---

### Continuous Mode Architecture

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                    CONTINUOUS DEVELOPMENT ORCHESTRATOR                        │
├──────────────────────────────────────────────────────────────────────────────┤
│                                                                               │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────────────┐   │
│  │ PROGRESS │ │   DOC    │ │ APPROVAL │ │    CI    │ │     QUALITY      │   │
│  │ TRACKER  │ │  ORACLE  │ │   GATE   │ │  MONITOR │ │    SUPERVISOR    │   │
│  │  AGENT   │ │  AGENT   │ │  AGENT   │ │   AGENT  │ │  (30-min check)  │   │
│  └────┬─────┘ └────┬─────┘ └────┬─────┘ └────┬─────┘ └────────┬─────────┘   │
│       │            │            │            │                 │             │
│       ▼            ▼            ▼            ▼                 ▼             │
│  ┌────────────────────────────────────────────────────────────────────┐     │
│  │                     TASK DEPENDENCY ANALYZER                        │     │
│  │         (Determines safe tasks during CI failures)                  │     │
│  └────────────────────────────────────────────────────────────────────┘     │
│                                    │                                         │
│         ┌──────────────────────────┼──────────────────────────┐             │
│         ▼                          ▼                          ▼             │
│  ┌─────────────┐           ┌─────────────┐            ┌─────────────┐       │
│  │  FEATURE    │           │   CI FIX    │            │  PARALLEL   │       │
│  │  AGENTS     │           │   AGENTS    │            │  SAFE WORK  │       │
│  │  (Primary)  │           │  (Priority) │            │   AGENTS    │       │
│  └─────────────┘           └─────────────┘            └─────────────┘       │
│                                                                              │
└──────────────────────────────────────────────────────────────────────────────┘
```

---

## 🤖 CONTINUOUS MODE AGENTS

### 1. Progress Tracker Agent (Background)

**Purpose**: Monitor TODO.md and track implementation progress

**Responsibilities**:

- Parse `docs/TODO.md` for task status (checkbox states)
- Track completion percentage per phase (P1.6, P1.7, etc.)
- Identify blocked dependencies between tasks
- Report progress every 15 minutes or after each commit
- Update `docs/governance/CODE_INVENTORY.md` automatically

**Invocation**:

```
Task(subagent_type="general-purpose", run_in_background=true):
"You are the Progress Tracker Agent. Monitor docs/TODO.md continuously.
Every 15 minutes OR after detecting a new commit:
1. Parse all checkbox items [x] vs [ ]
2. Calculate completion % per P1.x section
3. Identify next unblocked task based on dependencies
4. Report status in format:
   📊 PROGRESS: P1.X at Y% | Next: [task] | Blocked: [count]
5. If all tasks in current batch complete, signal BATCH_COMPLETE"
```

### 2. Documentation Oracle Agent (On-Demand)

**Purpose**: Answer questions using project documentation

**Knowledge Sources** (Priority Order):

1. `docs/architecture/UNIFIED_ARCHITECTURE.md` - Architecture decisions
2. `docs/architecture/SDD.md` - Technical specifications
3. `docs/product/PRD.md` - Product requirements
4. `docs/branding/BRAND_GUIDELINES.md` - Visual design standards
5. `docs/design/MARKETING_HOMEPAGE_DESIGN.md` - Marketing site design
6. `docs/agent-context/MASTER_CONTEXT.md` - Project overview
7. `docs/governance/COMPLIANCE_RULES.md` - Governance rules

**Invocation**:

```
Task(subagent_type="general-purpose", model="haiku"):
"You are the Documentation Oracle. Answer this question using ONLY
project documentation. Search these files in order:
- UNIFIED_ARCHITECTURE.md for architecture questions
- SDD.md for technical implementation details
- PRD.md for product/feature requirements
- BRAND_GUIDELINES.md for colors, typography, logos
- COMPLIANCE_RULES.md for governance/process questions

Question: [agent question here]

Respond with:
📚 ORACLE: [concise answer]
📍 Source: [file:section]"
```

### 3. Approval Gate Agent (Decision Point)

**Purpose**: Approve or block progression between phases

**Decision Criteria**:

| Check             | Threshold     | Action if Fail        |
| ----------------- | ------------- | --------------------- |
| TypeScript errors | 0             | BLOCK                 |
| ESLint errors     | 0             | BLOCK                 |
| Test pass rate    | 100%          | BLOCK                 |
| Coverage (API)    | ≥90%          | WARN, allow with note |
| Coverage (Shared) | ≥95%          | WARN, allow with note |
| Coverage (Web)    | ≥80%          | WARN, allow with note |
| Security audit    | No high/crit  | BLOCK                 |
| CI status         | All green     | BLOCK                 |
| TODO completion   | Current batch | BLOCK next batch      |

**Invocation**:

```
Task(subagent_type="general-purpose"):
"You are the Approval Gate Agent. Evaluate readiness to proceed.
Run these checks and report:

1. pnpm typecheck (must be 0 errors)
2. pnpm lint (must be 0 errors)
3. pnpm test (must be 100% pass)
4. pnpm test -- --coverage (check thresholds)
5. pnpm audit --audit-level=high (must have no high/critical)
6. gh run list --limit 1 (CI must be green)

Decision format:
✅ APPROVED: All gates passed. Proceed to [next task]
⛔ BLOCKED: [check] failed. Reason: [details]. Fix required.
⚠️ CONDITIONAL: Passed with warnings: [list]. Proceed with caution."
```

### 4. CI Monitor Agent (Background - Critical)

**Purpose**: Continuously monitor CI/CD pipeline status

**Behavior**:

```
LOOP every 30 seconds while CI running:
  1. Check: gh run list --limit 3
  2. For each in_progress run:
     - Track duration
     - Monitor job status
  3. On FAILURE detected:
     - IMMEDIATELY signal CI_FAILURE
     - Extract: gh run view <id> --log-failed
     - Identify affected files/tests
     - Trigger Task Dependency Analyzer
  4. On SUCCESS:
     - Signal CI_SUCCESS
     - Unblock waiting agents
```

**Invocation**:

```
Task(subagent_type="devops-automation-expert", run_in_background=true):
"You are the CI Monitor Agent. Run continuously after any push.

MONITORING LOOP:
1. gh run list --limit 3 --json status,conclusion,databaseId,name
2. For runs with status=in_progress, poll every 30s
3. On failure:
   - RUN: gh run view <id> --log-failed
   - EXTRACT: Failed job name, error message, affected files
   - SIGNAL: 🚨 CI_FAILURE: [job] failed - [error summary]
   - TRIGGER: Task Dependency Analysis
4. On success:
   - SIGNAL: ✅ CI_SUCCESS: All jobs passed
   - UNBLOCK: Feature development agents

NEVER exit until all monitored runs complete."
```

### 5. Quality Supervisor Agent (Background - Every 30 Minutes)

**Purpose**: Periodic quality inspection to catch drift, ensure task discipline

**Timing**: Every 30 minutes during continuous development

**Responsibilities**:

- Run quality verification scripts
- Check for task discipline violations (commits without [ID:xxxxxxxx])
- Verify fix_plan.md is being updated properly
- Check for creative drift (work outside source documents)
- Report quality gate status

**Invocation**:

```
Task(subagent_type="general-purpose", run_in_background=true):
"You are the Quality Supervisor Agent. Run inspection every 30 minutes.

INSPECTION PROTOCOL (every 30 minutes):
1. Check time since last inspection via .claude/state/quality-state.json
2. If 30+ minutes elapsed, run full inspection:

   a. Run quality gates:
      npx tsx scripts/governance/verify-task-completion.ts

   b. Check recent commits for task IDs:
      git log --oneline -10 | grep -c '\[ID:'
      (All commits should have [ID:xxxxxxxx])

   c. Check fix_plan.md progress:
      grep -c '^\- \[x\]' fix_plan.md  # Completed
      grep -c '^\- \[ \]' fix_plan.md  # Remaining

   d. Verify no creative drift (commits not in fix_plan.md)

3. Report status:
   🔍 QUALITY INSPECTION (30-min check):
   ✓ Quality gates: [PASS/FAIL]
   ✓ Task discipline: X/Y commits have IDs
   ✓ Progress: X completed, Y remaining
   ⚠️ Issues: [list any problems]

4. If issues detected:
   - Flag in .claude/state/quality-state.json
   - Add blocker entry if critical

5. Update lastCheck timestamp in quality-state.json"
```

**Quality State File**: `.claude/state/quality-state.json`

```json
{
  "lastCheck": "ISO timestamp",
  "typecheckErrors": 0,
  "testsFailing": 0,
  "lintErrors": 0,
  "taskDisciplineViolations": 0,
  "creativeDriftDetected": false,
  "blockers": []
}
```

---

## 🔄 CI FAILURE RECOVERY PROTOCOL

### CRITICAL: CI Must Be Monitored Continuously

**After EVERY push, you MUST check CI status:**

```bash
# Quick status check (use this frequently)
gh run list --limit 3

# If any failures:
gh run view <run-id> --log-failed
```

### Parallel Work Strategy During CI Failures

```
┌─────────────────────────────────────────────────────────────────┐
│  CI FAILURE DETECTED → DO NOT STOP ALL WORK                     │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  PARALLEL EXECUTION:                                             │
│                                                                  │
│  Thread 1: CI Fix Agent                                          │
│    → Focused on fixing the failing code                          │
│    → Commits fix, pushes, monitors until green                   │
│                                                                  │
│  Thread 2: Safe Task Development                                 │
│    → Continue work on INDEPENDENT tasks                          │
│    → Tasks with no dependency on failing code                    │
│    → Keep commits separate from CI fix branch                    │
│                                                                  │
│  COORDINATION:                                                   │
│    - Track via TaskCreate: "CI Fix" and "P1.X Development"      │
│    - CI Fix has PRIORITY if it blocks other work                │
│    - Safe tasks can merge immediately when CI is green          │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### Task Dependency Analyzer

When CI fails, analyze which tasks can safely continue:

```
┌─────────────────────────────────────────────────────────────────┐
│                   CI FAILURE DETECTED                            │
│                   Job: "Build & Test"                            │
│                   Error: apps/api/src/routes/customers.ts        │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│              TASK DEPENDENCY ANALYSIS                            │
├─────────────────────────────────────────────────────────────────┤
│ Affected Files:                                                  │
│   - apps/api/src/routes/customers.ts                            │
│   - packages/validation/src/customer.ts                         │
│                                                                  │
│ Affected Tasks (BLOCKED):                                        │
│   ⛔ P1.9 Customer Management - BLOCKED (directly affected)      │
│   ⛔ P1.11 Invoicing - BLOCKED (depends on customer schema)      │
│                                                                  │
│ Unaffected Tasks (SAFE TO CONTINUE):                            │
│   ✅ P1.10 Scheduling - SAFE (no customer dependency)            │
│   ✅ P1.15 Marketing Site - SAFE (independent)                   │
│   ✅ P1.12 Mobile Navigation - SAFE (UI only)                    │
└─────────────────────────────────────────────────────────────────┘
```

**Dependency Map** (Built from imports and TODO.md):

```typescript
const TASK_DEPENDENCIES = {
  "P1.6": [], // Auth - no deps
  "P1.7": ["P1.6"], // Web Foundation - needs auth
  "P1.8": ["P1.7"], // UI Components - needs web foundation
  "P1.9": ["P1.6", "P1.7"], // CRM - needs auth, web
  "P1.10": ["P1.6", "P1.7"], // Scheduling - needs auth, web
  "P1.11": ["P1.9"], // Invoicing - needs CRM
  "P1.12": ["P1.6"], // Mobile Auth - needs auth
  "P1.13": ["P1.12"], // Mobile Features - needs mobile auth
  "P1.14": ["P1.13"], // Mobile Polish - needs mobile features
  "P1.15": [], // Marketing Site - independent
  "P1.15a": [], // Marketing Homepage - independent
  "P1.15b": ["P1.6", "P1.7"], // Branding Config - needs auth, web
};
```

**Invocation**:

```
Task(subagent_type="general-purpose"):
"You are the Task Dependency Analyzer. CI has failed.

Failed files: [list from CI Monitor]
Error type: [build/test/lint]

Analyze and report:
1. Which P1.x tasks touch these files? (BLOCKED)
2. Which P1.x tasks depend on blocked tasks? (BLOCKED)
3. Which P1.x tasks are completely independent? (SAFE)

Output format:
🔴 BLOCKED TASKS:
  - P1.X: [reason - directly affected / depends on P1.Y]

🟢 SAFE TASKS (can continue):
  - P1.X: [reason - no dependency on affected code]

📋 RECOMMENDED ACTION:
  - Deploy CI Fix Agents to: [blocked tasks]
  - Continue development on: [safe tasks]"
```

### CI Fix Agent Deployment

When CI fails, automatically deploy fix agents:

```
Task(subagent_type="devops-automation-expert"):
"You are a CI Fix Agent. Priority: CRITICAL.

CI Failure Details:
- Job: [job name]
- Error: [error message]
- File: [affected file]
- Log: [relevant log excerpt]

Your mission:
1. Read the failing file and understand the error
2. Check related files for context
3. Implement the fix following project standards
4. Run local verification: pnpm typecheck && pnpm lint && pnpm test
5. If fix works, commit: git commit -m 'fix(ci): [description]'
6. Push and signal CI Monitor to re-check

DO NOT proceed to other work until CI is green.
Report: 🔧 CI_FIX: [status] - [what was fixed]"
```

### Concrete CI Failure Response Flow

```
1. DETECT: gh run list shows ❌ failure
   ↓
2. ANALYZE: gh run view <id> --log-failed
   ↓
3. IDENTIFY: Which files/tests failed?
   ↓
4. CATEGORIZE using Dependency Map:
   - BLOCKED: Tasks touching failed files
   - SAFE: Tasks with no dependency
   ↓
5. PARALLEL DEPLOY (if context allows):
   - CI Fix Agent (haiku, small scope) → Fix the failure
   - Development continues on SAFE tasks
   ↓
6. TRACK via Task tools:
   - TaskCreate({ subject: "Fix CI: [error]", description: "...", activeForm: "Fixing CI failure" })
   - TaskCreate({ subject: "P1.X: [safe task]", description: "...", activeForm: "Continuing safe work" })
   ↓
7. VERIFY: After CI Fix Agent commits:
   - gh run list → Check new run
   - Wait for green ✓
   ↓
8. MERGE: Safe task work can proceed to main once CI is green
```

### CI Status Indicators

| gh run list output | Meaning     | Action                                     |
| ------------------ | ----------- | ------------------------------------------ |
| ✓ (green check)    | Passed      | Continue development                       |
| ✗ (red X)          | Failed      | Deploy CI Fix Agent + analyze dependencies |
| ○ (circle)         | In progress | Wait, check in 2-3 minutes                 |
| - (dash)           | Skipped     | Check why, may need attention              |

---

## 🛑 MANDATORY CHECKPOINT (ALWAYS EXECUTE FIRST)

**STOP. Before ANY implementation, you MUST complete this checklist:**

```
□ 1. Run /context skill (REQUIRED - even on resumed sessions)
□ 2. Confirm context loaded with "✅ Context loaded" message
□ 3. ⚠️ CHECK SESSIONSTART HOOK OUTPUT (see below)
□ 4. State current phase, blocked features, and next task
□ 5. Create TaskList with implementation plan (TaskCreate for each task)
□ 6. If --continuous mode: Deploy background monitoring agents
```

> **Note:** The SessionStart hook (100% reliable) automatically detects:
>
> - Uncommitted changes from previous sessions
> - CI failures that need attention
> - In-progress CI runs to monitor
>
> Review the hook output before proceeding.

**This applies to:**

- ✅ Fresh sessions
- ✅ Resumed sessions (after compaction)
- ✅ "Continue with /develop" requests
- ✅ ANY invocation of this skill

**Why?** Compaction summaries provide task context but NOT project governance
context. The /context skill loads MASTER_CONTEXT.md which contains architecture
decisions, file placement rules, and compliance requirements that summaries
omit.

**DO NOT proceed to implementation until this checkpoint is complete.**

---

## 🔄 SESSION RECOVERY PROTOCOL

**The SessionStart hook (100% reliable) automatically handles steps 1-2 below.**
**Review the hook output at session start, then follow up as needed:**

### Step 1: Check for Uncommitted Work (AUTO via SessionStart Hook)

> **Hook handles this automatically:** The SessionStart hook runs `git status`
> and displays uncommitted files with recommended actions.

**If uncommitted changes were detected by the hook:**

```
1. Review what the changes are (git diff, git diff --cached)
2. Check git log for context on what was being worked on
3. Decision:
   a) COMMIT: If work is complete → commit with descriptive message
   b) STASH: If work is incomplete → git stash save "WIP: description"
   c) CONTINUE: If work should resume → pick up where left off
   d) DISCARD: If changes are invalid → git checkout . (careful!)
```

### Step 2: Check CI History for Failures (AUTO via SessionStart Hook)

> **Hook handles this automatically:** The SessionStart hook runs `gh run list`
> and displays any failing or in-progress CI runs with recommended actions.

**If CI failures were detected by the hook:**

```bash
# View detailed failure information
gh run view <run-id> --log-failed

# Address failures (fix or document as deferred)
```

### Step 3: Analyze Failed Runs

```bash
# For each failed run:
gh run view <run-id> --log-failed

# Document failures in session state
```

### Step 4: Check Session State File

```bash
# Read previous session state (if exists)
Read .claude/state/session-state.md

# Look for:
# - Incomplete tasks (in_progress status)
# - CI failures logged but not fixed
# - Continuation points noted
```

### Step 5: Check Task Tools for Interrupted Work

```
# Run TaskList() to find persistent tasks from previous sessions.
# Tasks with status "in_progress" represent interrupted work.
# Use TaskGet(taskId) to read full description and checkpoint info.
# This is the PRIMARY recovery mechanism (session-state.md is secondary).
```

### Recovery Decision Tree

```
┌─────────────────────────────────────────────────────────────────┐
│              SESSION RECOVERY DECISION                           │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  0. Any UNCOMMITTED changes? (git status)                        │
│     YES → Review and handle first:                               │
│           - Complete work? → Commit it                           │
│           - Incomplete? → Continue or stash                      │
│     NO  → Continue to step 1                                     │
│                                                                  │
│  1. Any FAILED CI runs?                                          │
│     YES → Fix CI or document why deferred                        │
│     NO  → Continue to step 2                                     │
│                                                                  │
│  2. Any IN_PROGRESS CI runs?                                     │
│     YES → Wait for completion, then re-check                     │
│     NO  → Continue to step 3                                     │
│                                                                  │
│  3. Session state has incomplete tasks?                          │
│     YES → Resume those tasks first                               │
│     NO  → Continue to step 4                                     │
│                                                                  │
│  4. TaskList has in_progress items from prior session?            │
│     YES → TaskGet each, complete or close those items            │
│     NO  → Safe to start new development                          │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### CI Failure Log Format

**When CI failures are found, log them to session state:**

```markdown
## CI Failures (Discovered [timestamp])

| Run ID | Workflow    | Commit | Error Summary              | Status      | Resolved |
| ------ | ----------- | ------ | -------------------------- | ----------- | -------- |
| 12345  | CI          | abc123 | Type error in customers.ts | PENDING_FIX | -        |
| 12346  | Integration | abc123 | Test timeout               | PENDING_FIX | -        |

## Fix Priority

1. [Run 12345] - Type error blocks all development
2. [Run 12346] - Integration test can be fixed in parallel
```

### CI Status Update Protocol

**After pushing fixes, update the session state log:**

```bash
# Check if previously failing runs now pass
gh run list --limit 20 --json databaseId,conclusion,name \
  --jq '.[] | "\(.databaseId): \(.conclusion)"'
```

**Update Status Values:**

- `PENDING_FIX` → Failure discovered, needs fix
- `FIX_PUSHED` → Fix committed and pushed, awaiting CI
- `RESOLVED` → CI now passing (update with timestamp)
- `DEFERRED` → Known issue, documented why safe to defer

**Example Update:**

```markdown
| Run ID | Workflow    | Commit | Error Summary              | Status   | Resolved         |
| ------ | ----------- | ------ | -------------------------- | -------- | ---------------- |
| 12345  | CI          | abc123 | Type error in customers.ts | RESOLVED | 2025-12-26 18:00 |
| 12346  | Integration | abc123 | Test timeout               | RESOLVED | 2025-12-26 18:05 |
```

**Cross-Session Tracking:** When resuming a session, always:

1. Read previous session-state.md
2. Check if any `PENDING_FIX` or `FIX_PUSHED` items exist
3. Run `gh run list` to verify current status
4. Update statuses accordingly before new work

### Session State Template

**Write to `.claude/state/session-state.md` on every session:**

```markdown
# Session State - [timestamp]

## CI Status

- Last checked: [timestamp]
- Failing runs: [list or "None"]
- Pending fixes: [list or "None"]

## Incomplete Work

- [ ] [Task description] - [file:line] - [status]

## Continuation Point

Next action: [specific next step]

## Context at Save

- Context %: [percentage]
- Agents active: [count]
- Last commit: [hash]
```

### Recovery Commands

```bash
# Quick recovery check (run at session start)
gh run list --limit 10 --json status,conclusion,name,headBranch \
  --jq '.[] | select(.conclusion == "failure") | "\(.name): \(.headBranch)"'

# If failures found:
echo "⚠️ CI FAILURES DETECTED - Must fix before new development"

# Check session state
cat .claude/state/session-state.md 2>/dev/null || echo "No previous session state"
```

### Recovery Priority Guidelines

```
IF CI failures exist AND you want to start new development:
  → Address failures first (recommended)
  → Either: fix them OR document why they can be safely deferred
  → Independent work can proceed in parallel with CI fixes

IF session state has incomplete tasks:
  → Resume those before starting new work (recommended)
  → Run TaskList, update in_progress tasks to reflect current state
```

---

## Workflow Instructions

You are the CleanScale Development Orchestrator. Execute the following workflow:

### 1. Load Context First

```
/context
```

Read and internalize:

- `/docs/agent-context/MASTER_CONTEXT.md` - Token-optimized project overview
- `/docs/TODO.md` - Implementation timeline and task breakdown
- `/docs/governance/CODE_INVENTORY.md` - Current implementation status

### 2. Compliance Check

Before ANY implementation, verify compliance with:

**Architecture (STRICT):**

- `/docs/architecture/UNIFIED_ARCHITECTURE.md` - Primary technical source of
  truth
- `/docs/architecture/SDD.md` - Detailed technical specifications

**Product Requirements:**

- `/docs/product/PRD.md` - Product requirements and user stories
- `/docs/product/BUDGET.md` - Infrastructure cost constraints (<0.5% of MRR)

**Governance:**

- `/docs/review-status.md` - Executive review status (all Phase 1 reviews
  COMPLETED)
- `/docs/governance/COMPLIANCE_RULES.md` - Architectural rules

**Branding (for UI/Marketing work):**

- `/docs/branding/BRAND_GUIDELINES.md` - Colors, typography, logos
- `/docs/design/MARKETING_HOMEPAGE_DESIGN.md` - Marketing site visual spec

### 3. Identify Next Tasks

From `TODO.md`, identify the next logical implementation batch following
priority order:

**ALL TASKS ARE ACTIONABLE - Build Everything:**

Check `fix_plan.md` for the current prioritized list. Work on ALL `- [ ]`
items.

**Key principle:** Deadlines are TARGET dates, not "don't start until" dates.
Being AHEAD of schedule is always good. Never skip work because of future
deadlines.

**CRITICAL: Phase labels are organizational, NOT blocking.**

- Tasks labeled "Phase 2", "Deferred to Phase 2", or "Later" are ACTIONABLE NOW
- When a task appears in fix_plan.md, work on it regardless of phase labels
- Phase names are arbitrary organizational markers, not execution barriers
- Goal: Empty the `- [ ]` list completely, across ALL phases

**Priority order** (work on ALL items - phases are just organization):

1. First `- [ ]` item in fix_plan.md (regardless of phase label)
2. Continue to next `- [ ]` item
3. Keep going until list is empty
4. Phase 1, Phase 2, Phase 3 - work on everything in queue order

### 4. Deploy Agents (Standard vs Continuous)

#### Standard Mode

Use the orchestrator agent to coordinate parallel work:

```
Task tool with subagent_type="orchestrator"
```

#### Continuous Mode (--continuous flag)

Deploy the full agent constellation:

```bash
# Step 1: Deploy background monitoring agents
Task(Progress Tracker Agent, run_in_background=true)
Task(CI Monitor Agent, run_in_background=true)
Task(Quality Supervisor Agent, run_in_background=true)  # 30-min inspections

# Step 2: Deploy feature agents for current batch
Task(Feature Agent 1) + Task(Feature Agent 2) + ... # Parallel

# Step 3: On batch completion, Approval Gate decides next steps
Task(Approval Gate Agent)

# Step 4: If approved, loop to next batch automatically
```

**Agent Deployment Rules:**

- Launch background agents for monitoring (Progress, CI)
- Keep foreground agents for critical path work
- Monitor context usage - stay under 70% before spawning new agents
- Use `haiku` model for simple tasks, `sonnet` for complex implementation
- Maximum 5 concurrent feature agents + 2 monitor agents

**Specialist Agents Available:**

- `database-expert` - Schema design, migrations, RLS policies
- `api-expert` - Hono.js endpoints, rate limiting, validation
- `react-typescript-specialist` - Web components, hooks, state
- `nodejs-specialist` - Backend services, async patterns
- `security-expert` - OWASP compliance, auth flows
- `unit-testing-specialist` - Vitest tests, coverage
- `devops-automation-expert` - CI/CD, deployment
- `style-theme-expert` - UI theming, Tailwind, accessibility

### 5. QA Gates (After Each Phase)

Run ALL quality checks before committing:

```bash
# Type checking
pnpm typecheck

# Linting
pnpm lint

# Tests (must pass)
pnpm test

# Security audit
pnpm audit --audit-level=high

# Format check
pnpm format:check

# Governance stub scan
pnpm run scan:stubs
```

**Coverage Requirements:**

- API/Backend: ≥90%
- Shared Packages: ≥95%
- Web Components: ≥80%
- Zero TypeScript errors
- Zero ESLint errors

### 5.5. MANDATORY Quality Audits (Before Commit)

**CRITICAL:** After implementation and before committing, you MUST run these
quality audit skills AND automatically fix all discovered issues.

#### Code Review Audit (REQUIRED for all code changes)

```
/review-code
```

Run this skill to:

- Check for security vulnerabilities (OWASP Top 10)
- Verify proper error handling
- Ensure test coverage requirements are met
- Validate adherence to project coding standards
- Identify performance issues (O(n²) algorithms, blocking I/O)

#### Frontend Design Audit (REQUIRED for UI/web changes)

```
/frontend-design
```

Run this skill when implementing ANY of:

- Web routes (`apps/web/app/routes/**`)
- UI components (`packages/ui/**`)
- Mobile screens (`apps/mobile/app/**`)
- Website templates (`apps/website/**`)

The frontend-design audit checks:

- Design quality and production-readiness
- Accessibility (WCAG compliance, aria attributes)
- Typography and color consistency with BRAND_GUIDELINES.md
- Animation and motion patterns
- Responsive design implementation

#### AUTO-FIX POLICY (Proceed Without Asking)

**AUTOMATICALLY fix ALL critical and minor issues** discovered by the audit
skills **without asking for user confirmation** when they align with:

1. `/docs/architecture/UNIFIED_ARCHITECTURE.md` - Primary technical source
2. `/docs/architecture/SDD.md` - Detailed specifications
3. `/docs/product/PRD.md` - Product requirements
4. `/docs/branding/BRAND_GUIDELINES.md` - Brand standards
5. Project coding standards and patterns

**Issues to auto-fix include:**

- React hooks issues (missing deps, memoization, useCallback)
- Accessibility violations (aria-labels, roles, focus management)
- Security vulnerabilities (input validation, XSS prevention)
- Performance issues (unnecessary re-renders, missing optimization)
- Error handling gaps (empty catch blocks, missing error boundaries)
- TypeScript strictness (proper typing, null checks)
- Code quality (dead code, unused imports, console statements)
- Brand color mismatches (wrong hex values vs BRAND_GUIDELINES.md)

**DO NOT auto-fix (ask user first):**

- Architectural changes that contradict UNIFIED_ARCHITECTURE.md
- Feature additions not in PRD.md
- Database schema modifications
- Breaking API changes
- Removal of intentional functionality

#### Audit Remediation Protocol (MANDATORY)

**🛑 CRITICAL: After running /review-code or /frontend-design, you MUST complete
the full fix-and-verify cycle. NEVER just report findings and move on.**

**Step-by-Step Remediation:**

```
1. RUN AUDIT
   → Execute /review-code (or /frontend-design for UI)
   → Receive findings report

2. CATEGORIZE FINDINGS
   → Critical: Must fix before proceeding (security, crashes, broken code)
   → Recommended: Should fix (performance, code quality, best practices)
   → Informational: Optional (style preferences, minor optimizations)

3. FIX ALL CRITICAL ISSUES (MANDATORY)
   → Fix each critical issue immediately
   → Do NOT ask user for permission on aligned fixes
   → Do NOT proceed until ALL critical issues are resolved

4. FIX RECOMMENDED ISSUES (EXPECTED)
   → Fix recommended issues unless they require architectural changes
   → Document any skipped recommendations with reasoning

5. VERIFY FIXES
   → Run: pnpm typecheck (must pass)
   → Run: pnpm lint (must pass)
   → Ensure fixes don't introduce new issues

6. CONFIRM COMPLETION
   → State: "✅ Audit complete: Fixed X critical, Y recommended issues"
   → List what was fixed
   → Only then proceed to commit
```

**Key Principle:** Audit skills are fix-and-verify cycles, NOT just reports. The
audit is only complete when fixes are applied and verified.

### 6. Pre-Commit Verification Gate

**🛑 STOP BEFORE COMMITTING. Complete this checklist:**

```
□ pnpm typecheck     → Must pass (zero errors)
□ pnpm lint          → Must pass (zero errors)
□ pnpm test          → Must pass (all tests green)
□ pnpm audit --audit-level=high → No high-severity vulnerabilities
□ pnpm format        → All files formatted
□ /review-code       → Run and fix all issues
□ /frontend-design   → Run if UI changes, fix all issues
```

**Only proceed to commit after ALL checks pass.**

### 7. Commit & Push Protocol

**After each feature is developed and QA tested, commit and push immediately.**

**Option A: Use Commit Skill (Recommended)**

```
/git-smart-commit    # Analyzes changes, generates semantic message
# OR
/git-commit          # Simple commit with manual message
```

**Option B: Manual Commands**

```bash
git status                    # Review changes
git add .                     # Stage all
git commit -m "type(scope): description

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
git push origin main          # Push to remote
```

**After push, monitor CI:**

```bash
gh run list --limit 1
gh run view <run-id>          # Monitor until green
```

**Commit Frequency Rule:**

- Commit after EACH feature/fix is complete and tested
- Do NOT batch multiple features into one commit
- Each commit should be independently deployable

**Commit Types:**

- `feat` - New feature
- `fix` - Bug fix
- `refactor` - Code restructure
- `test` - Test additions
- `docs` - Documentation
- `chore` - Maintenance

**CI Cost Optimization - [skip ci] Usage:**

To reduce GitHub Actions costs, add `[skip ci]` to commit messages for changes
that don't need CI validation:

```bash
# Documentation-only commits (no code changes)
git commit -m "docs: update README [skip ci]"

# Governance/inventory updates
git commit -m "chore(governance): update CODE_INVENTORY [skip ci]"

# Config file comments or formatting
git commit -m "chore: format config files [skip ci]"

# Markdown/text file updates
git commit -m "docs: add known issues [skip ci]"
```

**When to use [skip ci]:**

- ✅ Documentation files (\*.md) only
- ✅ Governance updates (CODE_INVENTORY, STUB_REGISTRY)
- ✅ Comments or formatting in non-code files
- ✅ .gitignore, .editorconfig updates

**When NOT to use [skip ci]:**

- ❌ Any TypeScript/JavaScript changes
- ❌ Package.json or pnpm-lock.yaml
- ❌ Test files
- ❌ Workflow files (.github/workflows/\*)
- ❌ Configuration that affects build (tsconfig, vite.config)

### 8. CI/CD Monitoring (BLOCKING - MANDATORY)

**🛑 CRITICAL: After EVERY push, you MUST complete this protocol. This is NOT
optional. Do NOT proceed to new work until ALL CI checks pass.**

#### 🔴 OWNERSHIP RULE (NON-NEGOTIABLE)

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  IF CI FAILS → YOU FIX IT. PERIOD.                                          │
│                                                                             │
│  ❌ FORBIDDEN RESPONSES:                                                    │
│     • "This is a pre-existing issue"                                        │
│     • "This failure is unrelated to my changes"                             │
│     • "The Performance Tests failure is not my fault"                       │
│     • "Let me move on and someone else can fix this"                        │
│     • "This is an infrastructure issue, not code"                           │
│                                                                             │
│  ✅ REQUIRED RESPONSE:                                                      │
│     • "CI failed. I own this. Let me investigate and fix it."               │
│                                                                             │
│  WE OWN THE ENTIRE SOLUTION. If it's broken, WE fix it.                     │
│  No exceptions. No excuses. No rationalizations.                            │
└─────────────────────────────────────────────────────────────────────────────┘
```

**Why this matters:**

- "Pre-existing issues" accumulate and rot the codebase
- Every CI failure is an opportunity to improve reliability
- Dismissing failures teaches bad habits and creates technical debt
- A healthy codebase has ZERO known failing tests

#### 🔴 HOOK BLOCKS ARE REAL BLOCKS (NON-NEGOTIABLE)

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  IF A HOOK RETURNS "blocking error" → THE EDIT DID NOT SUCCEED              │
│                                                                             │
│  ❌ FORBIDDEN RESPONSES:                                                    │
│     • "The edit was applied successfully (the warning is just a reminder)"  │
│     • "This is just a security reminder, not a blocking error"              │
│     • "The hook blocked it but I'll continue anyway"                        │
│     • Claiming success when the tool output shows "blocking error"          │
│                                                                             │
│  ✅ REQUIRED RESPONSE:                                                      │
│     • "The hook blocked this edit. I need to understand why and fix it."    │
│     • Read the error message carefully                                      │
│     • Address the security/compliance concern                               │
│     • Retry with a compliant approach                                       │
│                                                                             │
│  "PreToolUse:Callback hook returned blocking error" = EDIT FAILED           │
│  Do NOT claim success. Do NOT move on. Do NOT rationalize.                  │
└─────────────────────────────────────────────────────────────────────────────┘
```

**Logging Requirement:** Every CI failure MUST be logged to
`.claude/state/ci-failures.log`:

```bash
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] FAILURE: <workflow> - <error summary>" >> .claude/state/ci-failures.log
```

When fixed, mark as resolved:

```bash
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] RESOLVED: <workflow> - <fix commit>" >> .claude/state/ci-failures.log
```

**SessionStart hook enforces this** - unresolved failures are shown at session
start.

#### Standard Mode: Manual CI Monitoring

```bash
# 1. Push changes
git push origin main

# 2. IMMEDIATELY get the workflow run ID
gh run list --limit 1

# 3. Monitor until completion (BLOCKING - wait for result)
gh run view <run-id> --watch

# 4. If any job fails, get failure details
gh run view <run-id> --log-failed
```

#### Continuous Mode: Automatic CI Monitoring

The CI Monitor Agent handles this automatically:

```
CI Monitor Agent (Background):
- Detects push automatically
- Monitors all workflow runs
- On FAILURE: Triggers Task Dependency Analyzer
- Deploys CI Fix Agents to affected areas
- Signals safe tasks to continue
- On SUCCESS: Unblocks all agents for next batch
```

#### Required CI Jobs (ALL must pass)

| Workflow          | Jobs Required                                      |
| ----------------- | -------------------------------------------------- |
| CI                | Build & Test, Format Check, Security Audit         |
| Integration Tests | Clerk, Stripe, Database, E2E (or skipped for bots) |

#### CI Failure Response (Continuous Mode)

**Automatic recovery without user intervention:**

```
1. CI Monitor detects failure
2. Task Dependency Analyzer identifies:
   - BLOCKED tasks (affected by failure)
   - SAFE tasks (independent, can continue)
3. CI Fix Agents deployed to fix failing code
4. Safe Work Agents continue on unaffected tasks
5. On fix success, blocked tasks resume
6. Development continues uninterrupted
```

#### CI Failure Response (Standard Mode)

**When CI fails, execute this protocol WITHOUT user prompting:**

1. **STOP** all other work immediately
2. **READ** the failure logs: `gh run view <run-id> --log-failed`
3. **ANALYZE** the root cause
4. **FIX** the issue in the codebase
5. **RUN** local QA gates to verify: `pnpm typecheck && pnpm lint && pnpm test`
6. **COMMIT** the fix: `git add . && git commit -m "fix(ci): <description>"`
7. **PUSH** and monitor again: `git push && gh run list --limit 1`
8. **REPEAT** until ALL CI jobs pass

### 9. Update Documentation

After completing each batch:

1. Update `/docs/governance/CODE_INVENTORY.md` with new components
2. Register any new stubs in `/docs/governance/STUB_REGISTRY.md`
3. Increment batch number in CODE_INVENTORY.md

**In Continuous Mode:** Progress Tracker Agent handles this automatically.

### 10. Context Management (AGGRESSIVE MONITORING)

**⚠️ Context is THE limiting factor. Monitor aggressively.**

### Context Check Frequency (MANDATORY)

| Situation             | Check Frequency      |
| --------------------- | -------------------- |
| After deploying agent | Immediately after    |
| After agent completes | Before next action   |
| During implementation | Every 2-3 tool calls |
| After any file read   | Before next read     |
| Before spawning agent | ALWAYS               |

### Context Thresholds (HARD STOPS)

| Context % | Status      | Required Action                                |
| --------- | ----------- | ---------------------------------------------- |
| 0-40%     | 🟢 HEALTHY  | Normal operation, parallel agents OK           |
| 40-55%    | 🟡 CAUTION  | Reduce parallelism, prefer haiku               |
| 55-70%    | 🟠 WARNING  | Sequential only, small tasks, prepare to stop  |
| 70-80%    | 🔴 DANGER   | NO new agents, complete current work only      |
| 80%+      | ⛔ CRITICAL | EMERGENCY STOP, commit now, /compact immediate |

### Pre-Compact Checklist (At 70%)

```
□ Run TaskList, update in_progress tasks with checkpoint info
□ git add . (stage all changes)
□ git commit -m "wip: [task] - pre-compact checkpoint"
□ Update .claude/state/session-state.md
□ Note continuation point clearly
□ Run /compact
```

### State Preservation Protocol

```
BEFORE ANY COMPACTION:
1. Commit all work (even incomplete)
   → git commit -m "wip: [P1.X task] - context checkpoint

   Continuation point: [exact next step]
   Remaining: [list of remaining subtasks]

   🤖 Generated with Claude Code"

2. Update session state:
   → Write to .claude/state/session-state.md:
     - Current task and subtask
     - Files being modified
     - Next action to take
     - Agent tasks in progress

3. Update Task tools state:
   → TaskUpdate completed items to status: "completed"
   → Verify in_progress items have checkpoint info in description
   → Pending items remain as-is (persist across compaction)
```

### Post-Compact Resume Protocol

```
AFTER RESUMING FROM COMPACT:
1. Read .claude/state/session-state.md
2. Check git log for last commit
3. Run TaskList for persistent state recovery
4. Continue from exact checkpoint
5. Check /context immediately
6. Adjust agent budget accordingly
```

### Continuous Mode State Preservation

```json
// .claude/state/continuous-progress.json
{
  "lastContextCheck": "2025-12-26T16:00:00Z",
  "contextPercentage": 45,
  "activeAgents": 2,
  "totalAgentsSpawned": 5,
  "currentTask": "P1.15b",
  "nextTask": "P1.16",
  "checkpointCommit": "abc123",
  "remainingBudget": {
    "agents": 3,
    "tokensPerAgent": 10000
  }
}
```

### 11. Architecture Constraints

**Tech Stack (from UNIFIED_ARCHITECTURE.md):**

- Web: React Router v7, React 18, Tailwind CSS, TypeScript 5.x
- Mobile: React Native 0.76+, Expo SDK 52+
- API: Cloudflare Workers, Hono.js 4.x, Zod 3.x
- Database: Neon PostgreSQL 16, Drizzle ORM, Hyperdrive
- Auth: Clerk SDK
- Payments: Stripe

**Brand Standards (from BRAND_GUIDELINES.md):**

- Primary Green: `#3BB44C` - CTAs, icons, success
- Dark Teal: `#283C3F` - Text, headings, wordmark
- Forest Green: `#00803D` - Hover states, accents
- Typography: Playfair Display (headlines), DM Sans (body)
- Assets: `docs/branding/assets/logos/`, `docs/branding/assets/icons/`

**API Standards:**

- URL format: `/api/v1/{resource}`
- Response format: `{ success: boolean, data?: {}, error?: {}, meta?: {} }`
- Cursor-based pagination on all list endpoints
- Rate limiting per endpoint category

**Security Requirements:**

- 7-layer defense-in-depth
- Row-Level Security on all tenant tables
- JWT validation on all authenticated endpoints
- Input validation with Zod schemas

**Performance Targets:**

- API Response Time (p95): <100ms
- Time to First Byte: <50ms (edge)
- Database Query Time: <10ms (cached), <50ms (uncached)

---

## Quick Start (CONTEXT-AWARE)

### First Action (ALWAYS)

```bash
/context   # Get exact percentage before ANYTHING else
```

### Decision Tree Based on Context

```
┌─────────────────────────────────────────────────────────────┐
│                    /context result                           │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  0-40% → HEALTHY MODE                                        │
│    1. Load context docs (targeted reads only)                │
│    2. Grep TODO.md for unchecked items                       │
│    3. Deploy orchestrator (max 3 agents)                     │
│    4. Check context after each agent completes               │
│                                                              │
│  40-55% → CAUTION MODE                                       │
│    1. Use haiku agents only                                  │
│    2. Max 2 parallel agents                                  │
│    3. Commit more frequently                                 │
│    4. Check context every 2-3 tool calls                     │
│                                                              │
│  55-70% → WARNING MODE                                       │
│    1. Single task only                                       │
│    2. Max 1 haiku agent                                      │
│    3. Prepare commit message                                 │
│    4. Consider stopping soon                                 │
│                                                              │
│  70-80% → DANGER MODE                                        │
│    1. NO new agents                                          │
│    2. Complete current work only                             │
│    3. Commit immediately                                     │
│    4. Prepare for /compact                                   │
│                                                              │
│  80%+ → EMERGENCY                                            │
│    1. STOP all work                                          │
│    2. git add . && git commit                                │
│    3. Run /compact NOW                                       │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

### Standard Mode (Manual)

```
1. □ /context                        ← FIRST (get %)
2. □ Decide mode from decision tree
3. □ Grep TODO.md for tasks          ← NOT full read
4. □ TaskCreate for each planned task
5. □ IF ≤55%: Deploy orchestrator
   □ IF >55%: Work directly
6. □ Check context after each step
7. □ Commit frequently
8. □ At 70%: Wrap up
9. □ At 80%: /compact
```

### Continuous Mode (Autonomous)

```
⚠️ Continuous mode requires extra context discipline:

1. □ /context → Must be ≤40% to start continuous
2. □ If >40%: Use Standard Mode instead
3. □ Deploy LEAN orchestrator (not full agent constellation)
4. □ Orchestrator checks context before each spawn
5. □ Background agents limited to 2 total
6. □ Commit after every completed task
7. □ At 55%: Switch to single-task mode
8. □ At 70%: Complete current and stop
9. □ At 80%: Emergency /compact
```

### Anti-Pattern Examples

```
❌ WRONG: "Deploy 5 agents to work on P1.15-P1.20"
   → Context exhausted in 10 minutes

✅ RIGHT: "Deploy 1 agent for P1.15a, check context, then decide"
   → Sustainable development

❌ WRONG: "Read entire TODO.md to find all tasks"
   → 15,000 tokens wasted on file read

✅ RIGHT: "Grep for unchecked items, read only relevant section"
   → 2,000 tokens, same information
```

**Continuous Mode Commands:**

| Command                          | Action                                 |
| -------------------------------- | -------------------------------------- |
| `/develop --continuous`          | Start continuous development           |
| `/develop --continuous --resume` | Resume after compaction                |
| `/develop --status`              | Show current progress and agent status |
| `/develop --pause`               | Pause development (agents idle)        |
| `/develop --stop`                | Stop continuous mode completely        |

---

## Agent Communication Protocol

### Inter-Agent Signals

| Signal           | Sender           | Receiver       | Action                    |
| ---------------- | ---------------- | -------------- | ------------------------- |
| `BATCH_COMPLETE` | Progress Tracker | Approval Gate  | Evaluate for next batch   |
| `CI_SUCCESS`     | CI Monitor       | All Agents     | Unblock, proceed          |
| `CI_FAILURE`     | CI Monitor       | Task Analyzer  | Analyze dependencies      |
| `TASKS_BLOCKED`  | Task Analyzer    | Feature Agents | Pause affected tasks      |
| `TASKS_SAFE`     | Task Analyzer    | Feature Agents | Continue unaffected tasks |
| `FIX_DEPLOYED`   | CI Fix Agent     | CI Monitor     | Re-check CI status        |
| `APPROVED`       | Approval Gate    | Orchestrator   | Start next batch          |
| `BLOCKED`        | Approval Gate    | All Agents     | Halt until resolved       |

### Documentation Oracle Queries

Any agent can query the Documentation Oracle:

```
ORACLE_QUERY: "What are the brand colors for CTAs?"
ORACLE_RESPONSE: "📚 Primary Green #3BB44C per BRAND_GUIDELINES.md §Brand Colors"

ORACLE_QUERY: "How should API errors be formatted?"
ORACLE_RESPONSE: "📚 { success: false, error: { code, message } } per UNIFIED_ARCHITECTURE.md §6.2"
```

---

## Summary

**Standard Mode**: Manual, batch-by-batch development with explicit user
control.

**Continuous Mode**: Autonomous development with:

- ✅ Progress tracking via TODO.md monitoring
- ✅ Documentation-based question answering
- ✅ Automatic approval gates between batches
- ✅ Background CI monitoring
- ✅ Automatic CI failure recovery
- ✅ Task dependency analysis for safe parallel work during failures
- ✅ Automatic state preservation for compaction recovery

**All executive reviews are COMPLETED.** Full development can proceed on ALL
features. **Build the ENTIRE project** - do not stop at Phase 1. Continue until
user explicitly stops.

---

## 📚 SOURCE OF TRUTH BINDING (MANDATORY)

Every decision, implementation, and verification MUST trace back to one of these
canonical documents:

### Document Authority Hierarchy

| Document                  | Authority Level | Scope                              |
| ------------------------- | --------------- | ---------------------------------- |
| `UNIFIED_ARCHITECTURE.md` | **PRIMARY**     | Technical architecture, patterns   |
| `SDD.md`                  | **PRIMARY**     | Detailed specifications            |
| `PRD.md`                  | **PRIMARY**     | Product requirements, user stories |
| `TODO.md`                 | **EXECUTION**   | Task breakdown, priorities         |
| `BRAND_GUIDELINES.md`     | **DESIGN**      | Visual standards, assets           |
| `COMPLIANCE_RULES.md`     | **GOVERNANCE**  | Process rules, constraints         |

### Traceability Requirements

**Every implementation MUST include:**

```typescript
/**
 * @source UNIFIED_ARCHITECTURE.md §6.2 - API Response Format
 * @source PRD.md US-045 - Customer can view invoice history
 * @source SDD.md §4.3 - Invoice data model
 */
```

**Every agent decision MUST cite:**

```
📋 DECISION: Use cursor-based pagination
📍 SOURCE: UNIFIED_ARCHITECTURE.md §6.3 - Pagination Standards
📍 REASON: "All list endpoints MUST use cursor-based pagination"
```

### Document Cross-Reference Map

```
┌─────────────────────────────────────────────────────────────────────┐
│                    SOURCE OF TRUTH HIERARCHY                         │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │                         PRD.md                               │    │
│  │              (WHAT we're building & WHY)                     │    │
│  │         User Stories: US-001 through US-098                  │    │
│  └──────────────────────────┬──────────────────────────────────┘    │
│                             │                                        │
│                             ▼                                        │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │              UNIFIED_ARCHITECTURE.md                         │    │
│  │              (HOW we architect it)                           │    │
│  │    Sections: 1-11 covering all technical patterns            │    │
│  └──────────────────────────┬──────────────────────────────────┘    │
│                             │                                        │
│                             ▼                                        │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │                        SDD.md                                │    │
│  │              (DETAILED specifications)                       │    │
│  │    Sections: Data models, API contracts, integrations        │    │
│  └──────────────────────────┬──────────────────────────────────┘    │
│                             │                                        │
│                             ▼                                        │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │                       TODO.md                                │    │
│  │              (WHEN & ORDER of execution)                     │    │
│  │    Phases: P1.1 through P2.x with checkboxes                 │    │
│  └─────────────────────────────────────────────────────────────┘    │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

### Agent Source Lookup Protocol

**Before ANY implementation:**

1. **Feature Question** → Check `PRD.md` for user story
2. **Architecture Question** → Check `UNIFIED_ARCHITECTURE.md` for pattern
3. **Technical Detail** → Check `SDD.md` for specification
4. **Task Priority** → Check `TODO.md` for order and dependencies
5. **Visual Design** → Check `BRAND_GUIDELINES.md` for standards

**Documentation Oracle handles these queries automatically in continuous mode.**

---

## 🖥️ CLI & PLAYWRIGHT VERIFICATION CAPABILITIES

The development workflow has full access to CLI tools and Playwright for
comprehensive verification.

### Available CLI Tools

| Tool Category       | Commands                     | Purpose                    |
| ------------------- | ---------------------------- | -------------------------- |
| **Package Manager** | `pnpm`, `npm`, `npx`         | Dependency management      |
| **Version Control** | `git`, `gh`                  | Git operations, GitHub CLI |
| **Build Tools**     | `turbo`, `vite`, `astro`     | Build orchestration        |
| **Testing**         | `vitest`, `playwright`       | Test execution             |
| **Database**        | `drizzle-kit`, `wrangler d1` | Schema migrations          |
| **Deployment**      | `wrangler`                   | Cloudflare deployment      |
| **Mobile**          | `expo`, `eas`                | React Native tooling       |

### Playwright Browser Automation

**Full Playwright MCP integration available for:**

- 🌐 **Browser navigation**:
  `mcp__plugin_playwright_playwright__browser_navigate`
- 📸 **Screenshots**:
  `mcp__plugin_playwright_playwright__browser_take_screenshot`
- 🔍 **Page snapshots**: `mcp__plugin_playwright_playwright__browser_snapshot`
- 🖱️ **Interactions**: `browser_click`, `browser_type`, `browser_fill_form`
- 📋 **Console logs**: `browser_console_messages`
- 🌐 **Network requests**: `browser_network_requests`
- ⏳ **Wait conditions**: `browser_wait_for`
- 📑 **Tab management**: `browser_tabs`

### Visual Verification Protocol

**For UI implementations, use Playwright to verify:**

```
1. NAVIGATE to the implemented page
   → mcp__plugin_playwright_playwright__browser_navigate(url)

2. CAPTURE accessibility snapshot
   → mcp__plugin_playwright_playwright__browser_snapshot()

3. VERIFY elements exist and are accessible
   → Check snapshot for expected components

4. TAKE screenshot for visual record
   → mcp__plugin_playwright_playwright__browser_take_screenshot()

5. CHECK console for errors
   → mcp__plugin_playwright_playwright__browser_console_messages(level="error")

6. VERIFY network requests
   → mcp__plugin_playwright_playwright__browser_network_requests()
```

### E2E Verification Workflow

**Continuous Mode E2E Verification Agent:**

```
Task(subagent_type="stagehand-expert", run_in_background=true):
"You are the E2E Verification Agent. After each feature completion:

1. Start dev server: pnpm dev (background)
2. Wait for server ready: browser_wait_for(text='Ready')
3. Navigate to feature: browser_navigate(url)
4. Take snapshot: browser_snapshot()
5. Verify against PRD user story:
   - US-XXX: Check expected elements exist
   - Verify accessibility (aria-labels, roles)
   - Check console for errors
6. Take screenshot as evidence
7. Report:
   ✅ VERIFIED: [feature] matches PRD US-XXX
   ❌ FAILED: [feature] missing [element] from PRD US-XXX"
```

### CLI Verification Commands

**Pre-Commit Verification (Automated):**

```bash
# Full verification suite
pnpm typecheck                    # TypeScript compilation
pnpm lint                         # ESLint rules
pnpm test                         # Vitest unit/integration
pnpm test:e2e                     # Playwright E2E (if available)
pnpm audit --audit-level=high     # Security vulnerabilities
pnpm format:check                 # Prettier formatting

# Database verification
pnpm db:check                     # Drizzle schema validation

# Build verification
pnpm build                        # Full production build
```

**Deployment Verification:**

```bash
# Cloudflare Workers
wrangler deploy --dry-run         # Validate worker deployment
wrangler d1 migrations list       # Check pending migrations

# Website (Astro)
pnpm --filter website build       # Build static site
pnpm --filter website preview     # Local preview

# Mobile (Expo)
eas build --profile preview --platform all --non-interactive
```

### Source-Verified Implementation Example

```
┌─────────────────────────────────────────────────────────────────────┐
│                    IMPLEMENTATION FLOW                               │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  1. TASK: Implement customer list with pagination                   │
│     📍 SOURCE: TODO.md P1.9 "Customer Management"                   │
│                                                                      │
│  2. REQUIREMENTS: Check PRD                                          │
│     📍 SOURCE: PRD.md US-030 "Owner can view all customers"         │
│     📍 SOURCE: PRD.md US-031 "Owner can search customers"           │
│                                                                      │
│  3. ARCHITECTURE: Check patterns                                     │
│     📍 SOURCE: UNIFIED_ARCHITECTURE.md §6.3 "Cursor pagination"     │
│     📍 SOURCE: UNIFIED_ARCHITECTURE.md §6.2 "Response format"       │
│                                                                      │
│  4. SPECIFICATION: Check details                                     │
│     📍 SOURCE: SDD.md §4.2 "Customer data model"                    │
│     📍 SOURCE: SDD.md §5.1 "Customer API endpoints"                 │
│                                                                      │
│  5. IMPLEMENT: Write code with source citations                      │
│     /**                                                              │
│      * @source PRD.md US-030, US-031                                │
│      * @source UNIFIED_ARCHITECTURE.md §6.3                         │
│      * @source SDD.md §4.2, §5.1                                    │
│      */                                                              │
│                                                                      │
│  6. VERIFY: CLI + Playwright                                         │
│     → pnpm typecheck (pass)                                          │
│     → pnpm test (pass)                                               │
│     → browser_navigate('/customers')                                 │
│     → browser_snapshot() → verify list renders                       │
│     → browser_take_screenshot() → visual evidence                    │
│                                                                      │
│  7. REPORT:                                                          │
│     ✅ IMPLEMENTED: Customer list with cursor pagination             │
│     📍 SOURCES: PRD US-030/031, ARCH §6.3, SDD §4.2/5.1             │
│     🔍 VERIFIED: CLI checks pass, Playwright snapshot matches        │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

### Verification Agent Integration

**In Continuous Mode, verification happens automatically:**

```
After each feature implementation:

1. Progress Tracker signals: FEATURE_COMPLETE
2. Verification Agent activates:
   a. Run CLI verification suite
   b. If UI change: Run Playwright visual verification
   c. Cross-reference with source documents
3. Results feed to Approval Gate:
   ✅ All verified → APPROVED
   ❌ Verification failed → BLOCKED (with specific failure)
4. Approval Gate decides next action
```

### Source Document Quick Reference

**For quick lookups during development:**

| Need This...                  | Check This Section                  |
| ----------------------------- | ----------------------------------- |
| User story requirements       | `PRD.md §3.x` (feature sections)    |
| API endpoint format           | `UNIFIED_ARCHITECTURE.md §6`        |
| Database schema               | `SDD.md §4` (data models)           |
| Authentication flow           | `UNIFIED_ARCHITECTURE.md §4.3`      |
| Multi-tenancy rules           | `UNIFIED_ARCHITECTURE.md §5.2`      |
| UI component patterns         | `SDD.md §7` (frontend specs)        |
| Brand colors                  | `BRAND_GUIDELINES.md §Brand Colors` |
| Task priority order           | `TODO.md` (P1.x ordering)           |
| Governance rules              | `COMPLIANCE_RULES.md`               |
| Current implementation status | `CODE_INVENTORY.md`                 |

---

## 🔄 TODO RESOLUTION PROTOCOL (AUTONOMOUS)

The development workflow systematically resolves TODO items from `TODO.md`
**without requiring user intervention**. Every attempt uses CLI or Playwright
verification before proceeding.

### Resolution Hierarchy

```
┌─────────────────────────────────────────────────────────────────────────┐
│                     TODO RESOLUTION ORCHESTRATOR                         │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  1. SCAN: Parse TODO.md for uncompleted [ ] items                       │
│  2. PRIORITIZE: Order by P1.x number + dependency chain                 │
│  3. ASSIGN: Deploy appropriate specialist agent                          │
│  4. IMPLEMENT: Execute with source document citations                    │
│  5. VERIFY: CLI checks + Playwright visual verification                  │
│  6. REVIEW: Mandatory /review-code and security audit                   │
│  7. APPROVE: QA Gate validation before commit                            │
│  8. COMMIT: Semantic commit with source traceability                     │
│  9. ADVANCE: Mark [x] in fix_plan.md, move to next task                 │
│                                                                          │
│  ⚡ ALL STEPS AUTONOMOUS - NO USER INTERVENTION REQUIRED                 │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

### TODO Resolution Agent

**Purpose**: Systematically complete TODO items in correct order

**Invocation (Continuous Mode)**:

````
Task(subagent_type="orchestrator", run_in_background=true):
"You are the TODO Resolution Orchestrator. Process TODO.md systematically.

SCANNING PROTOCOL:
1. Read docs/TODO.md completely
2. Extract all [ ] uncompleted items with P1.x identifiers
3. Build priority queue: lower P1.x number = higher priority
4. Respect dependency chain from TASK_DEPENDENCIES map

FOR EACH TODO ITEM:
1. VERIFY SOURCE:
   - Check PRD.md for user story (US-XXX)
   - Check UNIFIED_ARCHITECTURE.md for patterns
   - Check SDD.md for specifications
   - Document all sources before implementing

2. ASSIGN SPECIALIST:
   - Database work → database-expert
   - API endpoints → api-expert
   - Web UI → react-typescript-specialist
   - Mobile → react-typescript-specialist
   - Security → security-expert
   - Tests → unit-testing-specialist
   - Styling → style-theme-expert

3. IMPLEMENT (No User Intervention):
   - Agent implements following source documents
   - All decisions cite @source annotations
   - No deviation from documented specifications

4. VERIFY WITH CLI:
   - pnpm typecheck (MUST pass)
   - pnpm lint (MUST pass)
   - pnpm test (MUST pass)
   - pnpm audit --audit-level=high (MUST pass)

5. VERIFY WITH PLAYWRIGHT (for UI):
   - browser_navigate to implemented route
   - browser_snapshot for accessibility check
   - browser_take_screenshot for visual record
   - browser_console_messages for error check

6. MANDATORY CODE REVIEW:
   - Run /review-code skill
   - Fix ALL critical issues (no user prompt)
   - Fix ALL recommended issues (unless architectural)
   - Verify fixes compile and pass tests

7. SECURITY AUDIT:
   - Run security-expert agent review
   - Check OWASP Top 10 compliance
   - Validate input sanitization
   - Verify authentication/authorization

8. QA GATE:
   - Run Approval Gate Agent
   - All thresholds must pass
   - If blocked: Fix and retry (no user prompt)

9. COMMIT:
   - Semantic commit message
   - Include @source citations in commit body
   - Push and monitor CI

10. ADVANCE:
    - **CRITICAL:** Use Edit tool to mark task complete in fix_plan.md:
      ```
      Change: - [ ] [ID:xxxxxxxx] Task description...
      To:     - [x] [ID:xxxxxxxx] Task description...
      ```
    - Note the [ID:xxxxxxxx] from the task you just completed
    - Update CODE_INVENTORY.md if appropriate
    - Signal TASK_COMPLETE
    - Move to next `- [ ]` item in fix_plan.md

BLOCKING CONDITIONS (require investigation, not user):
- Test failure → Analyze and fix automatically
- CI failure → Deploy CI Fix Agent
- Missing source documentation → Check all docs first
- Dependency not ready → Skip, move to next independent task

NEVER BLOCK ON:
- 'Ask user for clarification' → Check docs instead
- 'Need user approval' → Use Approval Gate Agent
- 'Confirm with user' → Verify against source documents

REPORT FORMAT:
📋 TODO PROGRESS: [X/Y] items complete
🔄 CURRENT: P1.X - [task name]
📍 SOURCES: [document citations]
✅ VERIFIED: CLI + Playwright checks passed
🔍 REVIEWED: /review-code + security audit complete
⏭️ NEXT: P1.X - [next task]"
````

### Resolution Order Enforcement

**Strict Priority Ordering:**

```typescript
// Resolution priority (lower = first)
const RESOLUTION_ORDER = [
  // Foundation (must complete first)
  "P1.1", // Monorepo setup
  "P1.2", // CI/CD workflows
  "P1.3", // Shared packages
  "P1.4", // Database layer
  "P1.5", // API scaffold

  // Core features (in dependency order)
  "P1.6", // Authentication
  "P1.7", // Web foundation
  "P1.8", // UI components
  "P1.9", // Customer/CRM
  "P1.10", // Scheduling
  "P1.11", // Invoicing

  // Mobile (after web)
  "P1.12", // Mobile auth
  "P1.13", // Mobile features
  "P1.14", // Mobile polish

  // Marketing (independent)
  "P1.15", // Marketing site
  "P1.15a", // Homepage design
  "P1.15b", // Branding config

  // Operations
  "P1.16", // Training system
  "P1.17", // Performance testing
  "P1.18", // Backup/recovery
  "P1.19", // iOS deployment
  "P1.20", // Android deployment
  "P1.21", // Security audit
  "P1.22", // QA verification
];
```

### CLI-First Resolution Strategy

**Every verification step uses CLI tools before asking user:**

| Verification Need         | CLI Solution                                 |
| ------------------------- | -------------------------------------------- |
| Code compiles?            | `pnpm typecheck`                             |
| Code style correct?       | `pnpm lint && pnpm format:check`             |
| Tests pass?               | `pnpm test`                                  |
| Security vulnerabilities? | `pnpm audit --audit-level=high`              |
| API working?              | `curl localhost:8787/api/v1/health`          |
| Web route accessible?     | `browser_navigate` + `browser_snapshot`      |
| Mobile builds?            | `eas build --profile preview --platform all` |
| Database schema valid?    | `pnpm db:check`                              |
| CI status?                | `gh run list --limit 1`                      |
| PR ready?                 | `gh pr checks`                               |
| Coverage sufficient?      | `pnpm test -- --coverage`                    |

### Playwright Resolution Strategy

**Visual verification without user intervention:**

```
PLAYWRIGHT VERIFICATION WORKFLOW:

1. Start Dev Server (Background):
   → Bash: pnpm dev &
   → Wait: browser_wait_for(text="ready", timeout=30000)

2. Navigate to Feature:
   → browser_navigate(url="http://localhost:3000/[route]")

3. Verify Accessibility:
   → browser_snapshot()
   → Parse snapshot for:
     - All interactive elements have labels
     - Proper heading hierarchy (h1 → h2 → h3)
     - ARIA roles present
     - Focus order logical

4. Check for Errors:
   → browser_console_messages(level="error")
   → If errors found: Fix automatically and retry

5. Verify Network:
   → browser_network_requests()
   → Check all API calls return 2xx
   → Verify no failed requests

6. Visual Evidence:
   → browser_take_screenshot(filename="verify-[feature].png")
   → Store in tests/e2e/screenshots/

7. Form Validation (if forms present):
   → browser_fill_form(fields=[...])
   → Verify validation messages appear
   → Test edge cases (empty, invalid, too long)

8. Close Server:
   → Kill background dev server
```

### Mandatory Review Gate

**Before ANY commit, these reviews are REQUIRED:**

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        MANDATORY REVIEW GATE                             │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  ┌──────────────────┐    ┌──────────────────┐    ┌──────────────────┐  │
│  │   CODE REVIEW    │    │ SECURITY AUDIT   │    │    QA GATE       │  │
│  │   /review-code   │ → │ security-expert  │ → │  Approval Agent  │  │
│  └────────┬─────────┘    └────────┬─────────┘    └────────┬─────────┘  │
│           │                       │                       │            │
│           ▼                       ▼                       ▼            │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │                     AUTO-FIX ALL ISSUES                          │  │
│  │   - Critical: Fix immediately (no user prompt)                   │  │
│  │   - Recommended: Fix unless architectural change                 │  │
│  │   - Security: Fix all vulnerabilities                            │  │
│  │   - Verify fixes: pnpm typecheck && pnpm test                    │  │
│  └──────────────────────────────────────────────────────────────────┘  │
│                                   │                                     │
│                                   ▼                                     │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │                    ALL GATES PASSED?                              │  │
│  │                                                                    │  │
│  │   ✅ YES → Proceed to commit                                      │  │
│  │   ❌ NO → Fix issues and retry (NO user intervention)            │  │
│  └──────────────────────────────────────────────────────────────────┘  │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

### Code Review Integration

**MANDATORY: Use the `/review-code` skill for comprehensive code review:**

```
# Step 1: Invoke the review-code skill
Skill(skill="review-code", args="Changes for P1.X implementation")

# Step 2: ACT ON ALL FINDINGS - No findings ignored
For EVERY issue identified by the review:
  1. Check source documents for authoritative guidance:
     - UNIFIED_ARCHITECTURE.md §X.X - Architecture patterns
     - SDD.md §X.X - Technical specifications
     - PRD.md US-XXX - Product requirements
     - BRAND_GUIDELINES.md - Visual standards

  2. Apply Source-Aligned Fix Decision:
     ┌─────────────────────────────────────────────────────────────┐
     │ FINDING → Check Source → Source Says X? → Implement X      │
     │                        → Source Silent? → Use 2025/2026    │
     │                                           Best Practice    │
     │                        → Conflicts?     → Source Wins      │
     └─────────────────────────────────────────────────────────────┘

  3. Fix Priority (NO EXCEPTIONS):
     - Critical/Security: Fix IMMEDIATELY before any other work
     - High: Fix in same commit batch
     - Medium: Fix before batch completion
     - Low/Informational: Fix if <5 min, otherwise document with deadline

# Step 3: Verify all fixes
pnpm typecheck && pnpm test && pnpm lint
```

**2025/2026 Cutting-Edge Best Practices (NO SHORTCUTS):**

```
MANDATORY PRACTICES - APPLY TO ALL CODE:

TypeScript 5.x:
- strict: true (no exceptions)
- noUncheckedIndexedAccess: true
- exactOptionalPropertyTypes: true
- Use 'satisfies' for type inference with validation
- Branded types for domain entities (CustomerId, JobId, etc.)

React 18/19:
- React.memo() only with profiled bottlenecks
- useCallback/useMemo with measured benefit
- Suspense boundaries for async operations
- Server Components where applicable (Next.js)
- Use React.use() for resource suspension (React 19)

Zod 3.x:
- z.input<> and z.output<> for transform types
- .brand<>() for nominal typing
- Coercion over manual parsing
- Error map customization for i18n

Hono.js 4.x:
- Type-safe routing with hono/typed
- Middleware composition over inheritance
- Streaming responses for large payloads
- Edge-optimized patterns (Cloudflare Workers)

Security (Zero-Trust):
- Input validation at EVERY boundary
- Output encoding for ALL user content
- Content Security Policy (strict-dynamic)
- Subresource Integrity for external scripts
- CSRF tokens with SameSite=Strict cookies
```

### Security Audit Integration

**MANDATORY: Use `security-expert` agent with OWASP 2021 checklist:**

```
Task(subagent_type="security-expert"):
"Audit implementation for security compliance using OWASP Top 10 (2021).

OWASP TOP 10 (2021) CHECKLIST - CHECK ALL:
A01:2021 - Broken Access Control
  [ ] Authorization checks on every protected endpoint
  [ ] Row-Level Security (RLS) in database queries
  [ ] No IDOR vulnerabilities (use UUIDs, verify ownership)
  [ ] Deny by default, allow explicitly

A02:2021 - Cryptographic Failures
  [ ] TLS 1.3 for all external connections
  [ ] Strong password hashing (Argon2id via Clerk)
  [ ] No sensitive data in URLs or logs
  [ ] Proper key management (env vars, not code)

A03:2021 - Injection
  [ ] Parameterized queries (Drizzle ORM)
  [ ] Input validation with Zod schemas
  [ ] Context-aware output encoding
  [ ] No dynamic code execution or string-based code building

A04:2021 - Insecure Design
  [ ] Threat modeling for new features
  [ ] Rate limiting on auth endpoints
  [ ] Account lockout after failed attempts
  [ ] Secure defaults (opt-in, not opt-out)

A05:2021 - Security Misconfiguration
  [ ] Security headers (CSP, X-Frame-Options, HSTS)
  [ ] Error messages don't leak info
  [ ] Debug mode disabled in production
  [ ] Unused features/endpoints removed

A06:2021 - Vulnerable Components
  [ ] pnpm audit --audit-level=high passes
  [ ] No known CVEs in dependencies
  [ ] Regular dependency updates
  [ ] Lock file integrity verified

A07:2021 - Authentication Failures
  [ ] Strong session management (Clerk handles)
  [ ] Multi-factor authentication available
  [ ] Password complexity requirements
  [ ] Session timeout and rotation

A08:2021 - Software/Data Integrity
  [ ] CI/CD pipeline integrity
  [ ] Signed commits (if configured)
  [ ] Dependency verification
  [ ] Secure deserialization

A09:2021 - Security Logging
  [ ] Authentication events logged
  [ ] Authorization failures logged
  [ ] No sensitive data in logs
  [ ] Log integrity protection

A10:2021 - Server-Side Request Forgery
  [ ] URL validation for external requests
  [ ] Allowlist for outbound connections
  [ ] No user-controlled redirect targets

FOR EVERY VULNERABILITY FOUND:
1. Stop current work immediately
2. Fix using pattern from UNIFIED_ARCHITECTURE.md §9
3. Add regression test to prevent recurrence
4. Verify: pnpm audit && pnpm test
5. Document fix in commit message

SECURITY AUDIT REPORT:
🔒 STATUS: [PASSED/FAILED]
📋 FINDINGS: [count] issues checked
✅ FIXED: [list with CVE/OWASP reference]
⚠️ ACCEPTED RISKS: [list with justification - rare]"
```

**2025/2026 Security Best Practices (NO SHORTCUTS):**

```
MANDATORY SECURITY PATTERNS:

Edge Security (Cloudflare Workers):
- Use Cloudflare Access for admin routes
- Rate limiting via Workers rate limit API
- DDoS protection via Cloudflare
- Bot management with Turnstile

Authentication (Clerk):
- JWT verification on every request
- Session token rotation
- Device fingerprinting awareness
- Passwordless options (passkeys, WebAuthn)

Data Protection:
- Field-level encryption for PII
- Tenant isolation via RLS
- Audit logging for compliance
- Right to deletion (GDPR)

API Security:
- API key rotation schedule
- Request signing for webhooks
- Idempotency keys for mutations
- Correlation IDs for tracing
```

### Source-Aligned Fix Policy

**CRITICAL: All fixes MUST align with source documentation:**

```
SOURCE-ALIGNED FIX DECISION TREE:

┌──────────────────────────────────────────────────────────────────────┐
│                         FINDING DETECTED                              │
│                              │                                        │
│                              ▼                                        │
│         ┌────────────────────────────────────────┐                   │
│         │ Search Source Documents for Guidance:  │                   │
│         │ 1. UNIFIED_ARCHITECTURE.md             │                   │
│         │ 2. SDD.md                              │                   │
│         │ 3. PRD.md                              │                   │
│         │ 4. BRAND_GUIDELINES.md                 │                   │
│         └────────────────────┬───────────────────┘                   │
│                              │                                        │
│              ┌───────────────┼───────────────┐                       │
│              ▼               ▼               ▼                       │
│     ┌────────────┐   ┌────────────┐   ┌────────────┐                │
│     │  SOURCE    │   │  SOURCE    │   │  SOURCE    │                │
│     │  EXPLICIT  │   │  SILENT    │   │  CONFLICTS │                │
│     └─────┬──────┘   └─────┬──────┘   └─────┬──────┘                │
│           │                │                │                        │
│           ▼                ▼                ▼                        │
│     Implement         Use 2025/2026     Source                       │
│     EXACTLY as        Best Practice     Documentation                │
│     documented        (documented)      ALWAYS WINS                  │
│                                                                       │
│  NEVER deviate from source documentation.                            │
│  NEVER take shortcuts even for "quick fixes".                        │
│  ALWAYS cite source in commit: @source DOCUMENT §SECTION             │
└──────────────────────────────────────────────────────────────────────┘

CITATION FORMAT IN COMMITS:

feat(auth): implement JWT validation middleware

Implements request-level JWT verification for all protected routes.

@source UNIFIED_ARCHITECTURE.md §4.3 Authentication Flow
@source SDD.md §5.2 Middleware Stack
@source PRD.md US-AUTH-003 Secure Session Management

🔒 Security: OWASP A07:2021 compliant
📋 Review: All findings addressed per /review-code

🤖 Generated with [Claude Code](https://claude.com/claude-code)
Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
```

### No-Surprise Guarantee

**All actions trace back to source documents:**

```
TRACEABILITY REQUIREMENTS:

Every implementation decision must cite:
- @source PRD.md US-XXX for feature requirement
- @source UNIFIED_ARCHITECTURE.md §X.X for technical pattern
- @source SDD.md §X.X for specification detail
- @source BRAND_GUIDELINES.md for visual decisions

Every commit message must include:
- Task identifier (P1.X)
- User story reference (US-XXX)
- Source document citations

Example:
```

feat(crm): implement customer list with pagination

Implements customer listing with cursor-based pagination.

@source PRD.md US-030 - Owner can view all customers @source
UNIFIED_ARCHITECTURE.md §6.3 - Cursor pagination @source SDD.md §4.2 - Customer
data model

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>

```

NO DEVIATION ALLOWED:
- Implementation must match documented specification
- No "improvements" beyond what's documented
- No additional features not in PRD
- No architectural changes not in UNIFIED_ARCHITECTURE
```

### Resolution Progress Tracking

**Progress Tracker Agent maintains state:**

```json
// .claude/state/todo-resolution-progress.json
{
  "lastUpdated": "2025-12-26T15:45:00Z",
  "totalItems": 85,
  "completed": 42,
  "inProgress": 1,
  "blocked": 3,
  "remaining": 39,
  "currentTask": {
    "id": "P1.9",
    "name": "Customer Management/CRM",
    "startedAt": "2025-12-26T15:30:00Z",
    "sources": ["PRD.md US-030", "UNIFIED_ARCHITECTURE.md §6"],
    "status": "implementing"
  },
  "blockedTasks": [
    {
      "id": "P1.11",
      "reason": "Depends on P1.9 (customer schema)",
      "blockedBy": "P1.9"
    }
  ],
  "completionLog": [
    {
      "id": "P1.6",
      "completedAt": "2025-12-25T10:00:00Z",
      "commitHash": "abc123",
      "reviewsPassed": ["code-review", "security-audit", "qa-gate"]
    }
  ]
}
```

### Continuous Resolution Loop

**In `--continuous` mode, resolution runs indefinitely:**

```
RESOLUTION LOOP:

while (uncompleted_todos.length > 0) {
  1. Get next TODO by priority order
  2. Check dependencies met
  3. If blocked: skip, try next independent task
  4. Assign specialist agent
  5. Implement with source citations
  6. Verify with CLI (typecheck, lint, test, audit)
  7. Verify with Playwright (if UI change)
  8. Run /review-code and fix all issues
  9. Run security audit and fix all issues
  10. Pass QA gate
  11. Commit with semantic message
  12. **Mark task complete in fix_plan.md:** `- [ ]` → `- [x]` (use Edit tool!)
  13. Update CODE_INVENTORY.md
  14. Continue to next `- [ ]` in fix_plan.md

  On CI failure:
    → Task Dependency Analyzer identifies blocked vs safe
    → CI Fix Agents deploy to fix failures
    → Safe tasks continue in parallel
    → Blocked tasks resume after fix

  On context limit (85%):
    → Save state to .claude/state/todo-resolution-progress.json
    → Commit all work in progress
    → Trigger /compact
    → Resume with /develop --continuous --resume
}

On all TODOs complete:
  → Final QA verification
  → Update all documentation
  → Report: "✅ PHASE COMPLETE: All P1.x items resolved"
```

### Resolution Signals

| Signal              | Meaning                     | Action                     |
| ------------------- | --------------------------- | -------------------------- |
| `TODO_SCANNING`     | Parsing TODO.md             | Wait for priority queue    |
| `TODO_ASSIGNED`     | Task assigned to agent      | Agent begins work          |
| `TODO_IMPLEMENTING` | Implementation in progress  | Monitor for completion     |
| `TODO_VERIFYING`    | CLI/Playwright verification | Wait for results           |
| `TODO_REVIEWING`    | Code review in progress     | Wait for fixes             |
| `TODO_FIXING`       | Auto-fixing review issues   | Wait for completion        |
| `TODO_APPROVED`     | QA gate passed              | Proceed to commit          |
| `TODO_COMMITTED`    | Commit and push complete    | Monitor CI                 |
| `TODO_COMPLETE`     | Task fully resolved         | Move to next task          |
| `TODO_BLOCKED`      | Dependency not met          | Skip, try independent task |
| `TODO_FAILED`       | Unrecoverable error (rare)  | Log and escalate           |

---

## 🔄 AUTOMATION ESCALATION CHAIN (MANDATORY)

**Human action is the LAST RESORT.** Before adding ANY task to `@human_actions.md`,
you MUST exhaust all automation options AND document what you tried.

### Step 0: SEARCH FOR EXISTING RESOURCES (ALWAYS DO THIS FIRST)

Before attempting ANY external service task, run these searches:

```bash
# 1. Search for documentation
find docs -iname "*servicename*" 2>/dev/null
# Example: find docs -iname "*stripe*" -o -iname "*cloudflare*"

# 2. Check for CLI availability
which stripe wrangler gh neonctl 2>/dev/null

# 3. Check for existing credentials
grep -r "SERVICENAME" .env .env.local .env.production 2>/dev/null
# Example: grep -r "STRIPE\|CLOUDFLARE" .env* 2>/dev/null

# 4. Check for setup guides
ls docs/guides/setup/ | grep -i servicename

# 5. Check existing integrations
find apps packages -name "*servicename*" -type f 2>/dev/null
```

**If docs exist, READ THEM before attempting configuration!**

### Escalation Order (Follow Strictly)

```
0. SEARCH DOCS      → find docs -iname "*service*" (READ what you find!)
1. CLI TOOLS        → Try first (wrangler, gh, stripe, neonctl)
2. ENVIRONMENT VARS → Check .env files for existing secrets
3. PLAYWRIGHT       → Automate browser-based dashboards
4. SPECIALIZED AGENTS → Use expert agents with specific knowledge
5. ONLY THEN        → Add to @human_actions.md WITH attempt log
```

### MANDATORY: Document All Attempts

When adding to @human_actions.md, you MUST include:

```markdown
- **Automation Attempted**:
  - ✅ Docs found: `docs/guides/setup/STRIPE_SETUP.md` (read and followed)
  - ✅ CLI check: `stripe --version` → v1.34.0 available
  - ❌ CLI attempt: `stripe connect accounts list` → Error: Not authenticated
  - ❌ Env vars: STRIPE_SECRET_KEY not set in any .env file
  - ❌ Playwright: Requires 2FA which cannot be automated
- **Why Human Required**: [specific reason automation failed]
```

**If you cannot show what you tried, DO NOT escalate to human action.**

### Service-Specific CLI Commands

**Cloudflare (R2, Workers, DNS)**

```bash
wrangler r2 bucket list                    # List all buckets
wrangler r2 bucket create <name>           # Create bucket
wrangler secret put <KEY>                  # Set Worker secret
wrangler secret list                       # List secrets
```

**GitHub (Secrets, Actions)**

```bash
gh secret set SECRET_NAME                  # Set secret
gh secret list                             # List secrets
gh run list                                # List workflow runs
gh run rerun <run-id>                      # Rerun failed workflow
```

**Stripe (Payments, Webhooks)**

```bash
stripe listen --forward-to localhost:3000  # Forward webhooks locally
stripe trigger payment_intent.succeeded    # Test webhook events
stripe products list                       # List products
```

**Neon (PostgreSQL)**

```bash
neonctl projects list                      # List projects
neonctl connection-string                  # Get connection string
neonctl databases create --name <name>     # Create database
```

### Playwright Automation Fallback (USE THIS BEFORE HUMAN ESCALATION)

**You have full Playwright access via MCP tools.** USE IT before escalating to human!

**Available MCP Playwright Tools:**

- `mcp__plugin_playwright_playwright__browser_navigate` - Go to URL
- `mcp__plugin_playwright_playwright__browser_snapshot` - See page state
- `mcp__plugin_playwright_playwright__browser_click` - Click elements
- `mcp__plugin_playwright_playwright__browser_type` - Type text
- `mcp__plugin_playwright_playwright__browser_fill_form` - Fill forms

**Workflow for Dashboard Automation:**

```
1. Navigate to dashboard URL
2. Take snapshot to see current state and get element refs
3. Fill login form if needed (check .env for credentials)
4. Navigate to target section
5. Fill forms / click buttons
6. Verify success
```

**Example: Stripe Dashboard Automation**

```
// 1. Navigate
mcp__plugin_playwright_playwright__browser_navigate({ url: 'https://dashboard.stripe.com' })

// 2. Snapshot to see login form
mcp__plugin_playwright_playwright__browser_snapshot()

// 3. If logged out, fill login (check .env for STRIPE_EMAIL, STRIPE_PASSWORD)
mcp__plugin_playwright_playwright__browser_fill_form({ fields: [
  { name: 'email', type: 'textbox', ref: '<from-snapshot>', value: process.env.STRIPE_EMAIL }
]})

// 4. Navigate to Connect settings
mcp__plugin_playwright_playwright__browser_click({ element: 'Connect', ref: '<from-snapshot>' })

// 5. Continue automating...
```

**Example: Cloudflare R2 Bucket Creation**

```
// 1. Navigate to Cloudflare
mcp__plugin_playwright_playwright__browser_navigate({ url: 'https://dash.cloudflare.com' })

// 2. Snapshot, find R2 link
mcp__plugin_playwright_playwright__browser_snapshot()

// 3. Click R2 Object Storage
mcp__plugin_playwright_playwright__browser_click({ element: 'R2 Object Storage', ref: '<ref>' })

// 4. Click Create bucket
mcp__plugin_playwright_playwright__browser_click({ element: 'Create bucket', ref: '<ref>' })

// 5. Fill bucket name
mcp__plugin_playwright_playwright__browser_type({
  element: 'bucket name input',
  ref: '<ref>',
  text: 'cleanscale-uploads'
})
```

**When Playwright CANNOT work (legitimate human escalation):**

- 2FA/MFA that requires authenticator app or SMS
- Identity verification (upload ID, video selfie)
- Payment information entry (credit card)
- Legal agreements requiring human acknowledgment
- Physical device pairing

### Environment Variable Check

Before claiming a secret is missing, CHECK:

```bash
# Check all .env files
grep -E "CLOUDFLARE|STRIPE|CLERK|GITHUB|NEON" .env .env.local .env.production 2>/dev/null

# Secrets are often already configured!
```

### Specialized Agents

Before escalating, try the appropriate specialist:

- `cloudflare-expert` → R2, Workers, D1, DNS
- `devops-automation-expert` → CI/CD, deployment
- `security-expert` → Secrets management
- `git-expert` → GitHub API, Actions
- `macos-signing-expert` → Apple notarization, code signing

### When to Escalate to Human

ONLY escalate to `@human_actions.md` when:

1. ❌ CLI tool requires interactive 2FA you cannot provide
2. ❌ Account creation requires human identity verification
3. ❌ Payment/billing information needs to be entered
4. ❌ Physical hardware access is required
5. ❌ Legal/compliance approval is needed
6. ❌ All automation attempts have failed with documented errors

### Adding to @human_actions.md

When escalation IS necessary:

1. Document what automation was attempted
2. Explain why each attempt failed
3. Provide clear step-by-step instructions
4. List all tasks that will be unblocked
5. Include verification command to confirm completion

```markdown
### [HA-XXX] Task Title

- **Automation Attempted**:
  - ❌ CLI: `wrangler r2 bucket create` - Error: Not authenticated
  - ❌ Playwright: Dashboard automation - Error: 2FA required
  - ❌ Agent: cloudflare-expert - Error: Account not linked
- **Why Human Required**: Requires initial 2FA setup with authenticator app
- **Instructions**: [step-by-step guide]
- **Blocking Tasks**: [list of task IDs]
- **Verification**: `wrangler r2 bucket list | grep bucket-name`
```

### Human Action Completion Flow

When human completes an action:

1. Human marks `- [x]` in @human_actions.md
2. Next sync run detects completion
3. Blocked tasks in fix_plan.md become actionable
4. Ralph automatically picks up newly unblocked tasks

### Reference Documentation

Full automation capabilities: `/docs/operations/AUTOMATION_CAPABILITIES.md`
