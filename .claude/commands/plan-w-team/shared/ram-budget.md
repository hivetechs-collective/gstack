# RAM Budget — Pre-Spawn Capacity Gate for `claude --bg` Sessions

`.claude/scripts/ram-budget.sh` is a host-RAM accountant used by `pwt-goal.sh` (and called from the supervisor's POLLING LOOP) to decide whether a new `claude --bg` session can be spawned without OOM-killing peers.

Each Claude Code background session costs roughly 1.5–2 GB resident. With parallel `/plan-w-team` runs in flight on a workstation, blind spawns can exhaust RAM. The gate fixes the failure mode: it consults free memory, counts active bg sessions, applies a safety factor, and returns one of `SPAWN_OK` / `AT_CAPACITY` / `REDUCE_PARALLEL`.

The user's stated goal is: **always maximize parallel runs while not exceeding RAM.** The gate is the mechanism — never a hard cap — and includes a documented override for cases where the operator has manually confirmed capacity.

## The Model

```
per_session_bytes      = estimated_session_cost_gb × safety_factor × 1 GiB
capacity_for_new       = floor( free_bytes / per_session_bytes )

if capacity_for_new ≥ 1                          → SPAWN_OK
elif bg_session_count ≥ 1                        → AT_CAPACITY    (running sessions consumed the budget)
else                                             → REDUCE_PARALLEL (host itself can't fit one session)
```

### Defaults

| Variable                    | Default | Source      | Why this value                                                                              |
| --------------------------- | ------- | ----------- | ------------------------------------------------------------------------------------------- |
| `estimated_session_cost_gb` | `1.8`   | Empirical   | A `claude --bg` /plan-w-team worker resident-set typically sits 1.5–2 GB once steady-state. |
| `safety_factor`             | `1.5`   | Engineering | Buffer for OS file cache, other processes, and the spike when a new session boots.          |

Per-session ceiling = 1.8 × 1.5 = **2.7 GB of free RAM required to spawn one more session**.

### Free RAM definition

- **macOS** — `pages_free + pages_inactive + pages_speculative` × `vm.pagesize`. Active + wired are treated as in-use. This mirrors what Activity Monitor calls "memory pressure" — inactive pages are reclaimable.
- **Linux** — `MemAvailable` from `/proc/meminfo`. This is the kernel's own "how much can a new app allocate" number and is what tools like `free -h` show as the "available" column.

`used_gb` is `total_gb - free_gb`. It's a derived number for the operator; the gate itself reasons about `free_gb`.

### bg_session_count

Read from `claude agents --json`, filtering `kind == "background"`. Soft-fails to 0 when:

- the `claude` CLI is unavailable on `PATH`
- `claude agents --json` returns non-JSON
- the call errors out

A miscount of 0 is fail-open — the gate will be more permissive than it should, but it won't break `pwt-goal.sh`. The decision is intentional: a broken counter must not block the user's primary spawn path.

## JSON Schema

```json
{
  "free_gb": 8.4,
  "total_gb": 24.0,
  "used_gb": 15.6,
  "bg_session_count": 2,
  "estimated_session_cost_gb": 1.8,
  "safety_factor": 1.5,
  "capacity_for_new_sessions": 2,
  "recommended_action": "SPAWN_OK"
}
```

On fail-open paths (unsupported platform, unreadable RAM source), `free_gb` / `total_gb` / `used_gb` / `capacity_for_new_sessions` are `null` and `recommended_action` is `null`. `pwt-goal.sh` treats `null` actions as "do not refuse" — the gate stays advisory.

A `"note": "<reason>"` field accompanies fail-open output for diagnosability.

## Environment Overrides

| Variable                         | Effect                                                                                                        |
| -------------------------------- | ------------------------------------------------------------------------------------------------------------- |
| `PLAN_W_TEAM_DISABLE_RAM_GATE=1` | `pwt-goal.sh` skips the RAM check entirely. Use when you've manually confirmed available RAM.                 |
| `RAM_BUDGET_SESSION_COST_GB=<n>` | Override the default 1.8 GB per-session estimate.                                                             |
| `RAM_BUDGET_SAFETY_FACTOR=<n>`   | Override the default 1.5x multiplier.                                                                         |
| `RAM_BUDGET_PLATFORM_OVERRIDE=…` | (testing) Pin `Darwin` / `Linux` / arbitrary string regardless of `uname -s`.                                 |
| `RAM_BUDGET_STUB_*`              | (testing) Inject deterministic vm_stat / sysctl / /proc/meminfo / claude-agents responses. See script header. |

## When to Tune

| Symptom                                                                 | Adjustment                                                                              |
| ----------------------------------------------------------------------- | --------------------------------------------------------------------------------------- |
| OOM happened despite `SPAWN_OK` verdict                                 | Raise `RAM_BUDGET_SESSION_COST_GB` to your observed per-session RSS (use `ps -o rss=`). |
| Gate refuses while you can clearly fit another session                  | Lower `RAM_BUDGET_SAFETY_FACTOR` toward 1.0 (no buffer). Verify before going below 1.2. |
| Running on a high-RAM box (64 GB+) and want more aggressive parallelism | Lower the safety factor, OR shrink the per-session estimate after measuring real RSS.   |
| Running on 8 GB MacBook Air with one or two non-Claude apps open        | Raise `RAM_BUDGET_SAFETY_FACTOR` to 2.0 — the gate becomes more conservative.           |
| Need to spawn during high-RAM moment for one specific run               | `PLAN_W_TEAM_DISABLE_RAM_GATE=1` for that single invocation.                            |

## Integration with `pwt-goal.sh`

The gate is invoked from `pwt-goal.sh` AFTER the cascade guard (PWT-DS2) and the double-spawn guard (PWT-DS1), BEFORE the actual `claude --bg` call. On non-`SPAWN_OK` it exits with code **5** (PWT-RAM1), printing a stderr block that names the verdict, the current numbers, the override env var, and the tunables.

Exit code map:

| Exit | Source   | Meaning                                                             |
| ---- | -------- | ------------------------------------------------------------------- |
| 3    | PWT-DS1  | Hook already spawned a worker this turn (double-spawn refused).     |
| 4    | PWT-DS2  | Worker-cascade refused (running inside a bg worker without escape). |
| 5    | PWT-RAM1 | RAM gate refused (this gate).                                       |

## Integration with the Supervisor Protocol

`shared/supervisor-protocol.md` POLLING LOOP includes a CAPACITY CHECK subsection. Each polling tick the supervisor calls `ram-budget.sh` and uses the JSON to:

- Surface `AT_CAPACITY` to the transcript so the user can see why no new batches are starting.
- When the supervisor is choosing whether to enqueue a follow-on batch (continuation discipline), refuse to spawn until the budget recovers — even if the worker is idle and the goal isn't terminal yet.

The supervisor does NOT silently override the gate. It either waits or escalates.

## Failure-Mode Catalog

| Failure                                 | Behavior                                                          | User-visible                             |
| --------------------------------------- | ----------------------------------------------------------------- | ---------------------------------------- |
| `vm_stat` missing on macOS              | `recommended_action: null`, `note: "macos_read_failed"`           | Spawn proceeds; one-line stderr advisory |
| `/proc/meminfo` unreadable on Linux     | `recommended_action: null`, `note: "linux_read_failed"`           | Spawn proceeds                           |
| Unsupported platform (Plan9, BSD)       | `recommended_action: null`, `note: "unsupported_platform:<name>"` | Spawn proceeds                           |
| `claude` CLI missing                    | `bg_session_count: 0`                                             | Gate uses 0 — conservative under-count   |
| `ram-budget.sh` missing from script dir | gate skipped silently                                             | Spawn proceeds (fail-open)               |
| Operator override `…DISABLE_RAM_GATE=1` | gate skipped                                                      | Spawn proceeds                           |

**Design rule**: the RAM gate is a safety net for the common case. It does NOT participate in correctness, never gates the existing PWT-DS1/DS2 logic, and always fails open. The user remains the ultimate authority.

## Testing

Run `.claude/scripts/ram-budget.test.sh` to exercise the gate against stubbed system primitives. The harness:

1. Builds synthetic `vm_stat` outputs (high free / zero free).
2. Pins `sysctl hw.memsize` and `hw.pagesize` via `RAM_BUDGET_STUB_*`.
3. Stubs `bg_session_count` directly via env to skip the `claude agents --json` call.
4. Asserts each `recommended_action` is what the math predicts.

Tests cover both macOS and Linux read paths plus the unsupported-platform fail-open path.

## See Also

- `.claude/scripts/ram-budget.sh` — the script itself.
- `.claude/scripts/ram-budget.test.sh` — regression suite.
- `.claude/scripts/pwt-goal.sh` — consumer (gate invocation between PWT-DS1 and spawn).
- `shared/supervisor-protocol.md` §POLLING LOOP — supervisor-side capacity awareness.
- `docs/specs/ram-aware-spawn-capacity-check.md` — design rationale for the gate.
