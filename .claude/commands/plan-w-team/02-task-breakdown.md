# Step 2: Create Task Breakdown

<!-- PWT-T2 Orchestrator Retrofit (2026-05-18)
     Pause sites in this file routed via .claude/scripts/plan-w-team-orchestrator-route.sh
     Classifier: shared/orchestrator-interception.md

     | Call-site label              | Verdict      | Original behavior                           |
     | ---------------------------- | ------------ | ------------------------------------------- |
     | task-breakdown-granularity   | orchestrator | Coarse-vs-fine task split decision           |
     | scope-unlock-for-drift       | user         | Mid-flight scope expansion (kept as user)    |

     Safe-fail: if router unavailable, falls through to AskUserQuestion.
     Kill switch: PLAN_W_TEAM_DISABLE_ORCHESTRATOR=1
-->

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

When the optimal task granularity is ambiguous (e.g., should a complex module be one task or three?), route through the orchestrator:

```bash
# snippet-lint: skip — illustrative orchestrator routing
GRANULARITY=$(route_orchestrator task-breakdown-granularity "$SLUG" \
  "module=$MODULE" \
  "file_count=$FILE_COUNT" \
  "options=single-task,split-by-layer,split-by-feature")
```

<!-- Original: implicit pause — lead asked user for task granularity guidance.
     Orchestrator decides based on complexity signals + file count.
     Fall-through: AskUserQuestion if router unavailable. -->

## Specialist Agent Assignment (MANDATORY)

Before proceeding to execution, assign each task to the best specialist agent:

1. **Read the agent roster**: `Read .claude/commands/plan-w-team/shared/agent-roster.md` — this lists all 85+ specialist agents organized by domain with their `subagent_type` values
2. **Assign `agent_type`** in each task's metadata matching the roster:

   ```
   TaskCreate({
     subject: "Implement WebSocket message handler",
     metadata: {
       ...
       agent_type: "nodejs-specialist"   // ← from agent-roster.md
     }
   })
   ```

3. **Use the most specific match** — prefer `fastapi-specialist` over `builder` for a Python API task, `react-typescript-specialist` over `nodejs-specialist` for React UI work
4. **Fall back to `builder`** only when no specialist fits the task domain

**Why this matters**: Without `agent_type`, builders spawn as generic `general-purpose` agents. Specialists bring domain expertise AND show their assigned name/color in tmux panes for visual tracking.

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

### New Type Dependency Detection (MANDATORY)

After file-touch analysis, check for **new types/interfaces** that one task creates and another task needs. This is the #1 source of post-merge type duplication when using worktree isolation (since worktrees fork from the same base commit and can't see each other's new types).

1. **For each task, identify new types it will create** — add to task description as `creates_types: [{name, location}]`
2. **Cross-reference**: If task T4 needs a type that T1 will create, this is a **new-type dependency**
3. **Resolve** using one of:

| Pattern          | Strategy                                                                                                                                                                       | When to use                                                             |
| ---------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------- |
| Extract T0       | Create a "shared types" task that all dependent tasks block on. T0 creates and commits the types before parallel builders fork.                                                | Multiple tasks depend on the same new types                             |
| Inline in prompt | Include the exact type definition in dependent builder prompts with: "Create this type at `{location}` — it will be identical to what T1 creates, and merge will deduplicate." | Only 1-2 dependent tasks, types are small and stable                    |
| Sequentialize    | Make T4 `addBlockedBy` T1                                                                                                                                                      | Type definition is complex or likely to evolve during T1 implementation |

**Default**: Extract T0. It adds one serial step but eliminates an entire class of post-merge fixes.

4. **Annotate in files_touched** — distinguish create vs modify:
   ```
   files_touched: ["src/types/critic.ts (create)", "src/services/review.ts (modify)"]
   ```
   Builders use this to know: `(create)` → Write new file, `(modify)` → Read first, then Edit

## Import-Coupling Check (MANDATORY)

After file-touch and new-type analysis, run the deterministic import-coupling analyzer. This catches structural coupling that the manual file/type review can miss — e.g., task A's file imports a type from a file task B is also editing, or two tasks both depend on a shared utility neither of them owns.

```bash
SLUG="<feature-slug>"
# Serialize the current task list (id + files_touched only) to JSON, then pipe.
# In practice the lead runs:
#   TaskList → filter to this run's tasks → write to /tmp/tasks-$SLUG.json
npx tsx .claude/scripts/plan-w-team-import-coupling.ts \
  --slug "$SLUG" \
  --tasks-json /tmp/tasks-"$SLUG".json
```

The analyzer writes its report to `.claude/state/plan-w-team-coupling-$SLUG.json` (registered in `shared/state-artifacts.md`) and prints a human-readable summary. Exit code carries the verdict:

| Exit | Meaning                            | Lead action                                                                                        |
| ---- | ---------------------------------- | -------------------------------------------------------------------------------------------------- |
| `0`  | No coupling detected               | Proceed to scope-lock                                                                              |
| `1`  | Coupling detected, no ack          | Choose a resolution (table below), then EITHER fix the breakdown and re-run, OR write the ack file |
| `2`  | Coupling detected and acknowledged | Proceed to scope-lock; the ack is recorded                                                         |
| `3`  | Environment error                  | Fix input/IO and re-run                                                                            |

### Resolution strategies (consume the report's `kind` field)

| Coupling kind                                   | What the report says                           | Strategy                                                                                                                                                                           |
| ----------------------------------------------- | ---------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `direct` (A imports a file owned by B)          | `evidence[].imports` is in B's `files_touched` | Merge tasks, OR designate one task as `shared_file_owner: true` and add `addBlockedBy` so the dependent task waits for it. Same options as the file-overlap table above.           |
| `transitive` (A and B both import a third file) | `shared_target` names the third file           | Default: extract a T0 shared-types task that owns `shared_target`, then `addBlockedBy: [T0]` on both A and B. This mirrors §New Type Dependency Detection's "Extract T0" strategy. |

### Acknowledgement escape hatch

If the lead has reviewed the matrix and accepts the coupling (e.g., a small, intentional cross-cut), create an ack file with a one-line justification:

```bash
echo "intentional: T1 owns canonical type, T2 reads it for read-only consumption" \
  > .claude/state/plan-w-team-coupling-ack-"$SLUG"
```

Re-run the analyzer; it returns exit 2. The ack file (registered in `shared/state-artifacts.md` as mode `handoff`) is preserved so Step 5 review and Step 8 retro can audit the decision.

### Why this is enforcing, not advisory

Post-merge type duplication is the single most-cited Stage 2 pain point (this exists section, and the §New Type Dependency Detection block above). The check exists to make the cross-reference deterministic instead of asking the lead to spot it by reading. If the report shows coupling and there is no ack, the scope-lock writer below refuses to proceed.

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

## Paired Task Protocol (UI features)

When `ui_scope_flag == true` from §0e, decompose each UI feature slice into a **paired task set**:

| Task  | Role                                   | Blocked by | Scope      | Agent                                                                                                       |
| ----- | -------------------------------------- | ---------- | ---------- | ----------------------------------------------------------------------------------------------------------- |
| `N.a` | Write Playwright tests (FAILING — red) | (none)     | `TESTS`    | `stagehand-expert` or `unit-testing-specialist`                                                             |
| `N.b` | Implement UI to make N.a pass (green)  | `N.a`      | `FRONTEND` | `react-typescript-specialist` / `vue-specialist` / `svelte-specialist` / `angular-specialist` per framework |

**Rules**:

- `N.a` commits specs that FAIL against current main. Builder verifies failure before marking complete.
- `N.b` cannot claim its task until `N.a` is committed and merged. `blockedBy: ["<N.a-task-id>"]` is MANDATORY.
- Every interactive element in `N.a` specs uses `data-testid` exclusively. Locator-hierarchy fallbacks only apply when `N.b` cannot add a `data-testid` (e.g., third-party widget); require justification in the spec file.
- `N.b` may ONLY edit the files named in its `files_touched`. No "convenience refactors" in adjacent files — those go in a separate task.
- Page objects live at `{{TEST_DIR}}/pages/<feature>.page.ts` and are created/edited as part of `N.a` (so the contract is test-owned, not implementation-owned).

**Rationale**: paired tasks preserve the red-green-refactor discipline even when builders run in parallel. `N.a` defines the testable contract before any UI code exists, which is the only robust way to prevent `N.b` from shipping untested happy paths.

## Paired Task Protocol (non-UI scopes) — STE Extension

The paired-task discipline also applies to **non-UI scopes that add new code**. Any task whose `scope` is in `[BACKEND, INFRASTRUCTURE, SCRIPTS, LIBRARY, API]` AND whose mode is `add` (creates new functions, classes, modules, endpoints — not `refactor`-only, not `docs`-only, not pure `config`) gets the same `N.a` (failing tests) + `N.b` (implementation) decomposition.

| Task  | Role                               | Blocked by | Scope (mirrors parent task) | Agent                                                                                                                                                            |
| ----- | ---------------------------------- | ---------- | --------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `N.a` | Write unit tests (FAILING — red)   | (none)     | `TESTS`                     | `unit-testing-specialist` — or a language-specific test specialist when available (e.g., `python-test-specialist`, `rust-test-specialist`, `go-test-specialist`) |
| `N.b` | Implement to make N.a pass (green) | `N.a`      | original (BACKEND/INFRA/…)  | language/framework specialist matched per `shared/agent-roster.md` (e.g., `nodejs-specialist`, `rust-backend-specialist`, `fastapi-specialist`)                  |

**Trigger expression** (the same shape used by all other paired-task gates):

```
ui_scope_flag == true
  OR (scope ∈ {BACKEND, INFRASTRUCTURE, SCRIPTS, LIBRARY, API} AND mode == "add")
```

**Single-task exceptions** (no pairing):

- `mode == "refactor"` — refactor-only tasks are constrained by existing tests; do not pair.
- `mode == "docs"` — documentation-only tasks pair would be vacuous.
- `mode == "config"` — pure config changes (env, build flags) without behavioral surface.
- `scope == "DATABASE"` schema migrations — paired test discipline lives in Step 5 (one-way-door reviewer scrutiny) instead of N.a/N.b.

**Rules** (mirror UI block):

- `N.a` commits unit tests that FAIL against current main. Builder verifies failure before marking complete.
- `N.b` cannot claim its task until `N.a` is committed and merged. `blockedBy: ["<N.a-task-id>"]` is MANDATORY.
- `N.b` may ONLY edit the files named in its `files_touched`. No drive-by refactors.
- Test files live next to the unit under test by repo convention (e.g., `foo.test.ts` next to `foo.ts`; `tests/test_foo.py` for pytest layout). The `N.a` builder reads existing test layout before placing new tests.

**Rationale**: the test-coverage gap between UI and non-UI scope was a 2026-05 retro finding — UI features ship behind paired Playwright contracts; backend features historically ship as single tasks with "tests added later." This unifies discipline. Refactor/docs/config keep single-task decomposition because the test-first contract doesn't apply (no new behavioral surface to assert against).

## Paired Task Protocol (security review) — Security Review Extension

In addition to the test-pairing rules above, **security-sensitive code-adding tasks** receive a paired `N.s` security-review task. The trigger has two layers — a filename/glob layer (mode-gated) and a content-signal layer that fires on what the diff _does_ (filename- AND mode-independent). EMIT a paired `N.s` when **either** layer holds:

```
(1) Filename/glob layer (mode-gated):
    scope ∈ {BACKEND, INFRASTRUCTURE, SCRIPTS, LIBRARY, API}
    AND mode == "add"
    AND ( files_touched intersects security-relevant surfaces (auth/secret/input-validation/injection/deserialization/crypto/SSRF/XSS)
          OR files_touched intersects any glob in shared/governance-tags.md
          OR files_touched intersects any OWASP category glob in shared/owasp-top10-mapping.md )

(2) Content-signal layer (forces N.s regardless of filename OR mode):
    diff_content matches any CONTENT-SIGNAL CS-1..CS-4
      CS-1  privilege-bearing field write (role, platformRole, tenantId/orgId, isQaUser,
            ownerId, isAdmin, permissions, passwordHash, balance, *Cents)
      CS-2  request-body spread into an ORM update/insert (.set({...body}), ...req.body,
            Object.assign(row, input))
      CS-3  service/bypass/QA/admin-token-gated handler (QA_SIM_TOKEN, *_BYPASS_*)
      CS-4  where/query-by-id lacking a tenant/owner predicate
    → see shared/owasp-top10-mapping.md §Content-Signal Triggers.
```

Layer (2) is the access-control coverage fix: the two bugs that escaped the pipeline on 2026-06-01 (`platformRole` escalation in `qa-sim.ts`, cross-tenant `assignedTo` in `jobs.ts`) lived in normally-named route files that matched no glob in layer (1). A "refactor" that introduces a body-spread or drops a tenant predicate is **not** exempt — see Single-task exceptions below.

| Task  | Role                                                       | Blocked by | Scope (mirrors parent task) | Agent             |
| ----- | ---------------------------------------------------------- | ---------- | --------------------------- | ----------------- |
| `N.s` | Security review against the implemented N.b surface output | `N.b`      | `TESTS` (review-pass)       | `security-expert` |

**Security-relevant surface globs** (the same list that drives OWASP attribution in `shared/owasp-top10-mapping.md`):

```
**/auth/**, **/login*, **/session*, **/jwt*, **/oauth*, **/mfa*,           # A07 Auth
**/secret*, **/key*, **/credential*, **/.env*,                              # A05/A08 Secrets
**/validate*, **/sanitize*, **/input*,                                      # A03 Injection / A05 Misconfig
**/sql*, **/query*, **/db.ts, **/db.py,                                     # A03 SQL injection
**/deserialize*, **/parse*, **/marshal*,                                    # A08 Deserialization
**/crypto*, **/hash*, **/encrypt*, **/cipher*, **/sign*,                    # A02 Crypto
**/fetch*, **/request*, **/proxy*, **/url*, **/http*, **/webhook*,          # A10 SSRF
**/render*, **/template*, **/html*,                                         # A03 XSS
**/rbac/**, **/permission*, **/policies/**, **/acl*                         # A01 Access Control
```

**Diff-content security signals** (force `N.s` regardless of filename — the layer (2) trigger). These catch Broken Access Control (OWASP #1) in ordinarily-named route files. Each maps to A01 plus an API Security Top 10 (2023) class:

| Signal | What the diff does                                                                                                        | Category           |
| ------ | ------------------------------------------------------------------------------------------------------------------------- | ------------------ |
| CS-1   | writes a privilege-bearing field (`role`, `platformRole`, `tenantId`, `isQaUser`, `isAdmin`, `passwordHash`, `*Cents`, …) | A01 / API3 (BOPLA) |
| CS-2   | spreads request body into an ORM update/insert (`.set({...body})`, `...req.body`)                                         | A01 / API3 (BOPLA) |
| CS-3   | gates a handler behind a service / bypass / QA / admin token (`QA_SIM_TOKEN`, `*_BYPASS_*`)                               | A01 / API5 (BFLA)  |
| CS-4   | runs a where/query-by-id without a tenant/owner predicate                                                                 | A01 / API1 (BOLA)  |

The `N.s` review uses `shared/access-control-invariants.md` (INV-1…INV-5) as its rubric for any content-signal hit. Canonical signal definitions live in `shared/owasp-top10-mapping.md` §Content-Signal Triggers.

**Rules** (mirror UI and STE non-UI paired-task blocks):

- `N.s` runs `security-expert` against the implemented `N.b` output. `blockedBy: ["<N.b-task-id>"]` is MANDATORY — security review evaluates the implemented code, not a spec.
- `N.s` consumes `shared/owasp-top10-mapping.md` to attribute findings to OWASP Top 10 categories and to determine which security tiers (per `shared/security-tiers.md`) must show evidence at ship.
- `N.s` may add or extend security tests (input-validation cases, auth-boundary assertions, injection-payload coverage). It may NOT change `N.b` production code without re-routing through the orchestrator (`security-fix-vs-defer` decision).
- Test files for `N.s` live alongside their `N.a` counterparts (e.g., `foo.security.test.ts` next to `foo.test.ts`; `tests/security/test_foo.py` for pytest layouts).

**Single-task exceptions** (no `N.s` pairing — same exclusions as STE):

- `mode == "refactor"` — refactor changes are constrained by existing security tests; do not pair — **UNLESS the diff matches a content signal CS-1…CS-4** (e.g. a refactor that swaps in `.set({...req.body})` or drops a tenant predicate). The content-signal layer (2) overrides every mode-based exemption in this list except `docs`.
- `mode == "docs"` — documentation has no security surface (no code diff to match a content signal).
- `mode == "config"` UNLESS the config touches `**/.env*` / secret wiring (A05 misconfiguration surface) OR the diff matches a content signal — config touching credentials or a privilege-bearing default gets a `N.s`.
- `scope == "DATABASE"` schema migrations — security review (RLS, GRANT, column-level encryption) lives in Step 5 one-way-door reviewer scrutiny instead of `N.s`. (A migration matching a content signal is still caught at Step 5 §5b and gated by §6c-ter.)

**Rationale**: the security-rigor gap between UI/non-UI tests and security review was the parallel finding to the 2026-05 STE retro — UI features ship behind paired Playwright contracts; non-UI features (post-STE) ship behind paired unit tests; but **security** review for code touching auth, secrets, injection paths, etc. remained ad-hoc. This block closes that gap. The surface globs above are deliberately the same set used by the OWASP map so forward-scoping (`N.s` emission) and retroactive analysis (`security-gap-analyzer` at Step 5) agree on what counts as a "security-relevant" file.

**Cost discipline**: `N.s` is a review pass, not a re-implementation. If `security-expert` finds high-severity issues, the orchestrator routes the fix-vs-defer decision through `pass-2-ask` (see `04-fix-first-review.md`) rather than letting `N.s` rewrite `N.b`. **Exception**: a confirmed high-severity broken-access-control finding in the diff's own touched code (A01 / API1 / API3 / API5 — cross-tenant IDOR, privilege-field/mass-assignment, or bypass-token) is **gating, not deferrable** — it is a Pass-1 CRITICAL that blocks ship per `04-fix-first-review.md` §5d-ter and `05-ship.md` §6c-ter.

## Hot-Path Overlay (STE Extension)

For any task touching a **hot-path file** — defined as ANY of:

- file size **>1000 LOC** (raw `wc -l` on the file), OR
- **>50 commits in the last 30 days** touching that file (`git log --since='30 days ago' --oneline -- <file> | wc -l`)

Step 2 emits an additional **optional task slot** for `perf-testing-specialist` to author a benchmark. The slot is offered, not enforced: the lead can decline it for low-risk edits, accept it for performance-sensitive changes, or auto-skip when a benchmark already exists for the touched file.

| Task  | Role                                            | Blocked by | Scope   | Agent                     | Required? |
| ----- | ----------------------------------------------- | ---------- | ------- | ------------------------- | --------- |
| `N.p` | Author or extend a micro-benchmark for the file | (none)     | `TESTS` | `perf-testing-specialist` | optional  |

**Heuristic detection** (Step 2 runs once per touched file):

```bash
# snippet-lint: skip — illustrative hot-path detection
for f in $TOUCHED_FILES; do
  [ -f "$f" ] || continue
  LINES=$(wc -l < "$f" 2>/dev/null || echo 0)
  CHANGES_30D=$(git log --since="30 days ago" --oneline -- "$f" 2>/dev/null | wc -l | tr -d ' ')
  if [ "$LINES" -gt 1000 ] || [ "$CHANGES_30D" -gt 50 ]; then
    echo "[hot-path] $f (lines=$LINES, changes_30d=$CHANGES_30D) — emit optional N.p benchmark slot"
  fi
done
```

**Shallow-clone safety**: if `git log` returns empty (e.g., depth-1 CI clone), fall back to LOC-only detection. Hot-path identification must NOT block planning.

**Default**: skip. The slot is emitted so the lead has the option; explicit accept moves the slot into the task list. Step 5 review treats missing benchmark on a hot-path-modifying PR as INFORMATIONAL (not CRITICAL) unless the task is also tagged `door_type: one-way`, in which case TO2 mutation testing AND a benchmark together become CRITICAL gates (see §TO2 Mutation Default-On below).

## TO2 Mutation Default-On for One-Way-Door PRs (STE Extension)

When ANY task in this run has `door_type: one-way`, TO2 mutation testing is **default-on** for the affected files. This is enforced (not advisory) by `04-fix-first-review.md` §Mutation-Gate and `05-ship.md` §Ship Gate — Mutation Floor.

How "enforced default-on" works in practice:

- Step 2 sets `mutation_required: true` in the task metadata for every task whose `door_type == one-way` AND whose files contain testable code (skip pure-doc/config one-way changes — e.g., a renamed env var).
- Step 5 review runs the detected mutation tool (`stryker.config.{ts,js}`, `mutmut.cfg`, `pitest.xml`, etc.) on the changed files. **Mutation-survived rate >5% = CRITICAL**, blocking merge.
- Step 6 ship gate re-asserts the mutation report exists and passes the threshold. Absence of a mutation runner on a one-way-door PR with code changes raises an INFORMATIONAL ASK to the user (offer to install or to record the gap in `.claude/state/coverage-policy.txt`).

**Why this is enforced rather than opt-in**: one-way-door changes (DB schema, public API shape, data migration) are precisely the changes where "the tests passed" is least sufficient — surviving mutants reveal weak assertions. The 5% threshold matches industry consensus (Stryker default rejects below 60% mutation score; >5% survived = <95% killed). Adjust per-repo by writing a `mutation-survival-floor: <pct>` line to `.claude/state/coverage-policy.txt`.

## Dual Time Estimates

For each task, provide two effort estimates:

- **Human effort**: How long this would take a developer manually
- **AI effort**: How long this takes with builder agents

This shifts cost-benefit analysis toward completeness. When AI effort is 10x lower than human effort, the threshold for "worth doing thoroughly" drops dramatically.

## Board Integration (Auto)

After task breakdown, update the board Issue with the task checklist so the card shows progress at a glance. Fire-and-forget — failures must NOT block the workflow.

```bash
# Add task checklist as a comment on the Issue
scripts/board.sh comment "<feature-name>" "## Task Breakdown

$(for task in tasks; do echo "- [ ] $task"; done)

**Execution strategy:** <parallel builders | single builder | lead-implements-directly>
**Estimated effort:** <AI hours> (human equivalent: <human hours>)
**Files touched:** <count> files across <areas>" || true
```

This comment becomes part of the feature's permanent history — future developers can see how the work was decomposed and why.

## Bisectable Commit Ordering

Order tasks by dependency graph for bisectability:

1. Infrastructure (config, schemas, types) — first
2. Models and services — second
3. Controllers and views — third
4. Tests — fourth
5. Documentation, VERSION, CHANGELOG — last

Every intermediate state after merging completed tasks must compile and pass tests. This ensures `git bisect` always lands on a runnable state.

## Scope Lock Artifact (ENFORCING)

At the end of Step 2, write a scope-lock file. Step 5 (review) and Step 6 (ship) read this file to detect scope creep — any task added after Step 2 that is not in the lock must be flagged.

**Pre-condition (ENFORCING)**: the import-coupling check above must have produced either a clean report (`couplings: []` in `.claude/state/plan-w-team-coupling-$SLUG.json`) or a coupling-ack file (`.claude/state/plan-w-team-coupling-ack-$SLUG`). The scope-lock writer below refuses to proceed otherwise — making the coupling decision a conscious, audited gate rather than a step the lead can forget.

```bash
SLUG="<feature-slug>"           # same slug used for the spec file
SPEC_PATH="docs/specs/${SLUG}.md"
LOCKED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p .claude/state

# Pre-condition gate: import-coupling check must have run
COUPLING_REPORT=".claude/state/plan-w-team-coupling-${SLUG}.json"
COUPLING_ACK=".claude/state/plan-w-team-coupling-ack-${SLUG}"
if [ ! -f "$COUPLING_REPORT" ]; then
  echo "✗ scope-lock refused: missing $COUPLING_REPORT"
  echo "  Run: npx tsx .claude/scripts/plan-w-team-import-coupling.ts --slug $SLUG --tasks-json /tmp/tasks-$SLUG.json"
  exit 1
fi
COUPLING_COUNT=$(grep -c '"kind"' "$COUPLING_REPORT" || true)
if [ "$COUPLING_COUNT" != "0" ] && [ ! -f "$COUPLING_ACK" ]; then
  echo "✗ scope-lock refused: $COUPLING_COUNT coupling(s) detected and no ack file"
  echo "  Either fix the breakdown and re-run the analyzer, OR write a one-line"
  echo "  justification to: $COUPLING_ACK"
  exit 1
fi

# Write the locked task set. Lock includes task IDs, subjects, and scope tags.
# Heredoc is unquoted so $SLUG / $SPEC_PATH / $LOCKED_AT are expanded by bash.
# Fill in `tasks` and `acceptance_criteria_count` from the actual breakdown
# before writing — the example here shows the expected shape.
cat > ".claude/state/plan-w-team-scope-lock-${SLUG}.json" <<EOF
{
  "slug": "${SLUG}",
  "locked_at": "${LOCKED_AT}",
  "spec_path": "${SPEC_PATH}",
  "task_count": 0,
  "tasks": [
    {"id": "1", "subject": "...", "scope": "BACKEND", "door_type": "two-way"}
  ],
  "acceptance_criteria_count": 0
}
EOF
```

**What the lock does**:

- Step 5 review compares the git diff against the lock's scoped files. If edits touched files outside the scope (e.g. `FRONTEND` task modified `src/db/schema.ts`), flag as scope drift.
- Step 6 ship refuses to push if `task_count` in the lock doesn't match the number of completed tasks — new tasks added mid-flight require a user-confirmed `.claude/state/plan-w-team-scope-unlock-$SLUG` file.
- Step 8 retro reads the lock to compute "scope stability" as a retro metric.

The lock is not a straitjacket — users can expand scope during execution by acknowledging the unlock file — but it forces the expansion to be a conscious decision, not silent accretion.

<!-- PWT-T2: scope-unlock-for-drift is classified as `user` in the orchestrator
     classifier table. This pause site is INTENTIONALLY kept as a user decision
     because mid-flight scope expansion alters the contract the user signed off on.
     It is a one-way-door for the feature's scope boundary. -->

## End-of-Stage Status Block (PWT-T5)

At the end of this stage, emit a status block for the `/goal` evaluator. This is a one-line invocation; the helper handles all field population (workflow lock, supervisor log, fleet log, escalations).

```bash
.claude/scripts/plan-w-team-surface-status.sh "$SLUG" "task-breakdown"
```

The stage label `task-breakdown` is the second argument — see `shared/goal-conditions.md` §Status-Block Schema for the full label list. `/goal` evaluator reads the emitted block to judge whether the pipeline terminal condition is met.

Skip this block entirely when `PLAN_W_TEAM_DISABLE_GOAL=1` (kill switch) — the helper itself is observability and remains safe to call, but invocation here is optional in that mode.
