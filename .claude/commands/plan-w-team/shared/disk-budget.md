# Disk Budget — Pre-Spawn Capacity Gate for `/plan-w-team` Worktrees

Companion to [`shared/ram-budget.md`](ram-budget.md). Where the RAM gate (PWT-RAM1)
prevents OOM, the **disk gate (PWT-DISK1)** and the **worktree cap (PWT-DISK2)**
prevent the failure mode from the **2026-05-29 cleanscale incident**: 67 worktrees /
64 GB drove the filesystem to 0 bytes free, and `git` + the Bash tool began failing
with `ENOSPC`. `pwt-goal.sh` consulted `ram-budget.sh` but **nothing checked free
disk**, so spawns proceeded into a ~98%-full FS.

Script: `.claude/scripts/disk-budget.sh` · Tests: `disk-budget.test.sh`
Wired into: `pwt-goal.sh` (the `--launch` / `--worker-only` spawn path), right after
the RAM gate and before fair-share.

## Why free GB, not %

On macOS/APFS, `df` percentage counts the whole shared container, so it routinely
reads **90%+ even with tens of GB free**. The 2026-05-29 host showed `94% used` with
26 GB free — perfectly safe. So the **hard gate is absolute free GB**; `used_pct` is
reported but **advisory only** (`PWT_DISK_MAX_PCT`). On Linux the % is meaningful but
the free-GB floor still governs. Inode exhaustion is also checked (ENOSPC can fire
with free bytes if inodes run out).

## The gate

`disk-budget.sh` emits JSON with `recommended_action`:

| Action        | Meaning                                                   | pwt-goal.sh                                                                      |
| ------------- | --------------------------------------------------------- | -------------------------------------------------------------------------------- |
| `SPAWN_OK`    | comfortable headroom above the floor                      | proceed                                                                          |
| `REDUCE`      | room for ~1 more worktree above the floor                 | proceed + warn                                                                   |
| `AT_CAPACITY` | at the floor; another worktree would breach min-free      | **refuse (exit 5)**                                                              |
| `BLOCK`       | `free_gb < min_free_gb`, or inode-free% below the minimum | **refuse (exit 5)**                                                              |
| `null`        | df unreadable / non-numeric                               | **fail-open** — proceed with a LOUD stderr warning (never block on a read error) |

**Heavy-build detection**: if the run's directive mentions `pnpm install`,
`npm install`, `yarn install`, `pod install`, `expo`, `eas build`, `gradlew`,
`xcodebuild`, or `cargo build`, the free-GB floor is raised from
`PWT_DISK_MIN_FREE_GB` (15) to `PWT_DISK_MIN_FREE_GB_BUILD` (25) and the per-worktree
cost estimate from 2.5 GB to 6 GB (iOS `Pods` + `DerivedData`, Android `.gradle`,
`node_modules`, etc.).

## Worktree count cap (PWT-DISK2)

Even with free disk, an unbounded worktree count is the accumulation that fed the
incident. `pwt-goal.sh` refuses a new spawn when `.claude/worktrees/` already holds
`PWT_MAX_WORKTREES` (default 10) entries, with a "GC or merge first" message pointing
at `plan-w-team-worktree-gc.sh --execute`.

## Env knobs

| Var                                | Default | Effect                                                                                                                                    |
| ---------------------------------- | ------- | ----------------------------------------------------------------------------------------------------------------------------------------- |
| `PWT_DISK_MIN_FREE_GB`             | `15`    | Hard free-GB floor for a normal spawn. Below → `BLOCK`.                                                                                   |
| `PWT_DISK_MIN_FREE_GB_BUILD`       | `25`    | Hard free-GB floor when the directive is a heavy build.                                                                                   |
| `PWT_DISK_WORKTREE_COST_GB`        | `2.5`   | Est. cost of one normal worktree (capacity math).                                                                                         |
| `PWT_DISK_WORKTREE_COST_GB_BUILD`  | `6`     | Est. cost of one heavy-build worktree.                                                                                                    |
| `PWT_DISK_MIN_INODE_PCT`           | `5`     | `BLOCK` if inode-free% falls below this (inode exhaustion → ENOSPC).                                                                      |
| `PWT_DISK_MAX_PCT`                 | `95`    | Advisory used-% threshold (reported, not gated — APFS % is unreliable).                                                                   |
| `PWT_MAX_WORKTREES`                | `10`    | Hard cap on concurrent worktrees under `.claude/worktrees/`.                                                                              |
| `PWT_STALE_LOCK_HOURS`             | `6`     | A locked worktree older than this AND merged/terminal is force-unlocked + reaped by the GC (see `plan-w-team-worktree-gc.sh`).            |
| `PLAN_W_TEAM_DISABLE_DISK_GATE`    | unset   | `=1` bypasses the disk gate entirely (use only with manually confirmed free disk).                                                        |
| `PLAN_W_TEAM_DISABLE_WORKTREE_CAP` | unset   | `=1` bypasses the worktree-count cap.                                                                                                     |
| `PWT_ORPHAN_IDLE_MIN`              | `30`    | Idle-minutes (transcript mtime) before an orphaned `claude --bg` session is reapable by the orphan reaper (runs from the daily GC timer). |
| `PWT_ORPHAN_REAPER_DISABLE`        | unset   | `=1` disables the orphan bg-session reaper.                                                                                               |

## Orphan bg-session reaper

The retro reaper (`07-retro.md` §8j-sexies → `child-cleanup.sh`) only stops bg
children when a run reaches Step 8. A worker that crashes, is abandoned, hits an
un-retro'd halt, or is a stray spawn leaves an orphaned `claude --bg` **process**
alive that nothing reaps (the worktree GC reclaims dirs + companion procs, not the
sessions). `plan-w-team-orphan-session-reaper.sh` is the catch-all — it runs from
the daily GC timer and stops a bg session ONLY when ALL hold: cwd is under **this**
repo (incl. worktrees), it is **not** the current session, status is **not busy**,
and its transcript has been idle ≥ `PWT_ORPHAN_IDLE_MIN`. Anything it cannot verify
as idle is skipped. Dry-run by default; the timer calls it with `--execute`.

## How the supervisor / lead uses it

Same contract as the RAM gate: when a spawn is about to happen, the gate runs first;
on `BLOCK`/`AT_CAPACITY` the spawn is refused with a clear reclaim instruction
(`plan-w-team-worktree-gc.sh --execute`, or merge open PRs). The gate never silently
proceeds on a read error — it fails **open** with a loud warning so a `df` glitch
can't wedge a run, while a genuine low-disk reading always refuses.

See also: `docs/operations/worktree-lifecycle.md` (GC + companion-process reaping)
and `shared/ram-budget.md` (the sibling RAM gate this mirrors).
