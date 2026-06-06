# Gotchas — /plan-w-team Repeated Failure Points

> **What this is**: the single consolidated surface for the hard-won, cross-cutting failure
> points the `/plan-w-team` skill has hit in real runs. Per Anthropic's skill-authoring
> guidance, a Gotchas section is the highest-value content in a skill — it documents the traps
> Claude actually falls into, not the happy path. **Read this before editing skill internals,
> authoring a stage file, or debugging a stuck run.**
>
> **Maintenance**: append a new entry whenever a run surfaces a _recurring_ trap (not a one-off).
> Each entry cites its authoritative source so the detail stays in one canonical place — this
> file is the index, the source file is the contract. Keep entries short; link, don't duplicate.

## How to use this file

- **Symptom → entry**: scan the headers for your symptom (double-spawn, clobbered main checkout,
  model-pin ignored, lock not held, CHANGELOG SHA wrong …).
- Each entry is: **what bites you**, **why**, **what to do instead**, **source**.
- The source link is canonical. If you change the behavior, update the source file and adjust
  the one-liner here — do not let them drift.

---

## G1 — The harness silently drops `additionalContext` from UserPromptSubmit hooks

**Bites you**: a UserPromptSubmit hook that passes data forward via `additionalContext` will
have that data vanish — the marker you check for in the next turn never arrives, so a guard
that depends on it never fires. This caused every natural-language `/plan-w-team` trigger to
**double-spawn** (hook spawn + manifest spawn).

**Why**: confirmed 2026-05-21 on v2.1.148 — 0 of 20 expected `additionalContext` deliveries
arrived. The harness delivers only the `systemMessage` field (as a `hook_system_message`
attachment).

**Do instead**: pass forward via `systemMessage`, and check for the visible
`🚀 /plan-w-team origin-chat supervisor active` marker — never an `additionalContext` token.

**Source**: `.claude/commands/plan-w-team.md:43`, `:48` (Routing Pre-Check Step 3a).

## G2 — LLM-attention is not a load-bearing guard (PWT-DS1 / PWT-DS2)

**Bites you**: a guard implemented as "the assistant will read the marker and not re-spawn" is
not reliable — an origin assistant can read the marker and call `pwt-goal.sh --worker-only`
anyway (the failure that produced commit `c9cfcd5`). Worse, a worker's own goal text contains
`Use /plan-w-team to …`, so the worker's LLM can re-match the trigger and cascade-spawn.

**Why**: visual markers are a first line of defense only; correctness must be deterministic.

**Do instead**: rely on the process-level backstops. **PWT-DS1** writes a flag file
(`.claude/state/plan-w-team-hook-spawn-<parent_sid_short>.flag`); `pwt-goal.sh --worker-only`
refuses to spawn (exit 3) if a fresh flag from the same parent exists. **PWT-DS2** propagates
`PLAN_W_TEAM_DISABLE_PROMPT_ROUTE=1` into the worker env so a nested call exits 4. Escape hatch
for legitimate nesting: `PLAN_W_TEAM_FORCE_SPAWN=1`.

**Source**: `.claude/commands/plan-w-team.md:50` (PWT-DS1), Step 3a (PWT-DS2);
`shared/state-artifacts.md` (flag registration).

## G3 — `claude --bg` does NOT auto-create a worktree

**Bites you**: assuming a background session is isolated. Without isolation a `--bg` worker
edits the **main checkout** and can clobber a concurrent in-session editor — the 2026-06-02
incident.

**Why**: earlier docs claimed `--bg` auto-creates a worktree; `claude --help` shows isolation
requires the explicit `-w/--worktree` flag.

**Do instead**: `pwt-goal.sh` spawns with `claude --bg --worktree <slug>` (PWT-WT1) so the
worker starts inside `.claude/worktrees/<slug>`. Any path that will Write/Edit under `--bg`
must be in a worktree (call `EnterWorktree` if `pwd` is not under `.claude/worktrees/`).
Opt-out only via `PWT_DISABLE_WORKER_WORKTREE=1`.

**Source**: `.claude/commands/plan-w-team.md:687`; manifest §Pre-Flight: Background Session
Worktree.

## G4 — The Agent tool's `model` param accepts ONLY aliases, never a full model ID

**Bites you**: passing `model: claude-opus-4-8` to an Agent call fails input validation; passing
an alias defeats a generation pin (the alias overrides the agent-definition frontmatter).

**Why**: the tool only accepts `opus` / `sonnet` / `haiku`.

**Do instead**: pin a specific generation in the **agent-definition frontmatter**
(e.g. `model: claude-opus-4-8` in `.claude/agents/team/evaluator.md`) and do **not** set
`model:` in the Agent call. For mechanical lead work, no pin is needed.

**Source**: `.claude/commands/plan-w-team.md:525` (§How tier pinning works).

## G5 — Use `mkdir` for locks, not `flock` (macOS has no `flock(1)`)

**Bites you**: a lock implemented with `flock` silently no-ops or errors on the user's macOS /
mac-mini `/bin/bash`, so two concurrent runs race on the same state files.

**Why**: `flock(1)` is not installed by default on macOS.

**Do instead**: atomic `mkdir` lock dirs (`plan-w-team-workflow-<slug>.lock`,
`plan-w-team-push.lock`, `plan-w-team-friction-log.lock`) with PID-based stale recovery. They
survive compaction and are atomic on every POSIX filesystem.

**Source**: `.claude/commands/plan-w-team.md:452` (§Pre-Flight: Workflow Lock);
`07-retro.md:351` (friction-log lock).

## G6 — CHANGELOG SHA off-by-one → the `(pending)` backfill convention

**Bites you**: writing the new CHANGELOG entry's `(<sha>)` from the current HEAD cites the
**prior** version's commit (a commit can never contain its own SHA). This recurred 3× (1.22.1,
…).

**Why**: the reflexive `git rev-parse --short HEAD` at write time is one commit behind the
commit that will actually ship the entry.

**Do instead**: write the entry with the literal token `(pending)`, commit the bump, then
backfill `(pending)` → real short-SHA in a docs-only follow-up commit (no new version). The
P14 SHA-lint enforces this.

**Source**: `shared/versioning.md:66` (§CHANGELOG SHA backfill convention).

## G7 — bash 3.2 portability (the test bash lies to you)

**Bites you**: a script that uses bash-4 features (`declare -A` associative arrays, `${var^^}`,
etc.) works in local testing (bash 5.x) but fails silently or errors on the mac-mini's
`/bin/bash` (3.2).

**Why**: the local interactive bash is 5.x; the deployment bash is 3.2 and silently lacks bash-4
idioms.

**Do instead**: target bash 3.2. No associative arrays, no `^^`/`,,` case modifiers, no
`mapfile`/`readarray`. The shell-safety primer documents safe patterns and assert helpers.

**Source**: `shared/shell-safety.md`; manifest Model Strategy note (bash 3.2 mac-mini).

## G8 — `set -e` + `((VAR++))` is a silent-exit footgun

**Bites you**: under `set -e`, `((counter++))` returns a non-zero exit status when the
pre-increment value is 0 (the arithmetic result is "falsy"), aborting the script mid-loop with
no error — counters in sync/GC scripts stop incrementing and the run "succeeds" having done
nothing.

**Why**: `((expr))` exits non-zero when `expr` evaluates to 0; `set -e` treats that as fatal.

**Do instead**: `((VAR++)) || true`, or `VAR=$((VAR+1))`. Hardened in sync-all
(commit `e2baa2b`).

**Source**: `.claude/scripts/sync-all-projects.sh` (counter increments); the sync-all hardening
commit.

## G9 — `claude agents --json` is intermittently empty-but-exit-0 under load

**Bites you**: trusting a single `claude agents --json` call — it can return empty JSON with a
0 exit under load, which froze the statusline on a stale snapshot and can make a supervisor
think a live worker is dead.

**Why**: a transient race in the agents dashboard under concurrent load.

**Do instead**: retry before trusting an empty result; the merged-view wrapper
(`claude-agents-extended.sh`) already retries (commit `dc90af4`). Treat a SID as DEAD only after
it is missing for >2 consecutive polls.

**Source**: `.claude/scripts/claude-agents-extended.sh`; manifest supervisor protocol
("missing for >2 polls → DEAD").

## G10 — `rsync -a` quick-check can silently skip a same-size file with changed content

**Bites you**: a tiny file whose size is unchanged but whose content changed (the 7-byte
`VERSION` marker is the classic victim) is **not** copied by an `rsync -a` size+mtime
quick-check, so a synced consumer repo silently keeps the old content.

**Why**: `rsync` default quick-check compares size + mtime, not content.

**Do instead**: verify a content signal, not just `VERSION`; sync uses `--checksum` /
`--ignore-times` for the at-risk files (fix `b84fae3`).

**Source**: `.claude/scripts/sync-to-project.sh` (rsync flags); the `--checksum` hardening commit.

## G11 — A new `.claude/scripts/*` file won't propagate unless it's allowlisted

**Bites you**: adding a helper script in claude-pattern and expecting it in consumer repos — it
silently does not sync because `sync-to-project.sh` syncs an **allowlist**, not the whole dir.

**Why**: the sync is deliberately allowlist-based to avoid pushing project-specific files.

**Do instead**: add the new path to the allowlist in `sync-to-project.sh`; the
`plan-w-team-sync-allowlist-check.test.sh` test guards against forgetting.

**Source**: `.claude/scripts/sync-to-project.sh` (allowlist); `plan-w-team-sync-allowlist-check.test.sh`.

## G12 — A new `.claude/state/plan-w-team-*` reader/writer must register in `state-artifacts.md`

**Bites you**: referencing a new state file from a stage without registering it fails the
symmetry check (`plan-w-team-symmetry-check.sh`), which reads `shared/state-artifacts.md` as the
authoritative registry.

**Why**: the registry is enforced — an unregistered path with a reader is a contract violation.

**Do instead**: register every `.claude/state/plan-w-team-*` artifact in
`shared/state-artifacts.md` (path, writer, reader, lifecycle) OR remove the reader.

**Source**: `shared/state-artifacts.md`; `.claude/scripts/plan-w-team-symmetry-check.sh:21`,
`:201`.

---

## Adding a gotcha

1. Confirm it is **recurring**, not a one-off — the blog's bar is "common failure points",
   not every bug.
2. Add a `G<N>` entry: what bites you / why / do instead / source. Keep it to a few lines.
3. Cite the **canonical** source file:line — this index points at the contract, it is not the
   contract.
4. If the gotcha came out of a retro, the friction-log entry and this file should agree.
