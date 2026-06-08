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

## [1.41.0] — 2026-06-08 (7b70927)

End-to-end cleanup hardening. A 27-agent deep evaluation (prompted by recurring Helm/
WhatsApp "🔴 CleanRev Intake Failed … could not detach HEAD" alerts) root-caused the
failure and found two adjacent stale-leak classes. The recent mac-mini reset cleared the
_snapshot_ but NOT the mechanism — confirmed recurring. All three fixes are additive.

- **fix(sync, recurrence root-cause)**: the CleanRev intake cron's `git pull --rebase
--autostash` (cleanscale `scripts/intake/run-cron.sh`) aborts whenever claude-pattern's
  synced test corpus sits UNTRACKED in a consumer while `origin` tracks the same path —
  the sync COPIES `tests/skill/*.bats` (rsync) + `.claude/scripts/*.test.sh` (cp) into the
  consumer working tree but never commits them, and `--autostash` only saves _tracked_
  mods. Extended the consumer-side gitignore self-heal in `sync-to-project.sh` (the idiom
  that already untracks per-session caches) to ignore the synced test corpus
  (`tests/skill/cases/`, `tests/skill/scenarios/`, `.claude/scripts|hooks/*.test.sh`) +
  per-run state classes (`plan-w-team-credwall-*.json`, `pwt-brief-*.md`, ship-verdict,
  `supervisor-progress-*`). An ignored untracked file is silently OVERWRITTEN on checkout
  (no abort) and never gets committed — eliminating the "could not detach HEAD" class.
  Source repo never syncs to itself, so its own tracked corpus is untouched; append-only,
  so already-tracked consumer copies stay tracked. Regression test
  `tests/skill/cases/sync-gitignore-test-corpus.bats` proves the git mechanism
  (ignored→overwrite vs un-ignored→abort).
- **fix(worktree-gc, stale-leak)**: the GC dirty-ignore set omitted the synced tooling
  layer, so a merged/pushed worktree whose only dirt was synced `tests/skill/`/`docs/
operations/` files was pinned `UNSAFE-KEEP` forever and never reclaimed (live: cleanscale
  2 merged, parts 4, helm 4 stuck). Added `tests/skill/` + `docs/operations/` to the
  `PWT_WORKTREE_GC_DIRTY_IGNORE` default at both sites (`plan-w-team-worktree-gc.sh:527`
  - `:777`). Genuine product dirt still pins (only the synced layer is ignored), and only
    merged/pushed worktrees are eligible. Regression test `worktree-gc.test.sh` T18b
    (synced-tooling-only dirt → SAFE-PRUNE-MERGED; contrast T18 keeps a real edit → KEEP).
- **fix(retro, cross-run stale-block)**: the credential-wall artifact was never deleted at
  retro and the ship gate (6a-quinquies) globs `plan-w-team-credwall-*.json` blocking on
  any `resolved:false`, so a stale/false-positive wall failed the NEXT run's ship gate
  closed (reproduced: gate exit=1). `07-retro.md` now removes the run's credwall marker
  (slug + the legacy literal `active`) on success — reaching retro means we shipped past
  that gate, so the wall is resolved/moot.
- Deferred (recorded in the recursive-follow-up log): WT-2 (share the GC dirty-ignore into
  `on-merge.sh` invariant-2 — backstopped by the periodic GC), WT-5 (retro worktree-scoped
  untracked sweep), SA-4 (broaden the stale-state janitor beyond SUCCESS goal-states).

## [1.40.0] — 2026-06-08 (4263454)

Finishes + ships the disk-hygiene WIP the 2026-06-08 deep-audit flagged (the user
directed "finish & ship it properly" rather than leave it fenced). The audit confirmed
the WIP was duplicative, un-allowlisted, and breaking capacity-gate AC1; all three are
resolved here. No enforcing gate weakened; the GC change is additive + fail-CLOSED.

- **feat(disk-hygiene)**: land the worktree-GC mid-flight-reap fix (the 2026-06-07
  incident — a supervised worker that PUSHED in Step 6 had its worktree reaped before
  Steps 6b-8 could run). `plan-w-team-worktree-gc.sh`'s live-session check now (a) uses
  a NEW canonical probe `pwt-live-session-cwds.sh` (`claude agents --json`, replacing the
  old `ps | grep argv` heuristic that could not see a `claude --bg` worker whose argv is
  `…/<ver> --bg-spare /tmp/…`), and (b) **fails CLOSED**: if the probe can't run (claude
  unavailable / unparseable), no reclaimable (merged/pushed/idle) worktree is reaped — a
  missed reap is cheap, an erroneous one orphans a live run. `classify_one` gains a
  `LIVE_QUERY_FAILED → UNSAFE-KEEP` guard + a `live_query_failed` JSON field; test seam
  `PWT_WORKTREE_GC_TEST_QUERY_FAILED=1`. GC test +2 non-tautological cases (T27 pushed +
  live-owner → KEEP; T28 probe-unavailable → reclaim-nothing), each with a contrast case
  (78 assertions). New `pwt-live-session-cwds.test.sh` (8 cases) pins the probe's own
  contract: QUERY_FAIL seam, missing-binary, `[]`→empty, live/dead-mix filter, non-list,
  malformed, empty-output, OVERRIDE. Both new scripts added to the sync allowlist (they
  ship together — the GC hard-depends on the helper, so a split would fail-close all
  consumers' GC).
- **refactor(dedup)**: removed the untracked WIP `pwt-hygiene-sweep.sh`(.test.sh) — a
  redundant reimplementation of the reclaim predicate (on-origin + churn-only +
  fail-closed live-owner) that the committed `plan-w-team-hygiene-sweep.sh` composer
  already delegates to `plan-w-team-worktree-gc.sh` + `plan-w-team-companion-gc.sh` (plus
  a dead orphan-companion block whose output was discarded). Its only divergence — a more
  aggressive dirty-ignore pattern — was deliberately NOT adopted; the GC's conservative
  `.claude/state/`-only default is the safer, tested behavior.
- **test(cap-gate)**: `pwt-goal-capacity-gates.test.sh`'s fake-claude now answers the GC's
  `agents --json` liveness probe with `[]` and does NOT count it as a spawn, so AC1
  (worktree-cap-under-disk-pressure) is no longer polluted by the new in-place GC probe
  (the probe runs faithfully, as in production; it's just not miscounted as a spawn).

## [1.39.0] — 2026-06-08 (b3d78a9)

Deep-audit follow-up. A 50-agent Workflow review of the whole 1.28.0→1.38.0 change
surface (code-duplication, correctness-vs-intent, no-regression) found the shipped work
largely sound — the reuse-protection suite (H1–M3) is genuinely wired, not prose no-ops —
but surfaced one CRITICAL committed defect and one duplication-with-conflict. Both fixed
here; both ADDITIVE (the anti-park fix mirrors an existing guard; the janitor reconcile
keeps the SUCCESS-only behavior both callers already wanted).

- **fix(anti-park, CRITICAL)**: the identity-based supervisor yield (PWT-SUP-YIELD-SID) in
  `.claude/hooks/plan-w-team-goal-evaluator.sh` omitted the anti-park guard that the
  env-flag yield path already carried. A non-owning **mid-session origin-chat supervisor**
  — the dominant NL-/plan-w-team mode, which cannot set `PLAN_W_TEAM_SUPERVISOR_SESSION`
  in its launch env — therefore `exit 0`'d on `STALL-ALERT` + `backlog>0`, silently parking
  and DEFEATING PWT-ANTIPARK exactly where it was built to protect (the 2026-06-07 cleanscale
  incident, re-introduced via the SID path). Added the missing
  `&& [ "$ANTIPARK_BLOCK" != "1" ]` to the SID-yield condition so it blocks when anti-park
  engages. The 1.36.0/1.37.0 anti-park gate test only ever ran the env path with
  `session_id:""`, which is why this shipped green — added regression coverage
  (`plan-w-team-antipark-gate.test.sh` AC1-SID + AC1-SID-control; +`write_goal_sid`/
  `run_sid_session` harness; gate test now 16 assertions).
- **refactor(janitor)**: reconciled two contradictory stale-goal-state cleaners into ONE.
  The deleted `plan-w-team-cleanup-stale-goals.sh` removed ALL terminal states over an
  unscoped glob, so a retro from one run would delete ANOTHER run's `USER_ESCALATION_HALT` /
  `LOW_CONFIDENCE_STREAK` / `DEAD` goal-state meant for inspection. `07-retro.md` now calls
  the SUCCESS-only janitor `plan-w-team-cleanup-stale-goal-states.sh` (also used by
  session-start; gained a `--quiet` flag for a clean drop-in) — which matches the retro
  comment's own stated intent ("stale SUCCESS files accumulate") and preserves
  escalation/dead/null. No common-case behavior change (this run's shipped state is SUCCESS
  → still cleaned). Sync allowlist + dry-run list trimmed; the deleted script's test removed.
- The uncommitted disk-hygiene WIP (`plan-w-team-worktree-gc.sh` mod, untracked
  `pwt-hygiene-sweep.sh` / `pwt-live-session-cwds.sh`) was audited but left fenced: it is
  duplicative (`pwt-hygiene-sweep.sh` re-implements the committed hygiene composer + GC),
  un-allowlisted, and the GC mod breaks capacity-gate AC1 — it must not ship as-is. Tracked
  separately; not part of this release.

## [1.38.0] — 2026-06-08 (0a26131)

- feat(reuse-protection): close the code-reuse / anti-duplication protection gaps —
  the skill previously protected only TYPE reuse (inlined spawn-prompt block) and
  intra-run task collisions (Stage-2 gates), but not function/helper/module-level
  reuse (brief: `.claude/state/pwt-brief-reuse-protection-gaps.md`; spec:
  `docs/specs/plan-w-team-reuse-protection.md`). Every change EXTENDS a cited
  existing mechanism — no enforcing gate weakened. HIGH + MED gaps:
  - **H1**: mandatory "Existing-Code Survey / Reuse Audit" spec-template section
    (`01-specification.md`) + ENFORCING Step-1 freeze pre-condition
    (`plan-w-team-reuse-audit-gate.sh`, mirrors the Step-2 coupling-ack gate).
    Kill switch `PLAN_W_TEAM_DISABLE_REUSE_AUDIT=1`. Dogfooded: this run's own
    spec carries a filled-in Reuse Audit.
  - **H2**: builder spawn-prompt TYPE PRESERVATION broadened to CODE PRESERVATION
    (`03-execute.md`) — grep-before-write for functions/helpers/utils/constants/
    enums; TYPE rules kept verbatim; positive exemplar; +15% WTF penalty in
    `shared/self-regulation.md` + `team/builder.md`.
  - **H3**: reuse-first rule embedded in a SYNCED skill artifact
    (`shared/reuse-first.md`) so it reaches worktree-isolated builders + consumer
    repos — no longer dependent on user-global CLAUDE.md.
  - **M1**: Step-5 reviewer reuse/duplication remit by default + a
    `consolidate-into-existing` Pass-2 routing option (`04-fix-first-review.md`).
  - **M2**: cross-feature / recent-commit overlap scan at Step 0
    (`plan-w-team-reuse-overlap-scan.sh`) — deterministic, bash 3.2, fail-open,
    no network; findings feed the H1 Reuse Audit.
  - **M3**: opt-in mechanical clone scan gated like deep-audit
    (`plan-w-team-reuse-clone-scan.sh`, `PLAN_W_TEAM_CLONE_SCAN=1`, default OFF,
    no hard dependency, no-op when absent).
  - 3 new scripts added to the `sync-to-project.sh` allowlist; 3 new `.test.sh`
    regression suites (21 cases) join the skill suite. LOW gaps recorded as
    follow-ups (out of scope per brief).

## [1.37.0] — 2026-06-07 (d8e83d3)

- fix(antipark-hermeticity): slug-scope the anti-park progress read + ship-time VERSION rebump —
  the two gaps the 2026-06-07 session (which shipped 1.35.0 + 1.36.0) surfaced
  (brief: `.claude/state/pwt-brief-antipark-hermeticity-and-version-collision.md`;
  spec: `docs/specs/antipark-hermeticity-version-rebump.md`). Both recorded in the
  1.34.0 recursive-follow-up log.
  - **Gap 1 — anti-park read hermeticity (correctness).** 1.36.0's `__antipark_state` reader in
    `plan-w-team-goal-evaluator.sh` read a GLOBAL, non-slug-keyed `supervisor-progress.json`, so a
    stale/foreign run's snapshot drove the current run's Stop decision — a stale May-28 file
    (`verdict:STALLED, backlog:9`) made goal-evaluator U18 (empty-criteria → backward-compat SUCCESS)
    return null on a live checkout. **Fix:** the snapshot is now slug-keyed
    (`supervisor-progress-<slug>.json`); the writer (`supervisor-progress-check.sh --slug "$SLUG"`,
    carries a `slug` field) and reader stay in lockstep; the reader fails open on a missing,
    foreign-slug, or stale (`PWT_ANTIPARK_MAX_AGE_S`, default 1h) snapshot. A snapshot from another
    run can never drive this run's terminal/yield decision. New hermeticity regression test
    (`plan-w-team-antipark-hermeticity.test.sh`) plants a stray global + foreign-slug + stale
    same-slug file in the real `.claude/state/` and proves the current run is unaffected and the
    suite stays green. Kill switch `PLAN_W_TEAM_DISABLE_ANTIPARK=1` unchanged.
  - **Gap 2 — concurrent-run VERSION collision.** Two `/plan-w-team` runs off the same base both
    bumped VERSION to the same value (the 1.35.0 collision). **Fix:** Step 6 ship now re-derives the
    version from main's CURRENT VERSION at ship time (not the spawn-time snapshot) via a deterministic
    helper `plan-w-team-next-version.sh` (resolution: `origin/main` → `main` → working tree). So a run
    that started at 1.36.0 but ships after a sibling landed 1.37.0 emits 1.38.0 — no collision, no
    cross-run coordination. Regression test `plan-w-team-next-version.test.sh` (hermetic git sandbox)
    proves the rebump and includes an explicit control showing the old spawn-snapshot bump would have
    collided. Documented in `shared/versioning.md §Concurrent runs` + `05-ship.md §6d`.
  - Docs in lockstep: `shared/goal-conditions.md §Anti-Park Gate` (+ `PWT_ANTIPARK_MAX_AGE_S` env row),
    `shared/supervisor-protocol.md §Step 0` (the `--slug "$SLUG"` invocation is now required).
  - Tests: `plan-w-team-antipark-gate.test.sh` updated to slug-keyed (still 13/13), 2 new test files
    added (8 + 9 cases). All 3 new `.claude/scripts/*` added to the `sync-to-project.sh` allowlist.
    bash 3.2 compatible. Honesty floor (C3) + worktree isolation NOT weakened.

## [1.36.0] — 2026-06-07 (91e98e9)

- feat(supervisor-no-park): PWT-ANTIPARK — promote `feedback_supervisor_progress_objective`
  from prose to an enforced gate so a supervised run never artificially parks/stalls while
  unblocked backlog remains (brief: `.claude/state/pwt-brief-supervisor-no-park-keep-driving.md`;
  spec: `docs/specs/supervisor-no-park.md`; root cause:
  `docs/operations/supervisor-no-park-rootcause-2026-06-07.md`).
  - **Root cause (cleanscale 2026-06-07):** a supervised multi-epic run caught a worker's
    fabricated "prod-verified GREEN", reverted it (honesty floor held), then PARKED in
    "recalibration" with 5/6 epics unbuilt. The goal-evaluator's supervisor-yield paths
    (`plan-w-team-goal-evaluator.sh` PWT-SUP-YIELD/-SID) let a supervisor session stop with a
    live `BLOCK_REASON` (backlog remains) with zero backlog/progress awareness;
    `supervisor-progress-check.sh` STALL-ALERT existed but was never consulted at the Stop decision.
  - **Fix (additive, fail-open, kill-switched `PLAN_W_TEAM_DISABLE_ANTIPARK=1`):** the evaluator
    now reads the objective progress snapshot `supervisor-progress.json` at the Stop decision via a
    fail-open helper. (1) A supervisor yield with `verdict=STALL-ALERT ∧ backlog>0` is BLOCKED →
    re-dispatch/escalate, never silent park. (2) An empty/missing AC contract is treated as not-done
    while objective backlog remains (no trivial SUCCESS). (3) Single-item-blocker partitioning falls
    out by construction — only the 3 registered hard-gates halt the whole run; a capability block keeps
    the run building the rest. (4) New "Supervisor Self-Regulation" rules (issue-handling≠stop,
    honesty-floor-without-paralysis) in `shared/self-regulation.md`.
  - Honesty floor (C3 worker-mode ship-verdict anti-spoof) and worktree isolation are NOT weakened.
  - Tests: `.claude/scripts/plan-w-team-antipark-gate.test.sh` (13 cases, bash 3.2). Docs:
    `shared/goal-conditions.md §Anti-Park Gate`, `shared/supervisor-protocol.md §Step 0`. New test
    added to `sync-to-project.sh` allowlist. Incident recorded in the recursive-follow-up log.
  - VERSION reconciled 1.35.0 → 1.36.0: this run was spawned in parallel off pre-1.35.0 main and collided on 1.35.0 with the seed-path fix (19e32f0); supervisor rebased the bump at merge.

## [1.35.0] — 2026-06-07 (19e32f0)

- fix(worker-only-stops-short-rootcause): fix the `--worker-only` "stops short of ship" root
  cause and make the worker self-ship (brief:
  `.claude/state/pwt-brief-worker-only-stops-short-rootcause.md`; spec:
  `docs/specs/worker-only-stops-short-rootcause.md`). Recorded as the first entry in the
  1.34.0 recursive-follow-up log (the run that built the capture skipped its own retro —
  exactly the gap the capture exists to catch).
  - **Root cause (Deliverable 1A) — seed where the worker runs.** `pwt-goal.sh --worker-only`
    seeded the anti-skip goal-state into `$PROJECT_ROOT/.claude/state`, where `PROJECT_ROOT`
    came from `git rev-parse --show-toplevel`. Invoked from inside a STALE SIBLING worktree
    (run `10ac5920`: origin chat sat in `pwt-evaluate-…`), `--show-toplevel` returned the
    CALLER's worktree, not the worker's freshly-created `pwt-apply-…` worktree → the seed
    landed in the wrong dir → the worker's goal-evaluator never found it → the anti-skip
    anchor (1.29.0) was inert → the worker stopped freely after commit+push, never reaching
    Step 6 ship or Step 8 retro. New `__pwt_main_repo_root` helper resolves the main checkout
    via `git --git-common-dir` (correct even from inside a sibling worktree); the seed now
    lands in (1) the worker's OWN runtime worktree state dir
    (`<main>/.claude/worktrees/<WT_NAME:0:60>/.claude/state`, race-safe — only when that
    worktree already exists) AND (2) the canonical `<main>/.claude/state` (always). `:0:60`
    truncation matches the `--worktree` flag so the path lands on the real worktree.
  - **Defense-in-depth (Deliverable 1B) — SID-disambiguated lookup.**
    `plan-w-team-await-terminal.sh::__resolve_goal_file` now also searches the true main
    checkout (via git-common-dir, so a supervisor that itself runs in a worktree still sees
    the main checkout's worktrees) and, when ≥2 worktrees carry a same-slug goal-state,
    prefers the one whose `worker_sid` matches `--worker-sid`. Added a non-looping
    `--print-goal-file` diagnostic seam.
  - **Worker self-ship (Deliverable 2) — Step 6 self-merges to `main`.** `05-ship.md`:
    `PLAN_W_TEAM_AUTO_APPROVE_PUSH=1` now AUTO-CLEARS the §6g push-ack gate (it was set by
    pwt-goal but never consumed — the worker either hand-touched the ack or blocked), and a
    new §6g-ter self-merges the PR to `main` (`gh pr merge --admin|--auto --squash
--delete-branch`, CI-aware) for **reversible** PRs in **autonomous** mode, then reclaims
    the worktree via `plan-w-team-worktree-on-merge.sh`. One-way-door (`DO NOT MERGE`) PRs stay
    human-gated; interactive runs open the PR and stop, unchanged. Fail-soft: a failed merge
    surfaces and continues to retro (never `exit 1` — that was the original stop-short trap).
    Kill switch `PWT_DISABLE_SELF_MERGE=1`.
  - **Regression test**: `.claude/scripts/pwt-goal-worker-seed-path.test.sh` (bash 3.2,
    hermetic git sandbox with a real stale sibling worktree) asserts seeded path == worker
    runtime worktree/slug (not the caller's), main-repo copy carries the worker SID, `:0:60`
    truncation parity, the `PWT_DISABLE_WORKER_WORKTREE=1` main-only path, and await-terminal
    SID disambiguation. Added to the `sync-to-project.sh` allowlist.
  - Worktree isolation (#6) and the supervisor-merge boundary were NOT touched — the worker
    self-ships; the supervisor is not relied upon to merge.
  - VERSION 1.34.0 → 1.35.0.

## [1.34.0] — 2026-06-07 (f400558)

- feat(dogfood-retro-and-safe-prompt-fixes): apply the regression-free findings from the
  2026-06-07 Claude-prompts-Claude evaluation and harden Step 8 retro for guaranteed
  recursive improvement (brief: `.claude/state/pwt-brief-dogfood-retro-and-safe-prompt-fixes.md`;
  spec: `docs/specs/dogfood-retro-safe-prompt-fixes.md`; report:
  `docs/operations/claude-prompts-claude-evaluation-2026-06-07.md`).
  - **F3 — positive exemplars (additive)**: paired the highest-risk negative anti-patterns in
    `team/builder.md` and `04-fix-first-review.md` with one-line `Good:` exemplars of the
    desired shape. Every pre-existing negative retained (defense-in-depth); positive exemplars
    per `opus-4-7-practices.md` §7.
  - **F6 — stale forward-looking phrasing (cosmetic)**: corrected `team/supervisor.md:131`
    ("future T5 /goal Haiku evaluator" → the shipped deterministic self-hosted Stop-hook +
    Anthropic's Haiku evaluator) and repo-grep-fixed every other "future T5"/"will consume"/
    "once T5 ships" site across `shared/supervisor-protocol.md` and `shared/fleet-manager.md`
    that described already-shipped behavior.
  - **F2-docs — tier-name prose + canonical table (docs only)**: softened non-load-bearing
    literal model-ID prose in `03-execute.md`, `shared/opus-4-7-practices.md` to tier names
    pointing at the SKILL.md Model Strategy table (now marked the single canonical tier→ID
    map), and added an explicit **frontmatter-pin exception** so a future maintainer never
    centralizes the pins. Frontmatter `model:` pins UNCHANGED (the tier split depends on them).
  - **F1/F5/F7 — recorded, NOT applied**: each behavior-affecting redundancy-removal teed up as
    a scope-challenge candidate (principle weakened + regression surface + PROCEED/DEFER/KILL)
    in `docs/specs/pwt-findings-f1-f5-f7-scope-challenge.md`. Verdict is the user's.
  - **Deliverable 3 — recursive-improvement capture (every full run)**: new retro §8j-decies +
    `plan-w-team-retro-capture.sh` (+ tests) ALWAYS capture weaknesses/struggles/gaps, check
    this run's best-practice adherence against the PRIOR run (regression flag), and queue
    follow-ups into a durable cross-run log surfaced at the next run's preflight. Self-assessment
    `<8` now emits a structured `investigate_and_update` instruction + a queued follow-up, not
    just a number. Strictly additive; advisory (R10 — never fails the retro).
  - VERSION 1.33.0 → 1.34.0; `plan-w-team-retro-capture.sh`/`.test.sh` added to the
    `sync-to-project.sh` allowlist.

## [1.33.0] — 2026-06-07 (aa7fe9d)

- feat(doc-secret-handling-gaps): close the 24 documentation-handling and
  secret-handling gaps found by the 2026-06-07 adversarial audit. Every fix
  EXTENDS an existing mechanism — none weakens a pre-existing enforcing gate
  (brief: `.claude/state/pwt-brief-doc-secret-handling-gaps.md`; spec:
  `docs/specs/pwt-doc-secret-handling-gaps.md`; ops page:
  `docs/operations/pwt-doc-secret-handling.md`).
  - **A1/A6/C2 net-new surface doc scan** — new `plan-w-team-netnew-surface.sh`
    complements the §7a per-file doc audit (which is structurally blind to
    genuinely-new surface). Detects added public-surface files, env vars, exported
    symbols, and CLI flags over a git range; new hooks/scripts additionally require
    a `docs/operations/*` page (A6); infra-glob changes require a runbook touch
    (C2). Waiver file `.claude/state/plan-w-team-docs-waived-<SLUG>.txt`.
  - **A2 default doc-coverage AC + `N.d` doc-pairing** — `shared/sprint-contracts.md`
    gains a default doc-coverage AC for `add`-mode code tasks (the doc analog of the
    STE test-coverage default); `02-task-breakdown.md` gains the paired `N.d`
    documentation task protocol.
  - **A3 documentation ship gate** — new `plan-w-team-doc-ship-gate.sh`, wired at
    `05-ship.md §6c-quater`, refuses a ship that adds net-new public surface with no
    CHANGELOG/doc/waiver. Mirrors the access-control/credential-wall gate pattern
    (thin wrapper around a tested script).
  - **A4 real §8d post-ship reader + phantom-reader guard** — `07-retro.md §8d` now
    reads the post-ship artifact and scores doc hygiene (was a phantom writer);
    `plan-w-team-symmetry-check.sh` excludes the writer file from reader matching so
    a markdown-only self-reference no longer counts as a real consumer.
  - **A5 `post-ship-complete` precondition** — `shared/goal-conditions.md` +
    `07-retro.md` require the post-ship artifact to exist before `retro-complete`.
  - **B1 write-time secret content scan** — `damage-control.sh` now scans Edit/Write
    content through `secret-scan.sh` (the single source of truth) and BLOCKS on a
    live secret; the dead `secretDetection:` regex list in `patterns.yaml` was
    replaced with a pointer to the scanner (advertised defense made real).
  - **B2 binary/over-size skip surfaced** — the ship-gate §6a-ter failure-modes
    table documents that a binary/>1 MB skip is a coverage GAP, not a pass; the
    retro §8c-bis workspace/state secret sweep re-surfaces persistent skips.
  - **B3 token-adjacency placeholder suppression** — `secret-scan.sh`'s
    `is_placeholder_token` suppresses a marker only when it is contained in, or
    within `SECRET_SCAN_PLACEHOLDER_GAP` chars of, the matched token (not anywhere
    on the line).
  - **B4 allow-file staleness check** — `pre-commit-quality.sh` skips + WARNs on a
    secret-scan allow-file older than `PLAN_W_TEAM_ALLOW_MAX_AGE_DAYS` (default 30);
    retro cleans up the run's allow + waiver files.
  - **C1/C2 secret-handling documentation duty** — `01-specification.md §1c`,
    `shared/secret-safety.md`, and `shared/governance-tags.md` require a secret-
    handling deliverable (`.env.example` row + provisioning/rotation note) when a
    new secret-bearing env var is introduced, and a runbook/config-reference update
    for infra-glob changes; `06-post-ship.md §7f` enforces both at post-ship.
  - Tests: 6 new `.test.sh` corpora (netnew-surface, doc-ship-gate,
    symmetry-check-phantom, secret-scan placeholder-adjacency, damage-control
    secret-content, pre-commit allow-file staleness); all new `.claude/scripts/*`
    added to `sync-to-project.sh` allowlist (drift detector green, 38/38).

## [1.32.0] — 2026-06-06 (87a8c40)

- feat(worktree-gc-bg-daemon-hardening): harden the disk-hygiene GC + bg-daemon
  resume for the **push-not-merge** lifecycle (founder-gated merge — branches are
  pushed + PR'd, never merged). Seven fixes, all EXTENSIONS of existing
  mechanisms (spec: `docs/specs/worktree-gc-bg-daemon-hardening.md`):
  - **AC1 SAFE-PRUNE-PUSHED** — `classify_one()` reaps a worktree whose HEAD is
    reachable from any `origin/*` ref (work preserved on the remote / open PR) when
    the only uncommitted delta is policy-churn; reapable under `--execute` like the
    other SAFE-PRUNE-\* classes (not orphan-gated). Closes the "14 worktrees all
    UNSAFE-KEEP, 0 reaped" accumulation.
  - **AC2 broadened dirty-exclusion** — the GC "real uncommitted work?" predicate
    now excludes all of `.claude/`, `node_modules`, `ios/Pods/`, `android/.gradle/`,
    `build`, `DerivedData`, `.expo`, `dist` (prefix + any-depth-segment matcher),
    not just `.claude/state/`. Only a delta OUTSIDE that set sets `UNCOMMITTED=1`.
  - **AC3 disk-aware worktree cap** — `pwt-goal.sh` PWT-DISK2 cap is now a soft
    nudge: on trip it auto-runs the improved GC `--execute` once, re-counts, then
    consults `disk-budget.sh` — hard-refuse (exit 5) ONLY on real disk pressure
    (BLOCK/AT_CAPACITY); healthy `df` allows the spawn. `PWT_SPAWN_DRY_RUN=1` added.
  - **AC4 bg-worker resume staleness self-exit** — `pwt-goal.sh
--resume-staleness-check` + new `SessionStart` hook
    `plan-w-team-bg-resume-guard.sh`: a resumed worker whose goal-state is terminal
    OR whose target branch is already merged/PR'd self-exits instead of re-running
    (prevents the duplicate/conflicting push to an open PR).
  - **AC5 orphan-dir + leaked build-daemon reaping** — `plan-w-team-companion-gc.sh`
    reaps esbuild/Metro/vite/rollup/webpack/watcher daemons rooted in a DEAD
    worktree dir (gone or git-unregistered; WHITELIST + SAME-UID preserved); the GC
    classifies git-unregistered orphan dirs `ORPHAN-ASK`.
  - **AC6 preserve-then-reap** — `remove_one()` dumps `git diff HEAD` + untracked
    list (or an orphan-dir file manifest+copy, ignore-set filtered) to
    `.claude/state/hygiene-backups/` before any `--force` removal carrying real
    delta; a failed dump SKIPS the removal (fail-safe).
  - **AC7 standing hygiene sweep** — new `plan-w-team-hygiene-sweep.sh` composes
    the GCs + disk-budget into one dry-run-by-default sweep emitting a one-line
    summary for the supervisor's per-wake transcript + pre-flight.
  - Tests extend the existing corpus (worktree-gc +6, companion-gc +4, disk-budget
    +2/AC3, new bg-resume-guard +9, new hygiene-sweep +15); zsh array-safe, bash
    3.2 compatible; new script + hook added to the sync allowlist.

## [1.31.1] — 2026-06-06 (b3b2614)

PATCH — **Integration cap-pressure test** for the four `pwt-goal.sh` capacity gates
(`.claude/scripts/pwt-goal-capacity-gates.test.sh`). Drives the gate WIRING under pressure
through the real `--worker-only` spawn path and asserts refuse/bypass/ordering for each gate —
closing the integration-coverage gap left by the unit-level `ram-budget.test.sh` /
`disk-budget.test.sh` (the budget _scripts_) and the misleadingly-named
`pwt-goal-cap-enforcement.test.sh` (only the 4000-char directive cap). Test-only; no behavior change.

- RAM (PWT-RAM1, exit 5), Disk (PWT-DISK1, exit 5), Worktree-count (PWT-DISK2, exit 5),
  Fair-share (PWT-RAM2, exit 6): each gate trips → exit code + **zero** spawns + diagnostic stderr;
  each documented `PLAN_W_TEAM_DISABLE_*` override bypasses → spawn proceeds.
- Gate-ordering assertion (RAM short-circuits before disk) + all-clear positive control with every
  gate active and healthy.
- Hermetic: scrubs every `PLAN_W_TEAM_DISABLE_*` kill-switch the ambient worker session exports
  (a `--worker-only` worker runs inside a worktree and the launcher sets
  `PLAN_W_TEAM_DISABLE_WORKTREE_CAP=1`), so the gates — not a leaked env var — decide each outcome.
  Budget scripts driven host-independently via their `*_STUB_*` knobs; fake `claude` on PATH counts spawns.
- Spec: `docs/specs/integration-cap-pressure.md` (AC1–AC10). Auto-discovered by `tests/skill/run.sh`;
  full suite green (bats + 61 shell integration tests).

## [1.31.0] — 2026-06-03 (15d477b)

MINOR — **Consolidated Gotchas reference (`shared/gotchas.md`)**, added as the single
discoverable surface for the skill's recurring cross-cutting failure points. Outcome of an
honest evaluation of `/plan-w-team` against Anthropic's "Lessons from building Claude Code: how
we use skills" blog (per-lesson report at
`docs/operations/pwt-skills-blog-evaluation-2026-06-03.md`).

- The blog names a Gotchas section as the single highest-value part of a skill. The skill had
  rich hard-won failure knowledge (PWT-DS1/DS2 double-spawn guards, harness-drops-`additionalContext`,
  `--bg` needs explicit `--worktree`, Agent-tool model-alias-only, `mkdir`-not-`flock`, CHANGELOG
  SHA off-by-one, bash 3.2, `claude agents --json` flakiness, rsync same-size skip, sync
  allowlist, state-artifact registry) but it was **scattered** across stage files, inline
  comments, and memories — `grep -ri gotcha` returned 1 hit.
- New `.claude/commands/plan-w-team/shared/gotchas.md` consolidates 12 cross-cutting gotchas
  (G1–G12), each with what-bites-you / why / do-instead / canonical `file:line` source, plus an
  "Adding a gotcha" maintenance protocol. Advertised from the manifest Shared Resources table.
- Purely additive: no stage flow, pause site, state-artifact schema, or supervisor protocol
  changed. Pre-bump worker sessions are unaffected. Full skill test suite stays green.
- The other 9 blog lessons evaluated as ALREADY-SATISFIED or NOT-APPLICABLE (command-style
  skill, not a distributed plugin) with `file:line` evidence in the report — no manufactured
  changes.

## [1.30.0] — 2026-06-03 (af6dd73)

MINOR — **Identity-based supervisor yield (PWT-SUP-YIELD-SID)** in the goal
evaluator. Closes the recurring friction where an ORIGIN chat that _becomes_ a
supervisor mid-session is dragged into Stop-hook busy-poll every turn: the
pre-existing yield was env-only (`PLAN_W_TEAM_SUPERVISOR_SESSION=1`), which such a
session cannot set in its own launch env — and 1.29.0's PWT-WT2 worsened it by
reliably seeding the goal-state where the hook always finds it.

- `feat`: the evaluator now reads `SELF_SID` from the Stop-hook input's
  `session_id` and, per blocking goal, compares it against the goal-state's
  `worker_sid` (already recorded by PWT-WT2). **Only the OWNING worker blocks and
  runs to terminal; any other session (supervisor/observer) YIELDS** and is
  re-woken event-driven by its background `await-terminal` loop. The env-flag yield
  is preserved as a parallel path.
- `fix` (safety, from adversarial verification `wf_9cab85b2`): `worker_sid` is
  normalized (trim all whitespace + lowercase) and ownership is established ONLY by
  a token starting with **8 hex chars** — anything else (empty, short, non-hex,
  whitespace-only/padded) is treated as UN-OWNABLE → **fail safe to BLOCK**, never
  yield. This closes a CRITICAL hole where a whitespace-padded `worker_sid`
  (e.g. `"  5de5b9ac"`) would make even the GENUINE owner wrongly yield.
- **Sacred invariant verified** across 4 independent red-team angles + 10 bats
  cases (`tests/skill/scenarios/goal-evaluator-sup-yield-sid.bats`): owning worker /
  in-session lead / un-ownable goal / empty-SID **always BLOCK**. Accepted-by-design
  (INFORMATIONAL): the 8-hex first-prefix collision (≈ 1/4.3e9, and in the safe
  block direction).

## [1.29.0] — 2026-06-03 (ef2cbc0)

MINOR — **Supervisor-wait worktree-awareness + goal-state anti-skip activation for
`--worker-only` bg workers** (brief `supervisor-wait-worktree-aware`, spec
`docs/specs/supervisor-wait-worktree-aware.md`). Fixes the collision between two
prior upgrades: the 1.24.0 event-driven supervisor wait (`587d577`,
`plan-w-team-await-terminal.sh`) watched the MAIN checkout's goal-state file, while
PWT-WT1 (2026-06-02) made `pwt-goal --worker-only` run the worker inside
`.claude/worktrees/<slug>/`. Result: the PRIMARY `terminal_state` trigger could never
fire for a worktree-isolated worker (degraded to the `WORKER_GONE` + 30-min-heartbeat
backstops), AND the `--worker-only` path never seeded a goal-state file at all — so the
self-hosted goal-evaluator saw "No active goal → exit 0" and nothing blocked a premature
stop. Concrete evidence: the 1.28.0 build-artifact worker `c68e27ac` pushed to origin
then went idle BEFORE its consumer-sync DoD; the supervisor finished the sync by hand.
Additive — the `WORKER_GONE`/heartbeat backstops and the existing `await-terminal.bats`
suite are preserved.

- `fix` **`plan-w-team-await-terminal.sh` worktree-aware (PWT-WT2)** — resolves the
  goal-state file **each loop tick** in precedence: explicit `--state-dir` → main
  `<root>/.claude/state/` → worktree fallback
  `<root>/.claude/worktrees/*/.claude/state/plan-w-team-goal-<SLUG>.json`. Detection is
  purely file-based, so a worker that goes IDLE at terminal (never exits) is still woken
  via `terminal_state` — independent of the `WORKER_GONE` liveness path. Adds
  `PWT_PROJECT_ROOT_OVERRIDE` for test-friendly root resolution. Bash 3.2-safe (no
  nullglob; `[ -f ]` guard rejects an unmatched literal glob).
- `fix` **`pwt-goal.sh --worker-only` seeds the goal-state file (PWT-WT2)** — generalizes
  the `--supervisor-goal` mirror so EVERY worker-only spawn writes
  `plan-w-team-goal-<SLUG_GUESS>.json` (terminal_state:null) into the launching checkout's
  `.claude/state/` at spawn. The anti-skip anchor is now active from t=0 regardless of
  whether the worker LLM runs the manifest's PWT-T5b activation; the worker's own evaluator
  finds it via `FALLBACK_STATE_DIR`, and the supervisor's `await-terminal.sh` resolves it.
  Fail-open: a failed seed never blocks the spawn.
- `docs` — manifest Step 3c, `shared/supervisor-protocol.md` Wait mechanism, and
  `shared/goal-conditions.md` document the worktree-aware resolution + spawn-time seed.
- `test` — `tests/skill/cases/await-terminal.bats` +4 cases (worktree-isolated SUCCESS
  without heartbeat, main-present precedence, explicit `--state-dir` wins, no-goal shadow
  path); `tests/skill/scenarios/worker-only-seeds-goalstate.bats` asserts the spawn-time
  seed. Existing terminal/worker-gone/heartbeat/§3.1 cases stay green.

---

## [1.28.0] — 2026-06-03 (411e1a6)

MINOR — **Build cleanup preserves installables, cleans only intermediates**
(brief `build-artifact-preservation`). Closes the 2026-06-02 cleanscale incident
where a build-cleanup deleted an iOS Simulator `.app` together with its ~931 MB
`ios/build` intermediates on the cofounder-demo critical path. The intermediates
were ~90%+ of the footprint and should be reclaimed; the reusable `.app` should
have been kept. claude-pattern carried the identical bug. Additive safety layer —
the GB-scale intermediate reclaim and the existing location/source invariants are
preserved, extended with a final-artifact dimension.

- `feat` **proactive layer** — `.claude/scripts/plan-w-team-build-artifact-clean.sh`
  now relocates any final installable (`*.app`/`*.ipa`/`*.apk`/`*.aab`) out of an
  about-to-be-cleaned build dir into a protected kept-artifacts home BEFORE removing
  intermediates. Fail-safe: a failed `mv` skips the `rm` (never lose an artifact we
  could not save). Reclaim is measured after relocation, so the GB figure reflects
  intermediates only. Refuses to clean the kept-artifacts home itself.
- `feat` **reactive layer** — `.claude/hooks/damage-control/damage-control.sh` adds a
  final-artifact guard that runs BEFORE the `safe_rm_targets` short-circuit: an
  `rm -rf` whose target IS or CONTAINS an installable requires confirmation (`ask`)
  even for `build`/`dist`/`target`; the kept-artifacts home is hard-blocked; a
  pure-intermediate `rm -rf` is still allowed (GB-reclaim path not regressed).
- `feat` **kept-artifacts home** — configurable via `PWT_KEPT_ARTIFACTS_HOME`
  (absolute used as-is, relative resolved under the repo root so it survives worktree
  removal); default `.playwright-mcp/`. Layout
  `<home>/kept-build-artifacts/<worktree>/<relpath>`.
- `feat` **policy doc** — `docs/operations/build-cleanup-preserve-installables.md`,
  referenced from CLAUDE.md's disk-hygiene section; propagated to consumers via
  `sync-to-project.sh`.
- `test` — new `.claude/hooks/damage-control/damage-control.test.sh` (8 cases) and
  extended `plan-w-team-build-artifact-clean.test.sh` (cases 8-14): preservation of
  `.app`/`.ipa`/`.apk`/`.aab`, intermediate reclaim ≥1 MB in the same run, kept-home
  never cleaned, override honored, dry-run inert, `ask`/`allow`/`block` decisions.

## [1.27.0] — 2026-06-02 (6095b87)

MINOR — **Credential-wall escalation + step-completeness invariant** (brief
`credential-wall-escalation`). Closes the 2026-06-02 cleanscale defect where a
deploy CLI hit a non-interactive credential wall (`wrangler` → "set a
`CLOUDFLARE_API_TOKEN`") and the run **stopped short** — neither completing the
deploy nor escalating, with the missing secret never surfaced or persisted.

- `feat` **detector**: new `.claude/scripts/credential-wall-detect.sh` — pure,
  testable classifier for CLI non-interactive credential/token walls
  (wrangler/gh/vercel/eas/flyctl/aws). Extracts the EXACT missing secret name;
  zero false positive on success output + prose.
- `feat` **runtime hook**: new `.claude/hooks/plan-w-team-credential-wall-detect.sh`
  (PostToolUse(Bash) + PostToolUseFailure). Persists the missing secret + the
  repo's documented operator action (from `DEPLOY_RUNBOOK.md` when present) to a
  durable `.claude/state/plan-w-team-credwall-<SLUG>.json` (survives compaction;
  a secret NAME only, never a value) and emits a `blocked-external`
  `USER_ESCALATION_HALT` block (`pending_escalations: ["credential-wall"]`).
  Kill switch `PLAN_W_TEAM_DISABLE_CREDWALL_GUARD=1`.
- `feat` **step-completeness gate**: new
  `.claude/scripts/plan-w-team-credential-wall-gate.sh`, wired ENFORCING at
  `05-ship.md §6a-quinquies`. Fails closed while the artifact is unresolved (and
  on a malformed artifact) so a deploy/ship step blocked on a credential can
  NEVER be marked complete or silently skipped. The gate has no bypass.
- `feat` **goal-evaluator**: `credential-wall` added to the hard-gate site set →
  `USER_ESCALATION_HALT` terminal (additive; push-ack/secret-scan-allow/
  scope-unlock-for-drift unchanged).
- `feat` **docs (extend, not regress)**: `secret-safety.md §REQ-6` (CLI sibling of
  the §REQ-5 browser-console guardrail; §REQ-5 untouched); `no-github-actions.md`
  §"Deploy Secret Access" → new "Escalate, never skip" subsection;
  `03-execute.md` REQ-6 deploy-discipline note; new state-artifact registered
  (symmetry-check 38/38).
- `test`: new `tests/skill/cases/credential-wall.bats` — wrangler/gh/vercel
  detection, success+prose negatives, hook persistence + escalation emission, and
  the fail-closed/malformed gate paths.
- `chore` **sync**: `credential-wall-detect.sh` + `plan-w-team-credential-wall-gate.sh`
  added to the `sync-to-project.sh` allowlist; the hook + `settings.json` wiring
  propagate via the base rsync.
- `fix` **secret-scan self-documentation**: adding §REQ-6 to `secret-safety.md`
  surfaced a pre-existing false-positive — `secret-scan.sh` flagged the
  `azure-conn` row of its OWN auto-generated Pattern Catalog (the catalog mirrors
  the scanner's pattern SHAPES). The scanner already self-excludes its source file
  for this reason; extended that to skip lines inside the drift-checked
  `BEGIN/END AUTO-GENERATED: secret-patterns` block (lines OUTSIDE the block are
  still scanned — a real secret elsewhere in the doc is still caught). Regenerated
  the catalog table to clear pre-existing doc-sync drift. New bats coverage in
  `secret-scan.bats` (inside-block skipped / outside-block still caught). This
  removes the stale per-slug allow-anchor fragility for `secret-safety.md`.

## [1.26.2] — 2026-06-02 (f258045)

PATCH — **Round-2 follow-up: close the remaining MEDIUM gaps the re-audit named.**

- `fix` **P11**: the symmetry checker's Pass-2 (orphan-reader) was DEAD CODE for
  every `$SLUG`-keyed artifact — the rg capture ends in `-`, and the old blanket
  `*-` skip dropped them all (4 real handoff artifacts unregistered yet
  uncatchable). Pass-2 now skips only the bare common prefix and uses an EXACT
  stem match for `$SLUG` refs; registered the 4 surfaced artifacts (fleet-intent,
  skill-version, pass1-synthesis, test-output). Checker 37/37, exit 0 — and the
  green is no longer hollow.
- `fix` **P9b/C4 (MultiEdit bypass)**: registered a `MultiEdit` PreToolUse matcher
  for `block-protected-paths.sh` + `block-gh-actions-build.sh` — a `MultiEdit` to
  `.github/workflows/` or the secret-scan-allow file no longer bypasses the gates.
  New bats (behavioral + matcher-registration).
- `fix` **CS-4 (Drizzle)**: the content-scanner's CS-4 regex now also matches the
  Drizzle relational `where: eq(t.id, …)` object-property form (round-2 §3.5).
- `feat` **P14 root fix**: new `changelog-sha.bats` lint asserts every CHANGELOG
  entry's cited SHA resolves AND `git show <sha>:…/VERSION` equals the entry's
  version — catching the off-by-one drift class at its root. The newest entry
  carries `(pending)` until backfilled with its own shipping commit (the
  chicken-and-egg a commit can't contain its own SHA); documented in
  `versioning.md`.

C3/SUP-YIELD: confirmed already gate-covered (the `goal-evaluator-c3-antispoof`
scenario runs in `tests/skill/run.sh`). Accepted-by-design (not forced, to avoid
the drift the audit warns of): P7 deterministic fix-counter (prompt caps +
drift-lock are the higher-value layer), P8 gating-integer recompute (a strict
recompute against the non-strict findings format would itself be drift; §6c-ter
scanner re-run already covers the GIGO case), §6c-ter exit-2 warn (defense-in-depth;
§5b is the primary detection). Full suite green (bats + 59 shell + 37/37 symmetry).

## [1.26.1] — 2026-06-02 (51e6b52)

PATCH — **Round-2 re-audit regression fixes.** A round-2 adversarial re-audit
([`docs/operations/pwt-principles-reaudit-2026-06-02-round2.md`](../../../docs/operations/pwt-principles-reaudit-2026-06-02-round2.md))
confirmed the 1.22-1.26 wave delivers its intent (8 YES / 6 MOSTLY / 0 NO, suite
green) but caught regressions the green suite did not exercise. All fixed with
tests that now DO exercise them:

- `fix` **§3.1 (BROKEN)**: `plan-w-team-await-terminal.sh` reported a false
  `WORKER_GONE` for a LIVE worker when the base `claude agents --json` flaked to
  `[]` but live subagents kept the merged array non-empty (passing the length>0
  guard). The bg-worker liveness check now uses `--bg-only` so subagents can't
  mask base flakiness → a flaky base degrades to `[]` → rearm, never false-gone.
  New bats case.
- `fix` **§3.2 (AT-RISK)**: C8 child-cleanup's `${SELF_SID:0:8}*` trailing-glob
  lineage match could over-reap a CONCURRENT run's worker on an 8-char-prefix
  collision (or a sub-8-char SELF_SID). Dropped the glob (exact match), guarded
  sub-8 SELF_SID (skips reconciliation), and stopped truncating
  `parent_session_id` at `pwt-goal.sh` (records the full SID → collision-free).
  New prefix-collision + sub-8 tests.
- `fix` **§3.6 (P6 regression from PWT-WT1)**: a worktree worker's retro couldn't
  reach the origin/main `supervisor_mirror` row → the mirror never patched to
  SUCCESS → a clean ship fell to a false `LOW_CONFIDENCE_STREAK` halt.
  child-cleanup now cross-checkout-resolves the main state dir and patches ONLY
  this worker's mirror (exact match, no glob). New cross-checkout test
  (`PWT_CLEANUP_MAIN_STATE_OVERRIDE`).
- `fix` **§3.3 (P14 regression)**: corrected the off-by-one CHANGELOG header SHAs
  for 1.22.1→1.26.0 (each had cited the prior commit).
- `fix` **§3.4**: renamed the duplicate `## 8j-octies` retro heading (fan-out →
  `8j-nonies`) + repointed its reader (state-artifacts.md) and the
  `plan-w-team.md` §8j-bypass cross-ref.
- `fix` **§4 (C7 part-2)**: pinned `access-control-content-scan.sh` in the
  sync-allowlist drift guard's `REQUIRED_NONPREFIXED` set.

Full suite green (bats + 59 shell-integration + 33/33 symmetry). Remaining
deferred backlog (P8 recompute, P9b/C4 MultiEdit matchers, C3/SUP-YIELD unit
coverage, P11 Pass-2, native auto-bump hook) confirmed as the only material set.

## [1.26.0] — 2026-06-02 (be7a147)

MINOR — **PWT-SUP-YIELD: let a supervisor session sleep instead of busy-polling
(completes the event-driven wait; principle #2).** Diagnosed from a live run
(2026-06-02): the goal-evaluator Stop hook fires in EVERY session that sees the
worker's goal-state — including the origin-chat/supervisor — so it dragged the
supervisor back to poll each turn, negating the 1.24.0 event-driven wait (the
supervisor couldn't actually sleep even with the await-loop running).

- `feat`: `plan-w-team-goal-evaluator.sh` — a session that marks itself
  `PLAN_W_TEAM_SUPERVISOR_SESSION=1` now YIELDS (allowed to stop) instead of being
  blocked on a non-terminal goal it is merely supervising; it re-wakes
  event-driven via `plan-w-team-await-terminal.sh` (+ heartbeat re-arm for the
  Step-0 progress/stall check). **Opt-in, default unchanged**: a session without
  the flag blocks exactly as before. All per-goal terminal detection + dead-child/
  mirror propagation still run; only the final no-terminal-yet outcome flips
  block→yield, and only for the supervisor.
- `fix` (safety invariant): `pwt-goal.sh` forces `PLAN_W_TEAM_SUPERVISOR_SESSION=0`
  into the worker's `LAUNCH_ENV` so a spawned worker can NEVER inherit a
  supervisor=1 marker — "the worker runs to terminal" holds by construction.
- `feat`: `supervisor-protocol.md` §Wait mechanism + `plan-w-team.md` Step 3c — the
  supervisor/origin sets the flag and launches the await-loop so it truly sleeps.
- new: 3 scenario assertions (supervisor yields; non-supervisor still blocks;
  flag=0 still blocks) added to `goal-evaluator-c3-antispoof.bats`.

Provably safe to sync into a live run: any session without the flag is
byte-identical to pre-change. Full suite green (bats + 59 shell-integration).

## [1.25.0] — 2026-06-02 (efbef1d)

MINOR — **PWT-WT1: spawn the bg worker INSIDE an isolated worktree (deterministic
principle #6).** Root-cause fix for the 2026-06-02 incident where a route-hook
bg worker edited the MAIN checkout and clobbered a concurrent in-session editor.

- `fix`: `pwt-goal.sh` now spawns the worker with `claude --bg --worktree <slug>`
  (both `--launch` and `--worker-only` paths). The worker branches from HEAD into
  `.claude/worktrees/<slug>`, so its edits can NEVER touch the main checkout — it
  merges back at Step 6 ship like any builder. Previously plain `claude --bg`
  started the worker in main, and worktree isolation was left to the worker's LLM
  calling `EnterWorktree` mid-session (LLM-attention, not enforced) — any edit
  before/instead of that landed in main. `claude --help` confirms isolation
  requires the explicit `-w/--worktree` flag; `--bg` alone does NOT auto-isolate
  (the manifest claim was wrong — fixed). Opt-out: `PWT_DISABLE_WORKER_WORKTREE=1`.
- `fix`: `plan-w-team.md` §Background Execution — corrected the inaccurate
  "`--bg` auto-creates a worktree" claim and documented the deterministic spawn.
- new: `pwt-goal-worker-only.test.sh` now captures the spawn args and asserts the
  worker is launched with `--worktree` (AC2.5) and that the opt-out drops it (AC2.6).

Full suite green (bats + 59 shell-integration). Developed in-session (the route
hook spawned yet another worker on the trigger message; neutralized via goal-state
deletion — its daemon is shared with a live progressive-qa run and can't be killed).

## [1.24.0] — 2026-06-02 (587d577)

MINOR — **Event-driven supervisor wait (principle #2): stop guessing poll
intervals.** The supervisor/origin-chat previously waited on a worker by active
polling at a guessed ~30–60s cadence — losing up to a full interval of dev time
between a worker finishing and the supervisor noticing, and burning a supervisor
turn on every unchanged tick. Adapted from the progressive-qa-initiative run's
background until-loop idea.

- `feat`: NEW `.claude/scripts/plan-w-team-await-terminal.sh` — a blocking watcher
  meant to run via `Bash(run_in_background: true)` so the harness re-invokes the
  supervisor THE INSTANT the run flips state. Watches the goal-state
  `terminal_state` (the evaluator writes it for ALL terminal/halt states —
  SUCCESS / USER_ESCALATION_HALT / LOW_CONFIDENCE_STREAK / API_HALT, so the sad
  path wakes too) plus worker liveness (debounced against the flaky
  `claude agents --json`, per C2). Exit 0 = terminal/halt; exit 3 = heartbeat
  re-arm (a re-check, **NOT** a wall-clock cap — principle #3). Tunable via
  `PWT_AWAIT_INTERVAL_S` / `PWT_AWAIT_HEARTBEAT_S` / `PWT_AWAIT_GONE_CONFIRM`.
- `feat`: `shared/supervisor-protocol.md` §POLLING LOOP and `plan-w-team.md`
  Step 3c now make the event-driven wait the **default**; active poll /
  `ScheduleWakeup` remain documented fallbacks for cross-session gaps. The Step-0
  Progress Check + CONTINUATION CHECK still run on every wake.
- new: `tests/skill/cases/await-terminal.bats` (5) — terminal detection (happy +
  sad path), heartbeat re-arm, worker-gone debounce, present-worker-not-reaped.
- sync allowlist updated so the helper propagates to consumer repos.

## [1.23.2] — 2026-06-02 (3493932)

PATCH — **C8: spawn-registry↔cleanup slug reconciliation (concurrent-run-safe).**
`pwt-goal.sh` registers a spawned worker under `SLUG_GUESS=__pwt_safe_slug(
ORIGINAL_REQUEST)`, but `plan-w-team-child-cleanup.sh` reads the registry keyed
by the feature SLUG — on mismatch the cleanup found no manifest and reaped
nothing, re-creating the orphan-bg accumulation the registry+cleanup pair exists
to prevent (lives up to principles #6/#11/#12).

- `fix`: `plan-w-team-child-cleanup.sh` gains a lineage-reconciliation pass: when
  the caller passes `PWT_CLEANUP_PARENT_SID`, it also scans sibling
  `plan-w-team-spawned-children-*.jsonl` registries and reaps rows whose
  `parent_session_id` matches THIS session — so a child registered under a
  different slug is still cleaned up. **Concurrent-run-safe**: another run's
  children carry a different `parent_session_id` and are left untouched.
  **Additive / no regression**: with the env unset the block is skipped and
  behavior is byte-identical (existing 24 assertions unchanged); dedup avoids
  double-stopping a child present in both the primary and a sibling.
- `fix`: `07-retro.md` §8j-sexies passes the worker's own session id
  (`CLAUDE_JOB_DIR` basename) as `PWT_CLEANUP_PARENT_SID`; empty when
  unavailable → reconciliation no-ops.
- new: 3 C8 assertions in `plan-w-team-child-cleanup.test.sh` (lineage reap +
  other-run child untouched + dedup); `reconciled` count added to the cleanup
  JSON.
- Still deferred (rationale in 1.23.1 entry + design-principles "Follow-up
  status"): P8 (its access-control GIGO sliver is already covered by P9c +
  §6c-ter fail-closed; the rest needs a recompute against a non-strict findings
  format → drift risk), C7 part-2, P14, C11, C12/C13.

## [1.23.1] — 2026-06-02 (f42bb0a)

PATCH — **Deferred-item follow-up from the 1.23.0 enforcement audit: the safe,
high-value MEDIUMs.** Three of the deferred seam findings are now fixed with
tests; the genuinely-risky / low-value ones are left deferred with explicit
rationale (see the audit report and the design-principles "Tracked follow-ups").

- `fix`: **C6** — `PLAN_W_TEAM_FORCE_SPAWN=1` could bypass the cascade/DS1/DS2
  spawn guards from _inside_ a worker, and the cascade guard's own stderr told
  the reader to "set FORCE_SPAWN and retry" — which a worker's LLM dutifully
  follows, defeating the guard. In-worker (PLAN_W_TEAM_DISABLE_PROMPT_ROUTE=1)
  the bypass now requires the out-of-band `PLAN_W_TEAM_OPERATOR_FORCE_SPAWN=1`;
  the stderr no longer instructs an in-worker FORCE_SPAWN. New AC6/AC7 in
  `pwt-goal-double-spawn-guard.test.sh` + updated `worker-cascade-blocked.bats`.
- `fix`: **C7 (drift guard)** — `plan-w-team-sync-allowlist-check.sh` now also
  requires the non-prefixed gate dependencies (`ram-budget`, `disk-budget`,
  `claude-agents-extended`, `locate-claude`, `secret-scan`) to be allowlisted,
  so a future rename can't silently drop one (they're all currently allowlisted).
- `fix`: **P7** — `builder.md` now inlines the WTF-likelihood self-regulation
  caps (20% STOP / 50-fix hard cap + regression-test discipline) so they travel
  with the agent definition, not only via a stage-file pointer. New drift-lock
  `builder-self-regulation.bats`.
- Still deferred (with rationale): **C7 part 2** runtime fail-loud on a missing
  capacity script; **C8** spawn-registry↔cleanup slug reconciliation (cross-
  process; a wrong fix over-reaps concurrent runs — needs concurrent-safe
  design; weekly GC backstops it); **P8** autofix scope-fence + gating-integer
  recompute (touches review/ship; §6c-ter already fails closed on the security
  count); **P14** native git-hook bump (the fix is untracked `.git/hooks`, low
  value; bumps-are-manual is documented and works); **C11** no-`model:` lint
  (a reliable lint needs Agent()-block parsing — stage prose legitimately
  mentions `model: opus`; frontmatter pins already protect); **C12/C13** low-value
  robustness/observability.

## [1.23.0] — 2026-06-02 (814b791)

MINOR — **Enforcement hardening from a verified adversarial principle audit.**
A multi-agent audit (verify → completeness-critic → synthesize) of whether each
of the 14 design principles is _actually enforced_ vs documented found the
governing defect class: the boundary GATES are deterministic, but several
DETECTION / accountability layers feeding them were LLM-procedural with no
deterministic backstop — a gate that re-checks an LLM-authored count is theater
over a silent miss. Every HIGH finding is fixed with tests; the audit report is
[`docs/operations/pwt-principles-enforcement-audit-2026-06-02.md`](../../../docs/operations/pwt-principles-enforcement-audit-2026-06-02.md)
and the principle/enforcement summary is
[`docs/operations/plan-w-team-design-principles.md`](../../../docs/operations/plan-w-team-design-principles.md).

- `fix`: **P3/C1** — bg workers inherited the default-8 Stop-hook block cap and
  were silently force-stopped mid-run (defeating "no turn cap" for the canonical
  autonomous path). `CLAUDE_CODE_STOP_HOOK_BLOCK_CAP=200` in `settings.json` +
  `pwt-goal.sh` `LAUNCH_ENV`. New `stop-hook-block-cap.bats`.
- `fix`: **C3** — the `/goal` completion contract was worker-spoofable (SUCCESS
  from transcript text + self-writable `terminal_state`). Worker-mode SUCCESS now
  requires a deterministic ship-verdict artifact (`05-ship.md` writes it only
  after every §6 gate passes); the `terminal_state` short-circuit is honored only
  with `evaluator` provenance. New `goal-evaluator-c3-antispoof.bats`.
- `fix`: **C4** — `secret-scan-allow` allow-file was self-clearable by a bg
  worker. `block-protected-paths.sh` now blocks in-worker writes to it. New
  `secret-allow-worker-guard.bats`.
- `fix`: **C2** — the parallel-worker gate used a single un-retried
  `claude agents --json` (fail-open under the exact load it detects). Routed
  through `claude-agents-extended.sh` retry + loud empty-after-retries marker.
- `feat`: **P9c** — new `access-control-content-scan.sh` deterministic CS-1..CS-4
  detection floor; gates Step 5 §5b and §6c-ter (fails closed on a missed
  signal). New behavioral `access-control-content-scan.bats`.
- `fix`: **P4** — hardcoded `HARD_GATES` floor in `plan-w-team-orchestrator-route.sh`
  (push-ack / secret-scan-allow / scope-unlock-for-drift forced to `user` even if
  the classifier table is tampered). New AC8a/b/c tests + `PWT_CLASSIFIER_DOC_OVERRIDE`.
- `feat`: **P9b** — new `block-gh-actions-build.sh` PreToolUse hook makes the
  No-GitHub-Actions rule actually enforcing; §6b-bis relabeled defense-in-depth.
  New `block-gh-actions-build.bats`.
- `feat`: **P1** — new `plan-w-team-bypass-rate.sh` turns the previously-fictional
  stage-file-bypass accountability into a real retro `bypass_rate` signal
  (§8j-octies); the lead now dual-sinks the marker to a slug-keyed log. New
  `bypass-rate.bats`.
- `fix`: **P11** — symmetry checker was RED; added a `*.test.sh` exclude and
  registered 5 artifacts (manifest, stage-events, ship-verdict,
  content-signal-suspects, bypass-log). Now 33/33, exit 0.
- `docs`: **C5** — reconciled goal-conditions.md to the hook's canonical terminal
  precedence (`SUCCESS < API_HALT < LOW_CONFIDENCE_STREAK < USER_ESCALATION_HALT`),
  documented `API_HALT`, fixed the "3 anchors" count.
- `docs`: **P2/P10/P12** — Layer-1 "route hook" → orchestrator-route script; 4
  stale model strings (`claude-opus-4-6`, gap-analyzer "Opus 4.7" → 4.8);
  DS1 dedupe-window doc/stderr 60s → `PWT_DOUBLE_SPAWN_WINDOW_MIN` (3 min).
- `docs`: **refuted recon** — P13 self-heal IS shipped (v1.18.0); P12 DS1/DS2
  guards are real + tested; P14 version bumps are manual (memory was correct).
- Deferred (tracked in the audit report): C6 (FORCE_SPAWN-in-worker), C7
  (sync-allowlist name-filter / fail-closed capacity gates), C8 (slug mismatch),
  P7 fix-counter, P8 handoff scope-fence, P14 native git-hook bump, C11-C13.

## [1.22.1] — 2026-06-02 (8f2afa7)

PATCH — **Consolidated design-principles doc (close the "no single place names the principles" gap).**
The principles governing the skill (spec-first gating, layered autonomy, no wall-clock caps,
human-owned one-way doors, ephemeral-vs-persistent layering, worktree isolation, self-regulation,
fix-first review, baked-in governance, model tiering, durable state, non-hijacking routing,
self-heal, quantitative retro) were real and consistently applied but distributed across the
manifest, `architecture-layers.md`, `self-regulation.md`, `goal-conditions.md`, and the DIRECTION
spec — with no one place to check a proposed change against.

- `docs`: **`docs/operations/plan-w-team-design-principles.md`** (new) — 14 governing principles,
  each with its enforcing mechanism cited, a §"how the principles interact / trade off" section,
  and a "when you change the skill" checklist.
- `docs`: **`shared/architecture-layers.md`** — added a "Where to look next" row pointing at the
  new principles doc.
- `docs`: **`plan-w-team.md`** — added a Design-principles callout under the intro linking the doc
  and noting that weakening a principle needs a recorded scope-challenge verdict.

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

## [1.1.0] — 2026-05-25 (0fda762)

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
