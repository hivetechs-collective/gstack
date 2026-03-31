# Step 2: Create Task Breakdown

Using TaskCreate, create tasks with metadata and dependencies:

```
TaskCreate({
  subject: "Implement alerting system",
  description: "Full implementation details...",
  activeForm: "Implementing alerting system",
  metadata: {
    spec_path: "docs/specs/feature-name.md",
    feature_area: "alerting",
    effort: "high",
    scope: "BACKEND",
    completeness: 9,
    door_type: "one-way"
  }
})
```

Tasks are created **unassigned**. Use TaskUpdate(addBlockedBy) for dependency chains.

Decompose by **feature** (not by file) — each task owns all files for its feature area.

## Shared File Conflict Detection (MANDATORY)

After task breakdown, run a file-touch analysis before proceeding to execution:

1. **List files each task will modify** — include in task description as `files_touched: [...]`
2. **Detect overlaps** — any file appearing in 2+ tasks is a **shared file**
3. **Resolve overlaps** using one of these strategies:

| Overlap Type                                                 | Strategy                                                                                                                                                              | Example                                                                       |
| ------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------- |
| Barrel/entrypoint file (`index.ts`, `mod.rs`, `__init__.py`) | Designate ONE task as the "barrel owner" — only that task edits the barrel. Other tasks add their exports to task description; barrel owner consolidates all exports. | 3 tasks add services → T1 owns `index.ts`, T2/T3 note "T1 will add my export" |
| Shared config/types file                                     | Consolidate into a single task or assign exclusive ownership                                                                                                          | Two tasks need new types → create T0 "shared types" task, block T1/T2 on T0   |
| Same feature file from different angles                      | Merge into one task                                                                                                                                                   | Two tasks both modify `auth.ts` → combine into single auth task               |

**Why this matters**: In the factory-orchestrator retro (2026-03), multiple agents editing `index.ts` required manual merge coordination and one agent operated on a stale version. This step prevents that class of problems entirely.

4. **Record shared file owners** in task metadata: `shared_file_owner: true` for the owning task
5. **Add dependency edges** — tasks that need the barrel owner's changes should `addBlockedBy` the owner task, or be scheduled to merge after it

## Task Metadata Fields

| Field          | Required | Values                  | Purpose                                   |
| -------------- | -------- | ----------------------- | ----------------------------------------- |
| `spec_path`    | Yes      | File path               | Links task to spec for resumption         |
| `feature_area` | Yes      | String                  | Groups related tasks                      |
| `effort`       | Yes      | `high`, `medium`, `low` | Controls builder thinking depth           |
| `scope`        | Yes      | See scope tags below    | Enables conditional review steps          |
| `completeness` | No       | 1-10                    | How thorough the implementation should be |
| `door_type`    | No       | `one-way`, `two-way`    | Extra review scrutiny for one-way doors   |

## Effort Levels

| Effort   | Use For                                           | Builder Behavior                           |
| -------- | ------------------------------------------------- | ------------------------------------------ |
| `high`   | Architectural tasks, complex logic, one-way doors | Thorough design consideration              |
| `medium` | Standard implementation (default if omitted)      | Balanced approach                          |
| `low`    | Simple file changes, config updates               | Direct implementation, no over-engineering |

## Scope Tags

Classify each task's change type. These tags control which review steps run in Step 5.

| Scope      | Description                       | Triggers                             |
| ---------- | --------------------------------- | ------------------------------------ |
| `FRONTEND` | UI components, styles, layouts    | Design review lite, AI slop check    |
| `BACKEND`  | Server logic, APIs, services      | SQL safety, race condition review    |
| `DATABASE` | Schema changes, migrations        | One-way door scrutiny, rollback plan |
| `CONFIG`   | Environment, build, deploy config | Minimal review                       |
| `TESTS`    | Test files only                   | Coverage audit                       |
| `DOCS`     | Documentation only                | Consistency check                    |

## Dual Time Estimates

For each task, provide two effort estimates:

- **Human effort**: How long this would take a developer manually
- **AI effort**: How long this takes with builder agents

This shifts cost-benefit analysis toward completeness. When AI effort is 10x lower than human effort, the threshold for "worth doing thoroughly" drops dramatically.

## Bisectable Commit Ordering

Order tasks by dependency graph for bisectability:

1. Infrastructure (config, schemas, types) — first
2. Models and services — second
3. Controllers and views — third
4. Tests — fourth
5. Documentation, VERSION, CHANGELOG — last

Every intermediate state after merging completed tasks must compile and pass tests. This ensures `git bisect` always lands on a runnable state.
