# /plan-w-team CHANGELOG

Tracks the version history of the `/plan-w-team` skill. Each release is tagged
with a semver bump, an ISO date, and the head commit at the time of release.

Versioning policy is documented in [`shared/versioning.md`](shared/versioning.md).

The current version is stored in [`VERSION`](VERSION). Each pwt-goal launch
records this value into the run's goal-state JSON as `skill_version` and the
commit SHA as `skill_commit_sha` so any bug surfaced after the fact can be
traced back to the exact /plan-w-team release that produced it.

## Format

```
## [<semver>] — <YYYY-MM-DD> (<short-sha>)
- <bump kind>: <description>
```

Entries are newest-first.

---

## [1.22.0] — 2026-06-01

MINOR — **Access-control content-signal gate (catch broken-access-control by diff content, gate it).**
Two real bugs shipped through the pipeline (2026-06-01): a `QA_SIM_TOKEN` `seed-platform-admin`
route that overwrote `passwordHash` + escalated `platformRole` with no `isQaUser` precondition
(account takeover · API3/API5), and a `jobs.ts` `assignedTo` that accepted a cross-tenant
`users.id` (IDOR · API1). Root cause: the security machinery was **path-glob-triggered**, so
access-control logic in normally-named route files (`qa-sim.ts`, `jobs.ts`) matched nothing →
no `N.s` task, `security-gap-analyzer` skipped (`no-security-surfaces`), no required tier. The
most damaging bug class — Broken Access Control (OWASP #1) — was the one the gate was structurally
blindest to. This release closes that blind spot with a content-signal trigger layer, an
access-control invariant layer, and gating (not retroactive) disposition for confirmed findings.
Spec: [`docs/specs/access-control-content-signal-gate.md`](../../../docs/specs/access-control-content-signal-gate.md).

- `feat`: **Content-signal triggering** — `shared/owasp-top10-mapping.md` gains the API Security
  Top 10 (2023) categories (API1 BOLA, API3 BOPLA/mass-assignment, API5 BFLA) and a
  Content-Signal Triggers table (CS-1 privilege-field write · CS-2 request-body spread into ORM
  update/insert · CS-3 bypass/QA/service-token-gated handler · CS-4 where-by-id without a
  tenant/owner predicate). Any signal forces A01/API attribution **regardless of filename**.
- `feat`: **`02-task-breakdown.md`** — paired `N.s` security-review task now has a second,
  filename- **and** mode-independent content-signal trigger layer; the refactor/config exemptions
  are overridden by a content-signal match.
- `feat`: **`shared/access-control-invariants.md`** (new) — the per-endpoint invariant rubric
  (INV-1 object ownership/BOLA · INV-2 function authz/BFLA · INV-3 mass-assignment/BOPLA ·
  INV-4 bypass-token scoping · INV-5 tenant isolation), consumed by the `N.s` pass, `security-expert`,
  and `security-gap-analyzer`.
- `feat`: **`shared/secure-by-default.md`** (new) — write-side defaults (deny-by-default,
  `z.object({...}).strict()` + `.pick()` allow-lists, no `req.body` spread, scoped `where`,
  `assertQaScoped()`); referenced by `03-execute.md` + `agents/team/builder.md`.
- `feat`: **`04-fix-first-review.md`** — §5b Access-Control Content-Signal Scan (Pass-1 CRITICAL),
  §5d-ter gating-not-retroactive rule, §5b CRITICAL table row, §5h `access_control_high_unresolved`
  frontmatter key; content-signal match overrides the `no-security-surfaces` analyzer skip.
- `feat`: **`05-ship.md`** — §6c-ter Access-Control Finding Gate (fail-closed `exit 1` on a
  confirmed unresolved finding; no ship-side override; a `DEFERRED` marker does not clear it).
- `feat`: **`01-specification.md`** — `### Threat Model & Access-Control Surface` template block +
  `## §1c` trigger so the surface is declared at spec time.
- `feat`: **agents** — `security-expert` (1.2.0→1.3.0) gains a mandatory per-endpoint invariant
  checklist + access-control verdict-table output; `security-gap-analyzer` (1.0.0→1.1.0) gains
  content-signal surface selection, four new gap_types, API-Sec categories, and a `gating` field.
- `feat`: **`shared/security-tiers.md`** — access-control diff checks ride on T2; §6c-ter is the
  SecBaseline-level (tier-independent) gate.
- `test`: four regression scenarios — `content-signal-triggers-ns`, `access-control-finding-gates-ship`,
  `access-control-invariants-checklist`, `owasp-api-top10-content-signals` (64 assertions, AC1–AC4).

## [1.21.0] — 2026-05-31

MINOR — **Canonical run manifest + observability rollup (stale-stage / split-state fix).**
A worker writes its live state into its worktree, so a supervisor/human polling
the main checkout saw only the spawn record, never the live stage. New
main-checkout-relative manifest closes the split and powers a builder-roster rollup.

- `feat`: **`pwt-manifest.sh`** — canonical per-run manifest
  (`plan-w-team-manifest-<slug>.json`) + append-only stage-event stream
  (`plan-w-team-stage-events-<slug>.jsonl`), both written to the MAIN checkout
  (resolved via `git --git-common-dir`) even when the writer runs in a worktree.
  Subcommands `init|set|task|read|path|list`; atomic, fail-open, kill switch
  `PLAN_W_TEAM_MANIFEST_DISABLE=1`, gitignore-on-write, bash 3.2 safe.
- `feat`: **`pwt-status.sh` rollup** — `pwt-status.sh <slug>` joins manifest ×
  `claude-agents-extended` (lead + nested builder subagents) × `fleet-query`
  (worktree-pointed) × stage history; `--json` machine-readable; list mode now
  shows the live stage. Solves the "claude agents --json can't show nested
  builders" gap.
- `feat`: **`fleet-query.sh`** worktree-aware fallback — reads `worktree_path`
  from the manifest so it works standalone from the main checkout.
- `feat (wiring)`: `pwt-goal.sh` inits the manifest at both spawn chokepoints;
  `plan-w-team-surface-status.sh` mirrors the stage every stage-end (deterministic,
  zero extra worker step); `03-execute.md` records strategy + per-task ownership;
  `07-retro.md` removes the per-run manifest at successful retro.
- `feat (surfacing)`: `supervisor-protocol.md` Standard Tick reads
  `pwt-status.sh <slug>` (structured — no ANSI log-grep) and surfaces a one-line
  stage summary to the origin chat when the stage advances.
- `test`: `pwt-manifest.test.sh` (26, incl. worktree→main-checkout guarantee) +
  `pwt-status.test.sh` rollup cases (T11–T13). Allowlisted in `sync-to-project.sh`.
- `docs`: `docs/specs/pwt-run-manifest.md`.

## [1.20.0] — 2026-05-31

MINOR — **Stale primary-checkout drift prevention + leftover-branch cleanup.**
Closes the two hygiene gaps that left the primary (non-worktree) checkout broken
after every shipped feature: nothing re-synced it to `origin/<default>` after a
server-side squash-merge, and the merged remote branch was never deleted.

- `fix (A1)`: `plan-w-team-worktree-on-merge.sh` now runs `__resync_primary_checkout`
  on the success path — fetch + (clean-only) `switch <default>` + `merge --ff-only
origin/<default>` (never force-resets a primary with real local commits) +
  `push origin --delete <branch>`. Fail-open. Two new `result_json` fields:
  `removed_remote_branch`, `primary_checkout_head`. Helper is now sourceable for tests.
- `fix (A2)`: `supervisor-protocol.md` — every `gh pr merge` gains `--delete-branch`;
  AUTO-MERGE bullet documents the helper's new re-sync duty; new Hard-Rules invariant
  "PWT mutates branches only inside `.claude/worktrees/`; primary stays on default".
- `feat (B)`: `pwt-goal.sh` `--launch` preflight `__assert_primary_on_default` restores
  a primary parked on a stale feature label (clean + 0 unique commits) before spawning;
  warns (never touches) when real local work is present. Targets the MAIN checkout via
  `--git-common-dir`, never the current worktree.
- `feat (D)`: `session-start.sh` drift guard auto-corrects or warns on a drifted primary;
  skipped inside worktrees (`.git` file vs dir gate).
- `fix (C)`: `sync-to-project.sh` self-heals consumers — ignores AND `git rm --cached`
  the per-session machine caches (`bg-agents-cache`, `last-claude-version`,
  `plan-usage-cache`, `usage-breakdown-cache`, `version-uplift-pending.flag`) so the
  tree is clean enough for the auto-switch to fire. claude-pattern `.gitignore` adds the
  one missing line (`version-uplift-pending.flag`).
- `test`: `plan-w-team-worktree-on-merge.test.sh` +2 cases (ff-resync + remote-delete;
  diverged-primary not-force-moved). Full harness 58/58 + bats green.
- `docs`: `worktree-lifecycle.md` gains a "Primary-checkout re-sync (post-merge)" section.

## [1.19.0] — 2026-05-29

MINOR — **Autonomy work order REQ-3/4b/5 (completes `docs/specs/claude-pattern-DIRECTION-pwt-autonomy-2026-05-29.md`).**
Doc/protocol changes; no new bg behavior that bypasses a gate.

- `feat (REQ-5, SAFETY)`: **vendor/SSO console hard guardrail** in `secret-safety.md`
  — workers must NEVER navigate to or interactive-login on a vendor/SSO management
  console (Neon/AWS/GCP/Stripe/Cloudflare/Apple/Google-Play/Keycloak/Okta/Auth0).
  Management-plane access is a **`blocked-external` gate**: HALT + escalate (like the
  one-way-door asks). Verification uses the programmatic path only (connection string
  / API token from the secrets inventory / prod API), never a browser login. Origin:
  a bg worker drove Playwright to `console.neon.tech` → Keycloak OAuth this session.
  Referenced from `03-execute.md` dispatch. (Browser automation of the app-under-test
  is still correct — the rule targets third-party consoles only.)
- `feat (REQ-3)`: **autonomous effort-escalation rung** — on STALL-ALERT /
  LOW_CONFIDENCE_STREAK (`supervisor-protocol.md`), and on confidence-low-twice / a
  HARD-tagged sub-problem (`04-fix-first-review.md`), elevate the reasoning budget
  (ultrathink / `/effort xhigh`) for the recovery turn instead of retrying at default.
  **PWT-WF1 stays** — bg workers never spawn nested workflows that bypass the RAM gate;
  effort is the autonomous lever, workflows stay operator/interactive-only.
- `feat (REQ-4b)`: **post-merge reclaim** in the supervisor AUTO-MERGE action — after
  `gh pr merge` (admin-squash on the remote → no local hook fires), call
  `plan-w-team-worktree-on-merge.sh` immediately so the merged worktree is reclaimed
  without waiting for the nightly GC timer. (REQ-4a — GC-timer commit — shipped in 1.14.0.)
- `test`: `tests/skill/scenarios/autonomy-workorder-req345.bats` (7 invariants). Suite 58/58.

> Full work order complete: REQ-1/REQ-2 (1.18.0, keystone), REQ-4a (1.14.0),
> REQ-3/REQ-4b/REQ-5 (this release).

---

## [1.18.0] — 2026-05-29

MINOR — **Ship-gate self-finish: cross the finish line unattended (REQ-1 + REQ-2).**
The keystone from the autonomy work order (`docs/specs/claude-pattern-DIRECTION-pwt-autonomy-2026-05-29.md`).
The skill self-drove to ship then **wedged** at the test gate on two environment
issues nothing self-healed (2026-05-29 cleanscale audit: 5 bg workers idling in
`waiting`). This converts "operator babysits every wave" → "workers finish unattended".

- `feat (REQ-1)`: **`plan-w-team-ship-preflight.sh`** — pre-push self-heal:
  (a) seeds a worktree's missing `node_modules` via `worktree-deps-share.sh`
  (fallback `pnpm install --frozen-lockfile`) so `turbo`/`make test-all` resolves —
  the bg-LEAD deps gap (SessionStart no-ops for a main-cwd lead, never fires for
  headless `claude -p`); (b) shuts orphaned booted iOS sims (`xcrun simctl`) so an
  app-less sim can't false-fail maestro. iOS/JS-scoped, fail-open, bash 3.2 safe.
  Kill switches: `PWT_SHIP_PREFLIGHT_DISABLE` / `PWT_SHIP_DEPS_DISABLE` / `PWT_SHIP_SIM_SHUTDOWN`.
- `feat (REQ-1)`: wired into `05-ship.md` §6a-quater (runs before the §6b test gate);
  bg-lead path in `03-execute.md` now calls deps-share **unconditionally** at
  worktree-create (REQ-1c — closes the SessionStart coverage gap at the source).
- `feat (REQ-2)`: ship-gate **wedge-recovery retry loop** (§6a-quater) — on a §6b
  failure, classify `env-gap` / `sim-orphan` / `real-test`; self-heal + retry ≤2 for
  the first two; a **real-test failure is NEVER retried into green** (surfaces via the
  §6-0a retro trap). Heal the environment, never mask a real failure.
- `test`: `plan-w-team-ship-preflight.test.sh` (9 cases) — seeds-when-missing /
  no-op-when-present / deps-share path / fail-open / sim shutdown + kill-switch /
  non-applicable skip / disable. Allowlisted. Full suite 58/58.

> REQ-4a (GC-timer commit) already shipped in 1.14.0. Remaining from the work order:
> REQ-5 (vendor/SSO OAuth guardrail — safety), REQ-3 (effort-escalation rung),
> REQ-4b (reclaim right after `gh pr merge`).

---

## [1.17.0] — 2026-05-29

MINOR — **Orphan bg-session reaper (catch-all for the retro-only cleanup gap).**
Diagnosing why stray `claude --bg` sessions weren't auto-cleaned revealed that the
ONLY automatic stopper of bg children is retro §8j-sexies (`child-cleanup.sh`),
which fires only when a run reaches Step 8. A worker that crashes, is abandoned,
hits an un-retro'd halt, or is a stray test spawn leaves an orphaned bg **process**
that nothing reaps (the worktree GC reclaims dirs + companion procs, not sessions).
This is the unhappy-path complement to the retro reaper — the same failure class as
the 2026-05-20 "19 background agents" incident, now covered regardless of retro.

- `feat`: **`plan-w-team-orphan-session-reaper.sh`** — stops a `claude --bg`
  session ONLY when ALL hold: cwd under **this** repo (incl. worktrees), **not**
  the current session, status **not busy**, and transcript idle ≥ `PWT_ORPHAN_IDLE_MIN`
  (default 30 min). Any session whose idleness can't be verified is skipped.
  Dry-run by default; `--execute` to stop. Fail-open.
- `feat`: wired into the **daily GC timer** (plist template + systemd ExecStart) so
  it runs without intervention, alongside the worktree + companion GC.
- `docs`: `shared/disk-budget.md` — reaper section + `PWT_ORPHAN_IDLE_MIN` /
  `PWT_ORPHAN_REAPER_DISABLE` knobs. Added to sync allowlist.
- `test`: `plan-w-team-orphan-session-reaper.test.sh` (8 cases) — reaps only the
  true orphan; never busy/self/other-repo/active/no-transcript; disable knob;
  empty-list fail-open; threshold honored. Full suite 57/57.

---

## [1.16.0] — 2026-05-29

PATCH-level fix shipped as MINOR — **GC-timer worktree-leak guard.** A regression
in 1.14.0 (E3): `plan-w-team-gc-timer-install.sh` resolves the repo via
`git rev-parse --show-toplevel`, but a bg worker / Agent-tool subagent runs with a
**worktree** as cwd — so `session-start.sh` installed a per-WORKTREE launchd timer
pointing at a dir that the GC later reaps. Left unfixed, every worker would leak a
stray daily timer (observed: `io.claudepattern.pwt-worktree-gc.integration-cap`
pointing at `.claude/worktrees/integration-cap`).

- `fix`: the installer now SKIPS when run inside a worktree (path under
  `.claude/worktrees/` OR git-dir under `*/worktrees/*`) — the main checkout owns
  the single per-repo timer. Idempotent install from the main session is unchanged.
- `test`: `plan-w-team-gc-timer-install.test.sh` case [10] — install from a
  worktree path is skipped and writes no plist. Suite 56/56.
- Operational: removed the leaked stray timer + two stray test worktrees on the
  author machine; consumers self-heal (no new per-worktree timers will be created,
  and any already leaked point at reaped dirs that fail harmlessly until removed).

---

## [1.15.0] — 2026-05-29

MINOR — **Worktree disk governance, part 4: build-artifact hygiene (E7).** A
shipped worker's worktree lingers awaiting merge (the `DO NOT MERGE` flow can hold
it for hours/days) still holding 100%-regenerable build output — iOS `Pods` +
`DerivedData` (5–9 GB each), Android `.gradle`/`build`, Rust `target/` — which
dominated the 64 GB in the 2026-05-29 incident.

- `feat`: **`plan-w-team-build-artifact-clean.sh`** — removes ONLY a fixed allowlist
  of regenerable build dirs from a worktree (or `--all`), dry-run by default
  (`--execute` to delete), `--json` output. Safety invariants mirror the GC:
  refuses any path outside `.claude/worktrees/`, never touches source, and
  **preserves the shared `node_modules` symlink** (E5/deps-share). Idempotent.
- `feat`: wired into Step 6 ship (`05-ship.md` §6g-bis) — cleans the shipped
  worker's worktree on the PR-opened path (build done → artifacts safe to drop),
  independent of whether the merge landed. Kill switch
  `PWT_BUILD_ARTIFACT_CLEAN_DISABLE=1`.
- `test`: `plan-w-team-build-artifact-clean.test.sh` (7 cases) — dry-run safe,
  execute reclaims, source preserved, node_modules symlink preserved, refuses
  outside-worktrees paths, `--all` sweep, idempotent. Added to sync allowlist.
  Full suite 56/56.

> Disk-governance series (1.12.0–1.15.0) closes all four incident root causes
> (no disk gate → E2, lock-pinning → E1, on-merge-can't-fire → E3/E4, build bloat
> → E7). E5 node_modules sharing was already the default via `worktree-deps-share.sh`;
> only the divergent-lockfile shared-store fallback remains as a minor refinement.

---

## [1.14.0] — 2026-05-29

MINOR — **Worktree disk governance, part 3: auto-installed daily GC timer (E3 +
E4).** Root cause #2 of the 2026-05-29 incident: the GC launchd template shipped
as a MANUAL template (WL-T5) and was **never installed**, so no periodic sweep
ever ran. This makes the timer install itself — never relying on a human.

- `feat`: **`plan-w-team-gc-timer-install.sh`** — idempotent auto-installer.
  macOS launchd + Linux systemd `--user` timer. Renders the (weekly) template to a
  **DAILY** schedule, only rewrites/reloads when content changed, and runs the GC
  **immediately when `disk-budget.sh` reports pressure** (free-GB based — supersedes
  the raw-% heuristic per the APFS caveat). `--status` / `--uninstall` subcommands.
  Fail-open: any error warns and exits 0 — installing the timer never blocks a
  session. Knobs: `PWT_GC_TIMER_DISABLE`, `PWT_GC_TIMER_HOUR`, `PWT_GC_TIMER_PRESSURE`.
- `feat`: **session-start wiring (E4)** — `session-start.sh` invokes the installer
  backgrounded on every session start, so consumers get the daily timer + a
  disk-pressure sweep automatically on next session. (Complements the existing
  SubagentStop + Step-8-retro sweeps and the already-present `gh pr list --state
merged` squash-merge detection.)
- `docs`/sync: installer + its test added to the sync allowlist so the timer
  auto-installs in every consumer repo.
- `test`: `plan-w-team-gc-timer-install.test.sh` (10 cases) — daily render
  (Weekday dropped), placeholder substitution, idempotency, status/uninstall,
  disable knob, fail-open. Hermetic (never triggers the production GC). Full suite
  55/55, verified green ×2.

> Remaining: E5 divergent-lockfile shared-store fallback (the nm-symlink default
> already exists), E7 build-artifact hygiene.

---

## [1.13.0] — 2026-05-29

MINOR — **Worktree disk governance, part 2: faster stale-lock reclamation (E1).**
The GC already force-reaps merged worktrees with stale locks (and squash-merge
detection via `gh pr list --state merged` already covers E4's hard case), but it
treated a lock as "in-use" for **24h** — so a merged-but-locked worktree lingered
~a day each, feeding the 67-worktree pileup.

- `feat`: lower the stale-lock window **24h → 6h** and adopt the canonical knob
  `PWT_STALE_LOCK_HOURS` (legacy `PWT_WORKTREE_LOCK_STALE_HOURS` still honored).
  A lock older than the window with no live session/recent commit is STALE; if the
  branch is also merged (or idle past `PWT_WORKTREE_IDLE_DAYS`) the worktree is
  force-unlocked + `--force`-removed. A live agent is still safe: recent commits,
  an active-run registry row, or an open PR all keep the worktree.
- `test`: `plan-w-team-worktree-gc.test.sh` Test 19b — a locked+merged worktree
  with a ~10h-old commit is now `SAFE-PRUNE-MERGED` (was kept under 24h), and
  `PWT_STALE_LOCK_HOURS=24` still keeps it. Existing Tests 19/20/21 (merged-locked
  reaped, fresh-locked kept, trust-locks kept) unchanged. GC suite 51/51; full 54/54.

> Still ahead: auto-installed daily GC timer (E3), session-start sweep (E4),
> node_modules-share default (E5), build-artifact hygiene (E7).

---

## [1.12.0] — 2026-05-29

MINOR — **Worktree disk governance, part 1: pre-spawn disk gate + worktree cap.**
Direct fix for the 2026-05-29 cleanscale incident (67 worktrees / 64 GB → 0 bytes
free → `ENOSPC`, git + Bash tool failing). `pwt-goal.sh` consulted `ram-budget.sh`
but had **no disk gate**, so spawns proceeded into a ~98%-full filesystem.

- `feat`: **`disk-budget.sh` (PWT-DISK1)** — mirror of `ram-budget.sh` for disk.
  Emits `{free_gb, used_pct, inode_free_pct, heavy_build, est_worktree_cost_gb,
capacity_for_new_worktrees, recommended_action: SPAWN_OK|REDUCE|AT_CAPACITY|BLOCK}`.
  **Gates on absolute free GB, not %** — APFS % counts the whole shared container
  (the incident host read 94% used with 26 GB free). Heavy-build directives
  (`pod install`, `gradlew`, `xcodebuild`, `pnpm install`, …) raise the floor
  15→25 GB. Inode-exhaustion aware. **Fail-open** with a loud stderr warning on an
  unreadable `df`.
- `feat`: **disk gate wired into `pwt-goal.sh`** (after the RAM gate) — refuses the
  spawn (exit 5) on `BLOCK`/`AT_CAPACITY` with a reclaim instruction
  (`plan-w-team-worktree-gc.sh --execute`); warns on `REDUCE`. Override
  `PLAN_W_TEAM_DISABLE_DISK_GATE=1`.
- `feat`: **worktree count cap (PWT-DISK2)** — `pwt-goal.sh` refuses a spawn when
  `.claude/worktrees/` holds ≥ `PWT_MAX_WORKTREES` (default 10). Override
  `PLAN_W_TEAM_DISABLE_WORKTREE_CAP=1`.
- `docs`: `shared/disk-budget.md` — the capacity model + all env knobs
  (`PWT_DISK_MIN_FREE_GB`, `…_BUILD`, `PWT_DISK_MAX_PCT`, `PWT_MAX_WORKTREES`,
  `PWT_STALE_LOCK_HOURS`). `disk-budget.sh` added to the sync allowlist so consumers
  get the gate.
- `test`: `disk-budget.test.sh` (9 cases) — BLOCK below floor; SPAWN_OK above;
  heavy-build higher floor; fail-open on missing df; APFS-% trap (94% used + 30 GB
  free → SPAWN_OK); + pwt-goal integration (spawn refused on low disk and over cap).
  Full suite green; bash 3.2 verified.

> Parts 2–4 (auto-installed daily GC timer, stale-lock force-reap + squash-merge
> detection, node_modules-share default, build-artifact hygiene) follow as separate
> increments — see `docs/specs` and the incident direction.

---

## [1.11.0] — 2026-05-29

MINOR — **Pilot (opt-in, default-strict): Opus-4.8 autonomy-profile tuning.** Third
and final no-workflow leverage pilot. `PWT_AUTONOMY_PROFILE=relaxed` loosens the
supervisor's stall/idle constants for long-horizon Opus-4.8 runs that legitimately
cook longer between landings; `strict` (or unset) is **byte-for-byte today**.

- `feat`: `supervisor-progress-check.sh` resolves `PWT_AUTONOMY_PROFILE` → fallbacks
  for `STALL_THRESHOLD` (strict 2 / relaxed 4) and a new `PWT_INFLIGHT_MMIN`
  (strict 30 / relaxed 60, the in-flight worktree-freshness window). Explicit
  `STALL_THRESHOLD` / `PWT_INFLIGHT_MMIN` / `--threshold` always win
  (explicit > profile > strict). Documented in `goal-conditions.md` kill-switch table.
- `fix`: **blocker the adversarial review caught** — the Step-0 documented invocation
  passed `--threshold "${STALL_THRESHOLD:-2}"`, which hardcoded 2 and would have made
  `relaxed` inert. The documented call now runs bare so the script's profile/env
  resolution governs (the flag remains for explicit override / tests).
- **REJECTED (not shipped)**: the originally-proposed "self-honesty grace-tick"
  (change #4) — it would reintroduce self-report as a deferral signal at the
  STALL-ALERT boundary, the exact gaming the objective progress-check exists to
  prevent. STALL-ALERT stays purely objective.
- **No regression**: strict/unset == today. `supervisor-progress-check.test.sh` adds
  behavioral parity cases (strict/unset → STALL-ALERT at 2 flat ticks; relaxed holds
  to 4) plus the existing 13 cases unchanged (16/16). Full suite 53/53.

---

## [1.10.0] — 2026-05-29

MINOR — **Pilot (opt-in, default-OFF): Tier-1 deep-audit breadth analyzer.** Second
no-workflow leverage pilot. An Agent()-tool fan-out (NOT the Workflow tool) for
breadth-heavy work, gated behind `PLAN_W_TEAM_DEEP_AUDIT=1`.

- `feat`: `shared/deep-audit.md` — opt-in read-only breadth sweep (roster:
  `code-review-expert` + `security-expert` + `documentation-expert`), **Tier-1 = the
  Agent tool only**; Tier-2 (Workflow-tool engine) stays deferred to GA. Width clamp
  `PLAN_W_TEAM_DEEP_AUDIT_MAX_AGENTS` (default 8). Single in-pipeline entry point in
  `03-execute.md` (post-build, opt-in).
- `feat`: artifact `plan-w-team-deep-audit-$SLUG.jsonl` (registered `audit-trail`)
  with a real grep-able reader in `07-retro.md` §8e "Deep-Audit Cost" (findings ×
  surfaces × agents; cleans up on clean retro; fail-open on malformed rows).
- `feat`: `plan-w-team-register-spawn.sh` purpose enum gains `deep-audit-spawn`
  (accepted, not folded to `other`) so a rare registered deep-audit child is
  reclaimed by retro cleanup.
- **No regression / corrections honored**: the §1.6 spec-freeze SHA256 snapshot
  timing is **untouched**; default (unset) leaves Step-1/execute/retro byte-for-byte
  current. Tests: `plan-w-team-deep-audit-reader.test.sh` (5 cases incl. default-off
  n/a + fail-open) + `plan-w-team-spawn-registry.test.sh` U5b (enum accepts the
  label). Full suite 53/53; symmetry-check 28/28.

---

## [1.9.0] — 2026-05-29

MINOR — **Pilot (opt-in, default-OFF): Step-1 multi-angle spec fan-out (§1b-pre).**
First of the no-workflow leverage pilots from the workflow-leverage evaluation
(`docs/operations/workflow-tool-leverage-evaluation.md`). Uses the GA **Agent
tool** (same-session subagents), NOT the research-preview Workflow tool.

- `feat`: `01-specification.md` §1b-pre — when `PLAN_W_TEAM_SPEC_FANOUT=1`, three
  Brain-tier reviewers (`system-architect` + `security-expert` + `code-review-expert`
  — spec-authoring agents, deliberately NOT the diff-based gap analyzers, which
  have no diff at Step 1) critique the draft spec and the lead folds findings in
  **strictly before the AC-snapshot freeze**, preserving the frozen-contract chain.
- `feat`: advisory artifact `plan-w-team-spec-fanout-$SLUG.json` (registered
  `audit-trail` in `state-artifacts.md`) read by `07-retro.md` §8j-octies for a
  marginal-catch-rate signal — the evidence gate before any future default-ON.
- **Default-OFF / no regression**: unset (or `!= 1`) → Step 1 single-pass exactly
  as before. Test `tests/skill/scenarios/spec-fanout-optin.bats` (7 cases) asserts
  the gate, the pre-freeze ordering, the corrected roster, no Workflow-tool use,
  and the registry/reader wiring. Full suite 52/52.

---

## [1.8.0] — 2026-05-29

MINOR — **Worker API/socket-halt recovery** (the second half of
`docs/specs/pwt-worker-recovery-and-workflow-guard.md`; completes the deferred
recovery+guard work begun in 1.7.0). Closes the failure mode observed live on
2026-05-28: a bg worker halted on `API Error: socket connection closed`, stayed
listed in `background_tasks` (so the 2.1.145 DEAD check never fired), and the
parent `/goal` session would have blocked forever.

- `feat`: **API_HALT classification** in `plan-w-team-goal-evaluator.sh` — an
  alive-but-idle child is classified `API_HALT` only when BOTH gates hold:
  (a) its transcript mtime is older than `PWT_API_HALT_IDLE_S` (default 600s),
  AND (b) the last meaningful decoded turn matches a transient-connection pattern.
  Fully **fail-safe**: a healthy worker has a recent mtime → idle gate fails → it
  is structurally immune; if the helper is absent or the transcript can't be
  resolved, the block no-ops and falls through to today's behavior. Precedence:
  `SUCCESS < API_HALT < LOW_CONFIDENCE_STREAK < USER_ESCALATION_HALT`.
- `feat`: `.claude/scripts/pwt-transient-errors.sh` — single source of truth for
  the transient-connection-error pattern set (mirrors the `secret-scan.sh`
  centralization model; bash 3.2 safe), shared by the evaluator and the supervisor.
- `docs`: supervisor-protocol Decision-Matrix `API_HALT` row + **RESTART
  (bounded N≤2)** action + a `worker_restart` supervisor-actions event — the
  supervisor respawns a continuation worker via `pwt-goal.sh --worker-only`,
  capped, falling through to DEAD → SURFACE on exhaustion.
- `test`: `plan-w-team-goal-evaluator-api-halt.test.sh` (AC1–AC5): idle+transient
  → API_HALT; recent-mtime → immune; idle+normal-text → no fire; no-transcript →
  fail-safe fall-through; persisted API_HALT propagates to the parent.

---

## [1.7.0] — 2026-05-28

MINOR — **Headless workflow guard + Workflow-tool leverage evaluation.** Ships the
unblocking half of the deferred recovery+guard spec, plus the durable outcome of an
18-agent adversarial design audit of how (and whether) /plan-w-team should leverage
the Workflow tool / ultracode / Opus 4.8. (API/socket-halt worker recovery — the
other half — follows as 1.8.0; it is critical-path and gets its own tested change.)

- `feat`: **PWT-WF1 workflow guard** — `pwt-goal.sh` adds `CLAUDE_CODE_DISABLE_WORKFLOWS=1`
  to `LAUNCH_ENV`, so every bg worker + supervisor it spawns runs headless with
  Dynamic Workflows disabled. The token "workflow" appears dozens of times in
  /plan-w-team prose; in headless mode that could trigger a nested workflow fan-out
  bypassing gated dispatch + the RAM-budget gate. Headless/bg only — interactive
  sessions keep workflows. Env-var name **verified** in the CLI 2.1.156 binary string
  table (not a silent no-op). Test: `pwt-goal-workflow-guard.test.sh` proves the var
  reaches BOTH spawn environments end-to-end.
- `fix(docs)`: resolve a self-report contradiction — `opus-4-7-practices.md` said
  "trust its self-reported blockers in autonomous /goal runs", contradicting the
  durable anti-gaming rule (progress "measured objectively, never self-reported").
  Now scoped to **non-terminal corroboration only**; the objective metric still
  governs STALL-ALERT.
- `docs`: `docs/operations/workflow-tool-leverage-evaluation.md` — the adversarial
  verdict (Workflow tool is research-preview / no stable API → deep pipeline adoption
  defers to GA; safe-now wins are no-workflow autonomy tuning + Agent()-tool depth,
  pilot-grade) and the sequenced roadmap. Records WHY the executor stays workflow-free
  until GA.

---

## [1.6.0] — 2026-05-28

MINOR — **Post-1.5.0 deep-audit follow-through.** A 79-agent adversarial audit of
the Opus 4.8 / Claude Code 2.1.140–2.1.154 surface (run under ultracode) confirmed
33 actionable items; this release ships the certain, low-risk tier and corrects
documentation that the 1.5.0 model rollover left stale. Spec for the deferred,
higher-blast-radius items: `docs/specs/pwt-worker-recovery-and-workflow-guard.md`.

- `feat`: **statusline effort display** — `.claude/statusline.sh` renders the active
  effort level (`⚡ ultracode` / `⚡ xhigh + workflows` / `max` / `high`…), reading
  `.effort.level` from stdin (the precise signal) then `$CLAUDE_EFFORT`. Hidden for
  effort-less models. No $-cost/burn-rate added (Max-only statusline constraint kept).
- `fix`: **flaky `pwt-claims-cleanup.test.sh`** — pinned `CLAUDE_PROJECTS_DIR` to an
  empty sandbox so the `claude-agents-extended.sh` wrapper finds no live subagents.
  Root cause: the test reached the real `~/.claude/projects`, so concurrent sessions'
  subagents leaked into the "live SID" set and made orphan-removal assertions
  non-deterministic (passed standalone, failed intermittently in-suite). Verified
  GREEN 2× under live-subagent load. This removes the pre-existing red that forced
  `--no-verify` on prior pwt commits; `make test-skill` is now 50/50.
- `feat`: **`--fallback-model` resilience** — `pwt-goal.sh` threads
  `--fallback-model` (default `claude-opus-4-7`, override `PWT_FALLBACK_MODEL`) into
  both worker and supervisor `claude --bg` spawns, so a missing Opus 4.8 pin degrades
  instead of hard-failing every request (2.1.152 behavior; no-op in interactive mode).
- `docs`: **`/effort xhigh` wiring** — `opus-4-7-practices.md` §5 replaces the obsolete
  "high + think-carefully to approximate xhigh" bullet with explicit guidance to use
  `/effort xhigh` for one-way-door reviews and gnarly specs (evaluator stays `high`).
- `fix(docs)`: **stale-model accuracy corrections** left by the 1.5.0 rollover —
  `04-fix-first-review.md` reviewers corrected from "Hands-tier `claude-opus-4-6`" to
  "Brain-tier (`model: opus` → Opus 4.8)" (verified vs `security-expert` /
  `code-review-expert` frontmatter); builder auto-fix subagent `Opus 4.6`→`4.7`;
  `goal-conditions.md` auto-mode change re-attributed `2.1.146`→`2.1.147`; CLAUDE.md
  `$CLAUDE_EFFORT` row re-attributed to 2.1.133 read-side (vs the set-side
  `CLAUDE_CODE_EFFORT_LEVEL`).
- `docs`: CLAUDE.md compat-table backfill — `terminalSequence` (2.1.141),
  `worktree.bgIsolation:"none"` + /goal in-flight gating (2.1.143), `--fallback-model`
  (2.1.152), statusline `COLUMNS`/`LINES` (2.1.153), stdio-MCP env (2.1.154), and the
  `effort.level` enum + `ultracode` note.
- `test`: `tests/skill/cases/opus48-uplift.bats` extended with 1.6.0 invariants
  (AC11–AC15: statusline effort levels, fallback-model spawn flags, reviewer-tier
  accuracy, version/changelog).

---

## [1.5.0] — 2026-05-28

MINOR — **Opus 4.8 + Claude Code v2.1.154 uplift.** Rolled the Model Strategy a
generation forward and adopted the low-risk surfaces from the 2.1.150→2.1.154
changelog delta. Spec: `docs/specs/opus48-v2154-uplift.md`.

- `breaking`: **Model generation rollover.** Brain-tier agent frontmatter pins
  `claude-opus-4-7` → `claude-opus-4-8` (`team/evaluator`, `team/validator`,
  `team/supervisor`, `team/silent-failure-hunter`, `research-planning/test-gap-analyzer`,
  `research-planning/security-gap-analyzer`, `research-planning/system-architect`).
  Hands-tier `claude-opus-4-6` → `claude-opus-4-7` (`team/builder`,
  `implementation/react-typescript-specialist`, `implementation/rust-backend-specialist`).
- `docs`: Manifest Model Strategy table + rollover guidance now reference Opus 4.8
  (Brain) / 4.7 (Hands); added a generation note.
- `docs`: **Dynamic Workflows (`/workflows`) vs /plan-w-team** positioning section
  in the manifest — when to fan out via the Workflow tool vs run the spec-first
  lifecycle. Adoption-into-pipeline deferred (research preview).
- `docs`: `shared/opus-4-7-practices.md` updated for Opus 4.8 — defaults to high
  effort, `/effort xhigh` now reachable from the CLI (the pre-4.8 "xhigh API-only /
  unreachable on Max" limitation is lifted). Filename keeps the `-4-7-` slug for
  backward-compatible references.
- `docs`: CLAUDE.md Models table adds Opus 4.8; compat table gains rows for
  2.1.150–2.1.154; hook-event table grows to 20 events (`MessageDisplay`) and notes
  `SessionStart` `reloadSkills`/`sessionTitle` + `disallowed-tools` skill frontmatter.
- `test`: `tests/skill/cases/opus48-uplift.bats` asserts the model pins, doc
  invariants, version bump, and report presence (AC1–AC8/AC10).
- `docs`: version-uplift report at `docs/operations/version-uplift-reports/2026-05-28-2.1.154.md`.

---

## [1.4.0] — 2026-05-27

MINOR — **Deploy Secret Access (Headless / Autonomous)** standard. The
no-github-actions rule moved build/CI/deploy onto the local Makefile, which
removed where CI used to read deploy secrets (`secrets.*` in the runner). This
adds the replacement secret source — and because autonomous workers run headless,
it must be prompt-free and reboot-stable. Lives in the skill so it travels to
every synced repo (concrete tokens/account IDs stay per-project).

- `docs`: **`shared/no-github-actions.md` §"Deploy Secret Access"** (landed from
  PR #15, `97c5d7f`). Documents the four components — `~/.config/<project>/deploy.env`
  (0600, outside the repo), `scripts/load-deploy-env.sh` (sources only when the
  token var is unset; an injected env always wins), `scripts/setup-<provider>-token.sh`
  (atomic 0600 write, never echoes the token, verifies the account before success),
  `scripts/preflight-deploy-account.sh` (wrong-account guardrail). Captures the
  CRITICAL Makefile gotcha (a preflight prereq runs in a separate process, so each
  deploy recipe must source the loader INLINE), the why-not-keychain/launchctl/GH-
  secrets rationale, mandatory least-privilege scope, `.gitignore` hygiene, and the
  CleanRev (cleanscale) reference implementation. Cloudflare worked example.
- `feat`: **`scripts/Makefile.template` seeds the pattern** — a `preflight-deploy-account`
  target and a `deploy: preflight-deploy-account` recipe that models the inline
  `. scripts/load-deploy-env.sh && <cmd>` shape, so every adopting repo gets the
  correct deploy-recipe shape for free instead of re-deriving (and re-fumbling) it.
- `chore`: `deploy.env` / `.deploy.env` added to `.gitignore` (defense-in-depth; the
  canonical store is outside the repo).
- `test`: `plan-w-team-makefile-template.test.sh` Test 7 (5 assertions) guards the
  seeded pattern. Corpus green.

---

## [1.3.1] — 2026-05-27

PATCH — close the double-spawn gap that the 1.3.0 run itself triggered (req4; the
autonomous run shipped reqs 1–3 but skipped this late-appended one, so it was
completed by hand per the fix-immediately rule).

- `fix`: **PWT-DS1 double-spawn guard now covers the `--launch` path**, not just
  `--worker-only`. Root cause (2026-05-27): the UserPromptSubmit route hook
  auto-spawns via `--supervisor-goal` (worker-only semantics) and writes the
  hook-spawn flag; the assistant then also ran `pwt-goal.sh --launch` in the same
  turn, and the old `WORKER_ONLY=1`-only guard let the detached `--launch`
  through → duplicate run (route-created `b3578658` vs manual `48adde90`) clobbering
  the same skill files. Guard condition extended to `{ --worker-only OR --launch }`.
  Safe: the route hook calls pwt-goal BEFORE writing its flag, so the hook's own
  spawn never self-trips.
- `fix`: freshness window widened 60s → `PWT_DOUBLE_SPAWN_WINDOW_MIN` (default 3 min)
  so it spans a full assistant turn between the route-hook spawn and a same-turn
  manual call. A stale flag (older than the window) still does NOT block a
  legitimate later run; `PLAN_W_TEAM_FORCE_SPAWN=1` remains the escape hatch.
- `test`: new `pwt-goal-double-spawn-guard.test.sh` (12 assertions): fresh-flag +
  `--launch`/`--worker-only` → refused (exit 3, zero spawns, emits existing
  worker_sid); no-flag and stale-flag → not blocked; FORCE_SPAWN bypasses.

---

## [1.3.0] — 2026-05-27

MINOR — three coupled development/testing governance rules baked into the skill, plus a
shipped local-CI Makefile template. Codifies memories
`feedback_fix_defects_and_flaky_immediately` and `project_no_github_actions` into the
skill so they propagate to every consumer repo instead of living only in per-machine
memory.

- `feat`: **Fix-Immediately, Never Defer** (`04-fix-first-review.md` §5-0, enforced at
  `05-ship.md` ship gate and audited at `07-retro.md` §8c + `shared/supervisor-protocol.md`
  Fix-Now Audit). A worker MUST fix any real defect OR flaky test immediately
  (fix→deploy→retest→verify-GREEN→note) and may NEVER advance past a red or merely-"noted"
  item. Flaky tests are repaired by removing non-determinism (mock/stub/pin/isolate, 100/100),
  never by loosening assertions, retries, `.skip`, or widened timeouts. A red gate is
  bypassed only after a stash→run→identical-failure proof of pre-existing non-determinism,
  and even then queued for immediate repair.
- `feat`: **No GitHub Actions for build/CI/deploy** governance rule
  (`shared/no-github-actions.md`, referenced by the `05-ship.md` §6b-bis drift gate). The
  canonical path is the local Makefile + admin-squash-merge; a GH-Actions build/deploy path
  is off-policy drift treated as a defect. The `ci-alert.yml.template` observer is EXEMPT.
- `feat`: **Ship the local Makefile with the skill** — `scripts/Makefile.template`
  (toolchain-agnostic `ci`/`test` + `merge` admin-squash + `deploy`) added to the
  `sync-to-project.sh` allowlist (mirroring `ci-alert.yml.template`), so every synced repo
  inherits the local build/merge/deploy path that prevents GH-Actions drift.

## [1.2.1] — 2026-05-27

PATCH — fix the worktree-cleanup defect that let `.claude/worktrees/` grow to
tens of GB despite the Layer-1 GC existing. Two independent root causes, both
proven against a 74-worktree cleanscale checkout where the GC reclaimed 0:

- `fix`: **stale-lock awareness** in `plan-w-team-worktree-gc.sh`. Claude Code
  locks a subagent's worktree for its lifetime and SHOULD unlock on
  SubagentStop, but the unlock is unreliable (crash/timeout). The legacy rule
  "any lock == in-use" therefore pinned merged/idle worktrees forever once their
  owner died. A lock is now honored as in-use ONLY when corroborated by a live
  session OR recent activity (last commit within `PWT_WORKTREE_LOCK_STALE_HOURS`,
  default 24h); a lock with neither is STALE and no longer blocks reclamation.
  New env: `PWT_WORKTREE_LOCK_STALE_HOURS`, `PWT_WORKTREE_GC_TRUST_LOCKS=1`
  (legacy opt-in). The misleading "in-use by live claude session" reason now
  distinguishes `session` / `lock-recent` / `lock-trusted` sources.
- `fix`: **ignore-path dirty check**. Runtime hooks rewrite `.claude/state/*`
  (e.g. `bg-agents-cache.json`) into every worktree, so the (correct) "never
  delete uncommitted work" rule fired on non-work cache files and kept every
  worktree forever. Dirtiness confined to `PWT_WORKTREE_GC_DIRTY_IGNORE`
  prefixes (default `.claude/state/`) is now treated as clean; any real
  source/doc edit still blocks.
- `fix`: **unlock-on-stop** — `subagent-stop-worktree-cleanup.sh` now runs
  `git worktree unlock` on the subagent's own worktree before the scoped GC, so
  locks self-release at the moment their owner stops (source-side fix). The
  retro sweep (§8j-septies) passes `PWT_WORKTREE_GC_IGNORE_LOCKS=1` for its own
  finished subagents. `remove_one` unlocks before `git worktree remove`.
- `test`: +10 assertions (ignore-path clean/real-edit, stale-lock prune,
  fresh-lock keep, trust-locks legacy). Corpus 39 → 49, all green incl. bash 3.2.
- JSON output gains additive keys `locked`, `stale_lock`, `in_use_source`
  (back-compat: existing keys unchanged).

Impact: against cleanscale the enhanced GC reclassified 22 previously-pinned
worktrees as SAFE-PRUNE and reclaimed ~11 GB; the full disk-hygiene pass freed
~48 GB.

## [1.2.0] — 2026-05-25

MINOR — objective-progress supervisor self-check (anti-stall + anti-drift),
generalized from cleanscale's `scripts/ops/supervisor-progress-check.sh` and
made portable to any repo. Additive; pre-bump worker sessions keep functioning.

- `feat`: **`supervisor-progress-check.sh`** — a generic STEP-0 supervisor
  self-check that runs FIRST in every polling tick. Snapshots objective,
  user-verifiable metrics (branch commit count, AC-PASS count from the run's
  spec roll-up, open-PR count), diffs against the prior tick in
  `.claude/state/supervisor-progress.json`, and emits PROGRESSING / IN-FLIGHT
  (recent `agent-*` worktree mtime guard) / BACKLOG-CLEAR / STALLED /
  STALLED-UNKNOWN / `🔴 STALL-ALERT`. `STALL_THRESHOLD` (default 2) consecutive
  flat ticks with backlog > 0 → exit 2: the supervisor MUST spawn the next
  backlog item or escalate a hard-gate — idling is a hard error, never a valid
  tick. Anti-drift: the backlog anchor is the run's OWN failing spec ACs (never
  improvise off-target). Portable (no repo-specific metric paths; metrics derive
  from the run's git + spec/transcript), bash-3.2 compatible, python JSON parse
  (never grep-on-JSON). 13-case test suite incl. the bash-3.2 runtime guard.
- `feat`: **`shared/supervisor-protocol.md` §Step 0**, wired ahead of the
  Standard Tick and the user-silence CONTINUATION CHECK (complements, does not
  duplicate it). Encodes the durable rule: _a monitoring-only tick is a failure
  while backlog > 0; progress is measured objectively, not self-reported._
  Explicitly notes that an `AT_CAPACITY` RAM verdict / "perceived ceiling" does
  not license indefinite idling — sustained flat ticks escalate.
- `chore`: synced into `sync-to-project.sh` allowlist (+ dry-run preview);
  allowlist symmetry verified.

Note: the unified `run.sh` surfaces a pre-existing non-hermetic flake in
`pwt-claims-cleanup.test.sh` (its `legacy`/`real-repo` cases read live
`claude agents` state rather than a mock) — unrelated to this change (fails
identically with it stashed); tracked as a separate test-isolation follow-up.

---

## [1.1.1] — 2026-05-25

PATCH — test-reliability + test-suite-coverage fixes from the 2026-05-25 complexity audit
(`docs/operations/pwt-complexity-audit-2026-05.md`). No product behavior changed; the audit
confirmed the bats suite green (328/328) and the routing/spawn cascade guards correct. The
fixes repair stale/fragile TESTS that had bit-rotted undetected because they ran outside the
canonical runner.

- `fix`: **route-prompt-recursion test env isolation** — the test invoked the hook without
  the kill-switch but never `unset` the ambient `PLAN_W_TEAM_DISABLE_PROMPT_ROUTE`, so it
  spuriously failed inside any pwt worker session. Now scrubs ambient kill-switch vars.
- `fix`: **route-prompt-supervisor-env test counts only `--bg` spawns** — `pwt-goal.sh`
  legitimately added a `claude agents --json` capacity probe; the test counted _all_
  `claude` calls and miscounted. Added a `bg_only` filter.
- `fix`: **tests/route-prompt `--supervisor-goal` flag** — the hook evolved from
  `--worker-only` to the superset `--supervisor-goal`; the test's `shim_received_worker_only`
  now accepts either.
- `test`: **`run.sh` now runs the `.claude/{scripts,hooks}/*.test.sh` corpus** as a unified
  Phase 2 (one canonical runner for ALL tests; per-test timeout; folded into exit code +
  JSON archive). Closes the orphaned-test gap that let the above rot undetected.

See the audit report for findings F1 (`$CLAUDE_PROJECT_DIR` cross-repo leak), F4 (dormant
`.githooks/pre-commit` test guard), and F5 (`--worker-only`→`--supervisor-goal` doc drift),
which are surfaced as recommendations.

---

## [1.1.0] — 2026-05-25 (e9443cc)

MINOR — consolidates the additive skill-surface work landed 2026-05-23 → 2026-05-25.
All changes are backward-compatible: pre-bump worker sessions keep functioning.
(This entry also reconciles a versioning gap — the auto-bump hook never fired since
1.0.0 because it misparsed escaped-quote commit messages; see the fix below.)

Disk hygiene (two-layer initiative):

- `feat`: **Layer 1 — worktree + companion-process lifecycle GC** (`2cbcfb7`, merge
  `099a93e`). New `plan-w-team-worktree-gc.sh` (classifies SAFE-PRUNE-MERGED /
  SAFE-PRUNE-IDLE / UNSAFE-KEEP / ORPHAN-ASK), `plan-w-team-worktree-on-merge.sh`
  (Step 6 ship post-merge sweep), `plan-w-team-companion-gc.sh` (orphan watcher
  reaper), a `SubagentStop` hook, a weekly launchd template, and Step 6/Step 8
  wiring. New state surface; nothing removed.
- `feat`: **Layer 2 — per-stack dependency-tree sharing** (`b62b4ff`, merge
  `bc4a63d`). New `worktree-deps-share.sh` engine + Step 3-4 wiring: shares
  node/cargo/python/etc. dependency trees into worktrees instead of
  re-materializing them. New `worktree-deps-hash-<slug>.json` state artifact.

Goal-evaluator + trigger robustness:

- `fix`: **goal-evaluator escaped-quote detection** (merge `bff0131`). The Stop
  hook now jq-decodes transcript JSONL so terminal signals (`retro-complete`,
  hard-gate escalations, low-confidence streaks) are detected even when stored
  with escaped quotes — previously false-negatived, trapping autonomous runs.
- `fix`: **deps-share trigger moved `WorktreeCreate` → `SubagentStart`** (`a664ee2`).
  `WorktreeCreate` _replaces_ worktree creation and must echo a path; registering
  a deps shim there broke every worktree-isolated agent. Corrected to the
  post-create event.
- `feat`: **deps-share also fires on `SessionStart`** (`c071174`) for
  `claude --worktree` / `--bg --worktree` sessions launched directly into a worktree.

Portability + correctness:

- `fix`: **bash 3.2 compatibility** (`8fae76f`, `e9443cc`). The deps-share engine
  used `declare -A` (bash 4+), fatal on macOS stock `/bin/bash` 3.2 (e.g. the
  mac-mini) — silently no-op-errored there. Rewritten 3.2-safe; runtime
  regression guards added to the engine + all three Layer 1 GC suites.
- `fix`: **VERSION auto-bump hook escaped-quote bug** (this release). The
  `pre-commit-pwt-version-bump.sh` `PreToolUse` hook truncated the command at the
  first `\"`, losing the commit message so every bump defaulted to PATCH and
  VERSION never moved off 1.0.0. Now jq-parses the command; classification is
  feat→MINOR / fix→PATCH / `!`/BREAKING→MAJOR. Covered by a new test suite.

Other skill-surface additions since 1.0.0:

- `feat`: STE + SRE extensions — universal paired test/security tasks, test-gap +
  security-gap analyzers, coverage/security ship floors (`8e5b53e`, `378b36a`).
- `feat`: task-conflict-detector for safe parallel spawning (`45ed7a4`, merge `27c48f9`).
- `feat`: `locate-claude.sh` — robust claude-binary discovery for hooks + pwt-goal (`fd17938`).
- `feat`: subagent visibility — `claude-agents-extended.sh` wrapper surfacing
  Agent-tool subagents in the fleet view.

---

## [1.0.0] — 2026-05-22 (initial release)

Baseline version captures the state of `/plan-w-team` as of 2026-05-22 after
the burst of stabilization work landed earlier in the day. The changelog will
be appended forward from this point; entries below are a **backfill** of the
most load-bearing commits that shaped this baseline (newest-first within the
day).

Backfilled day-of commits (2026-05-22):

- `1691336` feat(plan-w-team): cross-repo fair-share scheduler (PWT-RAM2) —
  pwt-fair-share.sh + tests; complements the RAM gate by preventing one repo
  from starving others when total slots are constrained.
- `c161e79` fix(pwt-goal): centralize slug derivation in `__pwt_safe_slug`
  helper — prevents multi-line / over-long ORIGINAL_REQUEST values from
  overflowing NAME_MAX or embedding newlines in downstream filenames.
- `f4c76f0` feat(plan-w-team): wire RAM gate into pwt-goal.sh (PWT-RAM1 T2) —
  RAM capacity check at spawn time prevents OOM under parallel-worker bursts.
- `c10fe9c` feat(plan-w-team): ram-budget.sh + tests (PWT-RAM1 T1) —
  underlying RAM-budget computation primitive.
- `7bfdf8b` fix(plan-w-team): PWG counts idle workers, not just busy —
  parallel-worker gate fairness fix.
- `c11ffde` feat(plan-w-team): completion-summary writer + AC roll-up +
  holistic-check — every retro now emits `plan-w-team-completion-<SLUG>.json`
  - `.md` artifacts. This release wires `skill_version` and `skill_commit_sha`
    into those artifacts for the first time (see deliverable #4 below).
- `d1874ff` feat(plan-w-team): CI-aware supervisor merge-gate — supervisor
  now consults CI status before approving merges, closing the gap that caused
  the 2026-05-22 cleanscale merge incident.
- `bf3750b` feat(plan-w-team): supervisor-mirror lifecycle auto-sync +
  slug-from-original-request — origin goal-state mirror auto-terminates with
  worker DEAD; slug is derived from the original request text deterministically.
- `b9edf2d` feat(plan-w-team): supervisor-protocol autonomy (5 of 6
  deliverables) — decision matrix, `next_batch_spec`, governance tags, and
  the supervisor's revised hard-rule contract for long-running runs.
- `0596d91` feat(plan-w-team): add parallel-worker gate to route hook (PWG) —
  prevents recursive cascade when "use /plan-w-team to ..." appears inside
  worker prose.
- `750fe36` feat(version-uplift): /plan-w-team skill for detecting Claude
  Code CLI version changes and classifying changelog entries — bash chain
  including `fetch-changelog.sh --curl`, `evaluator.sh`, and `uplift.sh`
  wired into session-start.

### Why 1.0.0 starts here

Earlier work on `/plan-w-team` is well captured in `git log` but was not
under a formal versioning policy. `1.0.0` marks the point at which every
subsequent change is tracked here AND every run records its version into
the goal-state for bug attribution.
