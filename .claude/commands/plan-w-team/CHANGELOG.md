# /plan-w-team CHANGELOG

Tracks the version history of the `/plan-w-team` skill. Each release is tagged
with a semver bump, an ISO date, and the head commit at the time of release.

Versioning policy is documented in [`shared/versioning.md`](shared/versioning.md).

The current version is stored in [`VERSION`](VERSION). Each pwt-goal launch
records this value into the run's goal-state JSON as `skill_version` and the
commit SHA as `skill_commit_sha` so any bug surfaced after the fact can be
traced back to the exact /plan-w-team release that produced it.

## Format

````

## [2.38.1] — 2026-09-02 (plan-usage: a foreign renderer's failure must not starve the shared cache) (04b5257)

Right after the 3:00pm reset every pane read `⚠ STALE 37m`: the account sample had
not refreshed since 2:28pm although a foreground `--sync` succeeded at once. Caught in
the act with a `ps` sampler: the refresher was a **2.37.0 copy of the helper inside a
cleanscale worktree** (`pwt-work-queue-item-fix-1886-…`; worktrees keep whatever
`.claude/scripts/` their branch had, the sync only touches the main checkout). That copy
has no backoff logic: it failed every 10 s (`code 1`) and re-minted `.err`, and every
2.37.1+ pane obeyed the 60 s backoff it kept renewing. One broken renderer starved the
whole login.

- `plan-usage.sh` + `statusline.sh`: the status line signs each call with its
  `session_id` (`PLAN_USAGE_WRITER`), `.err` records the writer, and a failure backoff
  gates ONLY its writer — a record with no writer (an older copy) gates nobody; a 429
  window stays shared (the account's state). Keychain account falls back to `id -un`;
  an empty token records `no-token` (missing curl/security/python3 → `no-tool`) with a
  15 s backoff (`PLAN_USAGE_NOTOKEN_BACKOFF`); the fixed system dirs are appended to
  PATH (`PLAN_USAGE_SYSTEM_PATH`); `.err` carries a `detail` (missing tool, or keychain
  exit status + account + blob size, never a token) so the next episode names its cause.
  `plan-usage.test.sh` +10 (47/47); docs env rows + paragraph.
- Also BDD-renamed the 8 `claude-launcher-wrapper.bats` names that 2.38.0 added
  without the `given/when/then` shape, so the r10 naming ratchet (and the suite) is
  green again — the allowlist is legacy-only and capped, so new tests rename, not enlist.

## [2.38.0] — 2026-09-02 (Model Tiering v7 for INTERACTIVE sessions: 150K window, one Fable lead per host, Opus 4.8 default) (f6507f5)

2026-09-02: five accounts exhausted in one 5-hour window. The interactive half of the
burn was 4–5 Fable terminals (`claude-fable-5-1[1m]` at effort xhigh from
`~/.claude/settings.json`) compacting at 250K, plus stale-skill repos fanning out on Opus 5.
Burn is turns × context, and the 250K/v6 cap only trimmed the second factor.

- `.claude/shell/claude-pattern.zsh`: `CLAUDE_CODE_AUTO_COMPACT_WINDOW` defaults to 150000
  (was 250000); an explicit value still wins.
- ONE Fable lead per host: `CLAUDE_LEAD=1 claude` adds `--model claude-fable-5-1` and holds a
  pid lock (`CP_FABLE_LEAD_LOCK`, default `~/.config/claude-pattern/fable-lead.pid`); a second
  lead launch while that one is live is downgraded to `claude-opus-4-8` with a notice. Every
  other interactive session takes the model in `~/.claude/settings.json` — set that file to
  `claude-opus-4-8` / `effortLevel: high` on every operator host (done on both CleanRev hosts).
  An explicit `--model` in argv always wins; utility subcommands are untouched.
- `tests/skill/cases/claude-launcher-wrapper.bats` (+8): window default/override, no-model
  plain launch, lead lock held-then-released, downgrade on a live lead, stale lock, explicit
  --model, subcommand pass-through.
- Pairs with cleanscale's fleet-side v7 (`scripts/ops/model-tiers.json`: Sonnet lanes, Opus 4.8
  judge/CE/hard rows, 200K lanes, `fleet-pause.sh`).

## [2.37.5] — 2026-09-02 (The operator sweep delivers the status-line bundle past the default-branch guard) (83a81a7)

The 2.37.3 guard defers the bundle on any default-branch checkout with an origin to
"the consumer's regular sync PR" — but the STATUSLINE_ONLY repos never take a skill
sync and a dirty consumer's skill sync stands down, so the 2.37.4 sweep left parts,
helm, liamslanais and progressive-qa-initiative on an old status line.

- `sync-all-projects.sh` exports `STATUSLINE_BUNDLE_ON_DEFAULT=1` for its run: an
  operator-run sweep with `--commit` is the deliberate delivery channel. The unattended
  session-start refresh keeps the guard. `sync-statusline-bundle.test.sh` +1 (29/29).

## [2.37.4] — 2026-09-02 (Status line: login-tagged stdin gauge for accounts whose windows coincide) (b151699)

Seen right after 2.37.2 landed (2.37.3 was taken by a parallel release on main): four of the five accounts reset at 2:59pm, so the
2.37.1 reset-time identity check let a pane whose last response came from a 103 %
account render `⛔ LIMITED` on the current login at 80 %.

- `statusline.sh`: the stdin payload is tagged with the login it was first seen under
  (`PLAN_USAGE_STDIN_TAG_DIR`, one file per session, from the sample's
  `_meta.account_email`); an unchanged payload after a `/login` is dropped, a new
  response re-tags it. `statusline-plan-usage.test.sh` +4 (39/39).

## [2.37.3] — 2026-09-02 (The bundle refresh never writes or commits on a consumer's default branch) (59d3a2c)

The 2.37.1 session-start bundle refresh committed straight onto the laptop's cleanscale
primary while it sat on `main`, so the checkout stood one local commit ahead of
`origin/main` — and every ff-only follower of that branch (cleanscale's
`io.cleanrev.self-update` timer, the ship chains' `git pull --ff-only`) reported
`diverged` until an operator moved the commit into a PR (cleanscale #1939) and reset the
tree. Writing without committing is no better on such a checkout: a dirty `main` makes the
same followers skip `dirty`.

- **Default-branch guard in `sync-statusline-bundle.sh`.** When the target has an `origin`
  remote and its checkout is on the default branch (whatever `origin/HEAD` names; `main` /
  `master` when it is unset), the helper writes nothing and commits nothing — `⏭ … deferred`,
  exit 4 — because such a consumer takes the bundle through its regular claude-pattern sync
  PR. A feature branch, a detached HEAD, or a repo without an origin behaves exactly as in
  2.37.1; `STATUSLINE_BUNDLE_ON_DEFAULT=1` forces the old behaviour for an operator who
  means to push to a consumer's default branch. `session-start.sh` already filters the
  helper's line, so a PR-gated consumer's session start stays quiet. Pinned by
  `sync-statusline-bundle.test.sh` §9 (+7, 28/28): deferred on `main` with an
  origin (files, HEAD and status untouched), deferred via `origin/HEAD` → `trunk`, refreshed
  on a feature branch, refreshed with no origin, forced by the override, `--dry-run` defers.

## [2.37.2] — 2026-09-02 (Status line: legible age marker, endpoint 5-minute floor, retry-after 0) (598017e)

Live observation after the 2.37.1 rollout: `/api/oauth/usage` answers 429 with
`retry-after: 0` and serves a new sample exactly every ~5 minutes, so `⟳4m`–`⟳6m`
appeared on every pane in the normal course of things and read as "refresher late"
when nothing was late — and the double-width `⟳` glyph overlapped the minutes.

- `statusline.sh`: `⟳ Nm` (space after the glyph, user report 2026-09-02); the grey
  marker is quiet under max(2×TTL, 7 min); `⚠ STALE` past 15 min is unchanged.
  `statusline-plan-usage.test.sh` +1 (35/35).
- `plan-usage.sh`: a `Retry-After` of 0 means unspecified → the default 120 s window,
  not the 30 s floor. `plan-usage.test.sh` +1 (37/37).

## [2.37.1] — 2026-09-02 (Rollout fixes: dirt verdict before the bundle refresh, 429 Retry-After backoff, session-start bundle refresh) (6692bfe)

Two defects found while verifying the 2.37.0 rollout across the fleet:

- **The sync guard tripped on its own writes.** `sync-to-project.sh` ran the status-line
  bundle refresh BEFORE the target-dirty guard but took the dirt VERDICT after it, so every
  consumer received the bundle (uncommitted — the sweep passes no `--commit` to the per-repo
  script) and the guard then skipped the skill sync in all of them: the fleet stayed at 2.35.2
  while `sync-all-projects.sh --commit` reported success. Fix: the verdict is taken FIRST, on
  the untouched tree; the bundle still refreshes a dirty consumer, and when the guard is about
  to skip it makes its own scoped `git commit --only` (`--commit` or `PWT_SYNC_BUNDLE_COMMIT=1`,
  exported by `sync-all-projects.sh --commit`). `sync-statusline-bundle.sh --commit` also sweeps
  bundle paths that are current-but-uncommitted, so a consumer never carries self-inflicted
  dirt for the next guard to trip on. Pinned by two new `sync-target-dirty-guard.bats` cases
  (dirty → SKIP + scoped bundle commit + skill files absent; clean → no SKIP + skill files
  present) and `sync-statusline-bundle.test.sh` 3b (21/21).
- **Refresh storm against a rate-limited endpoint.** `/api/oauth/usage` answers HTTP 429
  (`retry-after: 88`) to most refreshes when polled every 30 s from every pane; the refresher
  retried on every render and the `⟳Nm` age crept to 7 min. Fix: `plan-usage.sh` honours
  `Retry-After` (recorded in `<key>.err` as `rate-limited`; default 120 s, clamped 30–900),
  any other failure backs off `PLAN_USAGE_FAIL_BACKOFF` (60 s), the render path spawns nothing
  inside the window, `--sync` bypasses it, and the default TTL is 120 s. The 5h/7d gauges and
  the ETA stay real-time from Claude Code's stdin `rate_limits`; the endpoint feeds the scoped
  Fable bucket and the advisory. `plan-usage.test.sh` +6 (36/36): 429 window recorded, no spawn
  inside it, lapse → refresh, generic backoff, `--sync` bypass.
- **Every session start refreshes the bundle.** `session-start.sh` runs
  `sync-statusline-bundle.sh <repo> --commit` before the skill auto-sync, so a consumer whose
  auto-sync stands down for a dirty `.claude/` (or never takes the skill sync) still shows the
  current line; skipped for claude-pattern itself and for linked worktrees.
- **A `/login` no longer leaks the previous account's gauge.** stdin `rate_limits` is this
  session's LAST response, so after a switch an idle pane's stdin still held the old
  account's number and MAX rendered king's 94 % with lazio's reset time as one line. The
  status line now counts a stdin reading only when its window matches the account-keyed
  sample's (`resets_at` within 120 s); a known mismatch is dropped. `statusline-plan-usage.test.sh` +2.
- **Sync-inventory lint.** `sync-statusline-bundle.sh` is invoked from the source tree
  (sync-to-project / sync-all / session-start all call `$CLAUDE_PATTERN/...`), so it joins
  the `NOT_SYNCED_SOURCE_ONLY` carve-out in `sync-script-references.bats` — the lint had been
  red on it since 2.37.0.
- Docs: `docs/operations/statusline-usage-reporting.md` (identity rule, backoff, delivery
  ordering, env rows).

## [2.37.0] — 2026-09-02 (Status-line usage reporting: non-blocking, account-keyed, two-source, burn-rate ETA) (ea4f1e0)

Incident: panes hit `You've hit your session limit` while every status line read `5h 87%`
(the account was at 100 %). Claude Code CANCELS an in-flight statusLine command when the next
trigger fires, and the render did keychain+curl (`plan-usage.sh`), an N-account serial probe
(`account-advice.sh`) and a full transcript scan (`usage-breakdown.sh`) INLINE — under load the
render died mid-call, the display froze on its last completed frame, the cache never committed,
and nothing marked the number as old. The render also ignored the API's `limits[]`
(`is_active`, scoped Fable bucket, `severity`, `locked_reason`), had no lead indicator, and kept a
per-repo cache so panes disagreed and multiplied API calls.

- **`plan-usage.sh` rewritten** as a stale-while-revalidate singleton: the render only READS
  a file; a stale sample starts ONE detached `timeout`-bounded `--refresh` in its own process
  group; failures never replace a sample (`<key>.err`); `--sync` for deterministic callers
  (fable-guard, tests); `--meta`. Cache is MACHINE-WIDE and ACCOUNT-KEYED
  (`~/.config/claude-pattern/plan-usage/<key>.json`, key = sha12(env token) | `accountUuid` |
  keychain) so a `/login` re-keys instantly and every pane shares one sample. History ring →
  `_meta.rates` (rate %/min + ETA to 100 %) per window and per scoped model, with window-reset
  detection. Header-probe fallback for env tokens lacking `user:profile`.
- **Two sources reconciled:** Claude Code's stdin `rate_limits` (≥ 2.1.251, zero cost,
  pane-local) and the endpoint sample; the line shows the MAX of readings whose `resets_at`
  has not passed.
- **Render:** `▸` binding limit, scoped `Fable NN%`, `→100% in Xm` ETA (forces hot < 15 min),
  `⛔ LIMITED`, grey `⟳Nm` past 2× TTL, `⚠ STALE Nm` past 15 min; API `severity` raises the
  tier; the 👉/⚠ account advisory inherits the hottest plan tier. Reset times now render in
  12-hour US form (`3:00pm`; `STATUSLINE_TIME_24H=1` opts back).
- **`account-advice.sh` / `usage-breakdown.sh`** moved to the same detached, machine-wide
  shape; account-advice validity is checked by LOGIN, not mtime (same-second `/login` race).
- **Every pane, every repo:** new `sync-statusline-bundle.sh` refreshes the status-line
  bundle (statusline.sh + the six helpers it execs) in a consumer with a per-file PROVENANCE
  guard (only a byte-identical copy of SOME claude-pattern version is overwritten; a local
  edit is skipped, exit 5) and a `git commit --only` scoped to the bundle. Runs inside
  `sync-to-project.sh` BEFORE the target-dirty guard and from `sync-all-projects.sh` for the
  new `STATUSLINE_ONLY_REPOS` (liamslanais, parts, progressive-qa-initiative, Stories — alive,
  excluded from the skill sync). `account-advice.sh` falls back to the claude-pattern source's
  accounts CLI (`CLAUDE_PATTERN_ROOT` / sibling) and serves the shared cache read-only with no
  CLI at all. Evidence: three panes on ONE account read 5h 44 % / 38 % / 57 % at the same
  moment before this release.
- `operator-doctor.sh`: ccusage wording corrected (it feeds only the tok/tpm line).
- Tests: `plan-usage.test.sh` (31), `statusline-plan-usage.test.sh` (32),
  `account-advice.test.sh` (14), `usage-breakdown.test.sh` (8),
  `sync-statusline-bundle.test.sh` (18). Docs: `docs/operations/statusline-usage-reporting.md`.

## [2.36.1] — 2026-09-02 (Status line resolves state/helper paths against the git toplevel, not $PWD) (bc2af7c)

`statusline.sh` built every state and helper path (`bg-agents-cache.json`, `pwt-launches.jsonl`,
the completion-summary count, the ccusage / plan-usage / account-info / account-advice /
usage-breakdown helpers, and the three dashboard `cwd` filters) from bare `$PWD`. Whenever a
session's cwd was a **subdirectory** of the project — a worker that `cd`'d into `apps/web`, a
session opened in `tests/skill` — the status line created and read a nested
`<subdir>/.claude/state/` instead of the project's, scattering junk dirs across consumer repos.
One such stale file (`tests/mobile-bdd/.claude/state/plan-w-team-credwall-active.json`, written
2026-06-05, carrying a `WDIO_TAGS` line in its `command` field) false-failed CleanRev's pre-push
gate on 2026-09-02 (`ios-conf.assert.test.sh` scanned it as an "in-repo caller").

Fix: `PROJECT_ROOT` = `$PWD` walked up to the git root via `git rev-parse --show-cdup` + `pwd -L`
— a worktree resolves to its OWN root (unchanged behaviour for lanes), a plain directory falls
back to `$PWD` (unchanged behaviour for the sandboxed tests), and the LOGICAL path is kept on
purpose: `--show-toplevel` canonicalizes symlinks (macOS `/var` → `/private/var`), which would
break the dashboard's cwd-prefix match against the cache's logical cwd strings (caught by the new
test on the first cut). All ten `$PWD/.claude/...` paths and the three dashboard `--arg cwd`
filters now use it. `statusline.sh` only.

Coverage: new `.claude/scripts/statusline-project-root.test.sh` — subdir cwd renders the root
cache and creates no nested `.claude/`; a worktree subdir resolves to the worktree's own root;
a non-git directory keeps the `$PWD` fallback; a symlinked cwd keeps its logical path; mutation
guards on the derivation and on any remaining bare `$PWD/.claude` path. `statusline-dots` /
`statusline-account-advice` unchanged and green.

## [2.36.0] — 2026-09-02 (Fable 5.1 rollover + five bg-daemon defect fixes: effort/permission argv, goal-keyed double-spawn, conditional supervisor bind, content-sentinel phantom-lane guard) (c16df52)

Two CleanRev DIRECTION documents land as one release. **(A) Fable 5.1 generation
rollover** — every Fable model PIN moves `claude-fable-5` → `claude-fable-5-1`
(the four design agents `system-architect` / `ui-designer` / `style-theme-expert`
/ `team/fable-spec-consult`, the governor's `design`-tier default in
`pwt-governor-lib.sh`, and the two Model Strategy table rows in the manifest). The
prior-generation bare id `claude-fable-5` stays **accepted** in the governor's
`design` allow-list for ONE release (backward compat, DIRECTION line 30) so a
consumer manifest pinning the old id is not broken by the bump. This is a
generation rollover within the design tier, not a tiering change — the tiers,
budgets, guard, and Opus-4.8 landing rung are unchanged. `plan-w-team-fable-guard.sh`
needs **no** change: it matches the consult agent by display-name `test("Fable"; "i")`,
never by model id, so it is generation-agnostic by construction.

**(B) Five bg-daemon defects (a–e)**, all rooted in one measured fact:

**F1 MEASUREMENT (verbatim, item 2 / DONE3).** Probe session `947c7a54` launched
`claude --bg --model claude-haiku-4-5-20251001 --effort low --autocompact 400000
--permission-mode bypassPermissions`. The bg daemon recorded the respawn argv
`["--effort","low","--autocompact","400000","--permission-mode","bypassPermissions",
"--model","claude-haiku-4-5-20251001"]`, but the worker RUNTIME echoed
`PROBE_EFFORT=UNSET PROBE_EFFORT_LEVEL=UNSET PROBE_COMPACT=250000` (the daemon
default 250000, NOT the requested 400000). CONCLUSION: a `--bg` worker/supervisor
is forked by the bg daemon and inherits the DAEMON's environment, not the
launcher's — argv `--effort`/`--autocompact` do not surface to the worker runtime
as `CLAUDE_CODE_*` env vars, and launcher-exported env does not cross. The only
channels that reach a daemon-hosted session are **argv** and **prompt content**.

- **defect a (effort/compaction).** Because launcher env does not cross, effort and
  compaction now ride ARGV: `pwt-goal.sh` builds `BG_EXTRA_ARGS` with
  `--effort ${PWT_BG_EFFORT:-${CLAUDE_CODE_EFFORT_LEVEL:-high}}` and
  `--autocompact ${PWT_BG_AUTOCOMPACT:-${CLAUDE_CODE_AUTO_COMPACT_WINDOW:-}}`
  (kill switch `PWT_DISABLE_BG_EFFORT_ARGV=1`) and threads it into every worker
  AND supervisor `claude --bg` spawn. A first-class daemon-env knob
  `PWT_DAEMON_ENV_REFRESH=1` additionally exports `CLAUDE_CODE_EFFORT_LEVEL` /
  `CLAUDE_CODE_AUTO_COMPACT_WINDOW` for a daemon started in the same env, and the
  F1 rule is documented at the build site so a future edit cannot silently drop
  the argv threading.
- **defect b (permission mode).** `pwt-goal.sh` passes
  `--permission-mode ${PWT_BG_PERMISSION_MODE:-bypassPermissions}` on the `--bg`
  argv for worker AND supervisor (same `BG_EXTRA_ARGS` seam), so a daemon-hosted
  session no longer falls back to an interactive default that silently
  auto-rejects a `/dev/null`-stdin push.
- **defect c (double-spawn keying).** PWT-DS1 now keys on the GOAL (slug), not "any
  worker alive": helpers `__ds1_sid_slug` / `__ds1_hit_is_same_goal` resolve a live
  flag's worker to the goal-state slug it owns and CLEAR the refusal when that
  slug differs from the launch's slug — wired at the Tier A mtime fast-path and
  both Tier B refusal sites. A manual `--launch` of goal B now succeeds while
  goal A's worker is alive, WITHOUT `PWT_DOUBLE_SPAWN_LIVENESS_DISABLE=1`; a second
  launch of the SAME goal is still refused. Fail-closed preserved: an
  unresolvable slug refuses, and `PWT_DS1_SLUG_KEYING_DISABLE=1` reverts to the
  pre-2.36.0 slug-agnostic refusal.
- **defect d (supervisor binding).** The launching session is bound as supervisor
  ONLY under `PLAN_W_TEAM_SUPERVISOR_SESSION=1`; otherwise the SPAWNED supervisor's
  own session id is bound (post-spawn patch of the goal-state), so a plain
  `--launch` no longer wedges the launching chat under the lane guard. `--no-bind`
  forces the spawned-bind even when the env flag is set.
- **defect e (phantom lanes).** The route hook recognizes a bg BOOTSTRAP by CONTENT
  — a `PWT-BOOTSTRAP-DO-NOT-ROUTE` sentinel line — and short-circuits BEFORE trigger
  detection, never by env flag alone (F1: `PLAN_W_TEAM_DISABLE_PROMPT_ROUTE` may not
  cross to a daemon-hosted session). `pwt-goal.sh` writes the sentinel into every bg
  bootstrap it emits (worker goal text + supervisor bootstrap — the supervisor
  bootstrap starts with `#`, bypassing the slash-guard, so it was the live
  phantom-lane vector). Since argv/content is the one channel F1 confirms crosses,
  the content sentinel is authoritative where the env flag is not.

**DONE1 word-boundary caveat.** The DIRECTION's literal check
`grep -rn 'claude-fable-5\b' .claude tests/skill` is unsatisfiable as written after
the rollover: `\b` matches between `5` and `-`, so the pattern matches the rolled
`claude-fable-5-1` too. Satisfied by INTENT — no stray Fable *pin* remains; the
bare `claude-fable-5` occurrences that persist are all sanctioned: the governor's
backward-compat allow-list, the dated Model-Tiering-v5 generation note, the
`fable-spec-consult` incident-history comment (`claude-fable-5[1m]`), the test
substring-matchers, and non-shipped `.claude/state/` run artifacts.

**Coverage.** New `tests/skill/cases/pwt-bg-env-guards.bats` (14 cases) covers
defects a–e: permission/effort/autocompact argv threading into both spawn classes,
the `PWT_DAEMON_ENV_REFRESH` knob, the DS1 slug-keying helpers + kill switch + the
three guard sites, the conditional supervisor-bind + `--no-bind`, the sentinel in
both bootstraps, and a FUNCTIONAL route-hook pair proving a sentinel-bearing
trigger prompt does NOT spawn while the identical trigger WITHOUT the sentinel
does. `model-tiering-v3.bats` (exact-line consult pin → `-5-1`), `model-tiering-v5.bats`
and `governor-budget.bats` (design functional sweep → `-5-1`, plus new backward-compat
positives asserting the design tier accepts BOTH generations verbatim, and Fable in
either generation refused for the intelligent/mechanical tiers). `opus48-uplift.bats`
unchanged (14/14). The v5-substring sweeps (`grep -F 'model: claude-fable-5'`) stay
green because `claude-fable-5-1` contains `claude-fable-5` as a substring.

**Out-of-scope residuals (not touched this release).** `CLAUDE.md:446` and
`dotfiles/claude/settings.json` were left as-is — outside the enumerated 9-item
scope; the governor/agent/manifest pins are the load-bearing rollover surface.

## [2.35.2] — 2026-09-01 (Status-line account advisory colors by the plan's own heat tiers) (f3ec229)

The `👉 next: <email>` nudge stayed GREEN until the advisory's own `current_hot` flag flipped, and
that flag comes from a SECOND probe of the current account (registry usage cache, 10-min TTL, behind
the 5-min advice cache) — so beside a peach `5h 79%` from the live `/api/oauth/usage` read the nudge
sat green and read as "nothing to do", and it could stay green past 80% until both caches caught up.
The advisory now colors by the SAME tiers as the `📊 Plan` 5h number next to it (≥80 hot → red
`⚠ switch →`, ≥50 warm → peach `👉 next:`, else cool → the advisory's muted green), evaluated over
the hottest reading the status line holds: the plan segment's own 5h AND 7d (what the operator is
looking at) plus the advisory's cached `current_5h`/`current_7d`; the producer's `current_hot` still
forces hot. The tiers live in one `usage_tier`/`tier_color` pair shared by both segments so they
cannot drift apart again. `statusline.sh` only; `session_cred.py advise` is unchanged.

Coverage: `statusline-account-advice.test.sh` gains a stubbed `plan-usage.sh` and 7 heat cases —
peach at 79, red `⚠ switch` at 80 while the advisory's cache still says 66, red at 79.6 (rounds to
the displayed 80), peach from 7d alone, peach from the advisory's cache alone when the plan read is
absent, green when everything is cool, and `current_hot:true` forcing red under a cool plan read.
Accounts `README.md` + onboarding ops doc sentence.

## [2.35.1] — 2026-09-01 (Status-line account advisory names the account by full email) (8f29fd6)

The `👉 next: <label>` / `⚠ switch → <label>` segment shipped in 2.34.1 named the recommended account
by its registry LABEL. Labels are operator-chosen stems and collide in practice: with two accounts
on one company domain the segment read `👉 next: <company> (0/0%)` while the `👤` segment showed
`<other-user>@<company>` — the operator could not tell which account they were being pointed at,
and `/login` asks for an email anyway. The segment now renders the advisory's **`best_email`**
(present since 2.34.1), keeping the label only as a fallback when the advisory carries no email
(an older `accounts.sh advise`, or a registry row missing its email). `statusline.sh` only;
`account-advice.sh` / `session_cred.py advise` are unchanged.

Field check that surfaced it (2026-09-01, same operator): the `0/0%` on the recommended account is
what Anthropic's own `anthropic-ratelimit-unified-*` headers report for that token, so the pick is
faithful — the only defect was the ambiguous name.

Coverage: new `.claude/scripts/statusline-account-advice.test.sh` (sandboxed `$PWD` with stubbed
`account-info.sh` / `account-advice.sh`, same harness shape as `statusline-dots.test.sh`) — email
rendering for both `👉 next` and `⚠ switch`, rounded pcts, label fallback for an empty AND an absent
`best_email`, no segment on `switch:false` / `{}`, lean-mode skip (helper never invoked), and the
login-email-as-`$1` contract. Accounts `README.md` + onboarding ops doc updated.

## [2.35.0] — 2026-09-01 (Row-20 goal-termination handshake: ship-verdict-absent C3 corroboration pinning tests) (621ac9a)

Pins the recursive-followup **row-20** mechanism — deterministic SUCCESS when Step 6 committed +
pushed cleanly but produced **NO ship-verdict FILE at all** (the 1.47.0 runaway-after-ship, where
every SUCCESS path that needed the verdict failed and the worker could not self-terminate). The
row-20 machinery itself already shipped (PWT-TERM1/2/3, the C3 `__landing_corroborated` liveness
fallback, the F6 landing gate); this run's Step-1 adversarial review **overturned the "zero
coverage" premise** — the present-but-REDACTED verdict path was already pinned by
`rotated-lead-success.bats` ac6a–ac6g — so the deliverable is a **TESTS-only** delta (Outcome A: no
production code touched). Seven tests appended to `tests/skill/cases/rotated-lead-success.bats`,
homed there (not `landing-gate.bats`) so every case runs worker-mode
(`PLAN_W_TEAM_DISABLE_PROMPT_ROUTE=1`) and the SUCCESS assertions cannot be vacuous:

- **Ship-verdict-FILE-absent C3 handshake (AC1–AC3, AC5, AC7).** With NO ship-verdict file, a
  worker-mode run flips SUCCESS iff the landing is verified (`ac_r20_1`); withholds with
  `(C3 anti-spoof)` when the landing is absent (`ac_r20_2`, the non-vacuity control) or the
  corroboration kill switch is set (`ac_r20_3`); reproduces end-to-end under worktree isolation with
  C3 + F6 both passing (`ac_r20_5`); and STILL withholds for an interactive non-owner via `PWT-LANE2`
  (`ac_r20_lane2`) — the **C3-accept / LANE2-reject asymmetry** (the landing artifact is
  non-owner-forgeable) is now a pinned invariant.
- **Two genuinely-unpinned `__landing_corroborated` branches.** `ac_r20_stale` rewinds a REAL
  `land.sh` landing's own `default_ref` so `landed_sha` is unreachable → C3 withholds (anti-spoof at
  the C3 level, not F6). `ac_r20_failopen` removes the run root's `.git` so git cannot re-verify →
  the deliberate **fail-OPEN** arm is characterization-locked (SUCCESS), so a future refactor that
  silently flips it to fail-closed breaks a test.

Spec: [`docs/specs/goal-termination-handshake.md`](../../../docs/specs/goal-termination-handshake.md)
(row 20). No production code change; full skill suite green.

## [2.34.1] — 2026-08-31 (Multi-account skill: business-agnostic scrub + interactive-session advisory) (82c0f37)

Completes 2.34.0's portability promise and removes hardcoded personal/business identity from the
shipped skill. Two threads:

- **Business-agnostic scrub (portability + privacy).** The multi-account skill no longer bakes any
  vendor/business path or operator identity into shipped code or shared docs. `import_stores.py`
  drops the hardcoded `~/.config/cleanrev/secrets.env` + `~/.config/cleanrev/claude-accounts.json`
  + `~/.helm/tokens` default stores — the ONLY default search path is now the neutral
  `~/.config/claude-pwt/secrets.env`; a store kept elsewhere is reached with `$PWT_SECRETS_ENV`,
  and the two legacy store shapes (a JSON account store, a dir of `*.token` files) are opt-in via
  `--source PATH`. `_read_cleanrev_json` → `_read_json_store`; `selector.py`, `accounts.sh --help`,
  the accounts `README.md`, and the onboarding ops doc are all genericized (real emails and account
  labels replaced with `you@example.com` / `<label>` placeholders). No behavior change for anyone
  using the neutral default or `$PWT_SECRETS_ENV`; the only default-discovery paths removed were
  vendor-specific and asserted by no test.
- **Interactive rotation is now ADVISORY (2026-08-31 finding).** An earlier 2.34.1 attempt to
  auto-rotate interactive sessions by shadowing `claude()` with `accounts.sh launch` was **reverted**:
  an interactive session's account identity (status line, `/usage`, Remote Control, `~/.claude.json`)
  is bound to the keychain `/login`, and a `CLAUDE_CODE_OAUTH_TOKEN` env token cannot switch it — it
  only redirects model requests while breaking Remote Control and leaving the session on the old
  account. The `claude()` launcher now runs plain `command claude --allowedTools "Grep,Glob"` for
  interactive launches (no token injection); **fleet/bg-worker rotation (`lane_cred.py`) is unchanged
  and unaffected** — only model requests matter there. In its place, a status-line + command advisory:
  - `session_cred.py advise` / `accounts.sh advise` — token-free JSON (`best`, `current`, `switch`,
    `current_hot`, plus 5h/7d pcts) that maps the keychain login (`~/.claude.json` email) to a registry
    label and names the account with the most headroom; prints `{}` when dormant / all-hot /
    single-account (fail-open, so the status line just shows no segment).
  - `.claude/scripts/account-advice.sh` + a `statusline.sh` segment — renders `👉 next: <label>` once a
    cooler account exists, becoming `⚠ switch → <label> (5h/7d%)` when the current login is hot
    (binding window ≥ `PWT_ACCT_SWITCH_HINT_PCT`, default 80). Local cache + bounded timeout +
    fail-open; lean/pipeline status lines skip it. The cache is **login-keyed**: statusline passes its
    `👤` email in as `$1` and a `/login` to a different account invalidates it the instant it happens
    (not after the TTL) — fixing the field defect where, right after switching to the best account, the
    line kept replaying the pre-switch `⚠ switch → <that same account>` for up to 5 min.
    `PWT_ACCT_ADVICE_CACHE` relocates the cache file (tests point it into a sandbox).
  - `claude-account` shell function — prints the status table plus the recommended account and the
    exact `/login` step. You switch with `/login`; the advisory never mutates anything.

  Coverage: `tests/skill/cases/pwt-accounts.bats` **AC12–AC13** (8 new cases; 54 total — AC13 is the
  login-keyed cache regression guard). Docs (accounts `README.md`, onboarding ops doc §A10, root
  `README.md`) corrected off the retired auto-rotation model.

## [2.34.0] — 2026-08-31 (Multi-account onboarding automation — portable `secrets.env` source, guided `setup`, and interactive-session rotation) (d0c6128)

Closes the onboarding-friction gap in 2.33.0: registering accounts still meant a manual
`claude setup-token | add-account` loop, one account at a time — even when the operator
**already** had Max-account OAuth tokens saved on the machine. This release makes onboarding a
single command (`accounts.sh setup`), reads the operator's canonical token store, scaffolds one
for a fresh operator, and puts **interactive `claude` sessions on the same rotation as the fleet**.

- **New `import` subcommand** + **new module `accounts/import_stores.py`** (reuses
  `registry.upsert_account` for storage and `probe.probe_usage` for validation — no storage
  or validation logic is re-implemented). One command **discovers, validates, dedupes, and
  bulk-registers** tokens already saved on the machine, then flips `multi_account_enabled` on.
- **Canonical `secrets.env` source (portable, business-agnostic).** `import`/`setup` read
  `CLAUDE_MAX_SETUP_TOKEN_<LABEL>=sk-ant-…` lines (the `make secrets-set` convention) from a
  0600 env file — the **primary** store, scanned FIRST. The `<LABEL>` is the key suffix
  (lower-cased) and is authoritative identity, so a row registers on the **label alone**; a
  paired `CLAUDE_MAX_EMAIL_<LABEL>` is optional annotation. `ACCOUNT_FAILOVER_ORDER` is
  surfaced as a note. Empty slots and non-`sk-ant` values are skipped (never stored). Nothing
  consumer-specific is baked in: default search paths are neutral + auto-detected
  (`~/.config/claude-pwt/secrets.env`, then `~/.config/cleanrev/secrets.env`), and
  **`$PWT_SECRETS_ENV`** (`:`-separated) overrides them entirely. The parser is tolerant
  (`export `, quotes, comments) and **never sources the file** (no shell eval).
- **Scaffold for a fresh operator** (`scaffold_secrets_env`). An operator with no store gets a
  0600 template created for them (documented key convention + `claude setup-token` fill
  instructions) — created at OUR neutral path, **never** fabricated on top of existing data, and
  it **never overwrites**. This is the "build and configure one for them" path shared-skill
  users hit on their first `setup`.
- **New guided `setup` (alias `authorize`) + read-only `check`.** `setup` scaffolds a
  `secrets.env` if none exists, then imports every filled token — the discoverable entry point a
  new operator (or `/plan-w-team` onboarding) is pointed to. `check` shows what WOULD import
  (dry-run, stores nothing) plus the live status table.
- **Interactive-session rotation** — **new module `accounts/session_cred.py`** + `launch` /
  `which-account` subcommands. `accounts.sh launch [-- <cmd>]` resolves the SAME
  registry→probe→selector account the fleet would pick and `os.execvpe`s the command (default
  `claude`) with the token in the child **environment only**. `os.execvpe` resolves via PATH at
  the syscall level, so a `claude` shell-rc wrapper can shadow the binary **without recursing** —
  every foreground session then rides the identical rotation. Dormant / loose-perms / all-hot ⇒
  exec **unchanged** (ambient login); routing is opt-in and never blocks foreground work.
  `which-account` prints only the label a session would run as.
- **Honest boundaries.** Fully-identified rows register automatically. A bare token file has
  no email, so `import` reports the exact `add-account --token-file …` line rather than
  guessing an identity. An account with **no saved token anywhere** still needs the one-time
  human mint (A2–A3) — no automation invents a credential that was never minted.
- **Security parity with the add path.** Tokens are read from `0600` files into memory only;
  never printed, logged, or placed on argv; the returned result structure carries
  label/email/source/**fingerprint** (SHA-256 prefix), never a value. `launch` hands the token
  to the child via env only (never argv/stdout); only the non-secret label + a reason reach
  stderr. Dedupe is by full fingerprint (idempotent re-runs). Each new token is validated by one
  probe before storage (`--no-validate` is an explicit offline escape hatch; `--dry-run` /
  `check` probe/store nothing). The registry's loose-perms / symlink refusal is inherited
  unchanged.
- **Flags:** `import`: `--dry-run`, `--no-validate`, `--no-enable`, `--source PATH`; `setup`:
  `--no-validate`, `--no-enable`; `launch`: `--pinned L`, `--which`, `-- <cmd…>`.
- **Coverage:** 18 accounts bats cases across the new surface in
  `tests/skill/cases/pwt-accounts.bats` — AC9 (6: validate+store+enable, idempotent re-run,
  invalid-token rejection, partial bare-file reporting, CLI `--dry-run` / `--no-validate`,
  loose-perms refusal), AC10 (7: secrets.env label-authoritative discovery + empty/non-`sk-ant`
  skips + failover note, offline `run_import`, `$PWT_SECRETS_ENV` override, scaffold 0600 +
  no-overwrite, `setup` scaffold-when-empty, `setup` import+enable+idempotent, read-only
  `check`), AC11 (5: dormant→ambient resolve, chosen-label+token in-process, `which-account`,
  `launch` env-injection + token-safety, dormant `launch` execs unchanged). The sentinel-leak
  proofs extend to every new surface. **Full accounts suite: 46/46 green.** Operations doc
  `docs/operations/pwt-multi-account-onboarding-and-phase2.md` gains the `secrets.env` / `setup`
  / interactive-`launch` sections and the `claude` shell-wrapper recipe.

## [2.33.0] — 2026-08-31 (Multi-Anthropic-account awareness & management — local-first + a Phase-2 coordination seam) (68fa07a)

Adds skill-owned, machine-global, **local-first** multi-account routing to `/plan-w-team`. When an
operator holds more than one Claude Max subscription, the pipeline can register the accounts, read each
one's **real** 5h/7d utilization from Anthropic rate-limit response headers, and route each lane to the
account with the most headroom — proactively, with a reactive 429 backstop. With 0–1 accounts the
feature is **fully dormant**: byte-for-byte the pre-2.33.0 behavior, and the dormant path never spawns a
subprocess. All new code is portable and self-contained under `.claude/commands/plan-w-team/accounts/`
so it travels to every consumer via the standard sync; nothing lives in a business/consumer repo.

**The enabling discovery.** `POST https://api.anthropic.com/v1/messages` with `max_tokens:1` and the
Claude Code system prompt returns `anthropic-ratelimit-unified-{status,5h-utilization,5h-reset,
7d-utilization,7d-reset,representative-claim}` response headers (needs only `user:inference` scope);
`/api/oauth/usage` is a dead end for setup-tokens (403). This is the same source the CC statusline reads.

**New modules (`accounts/`).** `registry.py` (durable identity: label/email/token/added_at/active at
`${XDG_CONFIG_HOME:-~/.config}/claude-pwt/accounts.json`, 0600 file / 0700 parent, `O_NOFOLLOW`,
`fcntl.flock`, INV-3 mass-assignment allow-list, refuse-on-loose-perms); `probe.py` (pure
`parse_usage_headers` + injectable-transport `probe_usage` + fail-open `resolve_usage` writing a
write-rare `usage-cache.json` that owns the volatile `limited_until`, with a `PWT_ACCT_MAX_STALE`
staleness ceiling → UNKNOWN); `selector.py` (pure lowest-`max(5h%,7d%)`, exclude rejected /
`binding_pct≥HARD` / limited / UNKNOWN, `HOLD_SOFT` penalty, pin tie-break; exit 0 chosen / 3
measured-all-hot / 4 no-fresh-data); `lane_cred.py` (the ONLY spawn-time token writer: selector emits a
LABEL, this reads the token from the 0600 registry and writes the lane env block via `json.dump` to an
atomic 0600 temp — token never in a shell var/argv/stdout); `backend.py` (`CoordinationBackend` ABC +
wired `LocalBackend` default + `RemoteBackend` Phase-2 `NotImplementedError` stub); `lib.sh` (pure-bash
P0 dormancy short-circuit, no Python on the dormant hot path); `accounts.sh` (headless operator CLI:
add/remove/deactivate/activate/set-active/status/onboard; refuses to mint under `CLAUDECODE`).

**Integration.** `pwt-goal.sh` gains the dormancy short-circuit and wires the selector AS the **built-in
default resolver** behind the existing KI-1 `PWT_LANE_SETTINGS_RESOLVER` seam (precedence: explicit
`--lane-settings-json` > operator resolver > built-in selector > ambient). The failure policy splits by
CLASS: a **measurement/selection** failure (all-hot, stale/unknown, no python3, dormant) is FAIL-OPEN →
ambient login + warning (never idle the fleet); a **correctness/write** failure after an account is
already selected (lane_cred exit 5) is FAIL-CLOSED → abort the spawn, no ambient fallback (a silent
mis-route is worse than a loud stop). On a successful lane-cred write the launcher scrubs any inherited
`CLAUDE_CODE_OAUTH_TOKEN` so the lane binds to its assigned label. **429 rotation = death-and-respawn**
(never re-credential a live lane — the lane guard forbids it): `plan-w-team-rate-limit-resume.sh`, for a
lane carrying `PWT_ACCOUNT_LABEL`, calls `mark_limited` on a 429 (next spawn re-selects onto a fresh
account) and **auto-deactivates** on a 401/revoked token (a cooldown would resurrect a dead credential).
`damage-control/patterns.yaml` marks the per-lane `settings.local.json` and the `claude-pwt/` store
zero-access (reading a token into a transcript leaks it to reviewers).

**Security invariants.** Token values are never printed, logged, or passed on argv — read from the 0600
file, handed to a child only via the settings env block. No secret leaves the machine except as
`Authorization: Bearer` to `api.anthropic.com`. Verified by a SENTINEL leak audit across stdout/stderr
and an `xtrace` run. Coverage-of-record: `tests/skill/cases/pwt-accounts.bats` (bats is the only vehicle
— the `.test.sh`/`.test.ts` walkers don't scan `.claude/commands/`), sandboxed on `XDG_CONFIG_HOME` with
a guard refusing the real store, all probe paths offline via header fixtures + the injectable transport.
Ops doc: [`docs/operations/plan-w-team-multi-account.md`](../../../docs/operations/plan-w-team-multi-account.md).
Kill switches: `PWT_DISABLE_ACCT_BUILTIN_RESOLVER=1`, `PWT_DISABLE_ACCT_429_RESUME=1`. Deferred to
Phase 2 (per operator brief): the cross-machine shared-lease backend (`RemoteBackend`), a documented
seam only this run. Spec: [`docs/specs/pwt-multi-account-management.md`](../../../docs/specs/pwt-multi-account-management.md).

## [2.32.0] — 2026-08-31 (SPAWN-LIVE1/2 — spawn-death detection kills the lane-wedge at source and adds a self-reclaim backstop) (fd8cc55)

Fixes a **lane-wedge** class proven from a live incident (2026-08-31, worker `c42e401f`): a fresh
`claude --bg` worker hit the spurious "Not logged in · Please run /login" wall at spawn, its `/goal`
self-cleared "after an unrecoverable error," and the worker then sat `blocked` — a LIVE process behind
a DEAD run. Because `pwt-goal.sh` seeded the lane binding (goal-state + `worker_sid`) the instant it
parsed the `backgrounded · <sid>` line — BEFORE the worker authenticated — the dead-at-spawn run bound
a lane that could never be reclaimed: process-liveness reads ALIVE (the `blocked` process is real), so
the lane guard's confirmed-dead auto-release never fired, and the lane held until a manual USER release.
`bg-spawn-auth-glitch` (memory) had established the death signature and the in-session reclaim; this
makes both the prevention and the recovery mechanical.

Two independent, individually kill-switchable fixes:

**SPAWN-LIVE1 — spawn-liveness probe + bounded re-spawn (`pwt-goal.sh`).** After each `claude --bg`,
the launcher now PROBES the worker transcript before seeding anything: it waits (bounded) for the
transcript to appear, then watches for either the death signature (`Goal cleared after an unrecoverable
error` / `Not logged in · Please run /login`) or forward progress (transcript growth). On the death
signature it RE-SPAWNS (bounded by `PWT_SPAWN_MAX_ATTEMPTS`, default 3); on total exhaustion it seeds
NOTHING, binds NO lane, and exits LOUD (`75`) telling the operator to re-run once the account is
authenticated. The seed block downstream now uses the FINAL surviving `WORKER_SID`. The probe fails
OPEN (a transcript that never appears, or grows without either signal, is treated as "proceed") so a
slow-but-healthy spawn is never killed. Kill switch: `PWT_DISABLE_SPAWN_LIVENESS_PROBE=1` restores the
pre-2.32.0 single-spawn-then-seed path byte-for-byte. Test seams: `PWT_SPAWN_PROBE_PROJECTS_DIR`,
`PWT_SPAWN_PROBE_APPEAR_S` / `_WINDOW_S` / `_INTERVAL_S`, `PWT_SPAWN_RETRY_BACKOFF_S`.

**SPAWN-LIVE2 — frozen-abandonment verdict upgrade (`pwt-lane-alive.sh`), the backstop.** For a lane
that ALREADY wedged (or a worker that dies just after the seed), the ONE liveness truth now recognises
the dead run behind the still-`blocked` process: when the base verdict is not already `1`, and the
worker transcript's TAIL shows the unrecoverable-goal-clear AND the transcript is FROZEN (silent past
`PWT_LANE_ALIVE_ABANDON_FREEZE_S`, default 120s), the verdict is UPGRADED to `1` (confirmed-dead,
`source=transcript-abandoned+frozen`). This flows into the lane guard's existing confirmed-dead
auto-release, so a wedged lane self-reclaims within ~30s (the guard's memo TTL) with no manual release.
The freeze gate is the false-positive guard: a healthy worker writes constantly and the clear message
is TERMINAL, so "clear-in-tail + long silence" is a dead run and never a live, progressing one — the
upgrade only ever moves `0`/`2` → `1`, never masks a live worker. Kill switch:
`PWT_LANE_ALIVE_ABANDON_DETECT=0`.

**Tests.** Two new regression suites: `pwt-goal-spawn-liveness-probe.test.sh` (dead-then-healthy →
re-spawn-once-then-seed-survivor; all-dead → exhaust budget, exit 75, NOTHING seeded; probe-off →
single-spawn back-compat) and `pwt-lane-alive-abandon.test.sh` (frozen abandonment → verdict 1; fresh
[unfrozen] same signature → stays 0; frozen-but-healthy → stays 0; kill switch off → stays 0).
`tests/skill/run.sh` disables the spawn probe (`PWT_DISABLE_SPAWN_LIVENESS_PROBE=1`) for every OTHER
spawn test so the fake-claude corpus stays fast; the dedicated probe test re-enables it against a
controlled fake transcript.

## [2.31.0] — 2026-08-31 (KI-8 — unattended non-push halts fire a proactive operator alert) (b609e87)

Closes **KI-8** (KNOWN_ISSUES): a `--worker-only` (or bare `/goal`) run that hit a NON-push halt
(`secret-scan-allow`, `scope-unlock-for-drift`, or a 3-consecutive-low-confidence escalation) had NO
proactive operator signal — the halt surfaced only to the `/goal` daemon's pending-question state and
`terminal_state` in the goal-state file. `--worker-only` is now the primary autonomous mode and has
NO bg supervisor, so for an unattended run that was a silent dead-end. The only proactive notify
(macOS `osascript`) lived exclusively in the legacy `--launch` bg-supervisor path. KI-5 removed the
push-ack halt from auto-push mode (it auto-approves); this closes the residual for the halts that
legitimately DO pause.

**Fix — worker-side halt-notify directive (`pwt-goal.sh`):** the `AUTO_PUSH=1` branch of
`__PWT_PUSH_HALT_DIRECTIVE` now instructs the worker, upon reaching ANY halt, to FIRST fire a
best-effort operator alert before pausing — preferring the `PushNotification` tool, else a local
desktop notification (macOS `osascript` display-notification, else `notify-send`) naming the halt
reason, wrapped so a missing channel never fails the run (`|| true`). This reaches exactly the
unattended modes: `--worker-only` / `--launch` / `--supervisor-goal` / `--auto-push` all arm
`AUTO_PUSH=1`.

- **AUTO_PUSH=0 (bare `/goal`) is byte-identical** to the historical block — an attended paste needs
  no proactive notify, and the K4/K5 golden guard stays green (extended by K7).
- Prompt-directive design, mirroring the established pattern (the legacy supervisor bootstrap already
  instructs an `osascript` notify): the halt occurs *inside* the worker's `/goal` session after
  `pwt-goal.sh` has exited, so the launcher cannot fire the alert itself — it must instruct the worker.
- No change to push authority (push stays a user-owned grant) or to any halt condition.

Tests: `pwt-goal-intent.test.sh` K6 (--auto-push carries the operator-alert directive) + K7 (bare
omits it), EXPECTED_PASS 35 → 37; K1–K5 unchanged.

## [2.30.1] — 2026-08-31 (KI-7 — warn when a worktree-consumed gating hook is uncommitted) (5031e8f)

Closes **KI-7** (KNOWN_ISSUES): an "armed" gating hook was silently IGNORED in a fresh worktree.
`git worktree add … HEAD` checks out the **committed** HEAD, so the spawned bg worker runs the
WORKTREE's copy of every gating hook — never the working-tree copy in the main checkout. An operator
who edited a gating hook (e.g. armed the F7 completeness gate in `plan-w-team-goal-evaluator.sh`) but
had NOT committed it got the OLD hook inside the worktree, and the change silently no-opped (an armed
gate that never fires).

**Fix — spawn-time drift warning (`pwt-goal.sh`):** right after the `--worktree` flag is decided, and
only when worktree isolation is active, the launcher checks whether any worktree-consumed gating hook
(`plan-w-team-goal-evaluator.sh`, `plan-w-team-lane-guard.sh`, `plan-w-team-lane-context.sh`) differs
from HEAD in the main checkout (`git status --porcelain` non-empty ⇒ modified, staged-not-committed,
or untracked). If any do, it prints a LOUD warning naming each dirty hook and explaining that the
worker will use HEAD's committed copy, so the uncommitted edits will NOT take effect this run.

- **Advisory only — never aborts.** The operator may have committed on another branch or want HEAD's
  copy deliberately; the warning informs, it does not gate.
- **Fail-open SILENT** when the resolved root is not a git repo / git is unavailable, so test
  sandboxes and non-git checkouts never false-fire.
- The specific F7-evaluator case that surfaced KI-7 is **already closed** — its completeness-gate
  logic landed COMMITTED at `2c650c7` (v2.22.0). This fix generalizes the lesson to ANY worktree-run
  gating hook so the blind spot cannot recur silently.
- Kill switch: `PWT_DISABLE_WORKTREE_HOOK_DIRTY_WARN=1`.

Tests: `pwt-goal-worktree-hook-dirty.test.sh` (9/9) — clean baseline (no warn, spawn reached), dirty
evaluator (warns + names it), two dirty (both listed), untracked/staged-deletion drift (warns),
kill switch (silenced), non-git root (fail-open silent, spawn still succeeds).

## [2.29.0] — 2026-08-31 (Full per-run orphan broom — SA-4, followups row 18)

**Resolves recursive-followup row 18 `[cleanup-eval-2026-06-08] SA-4 (MEDIUM, deferred)`** —
the stale-state janitor's larger deferred half. Prong B reaped a provable orphan's family but
only a FIVE-prefix subset, so every reap BEHEADED its own family: it deleted the goal+manifest
anchors while leaving the other ~40 per-run classes on disk with no discovery anchor
("headless"). Spec:
`docs/specs/resolve-recursive-followup-row-18-cleanup-eval-2026-06-08-sa-4-medium-deferred-t-9c624d36.md`
(AC1–AC10).

> **Re-base note:** this fix originally shipped on a side branch as `2.21.0` (commit `6b15ac6`);
> that label collided with the shipped `2.21.0` credential-seam release when the branch was
> re-based onto current main (`2.28.0` / `3bf2a0c` at the time of landing), so it was renumbered
> `2.29.0` with a fresh version bump. The janitor script is byte-identical to the merge-base, so
> the rewrite applied cleanly; only `VERSION`/`CHANGELOG`/`.sync-version` needed collision
> resolution.

- **`plan-w-team-cleanup-stale-goal-states.sh` — PASS 2 rewritten to reap the COMPLETE
  per-run family**: `PER_SLUG_REAP_PREFIXES` now enumerates all the `$SLUG`-keyed
  `plan-w-team-*` artifact classes (goal, manifest, stage-events, directive, pwt-brief,
  workflow-lock, liveness, retro, retro-capture, …) plus `supervisor-progress-<slug>`, so a
  provably-orphaned non-terminal family is reaped WHOLE instead of decapitated. PASS 1
  (SUCCESS goal-state immediate delete) is unchanged.
- **Collision-safe prefix matching**: reap prefixes nest
  (`plan-w-team-retro-` ⊂ `plan-w-team-retro-capture-`), so a naive prefix loop would let a
  short prefix swallow a longer sibling's files. `__slug_of_file` resolves each file to its
  slug by **longest-prefix-wins**, a `GLOBAL_DENYLIST` protects the non-per-run classes
  (Governor `plan-w-team-approver-audit-`, `plan-w-team-given-spec-`, the run registry, and
  cross-run singletons), a `^[A-Za-z0-9_-]+$` slug charset guard rejects anything unexpected,
  and `.lock` directories are removed with a dir-safe `rm -rf`.
- **Registry-parity drift guard** (new): `--list-reap-prefixes` prints the janitor's reap set,
  and `plan-w-team-cleanup-registry-parity.test.sh` asserts it EXACTLY equals the `$SLUG`-keyed
  classes documented in the State Artifact Registry (`shared/state-artifacts.md`), minus the
  registry's non-reap exemption set. Adding a per-run artifact class without teaching the
  janitor now fails a test instead of silently leaking.
- **Structural orphan proof preserved**: a family is reaped only when it is "headless" (no
  goal/manifest/workflow-lock anchor) AND aged past `PWT_GOAL_STALE_HOURS`. No live-run family
  is ever touched.
- Docs: `shared/state-artifacts.md` documents the new artifact classes (incl.
  `supervisor-progress-<slug>`); `shared/governance-tags.md` registers the janitor as a
  one-way-door surface (every diff forces a Step-5 security review);
  `plan-w-team-cleanup-orphan-families.test.sh` gains extended corpus coverage;
  `sync-to-project.sh` allowlists both new tests.
- Kill switch: `PLAN_W_TEAM_DISABLE_ORPHAN_GC=1`.

## [2.28.0] — 2026-08-31 (KI-4 — resume restores the launch-time auto-push posture) (e5f15e4)

Closes **KI-4** (KNOWN_ISSUES): a resumed lane silently LOST `PLAN_W_TEAM_AUTO_APPROVE_PUSH=1` and
dead-ended at the push-ack pause (waited on a human who never comes). `pwt-steer.sh` rebuilt the
resume launch env with a **hardcoded** `__pwt_build_launch_env 0`, so the push posture the original
autonomous spawn was granted (`--worker-only`/`--launch`/`--supervisor-goal`/`--auto-push` all set
`AUTO_PUSH=1`) never reached the resumed worker unless the operator hand-passed
`--env PLAN_W_TEAM_AUTO_APPROVE_PUSH=1` on every steer.

**Fix — persist the posture, restore it automatically (reuse-first):**

- **Writer (`pwt-goal.sh`):** the goal-state seed now records `auto_push` (0/1 = `$AUTO_PUSH`) at all
  three seed sites (the jq writer, the no-jq printf fallback, and the supervisor-goal mirror
  heredoc). Additive field — every existing reader accesses named fields, so nothing else changes;
  no seed golden or key-set lock exists to perturb.
- **Steer (`pwt-steer.sh`):** the resume reads `.auto_push` back from the goal-state and feeds the
  **same** shared `__pwt_build_launch_env` builder (`__pwt_build_launch_env "$STEER_AUTO_PUSH"`)
  instead of the hardcoded `0`. A fallback arm restores the push var even when the launch-env lib is
  unreadable. Kill switch: `PWT_DISABLE_STEER_AUTOPUSH_RESTORE=1`. Operator `--env` is still appended
  AFTER, so an explicit override (e.g. `land.sh resume`'s hardcoded `--env AUTO_APPROVE_PUSH=1`)
  always wins — no conflict with the land path.
- The launch-env build was hoisted **above** the `--dry-run` branch so `--dry-run` now prints the
  REAL resume env (it previously printed a stale hardcoded literal), which is also the KI-4 test seam.

`__pwt_build_launch_env` itself is unchanged, so the `launch-env-autopush.golden` parity holds; the
K1–K5 prompt golden is byte-identical. `pwt-resume.sh` delegates through `land.sh` → `pwt-steer`, so
it inherits the fix with no parallel change. Tests: `pwt-steer.test.sh` T25a–e (124/124);
`pwt-goal-worker-only.test.sh` KI-4 seed cases (12/12); prompt golden 35/35; seed-reclaim 28/28.

## [2.27.0] — 2026-08-31 (KI-3 — pwt-steer auto-resolves an 8-char bg handle to the full session UUID) (42c666d)

Closes **KI-3** (KNOWN_ISSUES): `pwt-steer.sh` read the worker session id from the goal-state, but a
`--bg` spawn only prints (and the seed only persists) the 8-char process HANDLE (`backgrounded · aabbccdd`).
`--resume` requires the 36-char session UUID, so steer dead-ended at the W6 refuse ("'<handle>' is not a
full session UUID") — the worker was alive and `working`, but you could not steer or resume it without
hand-resolving the UUID from `claude agents --json`. This stranded 2-of-3 field resume attempts.

- **Handle→UUID auto-resolve** (`.claude/scripts/pwt-steer.sh`, before the W6 refuse). When the worker
  sid is an 8-hex handle (not a UUID), steer queries the live session registry via
  `claude-agents-extended.sh --json --bg-only` and upgrades to a UNIQUE bg session whose `sessionId`
  starts with the handle.
- **Fail-open, never resume a stranger.** 0 or >1 matches, an unqueryable/flaky registry, or a value that
  is not an 8-hex handle all leave the sid untouched, so the W6 refuse still fires. Only an unambiguous
  single match upgrades. Kill switch: `PWT_DISABLE_STEER_SID_RESOLVE=1`.
- **Testable seam.** Uses the wrapper's `CLAUDE_AGENTS_RAW` seam, so the resolve is driven
  deterministically without a live registry.
- **Scope note (writer-side deliberately NOT changed).** KNOWN_ISSUES also floated "goal-state should
  persist the full UUID." That would add a registry round-trip to *every* spawn's hot path and break 6+
  pwt-goal tests that assert exact `claude` call numbering — for zero correctness gain once steer
  auto-resolves. The steer-side resolve makes every handle-bearing goal-state (including all existing
  ones) resumable, so the writer-side persistence is redundant and was left out.
- **Tests**: `pwt-steer.test.sh` gains T24a–d (unique-match resolve, resolved UUID in the plan, no-match
  fail-open refuse, kill-switch refuse); T2 reconciled to pin an empty registry so the handle-refusal case
  tests the fail-open path. 116/116 (was 112).

## [2.26.0] — 2026-08-31 (KI-2 — a flag after the positional goal fails loud instead of silently degrading) (c4cf003)

Closes **KI-2** (KNOWN_ISSUES): `pwt-goal.sh "<goal>" --worker-only` (flag AFTER the goal) printed the
assembled `/goal` prompt and exited 0 with NO spawn — no worktree, no worker, no error. The arg-parse
`*)` arm did `REQUEST="$*"; break`, swallowing the trailing `--worker-only` into the request string;
`LAUNCH`/`WORKER_ONLY` stayed 0 and the script silently degraded to print-for-manual-paste mode. An
operator running an autonomous lane got a paste-me blob and a dead terminal instead of a running worker.

- **Guarded positional parse** (`.claude/scripts/pwt-goal.sh`). The `*)` arm now takes `$1` as the goal
  head, then scans the REMAINING argv: an option-shaped trailing token (starts with `-`) is a
  misplacement → loud error naming the offending token + guidance (put flags before the goal, or end
  options with `--`) + **exit 2**, mirroring the outer `-*)` unknown-option arm. Every other trailing
  word is appended, so an UNQUOTED multi-word goal (`--worker-only ship the thing`) still assembles.
- **Escape hatch preserved.** A goal that legitimately begins with `-` still works via `--`
  (`pwt-goal.sh --worker-only -- "-weird goal"`), handled by the `--)` arm above the positional arm.
  A goal with a flag-like substring INSIDE its quotes is a single argv element — no separate trailing
  token — so it is untouched.
- **Loud-not-silent.** exit 2 is distinct from the pre-goal unknown-option exit 1, so a caller can tell
  "you put a flag after the goal" apart from "unknown flag before the goal." No behaviour change for the
  correct flags-first invocation.
- **Tests**: `.claude/scripts/pwt-goal-worker-only.test.sh` gains 4 KI-2 cases — trailing flag exits 2,
  no spawn on rejection, stderr carries the misplacement guidance, and an unquoted multi-word goal still
  spawns (1 call, exit 0). 10/10 (was 6). Golden K1–K5 (`pwt-goal-intent.test.sh`) and heredoc-size stay
  green (flags-first path unchanged).

## [2.25.0] — 2026-08-30 (KI-6 — lane guard stops false-positiving on copy-family SOURCE operands) (fc76720)

Closes **KI-6** (KNOWN_ISSUES): the PreToolUse lane-guard (PWT-LANE1) classified `cp`/`rsync`/`ln`/`install`
as "mutators" and denied the call if ANY operand resolved inside the lane repo — including the SOURCE. A
bound supervisor's legitimate `cp $REPO/src/x /tmp/…` or `rsync $REPO/ /tmp/backup/` was blocked, forcing
operators to prefix `PLAN_W_TEAM_DISABLE_LANE_GUARD=1` (disabling the whole guard) to copy anything OUT of
the repo. A copy-family verb only WRITES its destination; a source under the repo is a read.

- **Copy-family / destructive split** (`.claude/hooks/plan-w-team-lane-guard.sh`). New `COPY_FAMILY_RE`
  (`cp|rsync|ln|install`) and `DESTRUCTIVE_MUTATOR_RE` (`rm|mv|truncate|dd|shred|unlink`) beside the
  existing `MUTATOR_RE` (unchanged — still the trigger). The mutator token-check now relaxes for a PURE
  copy-family command, checking ONLY the destination (final) operand and skipping in-repo sources.
- **Deliberately narrow relaxation.** It applies ONLY when the command matches a copy-family verb AND has
  NO destructive verb AND NO `-t`/`--target-directory` form AND NO command separator / pipe / substitution
  (`[;&|]`, `$(`, backtick). Every other shape — a destructive verb (`mv` deletes its source), the `-t`
  target-directory form (dest is not the final operand), or any chain/pipe/subshell — reverts to the strict
  all-operand check, so copying INTO the repo still DENIES, including a repo write hidden behind an
  out-of-repo FINAL token. `COPY_ONLY=0` behaviour is byte-identical to the prior guard.
- **Security-property preserved.** `cp /tmp/evil $REPO/src` (dest in repo), `cp -t $REPO/src …` (in-repo
  target dir), `cp /tmp/x $REPO/dst && …` (chained), and every `mv` from the repo still DENY. The existing
  D10 protected-artifact denials (`cp … ship-verdict.json`, release memo) are unchanged.
- **Tests**: `tests/skill/cases/plan-w-team-lane-guard.bats` gains 7 KI-6 twins (75–81) — cp/rsync
  source-out ALLOW + audited, cp/rsync dest-in DENY, the separator-smuggling DENY, the `-t` DENY, and the
  mv-still-denies witness. 81/81 (was 74). Lane-guard is a governance-tagged one-way-door surface.

Also in this version — two `pwt-goal.sh` correctness fixes surfaced while greening the suite for KI-6:

- **KI-5 follow-up (halt-directive wording).** The v2.24.0 auto-push halt directive embedded the literal
  `PLAN_W_TEAM_AUTO_APPROVE_PUSH=1` token in the emitted supervisor goal text. That leaked into the `--bg`
  argv and inflated `plan-w-team-route-prompt-supervisor-env.test.sh`'s occurrence count (2 launch-env
  copies + 1 goal-text literal = 3, the test asserts 2). Reworded to "(auto-push mode is armed)" — behavior-
  neutral, and the KI-5 golden assertions (`Push is AUTO-APPROVED for this autonomous run`) are preserved.
- **DS1 guard root-resolution precedence.** `GUARD_PROJECT_ROOT` resolved `CLAUDE_PROJECT_DIR` BEFORE
  `PWT_PROJECT_ROOT_OVERRIDE` — the inverse of every other root-resolution site (RSC_PRIMARY, the `__pwt`
  root helper, WT_ROOT, PROJECT_ROOT). With `CLAUDE_PROJECT_DIR` set (as `tests/skill/run.sh` Phase 2 does),
  the PWT-DS1 double-spawn guard scanned the REAL repo's state dir instead of a test sandbox, so stale
  `hook-spawn-*.flag` files there triggered extra `claude agents --json` liveness probes that corrupted the
  spawn-counter in sandbox-isolated tests (`pwt-goal-heredoc-size.test.sh` failed in-suite, passed
  standalone). Swapped to `PWT_PROJECT_ROOT_OVERRIDE` first. Production is unaffected (the override is
  test-only and unset in real runs — the fall-through to `CLAUDE_PROJECT_DIR` is unchanged); this only
  restores sandbox isolation when the override IS set.

## [2.24.0] — 2026-08-30 (KI-5 — push-ack halt contract is mode-conditional, stops alarming operators) (96f7475)

Closes **KI-5** (KNOWN_ISSUES): the `/goal` text printed a FIXED "Halt and surface to user … push-ack
pause site (irreversible push to remote)" block regardless of mode. But every autonomous spawn
(`--launch` / `--worker-only` / `--supervisor-goal` / `--auto-push`) already sets
`PLAN_W_TEAM_AUTO_APPROVE_PUSH=1`, so its push-ack pause AUTO-APPROVES and the run pushes + lands without
pausing — the run was advertising a halt it would never take, which reads to operators as "it will wait
on me." Only a bare `/goal` paste (`AUTO_PUSH=0`) actually pauses at push.

- **Mode-conditional halt contract** (`pwt-goal.sh`, `__pwt_build_goal_text`). New `AUTO_PUSH`-gated
  `__PWT_PUSH_HALT_DIRECTIVE`: under auto-push the goal text states push AUTO-APPROVES (no halt) and lists
  only the genuine halts (secret-scan-allow, scope-unlock-for-drift, 3-consecutive low-confidence); a bare
  paste keeps the push-ack halt line because it truly pauses there. `secret-scan-allow` and
  `scope-unlock-for-drift` halt in BOTH modes — only push-ack is auto-approved. The directive-overflow
  pointer text (`__PWT_HALT_INLINE`) is mode-aware too.
- **Byte-identical for `AUTO_PUSH=0`**: the bare-paste branch reproduces the historical block verbatim, so
  the byte-identical golden guard in `pwt-goal-intent.test.sh` (and the overflow test) stay green.
  Auto-push is confirmed ALREADY the default for every spawn mode — this corrects the *contract* to match,
  it does not change push authority (push stays a user-owned grant).
- **Tests**: `pwt-goal-intent.test.sh` gains K1–K5 (auto-push omits the push-ack halt + states
  auto-approval + keeps the both-mode halts; bare keeps push-ack + never claims auto-approve), 35/35.

## [2.23.0] — 2026-08-30 (KI-1 — per-lane credential resolver seam kills the bg-daemon account pin) (ec27949)

Closes **KI-1** (KNOWN_ISSUES): the bg-session daemon reads auth ONCE at startup, so every `--bg`
worker inherits whatever account the daemon started under and dies 15–23 min in when that token goes
stale (looks like a stall — session `waiting`, zero writes, `terminal_state` null). The v6 item-5 seam
(`--lane-settings-json` / `PWT_LANE_SETTINGS_JSON`) already let an OPERATOR hand each lane its own
credential, but the DEFAULT autonomous spawn still fell back to the daemon account. This wires an
optional per-lane credential SOURCE into the default spawn path.

- **New env `PWT_LANE_SETTINGS_RESOLVER=<executable>`** (`.claude/scripts/pwt-goal.sh`). When set AND no
  explicit `--lane-settings-json` / `PWT_LANE_SETTINGS_JSON` was given, the bg-spawn path calls it as
  `<resolver> <lane-slug> <worktree-name>` and uses the `settings.local.json` path it prints on stdout —
  so the lane authenticates with its own account from the first API call instead of the daemon's. The
  resolved path feeds straight into the existing item-5 validate+inject block (0600 drop, contents never
  logged).
- **Works in ANY repo — opt-in / byte-for-byte no-op when unset.** A friend's checkout or generic use
  sees no `PWT_LANE_SETTINGS_RESOLVER`, so this whole block is skipped and the legacy daemon-account
  behaviour is unchanged. **The generic skill only INVOKES the resolver and never handles a token** —
  all account/token logic lives in the consuming repo's resolver (e.g. a separate multi-account manager).
- **Fail-CLOSED** (the whole point of KI-1): a configured resolver that errors, is not executable, or
  prints nothing ABORTS the spawn — we never silently fall back to the daemon account. Also fails closed
  when worktree isolation is disabled (`PWT_DISABLE_WORKER_WORKTREE=1`) since there is no lane worktree to
  drop the credential into. Kill switch: `PWT_DISABLE_LANE_SETTINGS_RESOLVER=1`.
- **Tests**: `.claude/scripts/pwt-goal-lane-settings.test.sh` gains E3 (auto-source drops a 0600
  credential + passes the lane slug + spawns with `--worktree`), E4/E4b (resolver error / empty output
  both abort with no spawn), and E5 (unconfigured → normal spawn, legacy path unchanged). 31/31 pass; the
  full 19-file pwt-goal corpus stays green.

## [2.22.0] — 2026-08-30 (Completeness Gate (F7) — kills the enumerated-universe SCOPE-COLLAPSE) (2c650c7)

Closes the SCOPE-COLLAPSE defect (field incident 2026-08-30, cleanscale BDD-gap campaign): a goal to
"create 1 BDD test for **each** of 359 coverage-manifest gaps" reached `terminal_state: SUCCESS` after
covering **19**, then emitted `retro-complete` as if the whole set were done. Root cause: the
`feature_specific_done_criteria` AND-check measures completion against the criteria array's OWN length,
and that array is derived mechanically from whatever `AC<N>:` lines Step 1 authored — so a contract
written for the first CHUNK becomes both the contract and the pass bar. Nothing bound the full universe.

- **New opt-in goal-state field `completeness_gate`** (`{label, file, jq|grep_count, max_remaining}`).
  When present, the `/goal` evaluator (`plan-w-team-goal-evaluator.sh`, **F7**) re-measures the REMAINING
  count from the source of truth live at every terminal anchor and VETOES SUCCESS while remaining exceeds
  `max_remaining`. It is a **final veto** — placed after the Bug-B backstop and the F6 landing gate — so a
  run with items still remaining cannot resolve SUCCESS regardless of ship-verdict or landing artifact.
  The block reason instructs the pipeline to break the remaining items into the next wave (Step 2) and
  re-emit retro-complete, so one run iterates to full coverage instead of stopping at chunk one.
- **Fail-CLOSED**: a present-but-unmeasurable gate (missing file, malformed spec, non-integer measure)
  BLOCKS — a gate whose whole job is preventing false-green must never pass when it cannot see the truth.
- **OPT-IN / backward compatible**: engages ONLY on positive presence of the field; every existing goal
  keeps byte-for-byte behaviour. Kill switch: `PWT_DISABLE_COMPLETENESS_GATE=1`.
- **Population**: `01-specification.md` **§1.6** writes the gate for "for each `<enumerable set>`" goals
  (with the exact jq); `07-retro.md` gains a proactive precondition check so the worker loops before
  wasting a terminal attempt. Schema documented in `shared/goal-conditions.md` → "Completeness Gate (F7)".
- **Tests**: new `.claude/scripts/plan-w-team-goal-evaluator-completeness-gate.test.sh` (10 assertions:
  remaining>0 blocks, remaining==0 succeeds, missing-file/malformed fail-closed, grep_count variant, kill
  switch, absent-field back-compat). Existing evaluator suite (60 assertions) unchanged and green.

## [2.21.0] — 2026-08-30 (Model Tiering v6 — item 5: per-lane credential seam in pwt-goal.sh) (7d6c36a)

Item **5** — the final Model Tiering v6 change
(`docs/directions/DIRECTION-model-tiering-v6-lane-mechanics-2026-08-30.md`), hand-implemented on top of
2.20.0 (`da1922f`). **v6 is now complete** (items 1–5 all landed). This is the SUPPLY-side fix to the
token-burn crisis: it lets each lane authenticate with its own account, retiring the daemon-rotation
workaround (#1703) so parallel lanes can spread across several accounts instead of draining one.

- **New seam: `pwt-goal.sh --lane-settings-json <file>` / `PWT_LANE_SETTINGS_JSON=<path>`** (flag wins
  over env). The documented way to give a background session its own account is the lane directory's
  `.claude/settings.local.json` `env` block — NOT the daemon's env. Because `claude --bg --worktree
  <name>` creates the worktree and starts the session in one step, pwt-goal now **pre-creates** the
  worktree via `git worktree add`, drops the operator-supplied file at
  `<wt>/.claude/settings.local.json` **mode 0600**, then launches with `--worktree <name>`, which
  **REUSES the already-registered worktree** — verified on CLI 2.1.251 with a bounded probe (claude
  ADOPTS the existing path rather than colliding, disproving the earlier code-comment assumption). The
  seam applies to every worker spawn path (`--launch`, `--worker-only`, `--supervisor-goal`), so the
  shipyard's lane spawns get it.
- **Fail closed, never leak.** If the seam is set but worktree isolation is off, if the file is
  missing/empty/invalid-JSON, or if the pre-create or drop fails, the launch **ABORTS** (with the
  worktree rolled back) rather than silently running the lane on the wrong (daemon-default) account.
  The file's contents — an OAuth token — are never echoed to logs. Two testable helpers:
  `__pwt_validate_lane_settings` (input validation) and `__pwt_inject_lane_settings` (0600 drop).
- **Never committed.** `.claude/settings.local.json` is gitignored in consumers, so the ship gate and
  every git op skip it. A new **credential guard** in `shared/untracked-hygiene.md` HARD-BLOCKS a
  commit if a consumer's missing `.gitignore` line ever surfaces the token in the classification set.
- **Deleted at lane end.** The credential dies with the worktree at land-time reclaim (whole-tree
  removal), and is never captured by `preserve_then_reap` (which enumerates with `--exclude-standard`).
  Defense-in-depth: `plan-w-team-worktree-untracked-sweep.sh` gains an explicit **credential scrub** —
  a per-lane `settings.local.json` is reaped from any worktree that outlives its lane, EVEN THOUGH it
  is gitignored (the scrub is an explicit `[ -f ]` check, not enumeration), behind the same in-use /
  live-pid / newborn vetoes so a LIVE lane keeps its token.
- **Tests:** new `pwt-goal-lane-settings.test.sh` (14 checks — validation, 0600 drop, content fidelity,
  no-leak, flag-over-env, fail-closed guards) + two new cases in the sweep test corpus (credential
  scrubbed when gitignored; in-use veto preserves it). Parity (P0) held — the seam is inert unless
  `--lane-settings-json`/`PWT_LANE_SETTINGS_JSON` is passed, so an ungoverned run with neither set is
  byte-identical.

## [2.20.0] — 2026-08-30 (Model Tiering v6 — subagent tiers FOLLOW THE LANE + v6 doctrine in the manifest) (da1922f)

Items **1 & 4** of the five Model Tiering v6 changes
(`docs/directions/DIRECTION-model-tiering-v6-lane-mechanics-2026-08-30.md`), hand-implemented on top of
2.19.0 (`275ae01`). The founder doctrine (2026-08-30): *"Fable 5 is the most complete model (xhigh +
workflows); Opus 4.8 always does the job; Sonnet 5 is great; Haiku when the task needs less thought.
Parallelism is speed. Opus 5 stays forbidden."* v6's architecture is a **split of responsibility**:
the consumer's shipyard DECIDES the model per work item; `/plan-w-team` OBEYS the pins it is handed and
carries no business rule of its own.

- **Subagent tiers follow the lane** (item 1). The seven execution + spec/review agents — `builder`,
  `builder-opus`, `silent-failure-hunter`, `test-gap-analyzer`, `security-gap-analyzer`,
  `react-typescript-specialist`, `rust-backend-specialist` — flip their frontmatter from the v5
  hardcoded `model: claude-opus-4-8` to **`model: inherit`**: they now run on the launching session's
  model = the lane (`PWT_PRIMARY_MODEL` in autonomous runs). The consumer can land low-risk work on
  Sonnet 5 and intelligent work on Opus 4.8 without the skill hardcoding either. `difficulty: hard`
  now routes the PROMPT to `builder-opus`, not the model.
- **The anti-lockout floor is now LOAD-BEARING** (it was a redundant guard under v5). `pwt-goal.sh` and
  `pwt-steer.sh` keep pinning `PWT_PRIMARY_MODEL=claude-opus-4-8` (never Fable) at every spawn/resume
  site, so an inheriting builder can never fan out on Fable (2026-07 lockout lesson). The skill **never
  hardcodes Fable into a spawnable role**; the singleton verdict/supervisor roles (`evaluator`,
  `validator`, `supervisor`) stay pinned at the Opus-4.8 floor, so the judge/supervisor sit at a stable
  Brain floor and the escalation ladder degrades exactly one rung.
- **Consumer-override seams** (item 1). `PWT_SUBAGENT_MODEL_BUILDER` (execution lane) and
  `PWT_SUBAGENT_MODEL_MECHANICAL` (mechanical lane) let the shipyard override a subagent's model at
  spawn. Both are **alias-validated**: only `sonnet`/`haiku` are honored — `opus` / `claude-opus-5*` /
  `fable` / `inherit` / a full model ID are REFUSED, because the Agent-tool `model` param takes only
  aliases and bare `opus` resolves to the FORBIDDEN Opus 5.
- **v6 doctrine in the manifest** (item 4). `plan-w-team.md` Model Strategy gains the split-of-
  responsibility intro, the two builder table rows rewritten to the follow-the-lane tier, a full v6
  generation note, and a rewritten "control a subagent's model" mechanism + rollover checklist (most
  execution agents now carry `model: inherit` and have NO literal pin to bump — a rollover is mostly a
  spawn-site + floor edit). `03-execute.md` documents the builder-seam consumption at the spawn site;
  `shared/agent-roster.md` states the per-agent v6 tier.
- **P0 unchanged: ungoverned `/plan-w-team` stays byte-for-byte identical.** No spawn default changed
  (the floor is still Opus 4.8); `model: inherit` means the subagent tracks the lane the launcher
  already set. The flip changes only WHICH model a lane-following subagent runs on when the consumer
  sets a non-default lane — never the ungoverned baseline.
- **Corpus realigned to v6** (the same "corpus lags the doctrine" class that bit the v5 rollout):
  rewrote `model-tiering-v5.bats` v5-1 (inherit lanes + Opus-4.8 verdict floor) and added v5-9 (the
  PWT_SUBAGENT_MODEL_* seams are documented + stamped v6); `model-tiering-v2.bats` MT1/MT2 (builder +
  builder-opus + specialists follow the lane); `opus48-uplift.bats` AC1 (floor set narrowed to
  evaluator/validator/supervisor); `plugin-integration.bats` + the two gap-analyzer scenario tests
  (opus-4-8 → inherit). The Opus-5-forbidden (v5-4/v5-6) and no-Fable-in-fan-out (v5-7) negative
  guards are unchanged and still green.

**Item 5** (per-lane credential seam) remains deferred to its own later run.

## [2.19.0] — 2026-08-30 (Model Tiering v6 — burn-reducers: steered-lane #1673 permission-mode + shared compact window) (275ae01)

Two of the five Model Tiering v6 changes the CleanRev shipyard asked for
(`docs/directions/DIRECTION-model-tiering-v6-lane-mechanics-2026-08-30.md`, items 2 & 3),
hand-implemented as the cheapest, highest-leverage token-burn reducers. Builds on 2.18.0 (`f66bab7`).
**P0 unchanged: ungoverned `/plan-w-team` stays byte-for-byte identical** — both additions are
forward-only (fire only when the operator/lane sets the knob), so the launch-env parity golden holds
(`tests/skill/cases/governor-parity.bats` scrubs the two forward-only vars to assert the UNSET
baseline). The other three v6 items (subagent tiers follow the lane, the v6 manifest doc, and the
per-lane credential seam) remain their own later runs.

- **#1673 — the steered-lane death fix** (`pwt-steer.sh`): the resume `exec` passed `--model` /
  `--fallback-model` but **no `--permission-mode`**, so every RESUMED `claude --bg` worker started
  with no bypass grant and wedged at its first Bash/Edit (`waiting` in the roster, forever, with
  `/dev/null` stdin and no one to answer). A FRESH `pwt-goal` spawn worked; only the steer/resume
  path died — the root cause of every dead steered lane (reproduced 2026-08-30 00:26Z; eleven
  mass-steers 2026-08-29 23:07Z did zero work). The fix adds `--permission-mode` at the single
  resume exec site (default **`bypassPermissions`** — a bg fleet worker runs unattended), the
  dry-run `would run:` echo shows it, and `pwt-resume.sh` / `plan-w-team-land.sh` resume inherit it
  because they route THROUGH `pwt-steer` (single site, not duplicated). Seam `PWT_STEER_PERMISSION_MODE`
  (recognized modes `bypassPermissions|acceptEdits|default|plan|auto`); an unrecognized/empty value
  falls back to `bypassPermissions` with **one warning** — a steered lane can never wedge again over
  a typo. Regression: `pwt-steer.test.sh` T4k (argv is exactly 10 elements), T4y/T4z (default
  bypassPermissions present), T5c (injection fixture still one argv, now argc 10), T23a–d (the seam).

- **Shared compact window** (`pwt-launch-env.sh`): `__pwt_build_launch_env` now forwards
  `CLAUDE_CODE_AUTO_COMPACT_WINDOW` (documented knob; plain token count) when the operator/lane
  sets it — forward-only, exactly like `PLAN_W_TEAM_SPEC_FANOUT` — so the spawn, steer AND resume
  paths all compact at the SAME window. Measured 2026-08-30: without it, Opus 4.8 / Fable 5 lanes
  compacted only at the 1M limit (185–640K contexts, 0 compactions; **53% of spend was cache-read of
  that uncompacted history**); the biggest single burn lever. The operator shell wrapper
  (`.claude/shell/claude-pattern.zsh`) is updated in the same change to set
  `CLAUDE_CODE_AUTO_COMPACT_WINDOW=250000` for interactive sessions and drop the undocumented
  `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` (measured NOT to fire).

- **Verification**: `pwt-steer.test.sh` 112/112, `governor-parity.bats` 14/14 (golden byte-identical
  under the forward-only scrub), `model-tiering-v5.bats` 22/22 (resume still pins `claude-opus-4-8`;
  no Opus 5 anywhere). Landed at `275ae01`.

## [2.18.0] — 2026-08-30 (Governor Contract phase 3 — C2 budget obedience, C6 given-spec, C7 coordination hints; CONTRACT COMPLETE)

Phase 3, the FINAL phase of the Governor Contract — C1→C7 are all delivered (spec:
`docs/specs/governor-contract-phase-3-for-plan-w-team-the-final-phase-per-the-brief-c2-budge-9b3b572c.md`;
brief: `docs/directions/DIRECTION-pwt-governor-contract-for-shipyard-2026-08-29.md` §C2/§C6/§C7).
**P0 unchanged: ungoverned `/plan-w-team` stays byte-for-byte identical** — every new behaviour is
governed-only or the ONE deliberately regenerated-once golden. Builds on 2.17.0 (`2038330`).

- **C2 — budget obedience** (`pwt-governor-lib.sh` + gates + spawn sites): three governed-only,
  fail-open accessors — `pwt_governor_budget_int` (warns once on a present-but-invalid key so a cap
  that silently didn't take is diagnosable), `pwt_governor_clamp_builders` (named refusal of the
  excess), and `pwt_governor_model` (the **downward-only** model guard: per-tier EXACT-STRING
  allow-list membership, NOT rank≤ceiling — which would admit `claude-fable-5` into the intelligent/
  lead tier, the 2026-07 lockout; never emits Opus 5 / bare `opus` / `inherit` / a tier-raise).
  **Builder clamp (R1)** is wired into `plan-w-team-fleet-query.sh summary → max_concurrent`
  (`min(observed, max_builders)`) — the ONE chokepoint the dispatch supervisor already obeys, binding
  every dispatch pattern mechanically. **RAM/disk floors (R2, raise-only)** in `ram-budget.sh`/
  `disk-budget.sh` OVERRIDE the computed action and surface a NAMED `governed_floor` refusal (exit 5) —
  **this closes the open May-2026 disk-gate DIRECTION**. **Single-definition nice (R3)**:
  `__pwt_nice_prefix` in `pwt-launch-env.sh` (outside `__pwt_build_launch_env`, so the launch-env golden
  is byte-stable) at all four spawn branches + a best-effort post-spawn `renice` (bg-spare pool).
  **Applied budget (R5)** recorded per apply-site in the manifest (rejected value → `null`) and
  surfaced by `pwt-status --json` `budget`. Kill switches: `PWT_DISABLE_GOVERNED_FLOORS=1`,
  `PWT_DISABLE_GOVERNED_NICE=1`.
- **C6 — given-spec entry** (`pwt-goal.sh --spec <path>` → new `pwt-given-spec.sh`): validates a
  governor-supplied spec (grounding-theater: regular non-symlink file ≥ `PWT_GIVEN_SPEC_MIN_BYTES`
  (default 500); clean-slug basename; format/coverage freshness via `grounding-gate --phase review`),
  records the TRUTHFUL freshness outcome (`pass`/`skipped:binary-absent`/`disabled:killswitch` — never a
  false `pass`), installs it in-tree at `docs/specs/<slug>.md` with provenance appended to the COPY (no
  out-of-tree write/TOCTOU) + a sidecar, pins the run slug via `__PWT_SLUG_OVERRIDE` at every derivation
  site, and routes the worker into the router's `specd` path — **Step 5 adversarial re-verification
  UNCHANGED**. `--spec`+`--brief` refused; new exit code `8` `PWT_SPEC_INVALID`; omitted `--spec` is
  byte-identical. Governance-tagged surface.
- **C7 — coordination hints** (`pwt-coordination-hints.sh`, governed-only): from one chokepoint,
  annotates the run-local scope-lock with per-task `predicted_paths` (preserving the drift fields —
  inert to Step-5/6 drift), records `coordination_hints` in the canonical-main manifest (surfaced by
  `pwt-status --json`), and emits one `coordination-hint` event per task to the governor's `event_sink`.
  Ungoverned: scope-lock byte-identical, no manifest field, no sink line, drift comparison untouched.
  Kill switch: `PWT_DISABLE_COORDINATION_HINTS=1`.
- **Docs + registrations**: `docs/operations/governor-contract.md` phase-3 section with the **C1→C7
  delivery map + a known-residuals ledger** (the honest close); `shared/state-artifacts.md` registers
  the given-spec sidecar; `shared/governance-tags.md` gains the model-policy invariant + a given-spec
  row; `sync-to-project.sh` allowlists the two new scripts. The `pwt-status-json.golden` parity golden
  was regenerated ONCE (reviewed diff: exactly the two additive `budget`/`coordination_hints` null
  fields).
- **Tests**: `governor-budget.bats` (clamp + fleet-query cap, RAM/disk floors via stub seams,
  single-def nice, the FUNCTIONAL model-guard sweep, applied-budget + status); `governor-parity.bats`
  (regenerated golden + the manifest-surface leak guard); `model-tiering-v5.bats` v5-8 (functional
  accessor sweep) + `model-tiering-v3.bats` (`--exclude=pwt-governor-lib.sh`); `pwt-given-spec.test.sh`
  and `pwt-coordination-hints.test.sh`.

## [2.17.0] — 2026-08-29 (Governor Contract phase 2 — C1 observability, C4 delegated approver, rotated-lead SUCCESS)

Phase 2 of the Governor Contract (spec: `docs/specs/governor-contract-phase-2-c1-observability-c4-approver.md`;
brief: `docs/directions/DIRECTION-pwt-governor-contract-for-shipyard-2026-08-29.md` §C1/§C4).
**P0 unchanged: ungoverned `/plan-w-team` stays byte-for-byte identical** — every new behaviour is
governed-only or a deliberately regenerated-once golden. Builds on 2.16.0 (`3cbc9f3`).

- **C1 — `pwt-status/1` schema** (`pwt-status.sh --json <slug>`, applied ungoverned too): a versioned,
  machine-readable run API added ADDITIVELY over the existing `manifest`/`fleet`/`sessions` sub-objects
  (existing readers unaffected). Fields: `stage`, `strategy`, `strategy_reason`, `tasks{total,done,in_progress}`,
  `builders{declared,live_by_process,live_by_registry}` (live counts from `pwt-lane-alive`), `acs{total,pass,fail,pending}`,
  `pause_site` (null | `{gate,since,evidence_path}` from a pending approver request), `terminal_state` + `terminal_state_source`,
  `worker{sid,pid,started_at}`, `resources{rss_gb,builders_rss_gb}`, `last_event_at`, and `landed{verdict,sha}`
  (surfaces the UNDIVERGED verdict). Read-only + fail-open throughout. The `pwt-status --json` parity golden
  was regenerated ONCE (reviewed diff, `tests/skill/parity/pwt-status-json.golden`); every other golden stays byte-identical.
- **C1 — governed event sink** (`pwt-governor-lib.sh`: `pwt_governor_emit_event` + the shared
  `pwt_governor_run_cmd` execution primitive): tees EXACTLY ONE JSON line `{ts, slug, detail}` per event
  (stage transition, pause, decision, liveness-disagreement) to the manifest's `event_sink` command, under
  the phase-1 execution contract — argv exec via `env -i`, timeout REQUIRED (no timeout binary ⇒ SKIP),
  git-tracked-manifest REFUSAL, fail-open emission (a dead/failing sink never blocks the pipeline).
  **Ungoverned it emits ZERO lines and creates no file.** Wired at `pwt-manifest.sh set --stage`,
  `pwt-lane-alive.sh` §4.5, and `pwt-approver.sh`. Kill switch: `PWT_DISABLE_EVENT_SINK=1`.
- **C4 — delegated approver** (`pwt-approver.sh`, new; wired into `05-ship.md` §6g): on a governed hard-gate
  pause site with a file-mode approver, the run writes `<dir>/<slug>.<gate>.request.json` (`pwt-pause/1`),
  emits the pause event, and AWAITS (no wall-clock cap) `<slug>.<gate>.decision.json`. `approve` creates the
  gate's EXISTING operator file (`plan-w-team-ack-` / `-secret-scan-allow-` / `-scope-unlock-` — byte-for-byte
  what a human touch does), `deny` takes the deny path, `escalate`/silence stay halted. Every decision audited
  with `by` + `grant_ref`; a one-way approve without `grant_ref` escalates; malformed decisions are ignored
  loudly. **`PLAN_W_TEAM_AUTO_APPROVE_PUSH=1` precedence preserved** (auto-clear runs first). A tracked or
  escaping approver dir is refused (falls back to the human prompt). Kill switch: `PWT_APPROVER_DISABLE=1`.
- **C4 — structural self-approval denial** (`plan-w-team-lane-guard.sh`): the decision-file family
  `<slug>.*.decision.json` is denied to BOTH the owning worker (checked before its exemption) and the bound
  supervisor; only an out-of-band governor (neither) may write a decision. The REQUEST file stays the run's to
  write. Second layer: `pwt-approver.sh` ignores malformed/mis-authored decisions loudly.
- **Rotated-lead SUCCESS gap** (`plan-w-team-goal-evaluator.sh`): the worker-mode C3 gate now accepts a
  VERIFIED landing artifact (`plan-w-team-land.sh verify`, git-reverified) as an ALTERNATIVE corroboration to
  a PASS ship-verdict — a rotated-lead run whose ship-verdict is REDACTED but which genuinely LANDED now flips
  SUCCESS. The real rotated-lead run is always a bg worker (worker mode ⇒ C3), so C3 fully covers it. **The
  PWT-LANE2 actor gate deliberately stays STRICT** (phase-2 security review): the landing artifact is not in
  the lane guard's protected set, so a non-owner could forge it — the actor gate keeps requiring the
  structurally-protected PASS ship-verdict, and the C3 use is safe because its caller is the trusted executor
  (which can forge the ship-verdict too). Kill switch: `PWT_DISABLE_LANDING_CORROBORATION=1`.
- **Docs + state**: `docs/operations/governor-contract.md` phase-2 section; `shared/state-artifacts.md`
  registers the request/decision/approver-audit artifacts; `shared/governance-tags.md` flags the lane-guard
  decision-file + event_sink command-execution surfaces. The already-shipped `pwt-resume.sh --reason
  gate-answered` re-entry is documented as the follow-up for an already-stamped terminal.
- **Tests**: `tests/skill/cases/{pwt-status-schema,governor-event-sink,rotated-lead-success}.bats`,
  `governor-parity.bats` (regenerated `pwt-status` golden + governed-only inertness), and
  `.claude/scripts/pwt-approver.test.sh` (approve/deny/escalate/silence round-trip, malformed, one-way-grant,
  worker+supervisor decision denial).

## [2.16.0] — 2026-08-29 (Governor Contract phase 1 — governed mode, one liveness truth, truthful stop/resume)

Phase 1 of the Governor Contract (brief: `docs/directions/pwt-brief-governor-phase1-c3-c5.md`).
**P0: `/plan-w-team` stays byte-for-byte unchanged in every repo with no governor** — off by
default, proven by the parity harness.

- **Governed-mode detection** (`pwt-governor-lib.sh`, §2): opt-in via env `PWT_GOVERNOR` or a
  `.claude/state/pwt-governor.json` manifest (schema `pwt-governor/1`). OFF by default; a broken
  manifest is treated as ABSENT plus ONE stderr warning; the manifest is gitignored (operator-authored).
- **Parity harness** (`tests/skill/helpers/parity_helper.bash` + `tests/skill/cases/governor-parity.bats`, §3):
  `assert_parity` byte-compares against goldens; the empty-manifest and env-only mutations match too.
- **C3 — one liveness truth** (`pwt-lane-alive.sh`): exit 0 alive / 1 not-alive / 2 cannot-determine;
  alive requires positive PROCESS evidence corroborated (never the registry alone); confirmed-dead
  needs the ESRCH + no-`pgrep` conjunction (a stale pid HOLDS at exit 2); corrected `bg-spare`
  ownership (claim socket / pty-host child / live children — unclaimed spare and daemon never count);
  a `blocked` worker is process-alive. Wired into await-terminal (WORKER_GONE corroboration),
  pwt-status (lane-alive line), the DS1 Tier B spawn guard (confirmed-dead downgrade), and the lane
  guard (confirmed-dead RELEASE, memoized). Governed `liveness_cmd` consult records both answers to
  `plan-w-team-liveness-<slug>.jsonl` and prefers process on disagreement (NEVER created ungoverned).
- **O4** host-health orphan age floor (`PWT_HOST_ORPHAN_MIN_AGE_S`, default 300) + worktree-cwd exclusion.
- **C5 — truthful stop/resume**: `pwt-steer.sh` stops by the 8-char HANDLE (not the 36-char UUID — the
  confirmed root cause of the duplicate-lead incident), classifies the stop outcome (a genuine failure
  exits non-zero, never the old "continuing" line), refuses to resume while the old lead is
  process-alive, names EVERY sid on a live duplicate, resumes at the recorded manifest stage, and
  regains the FULL launch env via the shared `pwt-launch-env.sh` builder. New `pwt-resume.sh` fronts
  `plan-w-team-land.sh resume` (reuses worktree+UUID, refuses on terminal/landed) and adds a sanctioned
  gate-answered clear of an EVALUATOR-stamped terminal with provenance (`terminal_state_source=gate-answered:<actor>`).
- **Lane-guard D10 / D11**: D10 — exclude `MAIN_ROOT` from `ALL_WORKTREES` so a bound supervisor's
  `.claude/state/` Bash bookkeeping reaches the STATE_DIR allowance (protected artifacts still deny);
  D11 — mask heredoc bodies before redirect extraction (a markdown `> quote` in a heredoc is prose).
- **Landing `base_sha`**: the manifest records the run's base commit at spawn; the landing gate reports
  `NOT_LANDED / UNDIVERGED` for a branch with no commit beyond it (fixing the vacuous-ancestry false
  positive that made a watcher exit on false success), while every existing FF/squash/merge control stays green.
- **Spawn-test isolation** (§3, AC6): `run.sh` brackets the session registry (fail-open on an
  empty/invalid snapshot) and fails on a NEW background session left under a TMPDIR sandbox;
  `locate-claude.sh` honors `PWT_CLAUDE_BIN` and refuses the install-path fall-through under
  `PWT_CLAUDE_BIN_STRICT=1`.
- **Live evidence — this run itself**: resumed twice mid-flight (a 5-hour usage-limit death, then a
  process restart), demonstrating the C5 resume-at-recorded-stage requirement and the landing
  vacuous-ancestry false positive (the resume guard fired on this run's own undiverged HEAD).
- **Step-5 review hardening** (three read-only reviewers on the diff): (a) `pwt-lane-alive.sh` — a
  missing/erroring `pgrep` now returns `UNKNOWN`, not `0`, so it can never flip cannot-determine →
  confirmed-dead (AC8 conjunction is structural, not conventional); (b) governed `liveness_cmd` is
  REFUSED at runtime when the manifest is git-tracked and SKIPPED when no timeout binary exists
  (AC9's "with a timeout" / "never armed by a tracked manifest" clauses, enforced not just
  gitignored); (c) the confirmed-dead release memo joins the lane-guard protected set (a forged memo
  can no longer authorise a release); (d) `pwt-resume.sh` drops a `--env` flag the real
  `plan-w-team-land.sh` parser rejects (land.sh already forwards auto-approve-push itself); (e)
  `pwt-steer.sh` resume-at-stage now matches the REAL manifest vocabulary (`post-ship` routes to
  docs+retro instead of a full re-pipeline; `ship` re-verifies the landing instead of assuming it),
  keeps the manifest `run_sid` tracking the rotated lead so a SECOND steer still resumes at stage,
  and gives DUPLICATE-LEAD its own exit 8 (distinct from 7 = UUID-undiscoverable).

Every new behaviour has one kill switch that restores the prior behaviour. New scripts are
allowlisted in the sync; new state artifacts are registered; DIRECTION docs relocated to `docs/directions/`.

## [2.15.0] — 2026-08-29 (Lane guard decides by RESOLVED TARGET) (5a64f80)

**PWT-LANE1 out-of-repo scoping.** A bound supervisor's `git` writes and in-place edits
are now decided by the RESOLVED TARGET, not the command class. Committing in a DIFFERENT
repo (`git -C /abs/other commit`, `cd /abs/other && git commit`) or editing an absolute
file outside the lane repo (`sed -i '' … /abs/other/f`) is ALLOWED with an audit row; the
lane repo, its worktrees, and every relative / `$var` / glob / `~` / symlink-into-repo
target stay DENIED. Closes the internal inconsistency where the same file could be
`Edit`-ed but not `git -C`-committed or `sed -i`-edited (2026-08-29 incident: an operator
hand-ran three commits). D6 foreign-worktree-write, the kill switch, and the fail-open
`rm`/`mv`/`cp`+redirect/`tee` class are unchanged.

- **One shared predicate** (`__target_is_foreign`, over `__realpath_target` +
  `__path_in_repo`) is used by the Edit/Write path AND both Bash classes, so they cannot
  diverge again. Symlinks are followed (a symlink-into-repo denies); resolution is bash-3.2
  safe (bounded `readlink` loop + logical `cd+pwd`, python3 realpath backstop) — no new
  dependency.
- **Deliberate fail-closed vs fail-open policy**, documented in the hook header,
  `docs/operations/lane-enforcement.md` §"Resolved-target scoping", and `shared/gotchas.md`
  G13: git-write/in-place DENY on unresolvable (positive proof of "outside" required);
  mutator/redirect stay fail-open.
- **D7**: read-only listing forms (`git worktree list`, `git stash list|show`) are stripped
  before the write test like `git tag -l` (and audited as `classifier-exemption`).
  **D8**: `INPLACE_RE` is `${SEP}`-anchored so quoted prose "sed -i" is not classified.
  **D9**: the shell mask blanks a backtick inside single quotes so `` `git commit` `` in
  quoted prose is not a command boundary.
- **Operator allowance valve** `.claude/state/plan-w-team-lane-guard-allow-<sid8>.json`
  (`{"until","scope:"outside-repo"}`): relaxes ONLY the unresolvable branch, never a
  provably-inside target, and expires. Registered in `shared/state-artifacts.md`.
- **Adjacent findings**: **O1** — `pwt-status.sh` corroborates each lead row's `.pid` with
  `kill -0` and prints `N lead (M stale-registry)` (test seam `PWT_STATUS_AGENTS_OVERRIDE`).
  **O2** — no ps/lsof cwd-walking probe in claude-pattern enumerates `bg-spare` daemons;
  filed as a recursive-followups row with the evidence (nothing to fix here). **O3** —
  `pwt-steer.sh` prints the real stop outcome (stopped / already-gone / failed) instead of a
  generic note, and a fail-open loud advisory asserts exactly ONE live lead owns the slug's
  worktree after resume (reuses `pwt-live-session-cwds.sh`).
- **Security (independent review find, HIGH — git-dir/work-tree independence)**: git resolves
  its git-dir and work-tree INDEPENDENTLY, so a lone foreign `--work-tree` on `git push` (refs
  land in the CWD-discovered lane git-dir) or a lone foreign `--git-dir` on `git checkout`
  (files land in the CWD lane work-tree) would have read as a foreign write and ALLOWed — a
  bound supervisor could push/reset the lane by attaching a throwaway anchor. Fixed: the
  git-write resolver walks the command's segments (tracking the `cd`-established base) and
  requires BOTH the effective git-dir AND the effective work-tree of every git-write to be
  foreign. Regressions: the three git-dir/work-tree-independence cases + mutation M4.
- **Security (fix-first review find)**: a bound supervisor may write under `.claude/state/`,
  so it could write its OWN `plan-w-team-lane-guard-allow-<sid8>.json` and self-authorize the
  fail-closed branch (a relative in-repo `sed -i` would then pass). Closed: the guard now
  denies the bound supervisor writing any allowance valve (Edit/Write AND Bash redirect),
  exactly as it already denies the release valve. Regression: `T12-SEC`.
- **Corpus aligned to Model Tiering v5 (authorized scope expansion, origin-chat supervisor
  2026-08-29)**: the full-suite gate surfaced 8 pre-existing failures that 2.14.3 changed the
  SOURCE for (design = Fable 5, intelligent = Opus 4.8, Opus 5 FORBIDDEN) but never updated the
  CORPUS for — `model-tiering-v2.bats` (Hands/hard-lane/fallback pins), `model-tiering-v3.bats`
  fable-fanout (sanctioned-site sweep, manifest, agent set), `opus48-uplift.bats` AC1, and the
  `plugin-integration.bats` silent-failure-hunter pin. Aligned to v5 under governance guardrails:
  every negative guard STAYS negative, the Fable sanctioned set is an EXPLICIT allowlist (the four
  design agents), not a count; the r10 legacy allowlist is kept consistent. Adds
  `tests/skill/cases/model-tiering-v5.bats` — the canonical v5 negative guard (Brain = Opus 4.8,
  design = the four Fable agents, mechanical = Haiku, no agent/spawn-site/test requires Opus 5,
  no fan-out lane pins Fable). The code was already correct; only stale expectations moved.
- **Fixes the PWT-DISK2 worktree-cap full-suite red (authorized bounded scope, origin-chat
  supervisor 2026-08-29)**: `disk-budget.test.sh` [8]/[8c] failed deterministically because the
  test's `GENV` — which pins the capacity-gate env for hermeticity — omitted `PWT_MAX_WORKTREES`.
  The operator's ambient env raises it (`PWT_MAX_WORKTREES=18` from `~/.zshrc`), so the 10-worktree
  fixtures never reached the cap and the refusal/auto-GC-retry assertions silently no-op'd. The
  **code is correct** (the cap honors the documented `PWT_MAX_WORKTREES` override and defaults to
  10); the fix pins `PWT_MAX_WORKTREES=10` in `GENV` to restore the hermeticity the comment already
  claims. Test-only, ~1 line, no spawn-semantics change. disk-budget.test.sh 9/2 → 11/11.
- **Tests**: `plan-w-team-lane-guard.bats` 43 → 66 (T1–T12 + T12-SEC + git-dir/work-tree
  independence bypass trio + D7/D8/D9 + M1–M4
  mutation checks, every ALLOW with a DENY twin); `pwt-status.test.sh` +O1; `pwt-steer.test.sh`
  +O3 (EXPECTED_PASSES 87 → 95) and a fix for the pre-existing broken T4g assertion
  (a two-word `--fallback-model claude-opus-4-8` needle that the stub's one-arg-per-line
  argv.log could never match — it was failing the whole shell-test phase at baseline).

## [2.14.3] — 2026-08-29 (Model Tiering v5 — Opus 5 FORBIDDEN)

**Founder order (2026-08-29): "remove Opus 5 from ever being used; make sure you're using
Fable 5 or Claude Opus 4.8."** Opus 5 proved unreliable in fleet use (repeated refusals and
dead rungs under the CleanRev Shipyard, 2026-08), so the v4 generation rollover is reversed
and locked rather than treated as a drop-in pin move:

- **Brain tier = `claude-opus-4-8`** again: frontmatter pins for `team/builder-opus`,
  `team/supervisor`, `team/evaluator`, `team/validator`, `team/silent-failure-hunter`,
  `research-planning/security-gap-analyzer`, `research-planning/system-architect`,
  `research-planning/test-gap-analyzer`.
- `pwt-goal.sh`: `PWT_PRIMARY_MODEL` default at both bg spawn sites (worker + supervisor)
  → `claude-opus-4-8`; rationale comment rewritten. `pwt-steer.sh`: resume pin default →
  `claude-opus-4-8`. `plan-w-team-rate-limit-resume.sh`: attempt-2 step-down rung →
  `/model claude-opus-4-8`.
- **Tiers by the nature of the work** (second founder order, same day: "all design work
  needs to be Fable 5; all other intelligent helper work Opus 4.8; Sonnet can be used in
  things that don't require intelligence"): design agents `system-architect`,
  `ui-designer`, `style-theme-expert` → `claude-fable-5`; the routine builder lane
  `team/builder`, `react-typescript-specialist`, `rust-backend-specialist`,
  `stagehand-expert`, `claude-code-docs-updater`, `documentation-expert`,
  `performance-testing-specialist`, `unit-testing-specialist`, and every roster agent that
  was pinned to the alias `opus` (resolves to Opus 5 — banned as a pin) or `inherit`
  (`orchestrator`, `release-orchestrator`, `github-security-orchestrator`, `meta-agent`,
  `security-expert`, `api-expert`, `database-expert`, `code-review-expert`,
  `terraform-specialist`, `kubernetes-specialist`, `llm-application-specialist`) →
  `claude-opus-4-8`; `mechanical/*` stay Haiku. `PWT_FALLBACK_MODEL` defaults
  (`pwt-goal.sh` both spawn sites, `pwt-steer.sh`) → `claude-opus-4-8`.
- Fable tier keeps its guard (two sites + cap) — Fable does design, never fan-out
  building; its skip/refusal landing tier is Opus 4.8.
- Tests: `pwt-steer.test.sh` T4f/T4g expect the 4.8 primary and fallback pins;
  `agent-registry-check.bats` fixture pinned to 4.8. `opus48-uplift.bats` AC3 still passes —
  `claude-opus-5` remains in the manifest only as history (v4 note) and in the v5 note that
  forbids it.
- Manifest: Model Strategy table (Builder agents → Brain/4.8, new Design agents row,
  "Skip/refusal lands on Brain (Opus 4.8)"); Generation note (Model Tiering v5).

Consumer repos pick this up on the next `sync-to-project.sh`; the CleanRev fleet already
enforces the same rule at runtime (`sdk-organs/ladder.py` `FORBIDDEN_MODEL_RE`, watchdog/CE
ladders `claude-fable-5 claude-opus-4-8`, `dispatch-lane.sh` default `claude-opus-4-8`).

## [2.14.2] — 2026-08-22 (579f5c8)

**Name the flip condition, and make report-only data self-surfacing.** Closing note
from the Fable consult, adopted: a report-only mode with no recorded threshold
quietly becomes permanent — the same unfalsifiable state the originating ledger row
sat in for two months — and nobody opens 17 repos' retro JSONs by hand.

Two changes, both small:

- **`§8j-septies` auto-queues a follow-up when the candidate count is non-zero.**
  The next run's pre-flight in that repo prints it, so a non-zero result cannot go
  unread. Zero stays silent — that is the expected reading and needs no noise. The
  queued text tells the reader to check that repo's `.gitignore` for the
  default-deny `.claude/state/*` block FIRST, because a missing block is usually
  the real defect and repairing it is the correct fix rather than enabling
  deletion. (`plan-w-team-followups.sh` already ships to every consumer, so this
  works fleet-wide.)
- **The decision is written down with both outcomes and a count**
  (`worktree-lifecycle.md` §"The flip condition"): enable per-repo on any non-zero
  after ruling out a degraded gitignore; or, after **≥ 10 retros across ≥ 3 repos**
  all reporting zero, close the capability as **confirmed-inert** — keep the script
  and corpus, drop the call site. An inert call site running forever is worse than
  no call site, and that outcome is now as recorded as the other.

No behaviour change when the count is zero, which is every environment measured so
far.

## [2.14.1] — 2026-08-22 (0b8c658)

**Safety hardening of the untracked sweep, from a Fable spec consult that arrived
after 2.14.0 landed.** The Step-1 fan-out returned zero verdicts before the AC
freeze (recorded `NO_VERDICTS_RETURNED`); the consult reported afterwards. Its
findings were verified independently rather than accepted on faith, and the ones
that held are fixed here. Spec: the `## AMENDMENT — post-ship Fable consult` section.

**The value analysis was correct, and it changes the default.** The sweep's
candidate set is empty in every environment it actually runs in: the source
`.gitignore` (`:61-81`) already excludes the live per-run state classes from
`--exclude-standard`, and `sync-to-project.sh:1444-1487` ships a default-deny
`.claude/state/*` block to every managed consumer (2026-06-09). Measured in a
consumer fixture: **without** that block 2 files are removed, **with** it **zero**.
The only repos where the sweep has teeth are ones whose gitignore is degraded — and
there an un-gitignored `plan-w-team-goal-*.json` seed becomes deletable, so value
and risk are inversely correlated. `§8j-septies` is therefore **report-only by
default**; opt in with `PWT_RETRO_UNTRACKED_SWEEP_EXECUTE=1`. The dry-run still
records candidates in the retro JSON, which is how the evidence for flipping it
gets collected.

**A real data-loss window, closed.** The sweep shipped with liveness + a 30-minute
newborn grace and no lock veto. `git worktree add` writes the lock (carrying
`pid N`) at SPAWN, while the session becomes visible to `claude agents --json` only
on REGISTRATION — a gap measured at **~43 minutes** (`worktree-lifecycle.md:222`).
A worktree at minute 31–43 was past the grace, absent from the live-cwd set, and
sweepable while its owner was alive. GC veto 3 is now ported (live pid ⇒ keep;
unparseable reason ⇒ keep, fail-closed; dead pid ⇒ still reapable, GC parity) and
the newborn default is raised 30 → **60**, above the measured gap.

Three further gaps closed:

- **`claude-agents-extended.sh` is now REQUIRED** (missing ⇒ sweep nothing). The
  empty⇒blind rule only caught the ALL-empty case; the canonical probe's inclusion
  predicate drops `background`+`state:blocked` rows, so a probe returning other
  live sessions while blind to a blocked worker passed both the gate and the in-use
  veto. The GC tolerates the helper's absence because it has three more vetoes and
  writes a backup; this sweep has neither.
- **The sweep gets its own `PWT_SWEEP_DISCARD_IGNORE`** (defaulting to the preserve
  set). Reading `PWT_WORKTREE_GC_PRESERVE_IGNORE` gave one env var opposite safety
  directions — widening means "back up less" for `preserve_then_reap` and "delete
  more" here, so trimming backup volume would silently widen the fleet's delete set.
- **Class SYNCED now requires MODE equality**, not just byte equality.
  `git hash-object` is blind to the executable bit, so a `chmod +x`'d copy was
  byte-identical to the ref yet not reproducible by `git checkout <ref> -- <path>`.

Spec holes closed: the class-SYNCED prefix list is now written down
(`PWT_SWEEP_SYNCED_PREFIXES`, default `.claude/:tests/skill/:docs/operations/`) and
GATE-0's `<repo>` resolution is pinned to `--git-common-dir` (never
`--show-toplevel`, the 1.29.0 seed-mislocation bug class).

Not taken, with reasons recorded in the spec: deriving the discard set by `comm -23`
instead of `FILTER_INVERT` (sound, but the matcher is already shipped, tested and
green fleet-wide — churning it again is now the larger risk), and holding the
consumer sync entirely (superseded by the report-only default: what ships is a
non-destructive reporter, and shipping it is what collects the per-repo evidence).

Tests: sweep corpus 53 → **67** (lock veto live/unparseable/dead-pid, required
extended helper, own discard knob, mode equality — each with a positive control).

## [2.14.0] — 2026-08-21 (6fd991d)

**Worktree-scoped untracked sweep — the first cleanup path with FILE granularity.**
Closes recursive-followup row 17 (WT-5, 2026-06-08 cleanup-eval). Spec:
[`docs/specs/resolve-recursive-followup-row-17-cleanup-eval-2026-06-08-wt-5-deferred-no-clean-c8448fc5.md`](../../../docs/specs/resolve-recursive-followup-row-17-cleanup-eval-2026-06-08-wt-5-deferred-no-clean-c8448fc5.md);
operations doc: [`docs/operations/worktree-lifecycle.md`](../../../docs/operations/worktree-lifecycle.md)
§"Untracked sweep".

Every cleanup path in this subsystem reclaimed a **whole worktree**. Nothing ever cleared a
file *inside* one that survives, which left two gaps: a worktree the GC keeps — in-use,
unmerged, `ORPHAN-ASK`, or held by any fail-closed arm — accumulated untracked churn
forever (the 2026-06-08 audit measured 48–52 untracked `.claude/*` files in one); and
`preserve_then_reap`, which filters backups with the NARROW preserve set, copied that churn
into **every** backup as if it were authored work, burying the files the backup exists to
save.

`plan-w-team-worktree-untracked-sweep.sh` (dry-run default, `--execute`, `--json`,
`--print-classified`) runs at retro §8j-septies **before** both GC passes. It removes two
classes and keeps everything else:

- **STATE** — matches the BACKUP ignore set, i.e. the set `preserve_then_reap` already
  declines to save, **minus a durable keep-list**.
- **SYNCED** — under a synced-tooling prefix **and** hashing to the same blob the default
  branch stores for that path.
- **AUTHORED** — everything else, including every path whose class could not be PROVEN.
  A brand-new `.claude/` script, an edited copy of a synced file, and `output/*.html` all
  survive.

**The invariant is recoverability, not disjointness — the first draft got this wrong.** The
spec claimed the sweep never removes anything `preserve_then_reap` would back up. The oracle
test disproved it on its first run: class SYNCED *does* remove such files, because
`.claude/` is absent from the narrow backup set. That claim was a proxy and the proxy was
false; keeping it would have meant deleting a true test or gutting class SYNCED to satisfy a
property that never mattered. What makes a removal safe is that the bytes can be got back,
and a reachable git object is *strictly stronger* than a backup copy. Class STATE is proven
by disjointness from the backup set; class SYNCED by restoring the file after real removal
and byte-comparing. Both non-vacuously.

**A blanket `.claude/state/` discard would have destroyed durable data.** `.claude/state/`
is in the BACKUP ignore set because a worktree being *destroyed* has worthless per-run
state — but this sweep runs on worktrees that *survive*, and six `.claude/state/` artifacts
are declared cross-run DURABLE by `shared/state-artifacts.md`, including
`plan-w-team-recursive-followups.jsonl`, the ledger this row came from. They are excluded by
a keep-list the corpus **re-derives from the registry**, so a future durable artifact cannot
silently become sweepable.

Five fail-closed gates (lib, python3, liveness, default-ref, per-worktree in-use/newborn),
each sweeping NOTHING rather than guessing, in VETO-0-correct order — only the pure-shell
realpath containment check may precede the python3 probe. One deliberate divergence from the
GC and on-merge: an **empty** liveness result with no failure token is treated as blind. The
GC can read "no rows" as "nothing live" because it has three further vetoes and writes a
backup first; this sweep has neither.

Gitignored trees (`node_modules/`, `dist/`, `build/`) are **out of scope by construction** —
`--exclude-standard` never lists them. `worktree-deps-share.sh` may back them with a shared
store, and deleting through a shared symlink would destroy it for every other worktree.

Shared-module change: `PWT_DIRTY_FILTER_PY` gains a `FILTER_INVERT` mode and
`__pwt_path_discard_filter`, so the sweep gets the complement of the ignore-token partition
from the **same** matcher — a fourth private copy would have been the most dangerous of the
four, because this one decides what to delete.

Two bugs caught by the corpus rather than by review:
`paths=$(git ls-files -z)` silently drops every NUL (bash cannot hold NUL in a variable), so
the read loop found no delimiter and processed **zero** files while every guard reported
success — a sweep that scans nothing and calls itself clean; now a temp file, pinned by a
`scanned > 0` regression. And the row accumulator used TAB as its `read` IFS, which is
IFS-*whitespace*: runs collapse and empty fields drop, shifting every later column. Switched
to US (`\x1f`) and pinned structurally.

Tests: new corpus **53 cases**, 8/8 mutations verified RED; `plan-w-team-dirty-ignore-lib`
59 → **66**; GC and on-merge unchanged. Sync allowlist updated so both new files reach the
managed consumers.

## [2.13.0] — 2026-08-19 (6204909)

**The landing gate — a run that ships but does not LAND can no longer report SUCCESS.**
The two deltas queued against 2.12.0, shipped together: RC4 (F6/F7/F8) from the source
spec's ADDENDUM, and the README permission story that is its other half. Spec:
[`docs/specs/pwt-host-load-and-stall-protection.md`](../../../docs/specs/pwt-host-load-and-stall-protection.md)
(**AMENDED**, not superseded — see its new `## DELTA RESOLUTION` section); run spec:
[`docs/specs/process-the-two-queued-deltas-for-the-just-landed-plan-w-team-v2-12-0-host-load-128610c0.md`](../../../docs/specs/process-the-two-queued-deltas-for-the-just-landed-plan-w-team-v2-12-0-host-load-128610c0.md);
operations doc: [`docs/operations/plan-w-team-landing-gate.md`](../../../docs/operations/plan-w-team-landing-gate.md).
Closes recursive-followup row 142.

A 15-hour run completed **all 8 stages** — `retro-complete` at 13:21:11Z, retro captured,
tag created — and landed **nothing**. The worktree branch sat 31 commits ahead of master;
local master and origin/master had none of them; the tag existed only locally;
`terminal_state` stayed `null`, so the run was simultaneously "finished" (stage events)
and "still open" (goal-state). The watcher kept exiting 3 over the corpse because its
liveness check read PRESENCE only. Recovery was a manual resume that lived in exactly one
supervisor's context.

Root cause: PWT-WT1 made merge-to-default an **honor-system step** — "ExitWorktree happens
implicitly when the session ends (or explicitly after Step 8 retro **if you want** the main
checkout to inherit the merge)". For an autonomous run whose done-when includes a landed
version + tag, "if you want" is exactly the class the Rule-Enforcement Invariant bans. And
the ending is **deterministic, not occasional**: the bg worker gets no permission-mode flag
and `</dev/null` stdin, so the ship-stage `git push` prompt **auto-rejects with no visible
trace**; `PLAN_W_TEAM_AUTO_APPROVE_PUSH=1` clears only the SKILL's push-ack gate, one layer
above the harness permission that was never granted.

**The permission story, decided.** The addendum demanded an explicit choice and offered two.
2.13.0 takes the second: **push is a user-owned grant**, and the fix makes the denial LOUD
rather than automatic. Granting `git push` at spawn was rejected because it installs a
security decision invisibly — the same principle the README delta states in its own words.

- `feat` **F6 — landing is a verified artifact, ANDed into SUCCESS.** New
  `.claude/scripts/plan-w-team-land.sh` owns the predicate in ONE place (the gate and the
  remediation must never disagree): `merged` accepts **ancestry OR tree-equality** — the
  latter because §6g-ter's `gh pr merge --squash` puts the work in a NEW commit that the
  branch tip is nobody's ancestor of, and an ancestry-only predicate would have refused the
  pipeline's own sanctioned path — plus `tag_reachable` and `pushed`; no remote ⇒
  `pushed:"n/a"` so a local-only repo can still land. `verify` writes
  `.claude/state/plan-w-team-landed-<slug>.json` **only on a true verdict** and **removes**
  it when the predicate turns false, so a rewound landing cannot keep passing; there is no
  `--force` and no caller-asserted path, because the artifact IS the gate.
  `plan-w-team-surface-status.sh` reads it into a `landed` field plus a bare, grep-able
  `landed=<sha>` line. `plan-w-team-goal-evaluator.sh` withholds SUCCESS for a
  worktree-isolated run without one, naming the failed check and all three remediation
  commands. **Scoped, not global:** isolation is read from the run manifest's
  `worktree_path` and from nothing else. An earlier revision of this change also accepted
  "the goal-file PATH contains `/.claude/worktrees/`" — that conflates "this RUN is
  worktree-isolated" with "this CHECKOUT happens to live under a worktrees directory", and
  it false-fired across the entire evaluator + antipark shell corpus (those harnesses point
  `PWT_PROJECT_ROOT_OVERRIDE` at the repo root, and claude-pattern's own repo root IS a
  worktree whenever the skill self-hosts). A path SPELLING is not a fact about a run;
  `worktree_path` is, and `pwt-manifest.sh` writes it at every stage. Indeterminate ⇒ gate
  SKIPPED, leaving every non-worktree run byte-for-byte unchanged — and that is not a hole
  in practice, since a run with no manifest never emitted a status block and therefore never
  emitted `retro-complete` either. Fail-CLOSED on the artifact (C3's contract),
  fail-OPEN on the git re-verification (a Stop hook that errors is worse than one that
  under-tightens). New `merge` subcommand carries the dirty-tree protocol as CODE rather
  than stage-file prose — AC8 requires it proven by content comparison, and the shared stash
  stack means unique tag → capture SHA → **apply** (never `pop`) → drop by re-found tag.
  Kill switch `PWT_DISABLE_LANDING_GATE=1`.
- `feat` **F7 — the watcher stops heartbeating over a corpse.**
  `plan-w-team-await-terminal.sh` adopts PWT-DS1 Tier B's exclusion predicate
  (alive = present AND `state` ∉ {blocked, done}) and exits **6** on dead-but-unflipped,
  with a diagnosis naming the last stage event: `COMPLETE_UNLANDED` (land it) vs
  `DIED_MID_<stage>` (resume the work) — two cases that need opposite supervisor actions.
  A row with **no** `.state` counts as ALIVE: interactive rows carry `status`, background
  rows carry `state`, and narrowing a liveness predicate must never invent a death.
  **The TERTIARY coupling is what makes F7 reachable at all** — the transcript-success
  detector runs first, and the RC4 worker had `retro-complete` + every criterion `met:true`,
  so it would have certified `terminal=SUCCESS source=transcript` for the exact ending this
  work prevents; it now consults the same landing artifact and withholds. Kill switch
  `PWT_DISABLE_UNFLIPPED_DETECT=1`, deliberately distinct from F6's (the addendum requires
  the landing-gate switch to leave watcher and remediation working).
- `feat` **F8 — resume-to-land is scripted, not runbook knowledge.**
  `plan-w-team-land.sh resume` refuses (exit 6, nothing mutated) when already landed,
  already terminal, missing a `worker_sid`, or missing `pwt-steer.sh` — every refusal
  audited to `plan-w-team-land-audit.jsonl`, so a refusal is as diagnosable as an action.
  It **delegates** stop+resume to `pwt-steer.sh` rather than reimplementing the three traps
  that script closes by construction (36-char UUID vs 8-char handle, resume from inside the
  worktree, launch-succeeded ≠ delivery-succeeded) plus its goal-state bookkeeping and
  old-watcher teardown. `pwt-steer.sh` gains `--env KEY=VALUE` for the one thing it lacked —
  a resume loses the launch-time environment — and **refuses**
  `PLAN_W_TEAM_DISABLE_PROMPT_ROUTE` as a key, because that is the PWT-DS2 cascade guard,
  not a knob. It **never writes `terminal_state`**: the lane guard refuses supervisor writes
  to that field as self-termination spoofing (observed live 2026-08-19), so the flip must
  come from the resumed session's own Stop evaluator. Asserted by test, not just documented.
- `docs` **The permission story, where the operator meets it.** README gains a Step-7
  "Push authorization for unattended goals" subsection (the auto-rejection, the two ways to
  handle it, the narrow allowlist entries, and why a trailing wildcard also matches
  `--force`), a `settings.local.json` three-layer reference section after "What Gets Synced",
  and a Step-2 collaborator-vs-maintainer parity paragraph. New
  `dotfiles/claude/settings.local.template.json`; `setup-new-project.sh` installs it **only**
  when the target has no overlay and never touches an existing one.
- `test` `tests/skill/cases/landing-gate.bats` (33 cases: AC8/AC9/AC10) and
  `tests/skill/cases/permission-story.bats` (AC11–AC14). Four are deliberate **positive
  controls** — a non-worktree run still reaches SUCCESS, a live worker still heartbeats, a
  `.state`-less row counts as alive, a reachable tag passes — because a gate that refuses
  everything is as broken as one that refuses nothing.
- `chore` `plan-w-team-land.sh` added to the `sync-to-project.sh` allowlist (copy line **and**
  dry-run line): §6i, the evaluator and the watcher all sync and all name it, so a consumer
  without the script would exit 1 at ship and then block SUCCESS forever on a remediation
  command that does not exist. Both new artifacts registered in `shared/state-artifacts.md`;
  `landed` added to the Status-Block Schema in `shared/goal-conditions.md`.

**Deliberately NOT done** (still open, with reasons): followup row 147 — narrowing
`pwt-live-session-cwds.sh`'s inclusion predicate is a NEIGHBOUR of F7, not part of it, and
needs a fleet-wide scope decision the periodic GC and `plan-w-team-zombie-prune.sh` must both
sign off on (they genuinely disagree on whether `blocked` means alive). Followup row 143 —
registering the lane guard as a one-way-door surface changes merge behaviour across 17
consumer repos and is its own delta.

## [2.12.0] — 2026-08-19 (3bab477)

**Host-load protection, verification stall detection, and lane-guard hygiene** — the
2026-08-19 incident response. Spec: [`docs/specs/pwt-host-load-and-stall-protection.md`](../../../docs/specs/pwt-host-load-and-stall-protection.md)
(promoted verbatim from the authoring repo); operations doc:
[`docs/operations/host-load-protection.md`](../../../docs/operations/host-load-protection.md).

A 14-hour run spent **4.5 hours** looping on "Running the full suite and validators…" with
no commit, no stage event and no alert — and **the only active process on the machine was
that run**. It starved itself: the statusline spawned an unbounded, uncached, un-singletoned
`ccusage` per render; `ccusage` re-parses the transcript corpus, so its cost grew with the
run's own output (longer run → bigger transcripts → costlier helper → slower host → longer
run); load hit 24–27 on 12 cores; the full suite crawled past the Bash tool's 600s cap; each
timed-out call leaked its whole process tree (~17 orphan wrappers + 40-min-old hung pytest);
and the step was retried blindly every ~10 minutes with nothing written down. The human
asking "is it stuck?" was the detection mechanism. Three independent root causes, five fixes,
one kill switch each.

- `feat` **F1 — the spawn source is gone.** New `.claude/scripts/ccusage-blocks.sh` (a fourth
  statusline helper, same shape as `plan-usage.sh`/`usage-breakdown.sh`/`account-info.sh`):
  lean gate first, then a **REQUIRED** real bound (`gtimeout`→`timeout`→**skip**; the
  unbounded fallback is DELETED, not hidden behind a flag), a `mkdir` singleton, a 60s cache,
  and a `nohup`-detached refresh so a cancelled statusline cannot orphan a half-run helper.
  `statusline.sh` no longer contains any `ccusage` call of its own and skips
  `usage-breakdown.sh` (the other transcript-corpus parser) in lean mode. `pwt-goal.sh`
  exports `PWT_LEAN_STATUSLINE=1` into **every** bg spawn via `LAUNCH_ENV` **and** the
  bare-fallback branch; the supervisor protocol + manifest Step 3c export it for the duration
  of supervision. Kill switch `PWT_DISABLE_LEAN_STATUSLINE=1`.
- `feat` **F2 — the executor has stall semantics.** New
  `.claude/scripts/plan-w-team-verify-run.sh` runs a command as the leader of its **own
  process group** (`set -m`), so a bound firing reaps the whole tree (TERM → grace → KILL)
  instead of orphaning it. The zero-surviving-descendants contract is **measured**, not
  assumed: `orphans_after` is enumerated and recorded in every stall event. Retry cap
  **K=3** per `(slug, step)` behind a `mkdir` lock (without it two runners each read "2" and
  both proceed, granting a 4th attempt against a cap of 3); at the cap the runner REFUSES to
  execute the command, runs a mandatory host-health diagnosis, writes the distress artifact,
  and requires an explicit degraded-mode-or-halt choice. Exits `10` STALL_TIMEOUT / `12`
  STALL_CAP_EXCEEDED. Wired into `03-execute.md` (protocol) and `05-ship.md` §6b, where a
  stall verdict is surfaced as a HOST verdict and never laundered into "the suite is red".
  Kill switch `PWT_DISABLE_STALL_DETECTION=1`.
- `feat` **F3 — the supervisor watches the host, not just the worker.**
  `plan-w-team-await-terminal.sh` samples host health on its existing loop and exits **5** —
  distinct from `0` terminal / `3` re-arm / `4` duplicate — when a breach repeats on two
  consecutive samples, emitting a proactive `⚠ HOST-DISTRESS` block naming the consumer and
  the evidence. Strictly additive and ordered AFTER the terminal checks, so a real terminal
  always wins. Exit 5 is **not** a reason to end the run (P3 no-caps is untouched). Kill
  switch `PWT_DISABLE_HOST_DISTRESS=1`.
- `feat` **shared sampler** — new `.claude/scripts/plan-w-team-host-health.sh` (load, ncpu,
  top consumers, non-lane max %CPU, lane orphans, `load_suspect`, `breach_reasons`). One
  sampler, three consumers (F2/F3/F5) rather than three copies of a load parser. Lane
  processes are EXCLUDED from the runaway-CPU signal (the run's own builders are supposed to
  use CPU) and are the only ones counted as orphans. Fail-open: it never claims distress it
  cannot evidence.
- `fix` **F4 — the lane guard stopped blocking its own incident response.** Two classifier
  false-positives shared one root cause — the guard read shell TEXT as shell STRUCTURE. New
  `__mask_shell_text` neutralizes operators inside quotes and blanks command substitutions
  **before** any extraction, so `awk '$3 > 50'` is no longer a redirect and
  `mv "$(command -v ccusage)"` no longer sheds the fragment `` ccusage)" ``. Path characters
  inside quotes are PRESERVED, so `rm -rf '/repo/src'` still denies — a test asserts the
  masking cannot widen the permit set. `git tag -l`/`--list` is exempted as read-only while
  `git tag v1` and `git tag -l && git commit` still deny. New host-hygiene ALLOW class for
  BOUND supervisors: `kill`/`pkill`/`killall`/`renice` (evidence, not new authority — these
  were never denied), and `mv`/`cp`/`ln`/`rm` when **every** resolvable target is provably
  outside the repo **and every path in `git worktree list`**. `__audit` now records ALLOWs as
  well as DENYs, with the "no live lane" path deliberately excluded as a disk-exhaustion
  vector. Kill switch `PWT_DISABLE_LANE_GUARD_HYGIENE=1` (narrowing only — there is no
  widening env var).
- `feat` **F5 — durations carry their load context.** `plan-w-team-test-green.sh` records
  `load_1m`, `ncpu` and `load_suspect` beside `duration_s`; `shared/qa-tiers.md` carries the
  `load-suspect` annotation rule for hand-filled ledger rows. Observability only, no gating
  change (the same battery command measured 229/252/302/454 s purely by load). Kill switch
  `PWT_DISABLE_LOAD_ANNOTATION=1`.
- `fix` **four self-inflicted defects caught while building this**, three of them the same
  "fail-open on an input we actually HAVE" class the incident itself is made of:
  (1) the sampler handed its lane set to `awk -v`, which rejects a newline in the value —
  with no worktrees the string ends in one, awk exited non-zero, the `|| echo ""` swallowed
  it, and the ENTIRE process table normalized to empty (`max_nonlane_pcpu: 0` on a host that
  is on fire). Now passed through the environment.
  (2) `jq '.load_suspect // "null"'` rewrites every honest `false` into `null` — jq's `//`
  fires on `false` as well as `null` — silently deleting the "NOT load-suspect" evidence the
  annotation exists to provide.
  (3) with no breach reasons, `printf '%s' "" | jq -R` emits NOTHING while exiting 0, so
  `--argjson breach_reasons ''` failed the whole emit and dropped the sampler into its
  jq-ABSENT fallback, where `top_consumers` is hardcoded `[]`. Net effect: on any healthy
  host the sampler named no consumers at all, so the `⚠ HOST-DISTRESS` block could never
  say WHAT was starving the run — the one field it exists for. Every stubbed test took the
  breach path and missed it; only running the sampler for real surfaced it.
  (4) the stall runner's watchdog was killed by pid, orphaning its `sleep` for the remainder
  of the bound — an orphan produced by the very script whose contract is "zero surviving
  descendants". It now runs in its own process group and is group-killed.
  All four now have regression tests, and (1)–(3) are written up in the operations doc so
  the next author does not re-introduce them.
- `perf` the lane guard's shell masking is computed **lazily**, only once a live lane is
  confirmed and the tool is Bash. The hook fires on every Bash call in every session on the
  machine, and masking them all would add an awk spawn per tool call host-wide — the exact
  per-call spawn cost this release exists to remove.
- `fix` **registry gap (pre-existing).** `.claude/state/plan-w-team-ds1-audit.jsonl` shipped
  in 2.10.0 without a `shared/state-artifacts.md` entry, so `plan-w-team-symmetry-check.sh`
  reported an orphan reader (exit 4) — the exact "writer pointing at a wholly undeclared
  file" case the registry exists to catch. Registered; the check is green again.
- `test` **49 new cases**: `tests/skill/cases/host-load-protection.bats` (34 — AC1/AC2/AC3/AC5,
  including a grandchild-reaping proof and a per-fix kill-switch assertion) and 15 AC4 cases
  appended to `tests/skill/cases/plan-w-team-lane-guard.bats`. All 28 pre-existing lane-guard
  cases still pass unchanged — the invariant that mattered most for a one-way-door change.
- `chore` all three new scripts added to `sync-to-project.sh` (plus the dry-run listing);
  `ccusage-blocks.sh` carries an explicit comment because it does not match the
  `plan-w-team-*`/`pwt-*` prefix the allowlist checker enforces.
## [2.11.0] — 2026-08-19 (213a323)

**WT-2 — the per-merge ship path and the periodic GC now share ONE dirtiness policy.**
Resolves the `open` recursive follow-up queued by the 2026-06-08 `cleanup-eval` retro.

`plan-w-team-worktree-on-merge.sh` invariant 2 tested **raw porcelain** with no ignore
filter, making it stricter than `plan-w-team-worktree-gc.sh`. Because hooks rewrite
`.claude/state/*` into every worktree, ship-time reclaim skipped nearly every worktree the
periodic GC would have reaped — the leak was masked only because the GC swept up later.
Measured before the fix on a merged worktree whose entire porcelain was `?? .claude/`:
GC reported `uncommitted: false`, on-merge reported
`safe-skip: uncommitted changes in worktree (invariant 2)` and left the worktree on disk.

- `feat` **`plan-w-team-dirty-ignore-lib.sh`** — new sourceable module that is the SINGLE
  definition site for `PWT_DIRTY_IGNORE_DEFAULT`, `PWT_PRESERVE_IGNORE_DEFAULT`,
  `PWT_DIRTY_FILTER_PY`, `__pwt_dirty_ignore_filter`, `__pwt_path_ignore_filter`,
  `__pwt_tracked_dirty`, `__pwt_python_ok`, `__pwt_copy_files` and `preserve_then_reap`.
  Both cleanup scripts source it; neither carries a private copy. This is the structural
  fix for a recurring class — 1.41.0 had to patch the same leak twice because two sites
  held their own ignore sets, and WT-2 then found a third answer in on-merge.
- `fix` **on-merge adopts the GC's whole dirtiness contract, not just its filter.** The
  filter is only the *loosening* half; shipping it alone would have traded a leaked
  worktree for destroyed authored work (the 2026-07-30 loss class). Invariant 2 is now
  ordered: tracked dirt → absolute veto (ignore set does not apply, pure shell so it
  survives a broken python3); unevaluable guard → strict raw-porcelain skip; filtered
  remainder → skip; then `preserve_then_reap` before the destructive removal, with a
  failed backup aborting the removal.
- `fix` **fail-safe on unevaluable guards — on-merge gains a hoisted VETO 0.** The matcher
  runs in python3, and a broken interpreter emits nothing — indistinguishable from
  "clean". on-merge now probes first and degrades to *keep* on a missing module
  (`PWT_DIRTY_IGNORE_LIB`) or a broken interpreter, never to *clean*. The check sits
  **above every invariant**, not inside the dirt branch: a CLEAN worktree skips that
  branch, and invariant 3 (in-use) is *also* python3-backed — it returns an empty
  live-cwd list when the interpreter is broken — so a merged-but-live worktree would
  otherwise be removed with its in-use veto never evaluated. Found while writing the
  test, not by reading. The GC folds a missing module into its existing VETO 0, and its
  fail-closed reason now names the ACTUAL cause (a missing module no longer reports
  "python3 unavailable", which would send a fleet-wide keep-everything to the wrong place).
- `fix` **`preserve_then_reap` now backs up untracked CONTENT, not just filenames.**
  `git status --porcelain` collapses a wholly-untracked directory to one `?? dir/` entry,
  so the old patch recorded a directory name while the files inside were destroyed with
  the worktree. Untracked paths are now enumerated with `git ls-files --others` and copied
  into `<name>-<ts>.files/`. Benefits both callers. This mattered here because closing the
  leak is what makes on-merge start deleting these worktrees at all.
- `fix` **the untracked enumeration passes `core.quotePath=false`.** With git's default, a
  path holding non-ASCII bytes returns double-quoted and octal-escaped
  (`".claude/hooks/caf\303\251.sh"`). That string names no file on disk, so the copy
  failed, `preserve_then_reap` returned non-zero, and the caller skipped the removal —
  ONE accented filename anywhere in a worktree would have silently re-opened the very
  leak this release closes. It failed safe (never lossy), but it was still wrong. Spaces
  do not trigger quoting; non-ASCII does. Found by testing the shadow path, not by review.
- `refactor` the orphan-dir arm's inlined prefix/segment matcher (a fourth private copy of
  the token semantics) now calls the shared `__pwt_path_ignore_filter`.
- `test` `plan-w-team-dirty-ignore-lib.test.sh` (new, 59 cases) — including a mechanical
  single-source-of-truth guard that fails if any shared symbol, or the ignore token list
  itself, is ever defined in a second file, the both-consumers-fail-closed matrix, and the
  unusual-filename round trip. `plan-w-team-worktree-on-merge.test.sh` grows the GC-parity
  set including the backup-failure abort (26 → 50). GC suite unchanged at 131/131 (the
  move is a relocation). Full skill suite 1249/1249.
- `chore` `sync-to-project.sh` ships the module + its test (explicit allowlist entry AND
  dry-run listing) ordered BEFORE the two scripts that source it.
- `docs` `docs/operations/worktree-lifecycle.md` — the shared-policy banner, the
  "when the filter cannot be evaluated" degradation matrix, and what the backup saves.
- `chore` **CLAUDE.md size ratchet repaired** (pre-existing red, not caused by this work):
  the `claude-md-size` live anchor was already failing on main at 40688 chars vs the
  40000 limit (from `1c14d06`). Since this run's definition-of-done requires 100% of
  tests passing, it had to go green to ship. Information-preserving: the two
  self-described-historical Model Tiering v2/v3 notes were consolidated (canonical copy
  lives in the skill manifest) and markdown table alignment padding was collapsed across
  53 rows. 40688 → 36717 chars.
- `fix` **on-merge invariant 3 reaches fail-closed liveness parity with the GC.** WT-2
  *loosens* invariant 2, so on-merge now reclaims worktrees it used to safe-skip on any
  dirt — which makes invariant 3 (in-use) load-bearing where a dirtiness veto used to
  backstop it. But on-merge never consulted the canonical `pwt-live-session-cwds.sh`
  probe and had no `LIVE_QUERY_FAILED` arm: a missing/non-executable helper, or the
  known-flaky empty-but-exit-0 `claude agents --json`, left `LIVE_CWDS` empty and skipped
  the in-use check **entirely** rather than keeping the worktree. On the 2.9.0
  `.pwt-shipped` force path — where invariant 2 is deliberately relaxed and invariant 3
  is the *sole* remaining protection — that could force-remove a worktree with a live
  session in it. on-merge now mirrors the GC's 2026-06-07 mid-flight-reap contract:
  canonical probe first, `__QUERY_FAILED__`/missing-helper ⇒ fail closed ⇒ KEEP, and
  `claude-agents-extended.sh` demoted to an **additive-only** secondary source that can
  add protected paths but never clear the fail-closed flag.
- `fix` All surviving `git status --porcelain` call sites in the three cleanup scripts now
  pass `-c core.quotePath=false`, so every path enumeration in the module speaks one
  dialect (aligns them with the `ls-files` site fixed in 2.8.0). Consistency, not a
  verdict change — the shared filter already stripped the surrounding quotes.
- `docs` `05-ship.md` §6h now states what a `--worker-only` run with no supervisor does
  when the auto-mode classifier denies the cross-checkout merge — the branch is landed by
  pushing it to `origin/main` as a verified fast-forward, and the stale local `main`
  checkout is reported to the operator. Closes the OPS follow-up from the run-2 retro.
- Spec: `docs/specs/resolve-recursive-followup-row-16-cleanup-eval-2026-06-08-wt-2-medium-deferred-p-1a44b2dd.md`
  (the previously-cited `worktree-on-merge-dirty-ignore-parity.md` was never written —
  dangling reference corrected).

## [2.10.0] — 2026-08-18 (7e20b16)

**Double-spawn defense rebuilt after the cleanscale trifecta (3rd recurrence; rootcause:
`docs/specs/pwt-double-spawn-rootcause-2026-08-18.md`).** Two workers spawned 4m03s apart for
the same task because ALL THREE defense layers failed at once: the hook's systemMessage was
silently dropped (L1), the manual spawn landed just outside Tier A's 3-min window after
legitimate mandated pre-spawn work (L2), and Tier B failed open (L3). Fixes F1–F4+F6; F5
remainder queued in the follow-ups ledger.

- `fix` **F3 (the sharpest finding — Tier B was STRUCTURALLY INERT since 2.6.0).** The Bug C
  liveness filter tested `state ∈ busy|idle` — values `.state` NEVER takes (busy/idle live in
  the separate `.status` field; bg rows carry `state ∈ working|blocked|done`, verified on CLI
  2.1.233 AND 2.1.235). It matched nothing → Tier B could never positively confirm → never
  refused (the cleanscale L3 fail-open), and worse, `__pwt_owner_liveness` read a LIVE working
  owner as "dead" — the 2.6.0 seed auto-reclaim could have stolen a live lane's goal-state. All
  three predicates flipped to EXCLUSION (alive = present AND state ∉ {blocked, done}) — correct
  on every observed schema generation and drift-proof (an unknown new state value reads alive →
  the safe direction at every call site). Also fixed a latent copy-divergence: the real
  owner-liveness path still carried cwd scoping the fixture-seam copy had dropped.
- `feat` **F2 — same-origin wide window (Tier A).** When the hook-spawn flag's filename sid8
  matches the CALLER's own session id, a `PWT_DOUBLE_SPAWN_SAMEORIGIN_WINDOW_MIN` (default 30
  min) window applies instead of the 3-min default — the incident's 4m03s gap was legitimate
  skill-mandated work (disk preflight + briefing + lane-guard denial). Cross-session flags keep
  the short window.
- `feat` **F3 — goal-state fallback + audit trail.** Tier B now also refuses on CLI-independent
  evidence: a recorded worker owning a live (`terminal_state: null`, fresh) goal-state — covers
  an unavailable listing or another schema drift. EVERY Tier A/B verdict (refuse AND proceed) is
  appended to `.claude/state/plan-w-team-ds1-audit.jsonl` so the next incident is diagnosable
  from disk (the incident's Tier B verdict was unrecoverable).
- `feat` **F1 — manifest Step 3a is a DISK READ, not marker attention.** Before ANY
  `pwt-goal.sh` call the lead MUST read `.claude/state/plan-w-team-hook-spawn-<self-sid8>.flag`
  and treat it as authoritative when fresh (~30 min) or its worker owns a live goal-state —
  systemMessage delivery is proven droppable, so marker absence proves nothing.
- `feat` **F4 — flag hygiene.** `plan-w-team-zombie-prune.sh` reaps hook-spawn flags whose
  worker is provably finished (terminal goal-state, or absent from a valid listing + older than
  `PWT_FLAG_REAP_HOURS`, default 24). Live/indeterminate → KEEP (reaping a live flag would
  disarm the guard). Kill switch: `PWT_ZOMBIE_PRUNE_NO_FLAG_REAP=1`.
- `docs` **F6 — hook nondeterminism documented** in the route-hook header: firing is not
  inferable from context in EITHER direction (message drops; mid-turn triggers bypass
  UserPromptSubmit) — the flag file is the only authoritative record. Rootcause DIRECTION doc
  promoted to `docs/specs/`. F5 remainder (stop+resume lane continuity via pwt-steer /
  evaluator DEAD-propagation; lane-guard BUILDER_RE quoted-goal exemption) queued in the
  follow-ups ledger under `pwt-double-spawn-guard`.
- `test` Double-spawn suite grows 34→44 ACs: the incident case itself (live worker with REAL
  `state:"working"` → Tier B refuses — failed open pre-F3), same-origin wide window,
  cross-origin control, goal-state fallback, audit-trail assertions; zombie-prune 16→20 (flag
  hygiene). All 18 pwt-goal suites green.

## [2.9.0] — 2026-08-18 (7bf9a6e)

**Disk hygiene — reclaim worktrees "as it ships" (spec:
`docs/specs/plan-w-team-disk-hygiene-as-it-goes.md`).** A nearly-full 494 GB disk
(2026-08-18, 20 GB free) traced overwhelmingly to `/plan-w-team` residue: **parts alone held
25 leftover worktrees (~15 GB)** from runs that had already shipped, plus 10.4 GB of
`~/.claude/jobs/*/tmp` scratch. Root cause: "shipped" was INVISIBLE to the cleanup machinery —
a squash-merge defeats `git branch --merged`, a local admin-squash-merge repo has no gh PR to
consult, and the post-ship worktree's uncommitted generated artifacts then pinned it
`UNSAFE-KEEP` forever. One enabling primitive + three consumers close it; all fail-open,
kill-switchable, back-compat.

- `feat` **Part A — `.pwt-shipped` marker (`plan-w-team-worktree-mark-shipped.sh`).** Written
  into a run's worktree at the §6g confirmed-ship point (push+merge succeeded), recording the
  ship sha (+ any version tag) — the merge-path-INDEPENDENT proof the output landed. No-op for
  a lead-direct run (no worktree). Kill switch: `PWT_DISABLE_SHIPPED_MARKER=1`.
- `feat` **Part B — GC `SAFE-PRUNE-SHIPPED` class (`plan-w-team-worktree-gc.sh`).** A worktree
  whose marker's sha OR tag resolves on the default branch is reclaimable **even with
  uncommitted content** — closing MERGED's squash-merge / no-gh blind spots. The in-use veto
  stays absolute; a forged/off-branch/nonexistent marker falls through to today's uncommitted
  veto; the reap skips the wasteful pre-reap backup (the tag is the durable copy). Kill switch:
  `PWT_WORKTREE_GC_DISABLE_SHIPPED=1`.
- `feat` **Part C — §6h force-remove post-ship (`plan-w-team-worktree-on-merge.sh`).** Invariant 2
  (uncommitted → safe-skip) is RELAXED to a force-remove when a valid `.pwt-shipped` marker is
  present; invariant 3 (in-use) unchanged. Kill switch: `PWT_WORKTREE_ON_MERGE_NO_SHIPPED_FORCE=1`.
- `feat` **Part D — retro reaping (`07-retro.md` §8j-septies + `plan-w-team-zombie-prune.sh`).**
  D1: a `blocked` session whose cwd is inside `.claude/worktrees/` is now recognized as a PWT
  worker even when its launch-registry row rotated out (the `0a11736b` gap). D2: a job-scratch
  sweep clears `~/.claude/jobs/<sid>/tmp/` for completed (non-live) sessions past a grace window.
  D3: a full-repo GC `--execute` pass (now shipped-aware) reclaims prior runs' worktrees each
  retro. Kill switches: `PWT_RETRO_DISABLE_FULL_GC=1`, `PWT_RETRO_DISABLE_JOB_SCRATCH_SWEEP=1`.
- `test` `plan-w-team-worktree-gc-shipped.test.sh` (15 ACs: marker write; SAFE-PRUNE-SHIPPED via
  tag AND sha; forged/off-branch/nonexistent rejected; in-use veto absolute; kill switches;
  `--execute` removes without a backup; on-merge force-remove) + a D1 case in
  `plan-w-team-zombie-prune.test.sh`. Existing GC (131), on-merge (26), zombie-prune (16) suites
  remain green.

## [2.8.0] — 2026-08-16 (f84a514)

**Bug B — the goal-evaluator never flipped `terminal_state` on genuine retro-completes
(parts field incident, 2026-08-16).** Three back-to-back `--worker-only` builds all finished
their work correctly (retro-complete emitted, version tag cut, ship gate `allowed:true`) yet
`plan-w-team-goal-<slug>.json` kept `terminal_state: null`, so `await-terminal.sh` heartbeat
forever and the supervisor had to hand-write `terminal_state:"SUCCESS"`. Root cause: the
feature-specific criteria AND-check (`AC<N>: PASS` attestations) matched only the tail-500
transcript window, but that check runs only at the terminal anchor (Step 6 ship-verdict-PASS
/ Step 8 retro-complete) — by which point the Step 5/6 `AC:PASS` lines had scrolled out of the
window. So `met` stayed false (0/38, 1/23) and the AND never fired.

- `fix` **Full-transcript AC matching.** Each AC pattern is now matched against the WHOLE
  transcript file (raw `grep -E` — AC lines are plain text, so no decode needed), not just
  the recent window used for anchor detection. This directly fixes the reported cases: a
  legitimately-emitted `AC<N>: PASS` line anywhere in the run now marks its criterion met.
- `fix` **Instrumented block.** When generic anchors are present but criteria stay unmet, the
  evaluator logs `N/M ACs matched … unmatched: [descriptions]` to stderr instead of spinning
  silently — the operator can now see WHY a finished-looking run is being held.
- `feat` **Bounded backstop.** If retro-complete AND a deterministic PASS ship-verdict are both
  present but some ACs remain unmatchable past a settle window (default 300s), the evaluator
  flips SUCCESS rather than heartbeat forever — the ship-verdict (written by Step 6 only after
  every §6 ENFORCING gate passes) is the unforgeable floor. Gated hard (both anchors + settle +
  a per-run stamp in the goal-state) and kill-switchable: `PLAN_W_TEAM_DISABLE_BUGB_BACKSTOP=1`,
  `PWT_BUGB_BACKSTOP_SETTLE_S`. Adds a `bugb_backstop_first_seen` goal-state field (additive).
- `test` `plan-w-team-goal-evaluator-bugb-window.test.sh` (8 ACs): out-of-window AC now matched;
  unmatched block is instrumented; backstop arms-then-fires; gated on ship-verdict; kill switch.
  All existing goal-evaluator + await-terminal tests remain green.
- `docs` **Bug C was already fixed.** `await-terminal.sh` already reserves `exit 0` for terminal,
  `exit 3` for heartbeat re-arm, `exit 4` for a duplicate watcher — all distinct (the field
  report's "exit 0 heartbeat" did not match current source). Only a **stale comment** claiming
  "a duplicate exits 0" was corrected. **Bug D** (duplicate-watcher `exit 4`) is left as-is: the
  singleton `exit 4` is the intentional guard that killed real orphan-watcher pairs (1.54.0);
  making it "adopt" would reintroduce double-polling. It is a no-op the supervisor protocol
  already treats as such, not a watcher defect.

## [2.7.0] — 2026-08-15 (1c14d06)

**Bug D — first-class prune for orphaned `blocked` worker zombies.** Completes the
parts-incident lifecycle work: 2.6.0 fixed zombie *birth* (a completed run now flips
terminal and its worker exits) and stopped existing zombies from *blocking* spawns; this
is the janitor for the ones already accumulated (the field report counted 23).

- `feat` **`plan-w-team-zombie-prune.sh`** — the session-level sibling of
  `plan-w-team-worktree-gc.sh`. Sweeps `blocked` background sessions and stops the orphans
  via `claude stop <sid>` (the same mechanism `plan-w-team-child-cleanup.sh` uses).
  **Dry-run by default** (`--execute` to actually stop); `--cwd PATH` scopes to a project,
  `--min-age-min N` tunes the freshness gate, `--json` for machine output. A session is
  reaped ONLY when EVERY gate passes (any uncertainty → KEEP): (1) `state == blocked`
  (busy/idle are alive; `done` self-clears), (2) in scope (cwd under root), (3) a KNOWN
  PWT worker — its sid is in this project's `pwt-launches.jsonl` or a spawned-children
  registry, so a non-PWT blocked session is NEVER touched, (4) NO live goal-state owns it
  (an active run is protected even if momentarily blocked; a run with a *terminal*
  goal-state that never exited IS reaped), (5) aged past the freshness gate (default 30m).
  Validated live on a real months-old orphan (`700f796a`, a June deep-audit worker with no
  live goal-state). Ships to consumers via `sync-to-project.sh`.
- `test` `plan-w-team-zombie-prune.test.sh` (15 ACs) covers every gate plus dry-run-stops-
  nothing / `--execute`-stops-exactly-the-prune-set. Test seams:
  `PWT_ZOMBIE_PRUNE_AGENTS_JSON` (inject listing), `PWT_ZOMBIE_PRUNE_TEST_MODE` +
  `PWT_ZOMBIE_STOP_LOG` (record stops instead of issuing them).
- `note` The prune is operator-invoked (or timer/retro-invoked at the operator's option),
  not auto-executed on a hot path — consistent with the dry-run-default posture of the
  worktree GC. The residual "time-box a block that can't confirm terminal and exit" is
  already covered by 2.6.0's Bug B fix (terminal now flips on the restart path).

## [2.6.0] — 2026-08-15 (9ba9898)

**Worker spawn/restart LIFECYCLE hardening (parts field incident, 2026-08-15).** A parts
autonomous run built its feature correctly and gold-safe but could not reach terminal and
could not be recovered without operator intervention — four chained defects in the worker
spawn/restart/liveness lifecycle (never in the pipeline core). This release fixes three of
them at the source in `pwt-goal.sh`; all are escape-hatched and fail-safe.

- `fix` **Dead-owner seed auto-reclaim (Bug B — the killer).** On a mid-run restart the
  goal-state seed was orphaned: `__pwt_seed_guard_ok` stood down because a live seed
  existed, keeping the DEAD worker's `worker_sid`, so the goal-evaluator watched a ghost
  and a fully-completed run churned "busy" forever (0/17 criteria, no terminal flip). The
  guard now distinguishes a **live** foreign owner (stand down — concurrent-dup protection
  preserved) from a **provably dead** one (`__pwt_owner_liveness` → `claude agents --json`
  state ∈ busy|idle). A dead owner triggers a **surgical** `__pwt_reclaim_goal_state`:
  `worker_sid` is rewritten in place, `feature_specific_done_criteria` and `started_at` are
  PRESERVED, and `reclaimed_from`/`reclaimed_at` are stamped for audit. **Positive-death-only**:
  an alive owner or an indeterminate/flaky agents-listing → stand down (never clobber a
  possibly-live run). Applies to both the worker/main seed and the `--supervisor-goal`
  origin mirror. Kill switch: `PWT_DISABLE_SEED_RECLAIM=1`. No manual `PLAN_W_TEAM_FORCE_SEED=1`
  is required for the common "worker died, restart same goal" case anymore.
- `fix` **PWT-DS1 liveness is evidence-based, not presence-based (Bug C).** The double-spawn
  guard's Tier-B liveness jq filtered only `kind`+`cwd`, so a `blocked` (stuck at a Stop
  hook) or `done` zombie counted as a live worker and refused legit spawns as "duplicates"
  (the parts run accreted 23 blocked zombies). The filter now requires `.state` ∈ busy|idle;
  a `blocked`/`done`/`null` session no longer blocks a new spawn.
- `fix` **bg worker never hangs on the first-run MCP prompt (Bug A).** A fresh `claude --bg`
  worker froze indefinitely on the one-time "N new MCP servers found" interactive TUI (a
  background session cannot press a key). New `__pwt_predecide_project_mcp` pre-resolves the
  project's MCP trust (enable-all) in `~/.claude.json` before spawn — the field-validated fix
  that PRESERVES worker MCP capability — writing only when genuinely undecided, atomically,
  never overriding an explicit user decision, and never touching real config from a temp
  checkout. Plus a structural, version-independent backstop: the worker spawn now feeds
  `</dev/null` so ANY stray first-run TUI resolves to its default instead of hanging. Kill
  switch: `PWT_DISABLE_MCP_PREDECIDE=1`.
- `test` New `pwt-goal-seed-reclaim.test.sh` (26 ACs, via `--reclaim-check` CLI mode),
  `pwt-goal-mcp-predecide.test.sh` (9 ACs, via `--predecide-mcp`), and 2 new Bug-C ACs in
  `pwt-goal-double-spawn-guard.test.sh` (blocked/done zombies do not block spawns). Test
  seams added: `PWT_AGENTS_JSON_OVERRIDE`, `PWT_CLAUDE_JSON_OVERRIDE`.
- `note` **Bug D (blocked-zombie accumulation) is only partially addressed.** Bug B fixes the
  zombie-birth root cause (a completed run now flips terminal and its worker exits) and Bug C
  stops existing zombies from blocking spawns, but a first-class prune for already-accumulated
  `blocked` sessions with no live goal-state is deferred to a follow-up.

## [2.5.0] — 2026-08-14 (6894602)

**Three things you always remind the agent to do — bump the version, don't regress, and
commit→push→sync — are now enforced by the pipeline itself instead of relying on the
assistant to remember.** All three are fail-safe (escape-hatched, no-op where inapplicable)
because they run in every consumer's ship.

- `feat` **Consumer version ↔ commit binding (PWT-PVER).** A new
  `plan-w-team-project-version.sh` detects the project's own version artifact
  (`package.json` / `Cargo.toml` / `pyproject.toml` / `pubspec.yaml` / `VERSION`), bumps it
  by semver with a **surgical** in-place edit (a dependency pinned to the same string is
  never touched), and verifies a ship advanced it. Step 3 preflight captures the version
  baseline on the base tree; §6d now **auto-bumps** the consumer version if the run forgot,
  heads the CHANGELOG with it, folds it into the ship commit, and stamps a
  `Project-Version:` trailer + provenance artifact — replacing the prior prose-only reminder.
  Fail-open: no artifact detectable → surface, don't block. (29-case test, bash 3.2.)
- `feat` **No-regression gate (PWT-REGRESS).** A new `plan-w-team-regression-gate.sh`
  captures the test-suite state on the base tree at execute-start, then at §6b-regress
  re-runs and **hard-blocks + escalates** (`USER_ESCALATION_HALT` via the new
  `regression-halt` hard-gate site) on positive evidence a test green at run-start is now
  red **or a passing test was removed** — the two regressions the coarse whole-suite gate
  can't see. Pre-existing failures don't block; an un-runnable/unparseable suite is
  indeterminate and never blocks (fail-open). Automates the manual
  "stash → run on clean main → attribute blame" carve-out. Waiver file for intentional test
  removal; `PLAN_W_TEAM_DISABLE_REGRESSION_GATE=1` kill switch. (13-case test, bash 3.2.)
- `feat` **Same-machine propagation sync at ship (PWT-SHIPSYNC).** §6h-bis closes the
  "commit → push → **sync**" contract: on a skill self-ship from the source repo it
  propagates the merged change to the local fleet (files-only, `--no-commit`), fire-and-forget,
  `PLAN_W_TEAM_DISABLE_SHIP_SYNC=1` opt-out. Consumer ships need no sync (origin distributes
  them); cross-machine consumers keep their own session-start auto-sync (same-machine scope
  by design).
- `feat` `regression-halt` added to the goal-evaluator hard-gate site loop and
  `plan-w-team-surface-status.sh` `hard_gate_sites`, so an autonomous `/goal` run halts to
  the user on a detected regression instead of looping.
- `docs` New state artifacts registered (`plan-w-team-project-version-baseline-*`,
  `plan-w-team-project-version-*`, `plan-w-team-test-baseline-*`,
  `plan-w-team-regression-waiver-*`, `plan-w-team-sync-confirm-*`) + gitignore patterns
  (source `.gitignore` + consumer guidance in `untracked-hygiene.md`); `versioning.md`,
  `goal-conditions.md` (hard-gate list), and §6d/§6f/§6b prose updated.

## [2.4.4] — 2026-08-14 (210e866)

**PWT-DS1 double-spawn guard was wall-clock-scoped and missed the plan-mode gap.** Field
incident 2026-08-14: the user typed "Use /plan-w-team to …", the route hook spawned a worker
immediately, the origin assistant then spent ~15–20 min in **plan mode**, and the manual
`pwt-goal.sh` launch after plan approval sailed past the guard — producing **two rival
`v3.20.0` optimizers off the same base with incompatible `R240–R245`**. Root cause: PWT-DS1's
only mechanism was the mtime freshness window (`PWT_DOUBLE_SPAWN_WINDOW_MIN`, default 3 min),
and the gap it must cover — route-hook spawn → same-turn manual launch — is **not bounded by
wall-clock** when the turn contains a long plan-mode pause. A wall-clock cap on the *protection*
also directly violated the "no wall-clock/turn caps on `/plan-w-team`" principle.

- `fix` **PWT-DS1 gains a liveness tier (PWT-DS1-LIVE), `pwt-goal.sh`.** The guard is now two
  tiers: **Tier A** (unchanged) refuses on a flag fresh within the mtime window — offline-safe,
  no tooling. **Tier B** (new) fires *beyond* the window: it reads the recorded `worker_sid`
  from any lingering hook-spawn flag and refuses iff that worker is **still live** in
  `claude agents --json` (via the `claude-agents-extended.sh` retry wrapper — the same view PWG
  trusts). Protection now expires when the prior worker actually dies, not on a clock, so the
  plan-mode delay no longer opens a duplicate window.
- Fail-safe posture: Tier B only *adds* refusals on **positive** liveness confirmation. A
  missing tool / unparseable / empty-after-retries listing (the documented `claude agents --json`
  flakiness) is INDETERMINATE → proceed + loud stderr marker — never a new false-positive
  refusal. A valid, non-empty listing lacking every recorded worker → all prior workers gone →
  legitimate later run → proceed silently. Covers both `--worker-only` and `--launch`.
- Escape hatches: `PWT_DOUBLE_SPAWN_LIVENESS_DISABLE=1` reverts to pure Tier A;
  `PLAN_W_TEAM_FORCE_SPAWN=1` bypasses both tiers (unchanged).
- `test` `pwt-goal-double-spawn-guard.test.sh` +5 ACs (AC8–AC12): stale-flag+live-worker →
  refuse (the incident); stale-flag+worker-gone → spawn; liveness kill switch; force bypass
  beyond window; `--worker-only` liveness refusal. Now 30/30, bash-3.2 clean. The fake `claude`
  learned the `agents` subcommand so liveness queries don't inflate the spawn counter.
- `docs` PWT-DS1 Tier A/Tier B split propagated to `plan-w-team.md` (§Step 3a + mermaid),
  `shared/gotchas.md` (G2 + a new "plan-mode gap" sub-gotcha), `shared/state-artifacts.md`,
  `shared/supervisor-protocol.md`, `shared/goal-conditions.md`, and
  `shared/orchestrator-interception.md` (guard matrix + the stale "DS1 is 60s scoped" note).

## [2.4.3] — 2026-08-14 (fb22821)

**The retro's doc-hygiene reader scored a perfect 5/5 on unreadable input.** Found by
re-auditing the A4–A6 cluster adversarially: that cluster's auditor completed but never
returned findings across four requests, and since each of the other three clusters had
yielded a HIGH defect in territory already called clean, the lead re-examined it by
applying the specific fail-open shapes the others had found.

- `fix` **§8d `doc_hygiene` fails open (`07-retro.md`).** Every read in the block ends
  in `|| echo 0`, so corrupt JSON, an empty `{}`, and an artifact carrying `scan_rc: 1`
  with no `undocumented` key all produced `UNDOC=0` → score **5/5** (positive control: a
  well-formed artifact with two undocumented items correctly scored 1). Same laundering
  shape as the §7f check — and it lands on the LAST line of defense, since §8d is what
  prints "N net-new surface item(s) shipped UNDOCUMENTED — investigate why §7f did not
  block". With §7f and §8d failing open on the same malformed artifact, a run that
  shipped undocumented surface scored clean twice and nothing contradicted it.
  Unreadable is now scored `n/a`, never clean.
- `docs` A4(a) reclassified VERIFIED → PARTIAL in the audit report. The 1.33.0 phantom
  reader IS genuinely gone — that part of the 1.33.0 claim holds — but the real reader
  it was replaced with trusts its input.
- The same pass **corroborated** the rest of the cluster: `04-fix-first-review.md:249-295`
  maps every non-zero symmetry-check exit (1, 2, 3 environment-failure, 4, and a
  catch-all) to `exit 1` fail-closed — the most disciplined exit handling in the audited
  surface — and A6 survived a targeted evasion (an unrelated `docs/operations` page
  merely containing the new script's stem did NOT satisfy the requirement).

## [2.4.2] — 2026-08-14 (e407767)

**The documentation gates were weaker than 2.4.1 reported.** The row-12 re-audit's
four-agent fan-out returned after 2.4.1 shipped, carrying five reproducible defects
the lead's solo pass had missed. Each was re-verified independently before being
accepted, and one auditor recommendation was tested and **rejected**. 2.4.1's verdict
table is corrected in the audit report: A1 and A3 were not VERIFIED, C2 is REFUTED
rather than PARTIAL, and AC13 hid a permanently-red test.

- `fix` **`plan-w-team-netnew-surface.sh` reported "clean" without scanning anything
  (HIGH).** When no base ref resolved it fell back to `BASE=HEAD`, i.e. the always-empty
  range `HEAD..HEAD`, and reported "all net-new surface is documented". This fires on the
  pipeline's DEFAULT path (no `--range`/`--base`) in any repo whose default branch is not
  `main` and which has no remote — a consumer on `master`, a detached CI checkout, a
  fresh clone. Now exits 2 (review-required). Same fail-open class as the
  access-control scanner fix in 2.4.1, in the doc half of the surface.
- `fix` **`docs/specs/*.md` satisfied the documentation ship gate (HIGH).**
  `plan-w-team-netnew-surface.sh` deliberately excludes `docs/specs/` from the docs it
  will accept, `01-specification.md` says specs do not discharge the duty, and
  `02-task-breakdown.md`'s `N.d` rule agrees — but the gate accepted them, so a net-new
  script documented only in the run's own spec passed while the subscanner reported it
  UNDOCUMENTED. Every run writes a spec at that path, so the exclusion matters.
- `fix` **a missing subscanner made the doc ship gate pass silently (HIGH).** The
  `[ -x ]` guard left the residual at 0, so a consumer whose sync dropped the file got a
  green gate that tested nothing — the C7-part-2 silent-degradation shape. Now fails
  closed with the restore instruction.
- `fix` **`damage-control-secret-content.test.sh` was permanently RED under `/bin/bash`
  3.2**, the project's stated compat target: T1/T3 interpolate a variable inside nested
  escaped quotes within `$( )`, which bash 3.2 parses differently, mangling the JSON so
  the hook saw no secret. `make test-skill` was therefore red on mac-mini for a non-code
  reason and green locally only by PATH accident. Payloads hoisted out of the
  substitution; 7/7 under both 3.2 and 5.x. The defense itself was never broken.
- `fix` **consumer `.gitignore` missed the subdirectory test corpus.** `sync-to-project.sh`
  wrote `.claude/hooks/*.test.sh`, and gitignore `*` does not cross `/`, so
  `.claude/hooks/damage-control/damage-control-secret-content.test.sh` rsynced into every
  consumer untracked-and-not-ignored — precisely the "could not detach HEAD" intake abort
  the self-heal block exists to prevent. Adds `**/*.test.sh` forms plus an idempotent
  top-up for consumers that already ran the marker-guarded block.
- `docs` A3's remaining weakness is recorded, not silently patched: a CHANGELOG touch
  still satisfies the gate, and /plan-w-team touches CHANGELOG on every run, so it rarely
  binds. That is what AC3 and the brief specify, so tightening it is a spec change with
  fleet-wide blast radius — queued with the other four findings rather than slipped in.
- Tests: doc-ship-gate 5 → 7, netnew-surface 14 → 16, damage-control-secret-content
  green under both interpreters.

## [2.4.1] — 2026-08-14 (4dfac64)

**The access-control detection floor no longer reports "clean" without having
scanned anything.** `access-control-content-scan.sh` is the deterministic floor
beneath the §6c-ter ship gate — the gate that exists because
`access_control_high_unresolved` is authored by an LLM and cannot be trusted. Its
diff resolution fell back to `git diff HEAD` when no base ref resolved; on a
fully-committed tree that succeeds with empty output, so the scanner reported
`exit 0 — clean` for a HEAD full of live CS-1..CS-3 signals. Ship time is exactly
when trees are committed, so this fired at §6c-ter in any repo where `origin/HEAD`
and `origin/main` do not resolve (consumer checkouts without the expected remote, a
non-`main` default branch, a detached CI checkout) — the precise fail-OPEN
`pwt-design-principles-audit.md` forbids. An unresolvable base with no working-tree
changes now returns `2` (review-required); the dirty-tree fallback is preserved for
the Step-5 mid-review case.

- `fix` **§6c-ter honesty**: an `rc=2` result, or a missing/non-executable scanner
  (the round-2 C7 part-2 silent-degradation path), no longer falls through to an
  unqualified "no findings" line — both now mark the count `UNCORROBORATED` and say
  so. Blocking behaviour is deliberately unchanged: making `rc=2` fatal would wedge
  ships in every consumer without the expected remote.
- `fix` **CS-1..CS-4 convention gaps**: six realistic shapes the floor missed, each
  the same violation written differently — bracket-notation and snake_case privilege
  writes (CS-1), uppercase `SERVICE_TOKEN` (CS-3, the canonical spelling was the one
  the pattern lacked), and Prisma/TypeORM `where: { id }`, `getById`, and lowercase
  raw SQL (CS-4, where a BOLA floor blind to Prisma has a hole where BOLA lives).
  Nine negative cases confirm tenant-scoped and benign forms stay clean.
- `docs` **`shared/secret-safety.md` reconciled with the code it governs.** The file
  declares itself the single contract for placeholder rules and defense layers, and
  had drifted on both: its Placeholder Heuristic still described pre-B3 whole-line
  suppression (the scanner has used token adjacency since 1.33.0), and its
  defense-in-depth model listed three layers, omitting B1's write-time PreToolUse
  scan — the earliest interception in the system. Now token-adjacency semantics and
  a four-layer model with `damage-control.sh` as Layer 0.
- `fix` **the scanner no longer flags itself.** CS-1..CS-4 necessarily match the files
  that DEFINE and DOCUMENT them, so any run touching the scanner or its docs flagged
  itself and failed §6c-ter closed (`scan_rc=3` with an honest count of 0). This audit
  hit it live: 32 suspects, every one a pattern definition, a test fixture, or prose
  about a pattern. Fixed with a documented non-code skip (`*.md`/`*.rst`/`*.adoc`,
  `.claude/state/**`, the scanner's own source and fixtures) — the same self-reference
  fix `secret-scan.sh` already carries for its pattern catalog.
- `fix` **`plan-w-team-netnew-surface.sh`** no longer reports a PRE-EXISTING token as
  net-new. Extraction reads added lines only, so re-mentioning an existing flag/env-var
  /symbol in a comment or a moved line was classified brand-new and, via the ENFORCING
  §6c-quater gate, blocked a legitimate ship. Tokens present at the range base are now
  skipped. Found by this run against its own branch (`--diff-file`).
- `fix` **dead code removed**: `secret-scan.sh`'s `is_placeholder_line()` had zero
  call sites while carrying a comment claiming it served as a diff-mode pre-filter.
- `docs` **enforcement claims corrected.** Three gates were documented as enforcing but
  are prose-only: A5's `post-ship-complete` "precondition" (`07-retro.md` sets
  `RETRO_SUCCESS=1` before the check, and the anchor is never withheld) and §7f's C1/C2
  refusal conditions (only the A1/A6 arm is implemented in code). `goal-conditions.md`,
  `shared/secret-safety.md` and the ops page now carry explicit enforcement-status
  notes; making them enforcing needs new blocking gates and is queued.
- Tests: `access-control-content-scan.bats` 9 → 23 cases (BDD-named);
  `plan-w-team-netnew-surface.test.sh` 10 → 14 assertions.
- Audit report: [`docs/operations/pwt-doc-secret-handling-reaudit-2026-08-14.md`](../../../docs/operations/pwt-doc-secret-handling-reaudit-2026-08-14.md)
  — closes recursive-followup row `[12]`, and records what "24 gaps" actually means
  (24 raw findings consolidated into the 12 numbered gaps A1–A6/B1–B4/C1–C2; the 24
  are enumerated nowhere).

## [2.4.0] — 2026-08-13 (b65d03e)

**Your tracking Issue now closes itself when a feature ships.** `/plan-w-team`
opens a GitHub Issue per feature and, until now, only moved its board card to
"Done" at ship — it never closed the Issue. GitHub's native auto-close only fires
when a merged PR carries a `Closes #N` keyword, but the canonical workflow here is
commit-to-main / admin-squash-merge with no such PR, so every tracking Issue
stayed open forever (2026-08-13: 16 stale Issues had to be closed by hand). Step 6
(Ship) now closes the run's Issue directly the moment the ship lands, and stamps
the ship commit SHA onto the Issue timeline so you can see exactly what closed it.
It reuses `board.sh`'s existing `close` verb, is fail-open (a missing Issue,
disabled board, absent `gh`, or a failed close never blocks the ship), and is
idempotent (re-running against an already-closed Issue is a quiet no-op, and a
`Closes #N` PR — when a run does open one — is honored with no double-close).
`board.sh close` gains an optional close-comment argument and an already-closed
short-circuit; `shared/board-integration.md` documents the direct-close model.

## [2.3.2] — 2026-08-13 (6fef168)

**Correct a now-false steering-channel claim (CLI 2.1.231 uplift).** The
`2.1.224 → 2.1.231` version-uplift pass found that cross-session `SendMessage` +
`ListAgents` (new at 2.1.224) invalidates the absolute claim in
`shared/supervisor-protocol.md` §"Operator-invoked only" that "`SendMessage`
cannot address a `claude --bg` process, and there is no inbox." An attended live
probe (2026-08-13, throwaway `claude --bg` worker mirroring the `pwt-goal.sh`
spawn shape) **confirmed** the message reaches and is acted on by a live local
bg worker in ~1 tool round, with no approval gate same-machine/same-account. The
section is corrected: the operator-only + do-not-automate stance is **preserved**
(it rests on `pwt-steer.sh`'s stop-and-resume teardown, not on the false
"no channel" premise), and a note records the real channel plus two caveats
(the steered worker applies its own judgment — an ill-framed steer is refused as
prompt-injection; the cross-machine `crossSessionInbound` gate is unverified).
Adopting a `SendMessage`-based live-steer is a deferred design decision, not part
of this bump. Docs-only clarification (PATCH). Full analysis:
`docs/operations/version-uplift-reports/2026-08-13-2.1.231.md`; compatibility
table + `reference_bg_worker_steering` memory updated in the same pass.

## [2.3.1] — 2026-08-09 (695b487)

**Lane-guard seed gap: bind the origin chat on DIRECT Bash launches.** First
live use of 2.3.0 (cleanscale) surfaced the gap honestly flagged by its own
supervisor: a lane launched by a direct Bash tool call — no route hook (no
`PWT_PARENT_SID`), no bg job (no `CLAUDE_JOB_DIR`) — seeded
`supervisor_sid=""` AND a launches row with `parent_sid=""`, leaving the
origin chat UNBOUND: the lane-guard's bound-supervisor deny tier silently did
not apply to the one session most likely to drift. (Worktree protection,
artifact-forgery denial, and the PWT-LANE2 actor gate are binding-independent
and still held.) Fix: `pwt-goal.sh`'s `USER_SID` chain gains a final fallback
to `CLAUDE_CODE_SESSION_ID`, which Claude Code exports into every Bash tool
env — so identity binding now holds on every launch path. Precedence is
unchanged (`CLAUDE_JOB_DIR` → `PWT_PARENT_SID` → new fallback). Regression
tests in `scenarios/worker-only-seeds-goalstate.bats` cover both the
direct-launch fallback and route-hook precedence.

## [2.3.0] — 2026-08-09 (4fe3b1f)

**Lane enforcement — /goal + /plan-w-team becomes binding instead of advisory.**
Born from the 2026-08-09 cleanscale incident: a /goal-spawned lane was live, the
supervising session's role contract was dropped by compaction, and nothing at
the tool layer knew a lane existed — so the supervisor implemented the lane's
work itself in the main checkout while the worker ran in its worktree. The Stop
evaluator then accepted a hand-emitted retro-complete block from the
supervisor's own transcript. Three structural holes, three guards:

- **PWT-LANE1 — PreToolUse lane-guard** (`.claude/hooks/plan-w-team-lane-guard.sh`,
  wired to Bash/Write/Edit/MultiEdit): while a lane is live (non-terminal
  goal-state with a well-formed `worker_sid`, fresher than
  `PWT_GOAL_STALE_HOURS`), the owning worker (SID match) passes untouched; a
  BOUND supervisor (bg `PLAN_W_TEAM_SUPERVISOR_SESSION=1`, seeded
  `supervisor_sid`, or `pwt-launches.jsonl` lineage) is DENIED repo mutations —
  file tools outside `.claude/state/`, git write-subcommands, build/test
  runners, in-place edits, provable repo-targeted mutators/redirects; ANY
  non-worker session is denied writes into the lane's worktree and denied
  forging the evaluator-trusted artifacts (`ship-verdict`, `test-green`; bound
  sessions also `goal-state` + the release valve). Every deny re-teaches the
  role — enforcement doubles as post-compaction context restoration. Deny
  audit: `plan-w-team-lane-guard-audit.jsonl`. Release valve (USER-only,
  written outside the bound session): `plan-w-team-lane-release-<slug>.json`.
  Kill switch: `PLAN_W_TEAM_DISABLE_LANE_GUARD=1`.
- **PWT-LANE2 — actor-aware Stop evaluator** (`plan-w-team-goal-evaluator.sh`):
  the C3 ship-verdict corroboration now also applies OUTSIDE worker mode —
  when the goal records a `worker_sid` and the evaluating session is not that
  worker, SUCCESS anchors in its own transcript are hearsay and require the
  deterministic PASS ship-verdict. A supervisor hand-emitting the passing
  string can no longer terminate the goal (it yields instead; the worker keeps
  running). The worker's own transcript and parent-child propagation are
  untouched. Kill switch: `PLAN_W_TEAM_DISABLE_ACTOR_GATE=1`.
- **PWT-LANE3 — lane-context re-binding** (`.claude/hooks/plan-w-team-lane-context.sh`,
  SessionStart + throttled UserPromptSubmit): re-injects the WORKER/SUPERVISOR
  role contract from disk — where compaction cannot touch it — at every
  session start (including post-compaction) and every
  `PWT_LANE_CONTEXT_INTERVAL_S` (default 30 min) during long sessions.
  Delivered via `systemMessage` (the field the harness measurably delivers).
  Kill switch: `PLAN_W_TEAM_DISABLE_LANE_CONTEXT=1`.

`pwt-goal.sh` now seeds `supervisor_sid` (the origin session's UUID) into every
goal-state it emits — the identity binding the guards key on. Regression corpus:
`tests/skill/cases/plan-w-team-lane-guard.bats` (28 tests, deny paths
exercised), `cases/plan-w-team-lane-context.bats` (8),
`scenarios/goal-evaluator-actor-gate.bats` (6). Docs:
`docs/operations/lane-enforcement.md`.

## [2.2.1] — 2026-08-09 (1e86221)

**The janitor's fallback comment now matches the janitor's fallback.** Resolves
recursive-followup row 9 (`deep-audit-2026-06-08`, open since 2026-06-08):
_"cleanup-stale-goal-states.sh comment claims its grep+sed terminal_state
fallback matches goal-evaluator.sh, but the evaluator is jq-only-or-bail."_

Two findings, and the second is why the row was still worth doing:

1. **The quoted defect was already fixed.** The L55-59 text the audit cited was
   replaced by `fcb90fc3` (2026-06-10) shipping R-D2 of
   `docs/specs/goalstate-test-leak-hardening.md`. The row was stale-open.
2. **Its replacement was inaccurate in a new way.** The new comment described a
   *host-capability* fallback ("so this janitor still works on a host without
   jq") while `__terminal_state_of` / `__json_str_field` actually fall back on an
   **empty jq result** — which also fires when jq IS present and the file is
   unparseable. Verified by execution, not inspection: with jq installed, a
   corrupt goal file whose text contains `"terminal_state": "SUCCESS"` is
   grep-classified and **reaped** by pass 1, while `goal-evaluator.sh:441-445`
   fails its `jq -e .` guard and **skips** the same file. Same file, opposite
   disposition, undocumented.

- **`plan-w-team-cleanup-stale-goal-states.sh` — comment only, zero executable
  lines changed** (verified by a filtered diff). It now states the three real
  trigger conditions, the corrupt-JSON divergence with citations (evaluator
  `:201-205` no-jq bail, `:441-445` corrupt skip), and why the divergence is
  acceptable for a best-effort session-start GC rather than a bug to "fix" by
  going jq-only (which would break jq-less hosts for no safety gain).
- **The claim is now pinned, not merely restated.** A comment alone is
  unverifiable — which is exactly how the first bad comment shipped and survived
  a full spec cycle. Two cases in
  `plan-w-team-cleanup-stale-goal-states.test.sh` (corrupt-with-quoted-SUCCESS
  reaped; valid `null` preserved) assert the documented behavior, each guarded by
  a jq precondition so they cannot pass vacuously on a jq-less host. A negative
  control (mutate the extractor to jq-only) makes the new case fail — the test is
  not decorative. Janitor suite 19 → 22 cases.
- **Unrelated pre-existing red fixed to reach a green gate**:
  `operator-shell-setup.sh` (added 2026-08-08) was neither cp-allowlisted nor
  `NOT_SYNCED`, failing the R4 tracked-runtime-script coverage lint on `main`.
  Dispositioned **source-only** — it resolves `$REPO_ROOT/.claude/shell/` and
  `$REPO_ROOT/dotfiles/`, neither of which syncs, so a consumer copy would point
  at paths that do not exist there.

## [2.2.0] — 2026-08-08 (1a77f8d)

**Reuse-verdict re-verification — the reuse-first ladder's last rung.** Resolves
recursive-followup row 5 (`…-e6b61e7d`, open since 2026-06-08): _"ship-time
re-verify of the Step-0 80% premise / N.d consolidation queue."_

Until now the Reuse Audit was gated for **presence** at freeze and never
compared against what shipped. A spec could freeze `REUSE src/util/money.ts`,
ship a diff containing a fresh `fmtMoney()`, and pass every gate. Its sibling
spec-time claim — the Grounding Ledger — already had a re-verification rung
(§5a-ter); this closes the asymmetry.

- **`plan-w-team-reuse-audit-gate.sh` gains `--phase spec|review|ship`.**
  `spec` (default) is byte-for-byte the old freeze gate. `review`/`ship` detect
  an **unhonored verdict**: a `REUSE`/`EXTEND` row whose target's concept key
  collides with a **newly-added definition** in the run diff.
- **§5c-quinquies (`04-fix-first-review.md`) is the detection rung.** Findings
  route through the **existing** `consolidate-into-existing` classification so
  they get FIXED in-run — a new detector feeding an existing classifier, the
  same shape §5c-quater describes for itself.
- **§6c-quinquies (`05-ship.md`) is the re-assertion rung** — the same check at
  ship, covering code written in later Step-5 fix rounds, recorded as
  `reuse-verdict-recheck: <clean|findings|unverified|skipped>` in the status
  block. Advisory; never blocks.
- **`plan-w-team-followups.sh add`** makes §5d outcome 3 executable. That
  section has always told the lead to "record a follow-up in the ledger" while
  supplying no command, so the only append path was the retro's once-per-run
  writer. This is the consolidation queue.
- **`plan-w-team-claim-abstraction.sh normalize`** exposes the existing
  `normalize_key()` so both gates share ONE normalizer.

**What it deliberately does not detect.** Never "the diff does not reference the
target". A `REUSE` verdict frequently means *"this exists, so we are NOT
building one"* — which leaves no diff trace, so the most virtuous outcome would
be flagged. And a run's own spec is committed on its own branch citing every
target verbatim, making a reference rule inert until `docs/specs/**` is excluded
and mostly noise after. `BUILD-NEW` and qualified verdicts (`REUSE (pattern)`)
are exempt by construction.

**It never blocks.** An earlier draft blocked when a cited path had vanished.
Consumer-repo-generated specs are known to carry wrong claude-pattern paths, so
that would have hard-blocked shipping across every synced consumer on an
existing data pattern; and a legitimate consolidation-rename produces the same
signal. "The path is gone" is a provable fact, not a provable defect. Exit
contract is reused verbatim from `plan-w-team-claim-abstraction.sh`
(`0` clean / `11` findings / `12` could-not-verify / `2` usage), so `12`
distinguishes "verified clean" from "did not verify".

Fixed along the way:

- **Open followups row 11** — the section extractor truncated the Reuse Audit
  body at the first nested `###` sub-heading and at heading-shaped lines inside
  code fences. Loud under `spec` phase; under `review`/`ship` it would have been
  **silent under-enforcement**, so fixing it was a precondition, not a bonus.
- **Pre-flight follow-up counter** read the ledger's `status` field directly,
  which the registry forbids because the ledger is append-only — it reported 45
  open against the tool's 43. All three reads now delegate to
  `plan-w-team-followups.sh --json stats`.
- **`sync-to-project.sh` retired-paths skill map was always empty** — bare
  `case` arms inside a `$( … )` closed the substitution early, so every
  dangling-reference WARN degraded to "no absorbing skill reference for this
  name". Shipped in 2.0.0; `bash -n` cannot catch it.

Hardening: targets resolve through `git ls-files`, never `[ -f ]`, so traversal
and absolute paths are unreachable rather than filtered; matching is
fixed-string; `--slug` is charset-validated (closing a pre-existing read-path
hole); `--help` no longer truncates below the `--phase` line, which both
wrappers' capability probe depends on; findings are capped by
`PWT_REUSE_RECHECK_MAX` (default 3) because a queued row can become an
autonomous run's goal via `plan-w-team-followup-drain.sh`.

No new kill switch — `PLAN_W_TEAM_DISABLE_REUSE_AUDIT=1` covers all phases.
No new state artifact, no `.gitignore` entry, no sync-allowlist edit: every
script touched was already allowlisted, which is the concrete payoff of
extending rather than adding.

Dogfood: `--phase review` against this run's own spec and diff reports CLEAN
across 13 resolved targets — zero false positives on a 17-row audit.

> Shipped as **2.2.0**, not 2.1.0. This run and the 2.1.0 hardening run below
> were concurrent off the same base and both bumped to 2.1.0 from their spawn
> snapshot. The collision was caught at merge time and resolved the documented
> way — `plan-w-team-next-version.sh --bump minor` re-derived the number from
> main's CURRENT `VERSION` (2.1.0 → 2.2.0) rather than the spawn snapshot
> (2.0.0 → 2.1.0). See `shared/versioning.md §Concurrent runs`.

## [2.1.0] — 2026-08-07 (90037fb)

**Hardening release — the five weaknesses surfaced by 2.0.0 + the cleanscale
field test.** Operator brief: `.claude/state/pwt-brief-pwt-hardening-2-1.md`;
spec: `docs/specs/harden-plan-w-team-against-the-five-weaknesses-surfaced-by-the-2-0-0-release-and-b344ebd8.md`.

- **Commits staging `tests/skill/*` no longer die at the 60s hook default** —
  the pre-commit gate consults the archived `plan-w-team-test-green.sh` verdict
  instead of re-running the ~13-min suite inline, corroborated by a new
  `tree_digest` (staged-content blob digest — the suite must have seen exactly
  what you are committing) plus the `SUITE_EXIT=0` log witness; red, absent,
  stale, digest-mismatched, or witness-less verdicts still block, and repos
  without the harness keep today's warn-and-allow. The hook object carries an
  explicit 120s timeout (bound to `pre-commit-quality.sh` alone).
- **You can now steer a running bg worker with one command** — `pwt-steer.sh`
  encodes the field-proven procedure (validate-first, stop, pinned+route-guarded
  resume from inside the worker's worktree, marker-verified delivery, dual-dir
  `worker_sid`/`respawn_history` bookkeeping, old-watcher teardown) with 74
  test assertions; documented in `shared/supervisor-protocol.md §Steering a
  Running Worker`.
- **§1.5 criteria injection survives backslashes in AC text** — the echo→jq
  mangling that twice shipped runs with ZERO feature-specific done-criteria is
  gone (printf forms, anchored block, loud distinct abort on jq failure instead
  of the false "no AC entries" message), regression-tested under the verified
  `bash -O xpg_echo` reproduction vehicle.
- **Status blocks stop echoing resolved escalations** — new
  `escalation_resolved` event (closed `user_ack`/`auto_approve_env` reason enum
  on hard-gate sites) with file-order last-wins pairing and corrupt-line-resilient
  parsing in `plan-w-team-surface-status.sh`; legacy logs render byte-identically.
  NOTE: this fixes the EMITTER only — the goal-evaluator still greps historical
  transcript blocks until the queued W5 fix lands (it must corroborate, never
  trust, these rows).
- **Evaluation-worded goals no longer charter builds** — `pwt-goal.sh`
  classifies intent (conservative leading-verb core; build-override words win)
  and appends a disposition-only no-build constraint block to evaluation
  directives; new explicit `--type eval` opts into evaluation done-criteria.
  Trigger detection untouched — natural-language routing is sacred.
- Step-5 extras: two fail-open regressions closed same-run (schema-invalid
  escalation row blanking `pending_escalations`; corrupt line blanking
  `low_confidence_routes`), claim-ledger isolation test de-flaked (slug-scoped),
  friction-log triage pass (9 rows, first `{type:"triage"}` marker) recorded at
  `docs/operations/friction-log-triage-2026-08-07.md`.

**Why MINOR:** additive capabilities and defect fixes; no stage-file contract,
artifact schema, or consumer-visible surface breaks (the hook change preserves
gate semantics — red still blocks).

## [2.0.0] — 2026-08-07 (1004c0e)

**Agent-roster restructure per Anthropic's subagents-vs-skills taxonomy
(BREAKING).** `.claude/agents/` shrinks 159 → 33 keep-tier definitions — only
agents that use an agent-only capability (context isolation, binding
`disallowedTools`/`tools` restriction, per-lane model+effort pin) stay agents.
58 knowledge-persona definitions collapse into 15 new progressive-disclosure
skill directories (+ relocated `code-review-standards` ⇒ 16 under
`.claude/skills/`), each a lean `SKILL.md` router + `references/` files.
Retire tier deleted outright (openrouter-expert, chatgpt-expert, hive/ subtree,
AGENT_MIGRATION_GUIDE/AGENT_INTEGRATION_STRATEGY) plus the operator-directed
full retirement of discord-expert (definition + entire knowledge tree —
claude-pattern is client-agnostic; the ci-alert Discord *provider* plumbing
stays). Spec: `docs/specs/restructure-the-claude-agents-roster-per-anthropic-s-current-subagents-vs-skills-d6f25286.md`.

**Why MAJOR:** stage files and consumer repos lose previously-mandated agents —
any workflow addressing a converted specialist by `@agent-name` breaks; the
routing pattern is now `builder`/`builder-opus` + domain skill.

- **Sync retired-path cleanup pass**: permanent 123-row manifest
  (`.claude/scripts/sync-retired-paths.txt`, read from SOURCE only) with an
  11-rule two-phase guard set (validate-all-then-delete, charset allowlist,
  prefix+segment containment, ancestor-collision vs the source-enumerated
  shipped set, realpath containment, symlink=remove-link-only, git-rm staging,
  static lint, per-path action log) + consumer WARN epilogue for dangling
  references (62 retired names). Registered as a one-way-door surface.
- **Keep-tier repairs (R11)**: 6 strict-YAML frontmatter fixes for previously
  unspawnable agents (incl. system-architect, rust-backend-specialist);
  keep-tier promoted to 33 with performance-testing-specialist and
  github-security-orchestrator.
- **Security**: discord-webhook secret pattern added to `secret-scan.sh`
  (fleet-wide blindness — pattern was entirely absent); private-key pattern
  fixed at 3 grep sites (leading-dash regex never fired anywhere without
  `--`); the one embedded webhook (ID 1390445582585303100) redacted
  pre-conversion and **verified rotated/dead by the operator**; T1 redaction
  across 13 occurrences / 4 files.
- **Tests**: +6 new suites (keep-list set-equality, skills-shape with doc→disk
  citation checks, no-stale-agent-refs over the 62-name corpus,
  agent-frontmatter-valid, sync-consumer-warn, sync-retired-paths-cleanup
  59-case guard suite); 5 suites rewritten for the new roster; all with
  anti-vacuity controls.
- **Docs**: CLAUDE.md rewritten around the 33+16 model (38.8k chars, under the
  40k limit); `docs/operations/consumer-sync-cleanup.md` new.

## [1.69.0] — 2026-08-06 (6e0bdaf)

**Goal-run resilience + operator visibility.** Batch of operator-driven fixes
from the 2026-08-06 session, born from a live incident: the roster-restructure
run parked idle 90+ minutes over a 3-minute rate-limit wall at a 5h-block
boundary.

- **StopFailure halt-notifier** (`hooks/stop-failure-notify.sh`): any turn
  dying on an API error fires a desktop notification, a durable
  `state/stop-failures.log` breadcrumb, and an optional ntfy phone push
  (`~/.config/claude/halt-ntfy-topic`). Out-of-band by design — survives dead
  credentials. Proven in production the evening it shipped (3 rate_limit pings).
- **Rate-limit auto-resume** (`hooks/plan-w-team-rate-limit-resume.sh`, chained
  after the notifier on StopFailure): closes the gap where the goal evaluator
  re-engages via Stop but a rate-limited turn dies as StopFailure. Pure local
  shell (fires with zero API capacity); waits for the real gate-lift
  (error-stated reset time → weekly-cap aware, else ccusage block end, else
  15m); resume ladder = continue → fallback-model rung (/model
  claude-opus-5, the interactive analog of the spawn sites'
  --fallback-model) → final continue → loud give-up; repeated-give-up breaker
  (2 ladders/24h = weekly cap, stop re-arming). tmux-pane injection only —
  unattended goals launch inside tmux per the README. 8/8 tests
  (`hooks/plan-w-team-rate-limit-resume.test.sh`). Kill switch:
  `PWT_RATE_RESUME_DISABLE=1`.
- **Pane-scoped statusline agents line** (`statusline.sh`): each pane shows
  only its own agent tree (parentSessionId-gated vs the stdin session_id +
  launch-registry descendants); everything else collapses to a muted "+N other
  in repo". Fixes the multi-pane-same-repo union display.
- **Operator on-ramp**: `scripts/operator-doctor.sh` preflight (per-item ✅/❌
  with fix commands, sync-allowlisted), README rebuilt setup-first for
  non-developer operators (Step 0 Mac setup → protections → launch → done),
  /goal taught as the real unattended command, the NL route form demoted to a
  documented guardrail (fail-open, never an interface).
- Friction-logged for the next skill run (not fixed here): goal evaluator is
  context-blind across sessions (misfired 15+ times in an operator session);
  route hook fails open silently; evaluator should natively re-engage on
  StopFailure rather than relying on this hook.

## [1.68.0] — 2026-08-06 (d806026)

> Shipped as 1.68.0, not 1.67.0: this run authored its entry as 1.67.0 while a
> concurrent run (`c58efb9`, the agent-roster prompt-audit) took that number on
> `main` first. Renumbered at merge; both releases are real and both are below.

**The last anti-duplication gap: an abstraction that doesn't exist yet.** Every
existing gate protects something that is already there to find — grep-before-write
sees code, `creates_types` sees a plan-time declaration. Neither covers a shared
helper that (a) does not exist at worktree-fork time and (b) was not predicted at
Step 2. Two parallel builders each need it, each greps, each correctly finds
nothing, each writes a version under a different name, and the branches merge
cleanly into two divergent implementations of one concept. This closes recursive-
followup row 4 of `enhance-the-plan-w-team-skill-to-close-its-code-reuse-anti-
duplication-protectio-e6b61e7d` (spec:
`docs/specs/resolve-recursive-followup-row-4-enhance-the-plan-w-team-skill-to-
close-its-code-6baae17d.md`).

**Added — `plan-w-team-claim-abstraction.sh`, two layers, ordered strongest-first.**
Layer 1 (`verify`) is **the gate**: diff-driven, reading the run's merged diff at
Step 5, normalizing every newly-added definition's symbol to a concept key, and
flagging a key defined in more than one new file. Zero builder participation
required, and it works with no ledger at all. Layer 2 (`claim`/`release`/`list`) is
advisory: a builder about to write a plausibly-shared new abstraction claims it by
key, and a later builder claiming the same key gets an actionable CONFLICT.

**Why the gate is diff-driven and not ledger-driven.** A voluntary claim protocol
is a duty performed mid-task by an LLM agent. At per-builder compliance `p`, a
two-builder collision is only caught with probability `p²` — and a ledger-driven
verifier can only ever look for symbols that were claimed, so a non-claiming
builder's differently-named duplicate stays invisible regardless of how careful the
other builder was. Making the detector diff-driven moves the guarantee from `p²`
to `1` and demotes the claim layer to honest upside — cutting every dotted
(advisory) edge in the design still leaves a working detector.

**CRUD verbs are deliberately KEPT in the concept-key normalizer, not dropped as
noise.** The first draft of the normalizer dropped `get`/`set`/`create`/`new` as
boilerplate, which collapses `getUser`, `createUser`, `setUser`, and `newUser` onto
the single key `user` — a confident CONFLICT against genuinely different functions.
A false CONFLICT is strictly worse than a missed one: fail-open can rescue a wedged
builder, but nothing rescues a *wrong* verdict once a builder has acted on it. Only
true noise (`util`, `helper`, `common`, `impl`, `shared`, prepositions, articles) is
dropped, and any key that reduces to a single surviving token is downgraded to
advisory-only — one word is never enough evidence to block.

**The same class bit again during Step-5 review, and only adversarial probing found
it.** Sorting tokens is what makes `retryWithBackoff` and `backoff_retry_helper`
collide — but sorting also destroys argument ORDER, and `to` is a noise word. So both
directions of an inverse converter collapsed onto one key: `userToRole` and
`roleToUser` → `role-user`, `centsToDollars` and `dollarsToCents` → `cents-dollars`.
Two genuinely different functions, one blocking CONFLICT. Reading the normalizer did
not surface this; running it over a list of deliberately adversarial symbol pairs did.
Fixed with a directional disambiguator (when a symbol carries `to`/`from`/`into`,
append the first meaningful token), with tests pinning the fix AND both behaviours it
must not break. Lesson worth keeping: for a normalizer, the test that matters is not
"does it collide what should collide" but "does it collide what must NOT".

**A failed `git diff` made the gate report CLEAN.** The Layer-1 scan was
`git diff … | awk`, and in a pipeline `$?` is the LAST stage's status — so a failed
diff handed awk an empty stream, awk exited 0, and `verify` reported clean having
scanned nothing. Measured: `git diff BOGUSREF..HEAD | awk '{print}'` yields `$?=0`.
This is the 1.66.1 pipefail inversion wearing a different hat, and the same fix
applies: capture first, then match.

**The CONFLICT protocol replaces an instruction that can't actually be executed.**
"Import the incumbent" sounds like the obvious loser response, but the incumbent's
symbol does not exist in the loser's worktree — the import fails the PostToolUse
type check, and the builder prompt's own TEST EXECUTION rule then forces a
resolution whose cheapest form is writing the helper locally anyway, which
manufactures the exact duplicate the mechanism exists to prevent, plus a red build.
The real protocol: if the incumbent's declared path already resolves in your
worktree, import it and you're done; otherwise implement locally and tag the
definition with `PWT-CLAIM-DUP:<key> — see <symbol>@<path>`. The loser is never
blocked — the tag costs one comment line, keeps the build green, and makes
Step-5 consolidation deterministic (Layer 1 grades an untagged duplicate with a
recorded CONFLICT as CRITICAL; a tagged one as informational).

**No lock — deliberately, and this is the third time this decision has been made
in this skill and the first time it's been written down as a decision rather than
just an omission.** `pwt-ram-claim.sh:39` and `pwt-claims-cleanup.sh:38` each carry
a hand-written comment — `# keep in sync with <the other> acquire_lock — same lock
dir, same semantics` — because both scripts read-modify-write the same registry and
have to serialize. This ledger doesn't: it's read-then-append, rows are ~300 bytes
(under `PIPE_BUF`), so `O_APPEND` never interleaves. Adding a third hand-synced
`acquire_lock` copy to a feature whose entire purpose is preventing hand-synced
duplication would be self-refuting. The residual same-instant race grants both
claimants; Layer 1 catches the resulting duplicate regardless.

Also: fail-open on every infrastructure error (never wedges a builder), a
`.degraded` sentinel so a failed-open run can never look clean, a `PLAN_W_TEAM_
DISABLE_CLAIM_LOCK=1` kill switch, and exit codes `10`/`11` for CONFLICT/findings
sitting outside the `0/1/2` band so neither is confusable with a crashed script or
a missing script in a partially-synced consumer repo. Documented at
`docs/operations/plan-w-team-abstraction-claims.md`, including the honest limits:
pure synonyms (`fmtMoney`/`formatCurrency`) don't collide and can't without
semantics, and `verify` covers the builder-merge product only — code added by
later Step-5 fix rounds is not re-scanned. Script added to the `sync-to-project.sh`
allowlist (its bats corpus lives in `tests/skill/cases/`, which rsyncs wholesale
and needs no separate entry).
## [1.67.0] — 2026-08-06 (c58efb9)

**Agent-roster prompt audit applied — the orchestrator sheds its Opus 4.5-era scaffolding.**
First application of the `claude-api` skill's `prompt-audit` subcommand (CLI 2.1.221)
to the roster, targeting Opus 5 / Sonnet 5 per Model Tiering v4. Full report:
`docs/operations/prompt-audit-reports/2026-08-06-agent-roster.md`.

- **orchestrator**: description fossil removed ("79 agents / 96.0% / OPUS 4.5
  OPTIMIZED" — this text rode in every session's Agent-tool roster listing); the
  7-phase Extended Thinking Protocol (a 4.5-era planning scaffold that makes
  Opus 5 over-plan) replaced by a four-point "Before Spawning" contract; all
  parenthetical model-generation pins removed in favor of deferring to the
  canonical Model Strategy table, so the next generation rollover cannot strand
  this file again. Body counts + `claude-sonnet-4-5` code samples updated.
- **release-orchestrator**: the self-admittedly-redundant Gate 2 environment
  re-check retired (gate numbering preserved — later gates are cross-referenced
  by number in-file and in pipeline logs, deviating from the report's "renumber");
  stale model IDs in samples/pricing updated.
- **claude-sdk-expert / git-expert/SDK_ENHANCEMENTS / llm-application-specialist**:
  retired-generation model IDs (`claude-sonnet-4-5`, `claude-opus-4`,
  `Claude 3.5 Sonnet`) and stale pricing replaced with current IDs plus a
  standing deferral to the claude-api skill's model catalog.
- **37 specialist descriptions**: "with 2025 knowledge" year claims stripped
  (framework specifics kept — they are real routing signal).
- Deliberately untouched: builder / builder-opus / evaluator / supervisor
  (audited clean), and openrouter-expert / chatgpt-expert (deprioritized by
  standing policy; flagged as retirement candidates, not repaired).

## [1.66.1] — 2026-08-03 (7a87ecc)

**The 1.66.0 backfill hook never fired — `set -o pipefail` inverted its own guard.**
The hook piped `git show HEAD:CHANGELOG.md` into `grep -q`. `grep -q` exits on the
first match, which SIGPIPEs the still-writing `git show`; under `pipefail` the
pipeline then reports FAILURE even though the match SUCCEEDED — so the guard read
"no PENDING heading" and the hook exited 0 without doing anything, every time.

**It is size-dependent, which is why the unit test passed.** The test fixture was a
5-line CHANGELOG: `git show` finished writing before `grep -q` exited, the pipe never
broke, and the hook worked. The real CHANGELOG is 3400+ lines, so grep always exits
early and the pipe always breaks. Caught only by running the shipped hook against
the real repo — 10/10 green unit tests said it was fine.

**Fixed** — capture `git show` output into a variable first, then match against it,
so no pipeline exists to fail. Applied to both the PENDING guard and the version
extraction (`grep -m1` exits early for the same reason). The test fixture now pads
to 4000 lines so a reintroduced early-exit pipeline fails in the suite rather than
in production.

Lesson worth keeping: `set -o pipefail` + any early-exiting reader (`grep -q`,
`grep -m1`, `head`) is a latent inversion whenever the producer is large enough to
still be writing. Capture, then match.

## [1.66.0] — 2026-08-03 (d75c980)

**The CHANGELOG SHA backfill is no longer a "remember to do it" step.** Each release
heading names the commit that shipped it — but that SHA cannot exist before the
commit it names, so it is written one commit later. That step was manual, and manual
steps get skipped: 1.65.1 needed a catch-up backfill commit, and the 1.57.0 entry
went unbackfilled long enough that when its run's goal-state was reaped, the run
could not be traced to its release at all (the defect 1.65.2 fixed).

**Added — `post-commit-pwt-changelog-sha.sh` (PostToolUse, matcher `Bash`).** After a
`git commit`, if the CHANGELOG **in HEAD** carries a `(PENDING)` release heading, the
hook resolves it to HEAD's short SHA and commits just that file.

It deliberately does **not** `--amend`: amending rewrites the commit and changes its
hash, so a SHA written into amended content would name a commit that no longer
exists. The one-commit-later follow-up is the only correct resolution; the hook
removes the human step, not the extra commit.

Guards, each test-covered — this hook writes commits autonomously, so its refusals
matter more than its happy path:

| Guard                          | Why                                                              |
| ------------------------------ | ---------------------------------------------------------------- |
| not `git commit` / `--amend`   | only a real commit establishes a nameable SHA                    |
| commit message contains "backfill" | recursion — the hook's own commit must not re-trigger it      |
| `(PENDING)` absent from **HEAD**   | if it is only in the worktree the commit did not include it, and naming HEAD would attribute the release to the wrong commit |
| index non-empty after commit   | never bundle unrelated staged work into a `docs()` commit        |
| CHANGELOG dirty                | same — surface it and let the human resolve                      |
| any missing tool/path/git failure | fail-open: a missing SHA is a traceability nit, a blocked commit is a work stoppage |

Mirrors `pre-commit-pwt-version-bump.sh` (same jq-first payload parsing, same
`CLAUDE_PROJECT_DIR` resolution, same never-block contract) — that hook already
carried a "backfill" skip clause, so the two now form a matched pair: one bumps
VERSION on the way in, the other closes the SHA on the way out.

Verified: 10/10 in `post-commit-pwt-changelog-sha.test.sh`, and this very entry was
shipped as `(PENDING)` and resolved by the hook itself.

## [1.65.2] — 2026-08-03 (4844a00)

**The ship-verdict artifact carried no skill provenance, so a reaped run became
untraceable.** The versioning system's whole purpose is that any run can be traced
back to the exact release that produced it — `pwt-goal.sh` stamps `skill_version` +
`skill_commit_sha` into the goal-state for precisely this reason. But the goal-state
is **reaped once terminal**, and the Step-6 ship-verdict writer (PWT-TERM3) emitted
only `{slug, verdict, ts}`. Once the goal-state was gone, the ship-verdict was the
only surviving record of the run — and it did not say which release wrote it.

Field evidence (2026-08-03 fleet audit): the 1.57.0 model-tiering-v3 run
(`…4148b226`) survives *only* as its retro + ship-verdict artifacts; its goal-state
was reaped. Both carried `skill_version` from an older writer but no
`skill_commit_sha`, and today's writer stamps **neither** — so the regression had
widened silently. Across 4 repos / 210 versioned runs those were the only two gaps;
both have been backfilled to `aa09ae5` from this CHANGELOG's 1.57.0 heading.

**Fixed — `__pwt_write_ship_verdict` now stamps provenance (`05-ship.md` §6-0a-bis).**
The writer records `skill_version` + `skill_commit_sha` alongside the existing
fields. It prefers `PWT_SKILL_VERSION` / `PWT_SKILL_COMMIT_SHA` — already exported by
`pwt-goal.sh` — so every artifact within one run agrees even if HEAD moves mid-run,
and falls back to the `VERSION` file plus `git rev-parse --short HEAD` so an
**attended** ship (no `pwt-goal.sh` in the chain) still records provenance. Every leg
is fail-open: a missing VERSION or a non-repo cwd yields `""` and never blocks a
ship. Purely additive — the goal-evaluator's `jq -r '.verdict // ""'` reader and the
C3 anti-spoof corroboration are untouched.

Verified: the bats extractor (`ship-verdict-post-push-reliability.bats`) still lifts
the helper cleanly — 24 lines terminating at the column-0 `}` — `bash -n` clean, all
three structural assertions hold, the pre-push fail-safe still refuses to write, and
both the exported-env and self-derived fallback paths produce correct stamps.

## [1.65.1] — 2026-08-02 (cd60cdb)

**Ship-merge of the recursive-followup row 1 fix.** The 1.64.1 work below was cut
from `188f330` and passed its ship-readiness gate on 2026-07-31 (SUITE_EXIT=0,
866 bats + 93/93 shell + 1/1 TS) — but the run then **stopped short of its own
Step 6 merge and Step 8 retro**, leaving the branch unmerged while `main` moved on
to 1.65.0. That is precisely the failure class the fix addresses, reproduced one
more time on the run that fixed it. This entry records the merge to `main` and the
renumber 1.64.1 → 1.65.1 (the branch predates 1.65.0; no content changed).

A second, independent defect surfaced during recovery: the SessionStart auto-sync
ran its **consumer** gitignore self-heal against a *source-repo worktree*, appending
consumer ignore rules and `git rm --cached`-ing the 106-file skill test corpus. The
worktree was restored from HEAD; the self-heal scoping is filed as a follow-up.

**Fixed — `pwt-status.sh` rollup broke on a two-document capture (found by the ship
gate, pre-existing on `main`).** `pwt-status.sh` captured helper output as
`$(helper ... || echo FALLBACK)`. `claude-agents-extended.sh` **prints its payload
and exits 1** by design ("here is what I have, but I learned nothing reliable"), so
that idiom CONCATENATED the fallback onto the payload and the variable held two JSON
documents. The validity guard did not catch it: `jq -e .` accepts a multi-document
stream. Downstream, `jq -n --argjson` died with "invalid JSON text" (so `--json`
rollup emitted **nothing**, 3 assertions red) and `... | length` returned one number
per document, so `[ "$WF_N" -gt 0 ]` got `0\n0` → `integer expression expected` on
stderr. Replaced both call sites with a `single_json` helper that slurps (`jq -s`) —
which is simultaneously the true single-document assertion (`length == 1`) and the
repair (keep the last document) — and falls back on anything unparseable.
`pwt-status.test.sh` 35/38 → **38/38**. Swept the other wrapper consumers
(`plan-w-team-route-prompt.sh`, `plan-w-team-followup-drain.sh`): they capture
without `|| echo`, so `pwt-status.sh` was the only site with this bug.

**Fixed — the row-1 regression test was not hermetic against its own subject.**
`plan-w-team-goal-evaluator-main-lookup.test.sh` asserts how the evaluator
*resolves* goal-state sources, but inherited the two env families that rewrite
exactly that resolution. With `PWT_PROJECT_ROOT_OVERRIDE` set in the caller's
shell — the documented workaround for worktree-CWD fragility, so a plausible
operator shell — the override won over git-common-dir and AC1/AC6 went red
(`passed=6 failed=2`) while the code under test was correct. The
`PLAN_W_TEAM_DISABLE_*` family is worse: `pwt-goal.sh --worker-only` **exports**
it, so the suite could go red inside precisely the autonomous worker this test
protects. The test now scrubs both families at the top (AC3 re-exports the
override per-invocation, its one legitimate use). Verified 8/8 under a clean
env, under `PWT_PROJECT_ROOT_OVERRIDE=<worktree>`, and under
`PLAN_W_TEAM_DISABLE_GOAL=1`.

**Fixed — closing a follow-up row never drained the ledger (found while closing
this run's own row 1).** The ledger is append-only, so `close` appends a
resolution row and the ORIGINAL keeps `status:"open"` forever — but `list` and
`stats` filtered on `.status` read straight off the raw rows. A closed row was
therefore still reported open and the counters never moved: closure only ever
stacked another "closed" row on top of a permanently-open one, and the backlog
was **structurally undrainable** (34 open on 2026-07-26, 36 by 2026-08-02, none
removable). Row 1 proved it end-to-end — closed 2026-07-31, still listed open,
and closed a *second* time on 2026-08-02 because the pre-existing "already
closed?" guard reads the row's own `.status`, which append-only pins at "open".
Fixed by resolving effective status through the `closes_index` back-reference:
`list`/`stats` treat a row as closed when a later row closes it, `stats` counts
over ORIGINAL rows only (resolution rows are bookkeeping, not backlog) and
de-duplicates by distinct closed INDEX so pre-fix duplicate closures count once,
and `close` now scans for a prior resolution row instead of trusting `.status`.
Row 1 drains on the fixed reader (`oldest_open` advances 2026-06-07 →
2026-06-08). Regression: 5 new cases in `followups-ledger-tool.bats` (12 total),
all verified RED against the pre-fix script. The existing case pinned that the
resolution row is *appended*; nothing pinned that it takes *effect* — precisely
the gap the bug lived in.

## [1.65.0] — 2026-07-31 (58adc49)

CLI version uplift **2.1.195 → 2.1.220** (25 versions). Full analysis:
[`docs/operations/version-uplift-reports/2026-07-31-2.1.220.md`](../../../docs/operations/version-uplift-reports/2026-07-31-2.1.220.md).

**Fixed — dead Agent-tool parameter (breaking at CLI 2.1.212).** The `mode` parameter on
the Agent/Task tool is deprecated and **ignored**. The skill was still emitting
`mode: "auto"` in both builder spawn blocks (`03-execute.md`) and — worse — documenting
`mode: "plan"` in `shared/cognitive-frameworks.md` as the plan-approval switch for
security-critical work. That escape hatch had silently become a no-op. Removed the
parameter from both spawn blocks and rewrote the plan-approval guidance to use
`permissionMode` frontmatter or an explicit submit-plan-and-wait instruction. Builders'
effective posture is unchanged (it comes from the session `defaultMode: bypassPermissions`,
not from `mode:`), so this is a correctness/documentation fix, not a behaviour change.

**Docs — knowledge truth-up.** Hook-event table corrected 20 → **29** events in `CLAUDE.md`
(adds `UserPromptExpansion`, `PermissionDenied`, `PostToolBatch`, `TaskCreated`,
`StopFailure`, `CwdChanged`, `FileChanged`, `PostCompact`, `Elicitation`,
`ElicitationResult`, `DirectoryAdded`), plus the newer hook output fields
(`permissionDecision: "defer"`, `updatedToolOutput`, `watchPaths`, `applyPermissionRules`).
Backfilled the 2.1.155–2.1.220 rows in `docs/operations/claude-code-compatibility.md` — the
2.1.195 report's step 4 was never executed, leaving a 65-version hole. Recorded the new
subagent fan-out limits and the `docs.claude.com` → `code.claude.com` host move.

**Tests.** `opus48-uplift.bats` AC5 assertion updated to the new count and renamed into BDD
shape; stale `r10-legacy-allowlist.txt` entry removed rather than extended. 474/474 green.

**Not adopted this pass (tracked in the report):** explicit pinning of the three new subagent
limits (`CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH` / `_MAX_SUBAGENTS_PER_SESSION` /
`_MAX_CONCURRENT_SUBAGENTS`), the `AskUserQuestion` no-auto-continue hang risk (2.1.200) and
the `waitingFor` candidate it reopens, and verification of the reduced background-subagent
tool pool (2.1.198). These change runtime behaviour and warrant their own change.
## [1.64.1] — 2026-07-31 (02006fa)

Recursive-followup **row 1** (`worker-only-stops-short-rootcause`) resolved — and it
was NOT the bookkeeping closure it looked like. The row's own text said "Fixed in
1.35.0"; all three 1.35.0 components were still present at 1.64.0; and the bug was
reproducing anyway. This run caught it **on itself**.

**The gap.** `pwt-goal.sh --worker-only` dual-seeds the anti-skip goal-state:
(1) the worker's runtime worktree, (2) the canonical MAIN `.claude/state/`. Arm (1)
is gated on `[ -d "$WORKER_WT_ROOT" ]` and loses its race against `claude --bg`
worktree creation, so in practice **only the MAIN copy exists**. The worker's
goal-evaluator resolved state from `$PWD/.claude/state` and
`$CLAUDE_PROJECT_DIR/.claude/state` — and under `--worktree` **both equal the
worktree**. Two nominal sources, one effective source, neither reaching MAIN.
`GOAL_FILES` came back empty, the hook exited 0, and the deterministic anti-skip
anchor was **inert on exactly the autonomous path it exists to protect**.

`pwt-goal.sh:1674-1676` had asserted a "git-common-dir MAIN lookup (defense-in-depth
Fix B)" since 1.35.0. It was never implemented — canon describing a control that did
not exist.

**Evidence (live, this run).** A temporary probe in the real Stop hook recorded
`cpd=<worktree> pwd=<worktree> fallback=<worktree>/.claude/state goalfiles=0`, while
the same hook with `CLAUDE_PROJECT_DIR=<main>` found the slug and blocked the stop.

- **Evaluator third source** — `.claude/hooks/plan-w-team-goal-evaluator.sh` now also
  reads the MAIN checkout via `git rev-parse --git-common-dir`
  (`PWT_PROJECT_ROOT_OVERRIDE` wins first, preserving hermetic test-corpus isolation),
  de-duplicated by resolved path so a MAIN-checkout run still evaluates each goal once.
  Fail-open throughout: unresolvable MAIN degrades to the prior two-source behavior.
  Terminal write-back targets `$GOAL_FILE` — the file actually read — so a MAIN-only
  goal now persists its terminal state where `await-terminal.sh` and the Run-State
  Router read it.
- **§1.5 criteria injection** — `01-specification.md` derived `GOAL_FILE` cwd-relative,
  so a worktree worker hit "state file missing — skipping" and injected **no**
  `feature_specific_done_criteria` at all: the run's entire AC contract silently
  un-enforced. MAIN resolution is now hoisted above the guard (and the later
  dual-write block reuses it instead of re-deriving).
- **Comment accuracy** — `pwt-goal.sh` now points at the real implementation and
  records the history, so the claim and the code agree.
- **Regression** — `.claude/scripts/plan-w-team-goal-evaluator-main-lookup.test.sh`
  (8 assertions, hermetic git repo + real worktree, bash 3.2). Verified RED before
  the fix (4 failures) and GREEN after. Added to the `sync-to-project.sh` allowlist.

Note for whoever picks up row 43 (`criteria-marking-never-flips-met`): that path is
still broken and was deliberately NOT used to verify AC6 here — the test drives a real
terminal instead, so it asserts this fix rather than someone else's bug.

## [1.64.0] — 2026-07-26 (458fa3f)

Four deferred items closed, including a design flaw the operator caught: the
drainer's 03:00 timer is close to useless on a laptop.

### Fixed — the drainer was scheduled for a machine that is asleep

`StartCalendarInterval` at 03:00 assumes an always-on host. On a laptop that is
shut or asleep at that hour the drainer would almost never fire — a mechanism
that reads as scheduled and effectively is not, which is the same class of defect
as 1.60.0's hooks and 1.63.1's dead sync paths.

The drainer is now also invoked from **`SessionStart`** — the moment the machine
is demonstrably awake and in use — following the precedent already in the repo
(`session-start.sh` is how `plan-w-team-gc-timer-install.sh` gets run).
Backgrounded, fail-open, kill switch `PWT_FOLLOWUP_DRAIN_DISABLE=1`. The launchd
entry stays as post-wake catch-up for always-on machines; nothing depends on it.

Two trigger paths need a rate limit, so the drainer gained a **cooldown**:
`PWT_FOLLOWUP_DRAIN_COOLDOWN_H` (default 20h — roughly daily without pinning to a
wall-clock hour a laptop may sleep through). The stamp is written **before** the
spawn, so a crashed spawn cannot free the cooldown and retry in a tight loop; a
test asserts that ordering.

### Fixed — the self-competition gate could never open

It counted **any** background session for the repo. A laptop accumulates bg
sessions from ordinary work, so the drainer refused indefinitely — six live
sessions were already blocking it on the day it shipped. It now counts only live
`/plan-w-team` **workers**: a background session named by a goal-state whose
`terminal_state` is still null. That is what actually competes for the same files.

### Changed — `opus-4-7-practices.md` §5 and §7 rewritten (were banner-corrected only)

1.60.0 flagged both as stale with a banner but left the bodies intact. Now:

- **§5 effort** — start `xhigh` for coding/agentic and `high` elsewhere, then sweep
  **downward** against evals. `low`/`medium` are the primary cost/latency control
  on Opus 5, not a quality risk. The 4.7-scoped under-thinking warning is gone.
  Notes explicitly that **no sweep has been run since the Opus 5 rollover** in
  1.58.0, so current pins are inherited 4.8-era values.
- **§7 length** — an explicit length instruction is a legitimate instrument (a
  positive exemplar is an *addition*, not a substitute — reversing the 4.7 advice).
  Separates conversational output from **written deliverables**, which need their
  own calibration. States that `effort` does **not** reliably shorten visible
  output, so length is a prompting problem. Adds the tail-reminder pattern for
  long prompts.

The banner now reads REVISED rather than claiming the bodies are unrevised.

### Added — length calibration in `06-post-ship.md` §7a

The stage that writes to disk most had no length guidance in 329 lines. Adds a
REQUIRED budget per classification: **mechanical** touches only the stale token
(no reflowing, no explanatory notes); **substantive rewrite** stays within ~±20%
of the section it replaces; **new section** gets one paragraph plus at most one
example. Plus an explicit never-add list — no unrequested summary/overview,
"further reading", table of contents, or closing restatement — and the reader test
("would someone who knows this codebase skip this sentence?").

### Added

- `tests/skill/cases/followup-drain.bats` grows to 15 cases, covering the
  cooldown in both directions, the stamp-before-spawn ordering, the narrowed
  worker predicate, and the SessionStart trigger wiring.

## [1.63.1] — 2026-07-26 (d6856ff)

Two sync-profile defects found while verifying that 1.63.0 actually reached the
consumers. It had not. Third instance today of the same class: a declaration that
reads as a guarantee and enforces nothing.

### Fixed — 1.63.0 never reached consumer repos

`sync-all-projects.sh` passes no `--profile`, so every bulk sync runs `minimal`,
which refreshed ~17 of 160 agents. Seven of the eight Step-5 slot-3 domain
reviewers named by `04-fix-first-review.md`'s selection table were absent from it,
so the allowed-tools sweep landed in source while **36 stale agent files survived
in every consumer** — still declaring a read-only posture nothing enforced.

`api-expert`, `database-expert`, `documentation-expert`, `kubernetes-specialist`,
`llm-application-specialist`, `style-theme-expert` and `terraform-specialist` are
now in all three profiles (minimal 17→24, web 25→28, backend 25→29).

### Fixed — my own ratchet was passing on an incomplete list

1.59.1 codified "every agent a synced stage file mandates must appear in every
profile" and then shipped a required-list naming only the Pass-1 slots and the
`team/*` agents, omitting the slot-3 domain reviewers. The guard ran and proved
less than it appeared to — the vacuity trap of `ratchet-non-vacuity.bats`, reached
through an incomplete list rather than an empty corpus.

### Fixed — 14 profile entries pointed at a directory that does not exist

`web` and `backend` each carried 7 entries under `specialists/`. **There is no
`.claude/agents/specialists/` directory**; all 14 agents live under
`research-planning/`. An rsync `--include` of a missing path is a **silent no-op**,
so any repo synced with those profiles had been receiving nothing for those
entries, with no error and no warning. All 14 remapped to their real paths.

The required-list check could not catch this because it only inspected its own
list. `sync-profile-pipeline-agents.bats` gains a case asserting **every** entry in
**every** profile resolves to a real file.

### Note

Shipping this requires a one-time `--profile full` sync to flush the 36 stale
agent files already present in each consumer; the corrected `minimal` only keeps
them current from here forward.

## [1.63.0] — 2026-07-26 (3302f19)

The `allowed-tools:` sweep. 42 agent files declared tool policy through a key the
harness does not read — the same failure class as the 1.60.0 hook bug: a
declaration that reads as a guarantee and enforces nothing.

Count correction: an earlier note said 56. That came from a raw grep matching
`allowed-tools:` anywhere in a file, including prose — and it IS a legitimate key
for *skills*, so agent-bundled docs discuss it correctly. Parsing only YAML
frontmatter gives **42**.

### Fixed — the dead key removed from all 42

`allowed-tools:` is a SKILL frontmatter key; in an agent file it is inert. The
canonical agent allowlist is `tools:` ("inherits all if omitted",
`CLAUDE_CODE_CLI_REFERENCE.md:249`) and the denial key is `disallowedTools:`.
Removed from every agent frontmatter, each with a note naming the canonical keys.

**Not converted to `tools:`, deliberately.** Activating 42 dormant allowlists —
written while they had no effect and never validated — would restrict each agent
to that list, and any agent whose list omits a tool its own prompt tells it to
use would simply break. The sweep removed the dead key and re-expressed only the
restrictions it genuinely implied.

### Fixed — nine agents whose read-only intent was never enforced

Eight cloud specialists (`aws`, `azure`, `gcp`, `argocd`, `kubernetes`,
`terraform`, `mongodb`, `redis`) had allowlists omitting **both** `Write` and
`Edit`, while live config denied only `Write` — the harness reported them as "All
tools except Write", leaving `Edit` open. These fill Step-5 domain **reviewer**
slots (`04-fix-first-review.md` §5b-pre slot 3), so this is the same defect fixed
in `code-review-expert` earlier today: a reviewer able to edit the code it
reviews. Both are now denied. `github-security-orchestrator` — a security auditor
whose denial list was empty — gains `Write`/`Edit`/`NotebookEdit`.

If a consumer repo assigns one of these as an *implementer*, it will now refuse.
That refusal matches what the frontmatter author expressed; override deliberately
by editing the agent.

### Deliberately NOT done

- **`MultiEdit` denials.** Absent from the current tool table, so denying it would
  add a fresh inert declaration — exactly what this removes.
- **`security-expert` keeps `Edit`** (implements retroactive-security-coverage
  tasks) and **`system-architect` keeps `Write`/`Edit`** (authors design docs).
  Both pinned by a test that fails in **both** directions, so a later sweep cannot
  "complete" the lockdown and silently break those lanes.
- **A `NotebookEdit` denial inferred purely from omission.** Applied across all 42
  at first, then reverted for `mlops-specialist` and `llm-application-specialist`,
  which plausibly edit notebooks. An omission is not an expressed intent.

### Added

- `tests/skill/cases/agent-tool-key-canonical.bats` (5 cases): no frontmatter may
  carry the dead key; the read-only specialists deny both mutating tools; the two
  exceptions retain theirs; no invented `MultiEdit` denial; plus a non-vacuity
  guard. Its matchers are scoped to frontmatter — the first version false-positived
  on an SDK doc discussing `MultiEdit` in prose, the third over-broad-matcher slip
  of the day.

## [1.62.0] — 2026-07-26 (86499d1)

The scheduled follow-up drainer 1.61.0 declined to build, plus a retraction of
the reasoning that declined it.

### Fixed — a false claim, already shipped to 22 repos

1.61.0 recorded that four `/plan-w-team` worktrees had stalled on the same work
and concluded that "scheduling autonomous workers against a queue is premature
until that stall is understood." **That was wrong.** The interruptions were
external — a machine reboot and an Anthropic account switch mid-session — with no
pipeline fault involved. The claim is retracted in place (struck through, not
deleted, so the correction is visible to anyone who read the original) in both
the 1.61.0 entry and `.claude/state/pwt-brief-followup-hardening.md`.

This matters because that sentence read as evidence of a reliability problem and
was already synced to 22 repos. A future session — human or agent — would have
found it and made decisions on it. Do not cite those worktrees as evidence; they
are debris, and the worktree GC reclaims them.

### Added — opt-in scheduled ledger drainer

`.claude/scripts/plan-w-team-followup-drain.sh` spawns **one**
`pwt-goal.sh --worker-only` run against the **oldest** open ledger row.

The surviving design constraint was always the *actor problem*: the friction-log
timer was removed because a scheduled **writer** with no actor is theatre. A
`--worker-only` run is an actor, which answers that objection on its own terms —
and the distinction deliberately does not generalise to digests or notifications.

Refusal is the behaviour under test, since the dangerous failure is spawning when
it should not:

- **Default OFF.** Enable via `PWT_FOLLOWUP_DRAIN_ENABLE=1` **or** by touching
  `.claude/state/pwt-followup-drain-enabled` — the file form exists because
  launchd does not reliably inherit an interactive shell's environment.
- **One row per invocation**, never a batch. Most rows are LOW severity; a
  parallel drain would spend a weekly Max budget on the least important work in
  the repo.
- **Oldest row first** — the backlog head, so two-month-old rows actually get
  picked rather than the queue draining from the wrong end.
- **Capacity chain, all three must return `SPAWN_OK`**: `ram-budget.sh --bg-only`,
  `disk-budget.sh`, `pwt-fair-share.sh`. An unreadable gate **fails closed** — it
  is never treated as permission.
- **Refuses when a bg session is already live** for the repo (no self-competition
  for the same files).
- **Never crosses the PWT-DS2 cascade boundary**: refuses outright when
  `PLAN_W_TEAM_DISABLE_PROMPT_ROUTE=1`. Additive to that guard, never an
  exception to it.
- The generated brief scopes the run to one row and states that **closing the row
  with a reason is a valid outcome**, so a worker does not invent work to look
  productive.

Rides the **existing** GC timer (`plan-w-team-worktree-gc.plist.template`) rather
than shipping a second installer — one timer, one plist. It is inert there until
opted in. Allowlisted in `sync-to-project.sh`.

- `tests/skill/cases/followup-drain.bats` (10 cases), including one asserting
  there is still exactly **one** plist template, since a second installer is
  precisely what this avoided.

## [1.61.0] — 2026-07-26 (d7053cd)

Three queued follow-ups, closed. Theme continues from 1.60.0: **a guard that
cannot fail is indistinguishable from one that works.** All three items are
variants of that.

Trigger: these were the surviving actionable output of the ladder audit. An
autonomous run was attempted first and was interrupted mid-specification —
externally, by a machine reboot and an account switch, **not** by a pipeline
fault (see the retraction under "Deliberately NOT done"). Its partial output was
unusable (a comment-only hook edit documenting protection it did not perform, and
a NUL-corrupted script), so the work was completed in-session and that worktree
was discarded.

### Added — shell-rc write guard (was deferred 2026-06-28)

`.claude/hooks/config-protection.sh` now blocks writes to shell startup files
(`.zshrc`, `.zshenv`, `.zprofile`, `.zlogin`, `.zlogout`, `.bashrc`,
`.bash_profile`, `.bash_login`, `.bash_logout`, `.profile`, `.inputrc`) that sit
**directly in `$HOME`**. A `~/.zshrc` write is the one blast radius that escapes
every repo-scoped guardrail — `damage-control.sh`'s `zero_access`/`read_only`
arrays contain no shell rc file.

**Path scoping is the whole point, not a refinement.** Basename-only matching
over-blocks legitimate in-repo `.zshrc`/`.profile` fixtures across ~22 consumer
repos, which is exactly why this was deferred rather than shipped — the design
implemented here is the one specified at
`docs/operations/version-uplift-reports/2026-06-27-2.1.195.md:55-58`. Traversal
aimed into `$HOME` (`$HOME/r/../.zshrc`) fails closed rather than being resolved
in pure bash. bash 3.2 compatible; `patterns.yaml` deliberately untouched (dead
config — `damage-control.sh:11` assigns it and never reads path lists from it).

- `tests/skill/cases/shell-rc-write-guard.bats` (8 cases). The *allow* cases are
  load-bearing, not filler — they encode the reason for the original deferral.

### Added — non-vacuity guards for the ratchets

`tests/skill/cases/ratchet-non-vacuity.bats` (6 cases). A large share of this
suite passes when a search finds **nothing**; if the enumeration breaks, the
search finds nothing for the wrong reason and the ratchet reports PASS.

This is not hypothetical: while writing `hook-enforcement-contract.bats` for
1.60.0, its resolver silently returned zero files, making two class-level
ratchets vacuous. Rather than rewrite each ratchet, this guards the **corpora**
they sweep — the four fable fan-out roots, the nine stage files, the bats
corpus, the `settings.json` hook registry, and the agent corpus. A final case
proves the counting helper discriminates, so this file cannot itself become the
vacuous guard. Thresholds are tripwires for a broken enumeration, not coverage
targets.

### Added — follow-up ledger tooling

`.claude/scripts/plan-w-team-followups.sh` — `list` / `stats` / `show` / `close`
over `plan-w-team-recursive-followups.jsonl` (34 open, oldest 2026-06-07).
Closure **requires a reason** and **appends** a resolution row rather than
rewriting history, matching the existing writers. Allowlisted in
`sync-to-project.sh` so it reaches consumer repos.

The Step-0 preflight now surfaces the **age of the oldest open row** and states
that it is showing 5 of N. The count was always shown; five recent lines out of
thirty-four read like a short list rather than a two-month backlog.

- `tests/skill/cases/followups-ledger-tool.bats` (7 cases).

### Deliberately NOT done

- **Auto-close by slug match**, which the audit recommended. A follow-up is a
  deferral recorded *during* run X — precisely the work X did not do. Closing
  rows because X shipped would erase the backlog rather than drain it, turning a
  visible debt invisible. The reason-required test pins this decision.
- **A scheduled worker to drain the queue.** ~~Four `/plan-w-team` worktrees have
  now stalled on this same work… premature until that stall is understood.~~
  **CORRECTED 2026-07-26 — this reasoning was wrong and is retracted.** The
  stalled worktrees were caused by external interruptions during the session (a
  machine reboot and an Anthropic account switch mid-run), not by any pipeline
  defect. There was no stall to understand. Do not cite those worktrees as
  evidence of a `/plan-w-team` reliability problem — they are debris, and the
  worktree GC reclaims them. The drainer ships in **1.62.0**; the surviving
  design constraint was always the actor problem, which a `--worker-only` run
  satisfies.

## [1.60.0] — 2026-07-26 (e58b208)

Hook enforcement contract repaired. Theme: **the guards reported blocking while
allowing.** Four block sites across two PreToolUse hooks used a non-blocking exit
code, and damage-control's entire `ask` tier used the wrong event's schema — so
the operations they exist to gate proceeded silently.

Trigger: surfaced while auditing `/plan-w-team` against Boris Cherny's AI-adoption
ladder; unrelated to the ladder itself, and verified directly against the hook
sources and both hook references before any edit.

Why this is severe here rather than cosmetic: the standing posture is
`bypassPermissions`, so there is no permission dialog behind these hooks. As
`.claude/docs/SKILL_PERMISSION_CONVENTION.md` puts it, "Safety is in the hooks,
not the allow-list" — this layer was 100% of the policy.

### Fixed — `exit 1` does not block

The contract (`CLAUDE_CODE_CLI_REFERENCE.md:471-477`,
`claude-sdk-expert/docs/hooks.md:126-138`): exit 0 allows and **stdout is parsed
for JSON control**; exit 2 **blocks** and shows **stderr**; any other code is a
non-blocking error and **the tool call proceeds**.

- `block-protected-paths.sh` (3 sites) and `block-gh-actions-build.sh` (1 site)
  printed `{"decision":"block"}` to stdout and then `exit 1` — failing twice
  over: exit 1 did not block, and the JSON was never read because stdout is only
  parsed on exit 0. All four now write the reason to **stderr** and `exit 2`.
- This silently disabled the PWT-C4 guard that stops a bg worker self-authoring
  the secret-scan allow-file, and the PWT-P9b no-GitHub-Actions governance guard.
- `block-gh-actions-build.sh:5-8` was itself written to eliminate "ENFORCING but
  doesn't enforce" theater, and reproduced the bug inside the fix.

### Fixed — the whole `ask` tier was inert

`damage-control.sh` emitted a top-level `{"decision":"ask"}` with `exit 0`. That
is the **PermissionRequest** schema (`CLAUDE_CODE_CLI_REFERENCE.md:484-492`); for
PreToolUse it is `hookSpecificOutput.permissionDecision` (`hooks.md:249-262`).
Exit 0 with an unrecognized payload means **allow**, so `DROP`/`TRUNCATE TABLE`,
`gcloud … delete`, `az … delete`, `docker system prune`, `redis-cli FLUSHDB` and
the final-artifact `rm` guard were all ungated. Now emits the correct schema,
with quote/backslash escaping so a malformed payload cannot reintroduce the same
silent-allow failure.

Its `block` path already exited 2 (so it did block) but printed the reason to
stdout, which is not read on exit 2 — Claude was never told why. Reason now goes
to stderr.

### Changed — `ask` fails closed in an unattended worker (BEHAVIOR CHANGE)

An `ask` needs a human at the keyboard. A bg `/plan-w-team` worker has none, and
under `bypassPermissions` an ask auto-approves — so unattended, `ask` degraded to
`allow` on exactly the irreversible operations it exists to gate. When
`PLAN_W_TEAM_DISABLE_PROMPT_ROUTE=1` (set by `pwt-goal.sh` for every spawned
session), an `ask` now becomes a block telling the worker to surface a
`pending_escalation`. Interactive sessions are unchanged.

**Operator note:** autonomous runs that previously performed an ask-tier
operation will now stop instead. Escape hatch:
`PLAN_W_TEAM_ALLOW_DESTRUCTIVE_UNATTENDED=1`.

### Added

- **`tests/skill/cases/hook-enforcement-contract.bats`** (11 cases): per-hook
  behavioral assertions plus two class-level ratchets scoped to hooks actually
  registered on PreToolUse and stripped of comments. Both scopings are
  load-bearing — a **Stop** hook legitimately uses top-level
  `{"decision":"block"}` with exit 0 (`plan-w-team-goal-evaluator.sh:1106`), and
  the fixed hooks document the old shape in their own headers.
- A third ratchet asserts the resolver finds ≥3 PreToolUse hooks. It caught the
  first version of itself returning **zero** files, which made the other two
  ratchets pass vacuously — the same invisible-failure class they exist to catch.

### Fixed — a test that pinned the bug

`tests/skill/cases/secret-allow-worker-guard.bats:23` and `:42` asserted
`status -eq 1`, encoding the broken behavior as the expectation. Both now assert
`-eq 2`.

## [1.59.1] — 2026-07-25 (d92aafb)

Distribution fix: the sync profiles omitted the Step-5 pipeline agents, so
1.59.0 would have shipped its stage-file changes without the agent changes they
depend on.

Trigger: found while pre-flighting the 1.59.0 rollout to consumer repos. Caught
before syncing, not after.

### Fixed — `minimal` profile shipped stage files without the agents they mandate

`.claude/commands/` is **always** synced; `.claude/agents/` is filtered by
profile — and `sync-all-projects.sh` passes no `--profile`, so every bulk sync
runs `minimal`. That profile carried only `team/silent-failure-hunter` out of the
six agents 1.59.0 touched.

The failure mode is silent rather than loud: consumers already hold all ~160
agent files from an earlier full sync, so the omitted agents are **stale, not
missing**. Nothing errors — the consumer simply runs `04-fix-first-review.md`'s
new instructions against the previous revision of every agent it names, keeping
the under-reporting gap analyzers and the write-granted reviewers indefinitely.

- **`minimal` gains five pipeline agents**: `code-review-expert` and
  `security-expert` (Pass-1 slots 1-2, "Skip If: Never" at `04-fix-first-review.md:443`
  and `:444`), `test-gap-analyzer` and `security-gap-analyzer` (§5c-bis / §5d-bis,
  default-on for any code diff), and `system-architect` (§1b-pre spec fan-out,
  `01-specification.md:336`).
- **`web` and `backend` gain three**: `system-architect`, `test-gap-analyzer`,
  `security-gap-analyzer` (both already carried the two reviewers).
- The invariant is now stated in-file above the profile definitions: *every agent
  a synced stage file mandates must appear in every profile.*

### Added

- **`tests/skill/cases/sync-profile-pipeline-agents.bats`** (4 cases) pins the
  invariant across `minimal`/`web`/`backend`, and additionally asserts each
  profile entry resolves to a real file on disk — a typo'd or moved path makes
  the rsync `--include` a silent no-op, which is the same class of invisible
  failure.

## [1.59.0] — 2026-07-25 (62e47b3)

Opus 5 prompt-hygiene correction + reviewer read-only enforcement. Theme:
**1.58.0 rolled the model but not the prompts.** The Brain tier became Opus 5,
while three pieces of instruction text still encoded Opus 4.7/4.8 behavior that
Opus 5 inverts — and the Step-5 reviewers turned out never to have been read-only
in the first place.

Trigger: an audit of the pipeline against Anthropic's published Opus 5 prompting
guidance and a third-party "graph engineering" rubric. The graph-structural half
came back clean (typed nodes, deterministic gates, durable state, bounded cycles,
a real worker/invigilator/evaluator split); every defect below is Anthropic-sourced
except the reviewer tool grants, which the rubric surfaced.

**Provenance — read this before re-litigating any change below.** The rubric arrived
via a viral X post that credited it to Boris Cherny; **he has since publicly stated
he did not write it**, so it carries no authority and none of the changes here rest
on it:

- The two delegation/reporting fixes are sourced **verbatim from Anthropic's official
  Opus 5 prompting guide** (`platform.claude.com/docs/en/build-with-claude/`
  `prompt-engineering/prompting-claude-opus-5`, §"Controlling subagent spawning" and
  §"Capability improvements → Code review and bug-finding"). Independent of the post.
- The reviewer read-only fix rests on **this repo contradicting itself** —
  `04-fix-first-review.md:482` ("Do not edit files… Read-only review") and `:824`
  (reviewers "lose their neutral-reviewer frame when they touch code") versus
  frontmatter that granted Write/Edit — plus the empirically verified fact that
  `allowed-tools:` is inert in an agent file (`CLAUDE_CODE_CLI_REFERENCE.md:249`).
  The rubric pointed at where to look; it is not the evidence.
- Recommendations that rested on the rubric ALONE were **declined**: the ~500-token
  router budget, splitting stage files under "one idea per file", re-adding an
  `expired` terminal state (deliberately removed 2026-05-19, `goal-conditions.md:217`),
  and per-answer token accounting.

Known limitation: the audit's organizing taxonomy came from that rubric, so the sweep
is shaped by what it thinks to ask about. Treat it as one lens, not a complete review.

### Changed — delegation guidance is INVERTED for Opus 5

- **`shared/opus-4-7-practices.md` §3 rewritten** from "Deliberate Subagent
  Spawning" (push the lead to fan out — correct for 4.7/4.8, which under-delegated)
  to **"Bounding Subagent Spawning"**. Opus 5 delegates readily on its own, so the
  section now carries a three-part warrant test (disjoint files · more than a
  handful of tool calls · results need not be read together), "prefer one subagent
  over several", and "never delegate verification of your own work". The
  structurally-independent Step-5 reviewer fan-out is explicitly carved out and
  KEPT — those reviewers never saw the builder's reasoning, which is the point.
- **New Opus 5 banner** at the top of the same file. The 4.8 banner's blanket claim
  that "Every pattern below still applies" was the load-bearing error; it is now
  scoped to history, with §5 (effort) and §7 (length) flagged inline as known-stale
  pending revision, and a standing "do not add self-verification scaffolding" rule.
  Deterministic gates — test suites, `tsc --noEmit`, the ship gate's exit code —
  are explicitly excluded from that rule: they are not model self-verification.
- **Two duplicate sites corrected** so the inversion cannot be read the old way:
  `plan-w-team.md` Opus practices bullet, and `03-execute.md` §3 tip. The §9
  cross-reference table row for Steps 3-4 now reads "bounded parallelism".

### Fixed — Step-5 gap analyzers instructed themselves to under-report

- **`test-gap-analyzer.md` and `security-gap-analyzer.md`** both carried the
  byte-identical line _"Report 5 well-reasoned high-severity gaps over 30
  low-severity ones."_ Anthropic documents this exact prompt shape as one Opus 5
  follows literally, suppressing recall. Both are pinned `model: claude-opus-5` and
  run default-on for any code diff (§5c-bis, §5d-bis), so the suppression was live.
  Replaced with report-everything-with-severity-and-confidence; the lead-side filter
  that converts findings into tasks already existed, so no new machinery.
  Note the original bolded label ("Prefer coverage over completeness") already
  argued the opposite of the sentence beneath it.

### Fixed — Step-5 reviewers were never actually read-only

`04-fix-first-review.md:482` has always said "Do not edit files. Do not auto-fix.
Read-only review." — enforced by **prose only**. The frontmatter disagreed:

- **`code-review-expert`** declared `allowed-tools:` — which is a **skill**
  frontmatter key, not an agent key (`CLAUDE_CODE_CLI_REFERENCE.md:249`), so it was
  inert — plus `disallowedTools: []`. It inherited every tool including Write/Edit.
  The harness confirmed it as "All tools", while `security-expert`'s
  `disallowedTools: [Write]` WAS honored ("All tools except Write"). Now denies
  Write/Edit/NotebookEdit/Agent; the inert key is removed with a note explaining why.
- **`silent-failure-hunter`** had no tool key at all — same total inheritance. Now
  denies Write/Edit/NotebookEdit/Agent.
- **`security-expert`** gains NotebookEdit/Agent denials but **deliberately keeps
  `Edit`**: it is both a mandatory Pass-1 reviewer (§5b-pre slot 1) and the assignee
  that implements retroactive-security-coverage tasks (`04-fix-first-review.md:684`).
  Denying Edit would have broken that lane. The reviewer/implementer role overlap is
  recorded in-file as a tracked residual — the real fix is splitting the agent.
- **`system-architect`** gains NotebookEdit/Agent denials and
  `supports_subagent_creation: false`; the lead owns spec fold-in
  (`01-specification.md:339`). Write/Edit intentionally retained — it authors design
  docs and is not a Step-5 code invigilator.
- `Agent` is denied across all four because the **lead** does every reviewer spawn
  (`01-specification.md:336`, `04-fix-first-review.md:463-466`) — verified before the
  change, so the fan-out is unaffected.

### Added

- **`tests/skill/cases/reviewer-readonly-guard.bats`** (5 cases) pins the above.
  The ratchet asserts each mutating tool is PRESENT in `disallowedTools` rather than
  absent from an allowlist — asserting on an allowlist would pass vacuously against
  the inert key, which is the bug being prevented. Case 3 pins `security-expert`'s
  Edit retention in **both** directions, so a maintainer "completing" the lockdown
  fails the test and reads the reason.

### Known residuals (not fixed here)

- `shared/opus-4-7-practices.md` §5 and §7 bodies are flagged by the new banner but
  not yet rewritten (effort sweep; explicit length calibration for Opus 5).
- `06-post-ship.md` still has no written-deliverable length calibration.
- 60 agent files repo-wide still carry the inert `allowed-tools:` key; only the four
  reviewers were corrected. The new test scopes its ratchet accordingly.

## [1.58.0] — 2026-07-24

Model Tiering v4 — **Opus 5 rollover**. Brain tier moves `claude-opus-4-8` →
`claude-opus-5`, and Opus 5 becomes the tier a Fable skip or refusal lands on.
Theme: **a generation rollover, not a tiering change** — the tier shapes, the
Fable blast-radius guards, and the burn profile are all unchanged.

Trigger: Opus 5 ships as a drop-in upgrade at Opus 4.8's pricing ($5/$25 per MTok),
feature set, and 1M context, with materially better long-horizon agentic execution
and code review. Verified against CLI 2.1.219 before rollout: `claude --model
claude-opus-5` is accepted as a full model name.

### Changed — Brain tier is Opus 5

- **Eight Brain-tier frontmatter pins** rolled to `model: claude-opus-5`:
  `team/evaluator`, `team/validator`, `team/supervisor`, `team/silent-failure-hunter`,
  `team/builder-opus`, `research-planning/test-gap-analyzer`,
  `research-planning/security-gap-analyzer`, `research-planning/system-architect`.
- **`pwt-goal.sh` spawn sites**: `PWT_PRIMARY_MODEL` default `claude-opus-4-8` →
  `claude-opus-5` at all three occurrences (worker + both supervisor paths). The
  explicit `--model` pin itself is untouched — it remains the load-bearing protection
  against a bg fleet inheriting an expensive interactive session default.
- **`PWT_FALLBACK_MODEL` stays `claude-sonnet-5`** — deliberately. That flag is the
  *capacity* fallback (Opus exhaustion), not the Fable fallback; pointing it at another
  Opus would defeat its purpose of reaching the separate Max Sonnet bucket.
- Hands routine lane **unchanged** at `claude-sonnet-5`. The hard lane tracks Brain,
  so `team/builder-opus` is now Opus 5.

### Changed — Opus 5 is the Fable landing tier

- The Step-5 escalation ladder (`04-fix-first-review.md`) now states explicitly that a
  guard SKIP **or** a Fable `stop_reason: "refusal"` lands on **Brain (Opus 5)**, never
  on the Hands lane — Opus 5 is Anthropic's documented recommended fallback for a
  Fable-tier refusal, so the ladder degrades exactly one rung. Rationale for the
  never-drop-to-Hands rule: a task only reaches this rung *because* Sonnet and the hard
  lane already failed on it.
- `plan-w-team-fable-guard.sh` needed no change — it was already written against the
  tier name ("continue on Opus"), not a literal model ID. That indirection is why the
  rollover touched no guard logic.

### Unchanged — the Fable blast-radius invariants

Fable 5 remains bounded to its two sanctioned sites (Step-1 §1b-bis consult, Step-5 top
rung; ONE task, cap 2/run). The negative fan-out guard in
`tests/skill/cases/model-tiering-v3.bats` still fails the suite if `claude-fable-5`
appears in any agent frontmatter beyond `team/fable-spec-consult`, or if the pinned
`--bg … --model` spawn sites drop below four. The 2026-07 Fable-default lockout remains
the reason.

### Docs

- Model Strategy table in the manifest updated (the single canonical tier→ID map) plus a
  v4 generation note that marks the v2/v3 notes as rationale-only, IDs-superseded.
- Two Opus-5 prompt-tuning deltas recorded for future Brain-tier prompt edits: it
  self-verifies unprompted (so *added* "double-check your answer" scaffolding now causes
  over-verification), and it delegates to subagents more readily than 4.8 did (inverting
  the 4.8-era advice to nudge delegation upward).
- `docs/operations/claude-code-compatibility.md` model table refreshed (it was two
  generations stale on the Hands and fallback rows) + a 2.1.219 Features-Adopted row.

## [1.57.0] — 2026-07-19 (aa09ae5)

Model Tiering v3 — **Fable-as-escalation**. Fable 5 becomes a tier at exactly two
bounded sites, behind one guard. Theme: **an escalation rung that fan-out could
select is a spend incident, not a tier.**

Trigger: Fable 5 is included again at up to 50% of weekly Max limits
(operator-confirmed 2026-07-19), removing the credits-only funding barrier that
caused the 2026-07-09 tiering decision to defer this adoption.

### Added — the Fable consult rung (Step 1)

- **`team/fable-spec-consult`** — a read-only spec consultant pinned to the bare
  `claude-fable-5` id (deliberately NOT the `[1m]` variant that caused the 2026-07
  default-inheritance incident) with `effort: high` pinned so a session at
  ultracode/xhigh cannot bleed in. It ADVISES; the Opus lead still authors the spec.
- **Rides the EXISTING §1b-pre fan-out** (`01-specification.md` §1b-bis) rather than
  carrying its own machinery. It reuses §1b-pre's non-triviality classifier, its
  strict pre-freeze ordering rule, and its advisory record. An earlier draft of this
  work proposed a bespoke project-level classifier on the belief that none existed —
  the spec fan-out refuted that, and the reuse removed most of the proposed surface.

### Added — the Fable escalation rung (Step 5)

- The top rung of the knowing-vs-trying ladder in `04-fix-first-review.md`
  **previously dead-ended** at "surface to the user as a Fable-credits candidate …
  NEVER switch models yourself". It is now autonomous but hard-bounded: an Opus 4.8
  agent that is confidently-wrong-with-full-context on the SAME task *after* the
  hard-lane bump escalates to ONE Fable-pinned fix agent for THAT TASK ONLY.
- **Cap 2 per run** (`PLAN_W_TEAM_FABLE_ESCALATION_CAP`). Exhausted cap falls through
  to the existing hard-gate / human-escalation path, unchanged.

### Added — the guard (`plan-w-team-fable-guard.sh`)

Single gate for every Fable spawn: env overrides, weekly-bucket budget, per-run cap,
evidence ledger. `exit 0` ALLOW / `exit 10` SKIP / `exit 2` usage. Only exit 0
authorizes a spawn — including `127`, which is what a consumer repo missing the
script produces.

- **Fails CLOSED to skipping Fable** on every unknown: unresolvable bucket,
  unwritable ledger, corrupt ledger line, or missing `jq`. An unknown budget never
  authorizes spend, and a skip never fails the run.
- **Budget reads the Fable-scoped weekly bucket only** (`limits[] | kind ==
  "weekly_scoped", scope.model.display_name ~ "Fable"`). There is deliberately NO
  fallback to `.seven_day.utilization`: that is the all-models bucket, systematically
  lower and causally unrelated, so a fallback would silently degrade the guard into a
  permissive unrelated number the day "Fable" is renamed at GA. Unresolvable is
  reported as `bucket-unresolved` so the degradation is visible.
- **The ledger IS the counter.** The cap counts the guard's own
  `verdict=="ALLOW" and kind=="escalation"` rows — one artifact, no second source that
  can disagree. Rows are emitted with `jq -cn --arg`, never printf interpolation: a
  malformed row would be a cap bypass, not just bad logging. An unparseable line fails
  closed rather than being skipped, because a skipped line may be a real ALLOW.
- Ledger resolves to the MAIN checkout via `git rev-parse --git-common-dir`, so a
  worktree cannot fork the counter into "2 per checkout"; a `mkdir` lock serializes
  read-count-append so concurrent escalations cannot both read `used=1`.
- `PWT_PLAN_USAGE_CMD` test seam (`plan-w-team-test-green.sh` precedent) — without it
  the budget tests would make a live keychain + network call inside `make test-skill`.

### Changed — propagation, docs, env hygiene

- `sync-to-project.sh`: the agent joins all three profile allowlists **and** the guard
  gets an explicit `cp` line. `scripts/` is excluded from the rsync, so without that
  line a consumer would receive the spender without the brake.
- `pwt-goal.sh`: `unset PLAN_W_TEAM_FORCE_FABLE_CONSULT` beside the existing
  `ALLOW_CONTEXT_BLIND` unset — exported once in a shell, FORCE would inherit into the
  worker and every nested pwt-goal, turning a one-run override into a fleet-wide spend
  amplifier. **Spawn-site `--model` pins are untouched.**
- Manifest Model Strategy table gains the Fable row (the ONE sanctioned literal-id site
  in `.claude/commands`); repo `CLAUDE.md` and `design-principles.md` §10 updated.
- `design-principles.md` §10 also corrected: it still described the Hands tier as
  **Opus 4.7**, retired back in 1.51.0 (doc-decay GAP-5 from the 2026-07-15 audit).

### Added — invariant guards (`tests/skill/cases/model-tiering-v3.bats`, 48 tests)

- **Negative fan-out sweep**: `claude-fable-5` appears in exactly two sanctioned places
  (the consult agent's frontmatter, the manifest table row) and nowhere else in
  `.claude/{scripts,hooks,commands,agents}`; zero occurrences in `pwt-goal.sh`, whose
  ≥4 pinned `--bg … --model "` spawn sites are re-asserted. Uses `grep -F` on the
  literal — a case-insensitive `fable` grep false-positives on six `spoofable` lines.
- Guard behavior: override precedence, budget, clamping, cap, fail-closed paths,
  note-injection safety, slug validation, one-row-per-invocation, worktree path.
- Ordering guard: the stage text's guard invocation must textually PRECEDE the spawn
  instruction — the only property that survives the prose-invocation residual below.
- MT5 in `model-tiering-v2.bats` asserted the now-deleted literal `NEVER assume credits
  exist`; its replacement is strictly stronger (guard named, `ONE task`, `Cap 2 per run`)
  rather than a deletion. MT12/MT14 inventories grew by the new agent.

### Known residual (recorded, not hidden)

The guard is invoked by stage-file prose read by an LLM lead, so it is deterministic
**once invoked**, not a chokepoint: a lead that skips the call spawns Fable uncapped and
unrecorded. The structural fix is a `PreToolUse` binding on `Agent` spawns (the
`no-github-actions.md` "ENFORCING — backed by a real mechanism, not just prose" pattern)
and is tracked as a P1 deferred item on the spec. Partial mitigations shipped here: the
negative fan-out guard, the ordering assertion, and fail-closed recording.

## [1.56.0] — 2026-07-16 (d3d918b)

Bottom-line-loops hardening + the 2026-07-16 goal-integrity field defects.
Theme: **a signal that looks like an enforcement mechanism must actually be
consumed authoritatively** — the "canon is not a control" failure class.

### Fixed — goal-integrity field defects (both reproduced RED, then GREEN)

- **Defect B — done-criteria now fail CLOSED** (`plan-w-team-goal-evaluator.sh`).
  A `feature_specific_done_criteria` row that was not the canonical
  `{pattern, description, met, met_at}` object silently resolved SUCCESS having
  checked nothing. Verified root cause (NOT the originally-suspected fail-open
  `2>/dev/null || echo ""` idiom): at the consume loop, `.pattern` on a
  bare-string row errors to EMPTY, and the following `grep -E ""` — an empty
  regex — matches EVERY line, marking the row met; the write-back then errors
  too, so nothing persists and no unmet reason is ever recorded. Now: non-object
  row → UNMET citing "malformed done-criteria row"; unparseable array → BLOCK;
  empty/non-compiling pattern → UNMET (never `grep -E ""`). Canonical rows
  behave exactly as before. Test: `plan-w-team-goal-evaluator-criteria-failclosed.test.sh`.
- **Defect A — transcript SUCCESS now requires corroboration**
  (`plan-w-team-await-terminal.sh`). The TERTIARY detector (1.48.3) treats
  transcript anchors as a STATE, but they are a HISTORY: once any stop attempt
  emits them they match forever — including when the /goal evaluator correctly
  BLOCKED that stop for unmet criteria and the run is still working (observed
  twice in the field). A transcript-only SUCCESS is now withheld when the
  resolved goal-state shows unmet criteria and a null `terminal_state`.
  Fail-open by construction: absent/unreadable goal-state, empty criteria, or
  all-met criteria still emit SUCCESS, preserving the exact lingering-worker
  case 1.48.3 exists for. Test: `plan-w-team-await-terminal-blocked-stop.test.sh`.

### Added

- **`SUITE_EXIT=<code>` marker** (`tests/skill/run.sh`, R1): emitted exactly once
  as the literal final stdout line at the final gate, plus explicit emission on
  the no-bats GREEN path (0) and the env-error exits (2). Deliberately not an
  EXIT trap (subshell phases risk double-emit). Marker-less termination is RED
  by construction downstream, so a truncated log can no longer read as green.
- **`plan-w-team-test-green.sh`** (R2/R3): bg-safe wrapper that owns the suite
  run, keys green off a literal trailing `SUITE_EXIT=0`, writes a dual-written
  verdict artifact, NO-SUITE-guards consumer repos (exit 3, no artifact), and
  takes a repo-root-keyed lock. `--log` / `PWT_TEST_GREEN_SUITE_CMD` fixture seam.
- **pwt-goal deictic refusal + done-when synthesis** (R4/R5): exit 6
  `PWT_CTX_DANGLING` for context-blind requests with no resolvable brief;
  `--brief` regular/non-symlink/≥200-byte guard; `DONE<k>: PASS` criteria
  synthesized via jq only, seeded to worker-visible copies only; goal text
  anchor-stripped so it cannot self-satisfy. §1.5 merges by union
  (`unique_by(.pattern)`) so seeded rows survive AC injection.
- **`plan-w-team-friction-triage-due.sh`** (R7): deterministic
  `FRICTION_TRIAGE_DUE` advisory + `--validate` schema mode, invoked fail-open
  from session-start and the retro preflight. No launchd timer (actor problem).
- **W3 — route-hook trigger matcher widened**: the nine exact-substring patterns
  missed ordinary English ("Use **the** /plan-w-team **skill** to …" produced no
  route at all — no log entry, no systemMessage, no trace). One tolerant regex
  now matches `<verb> [the|our|a] /plan-w-team [skill|run|…] <to|for>`; the
  required verb + to/for keep casual mentions from spawning. 19-fixture corpus
  including the origin prompt and 7 negative controls.
- **W4 — state gitignore hygiene**: statusline's stale-while-revalidate
  `.refreshing`/`.tmp.<pid>` cache siblings, `hygiene-backups/`, and
  `plan-w-team-run-state-audit.jsonl` were untracked-and-unignored, dirtying the
  ship gate every session. Rows added + an executable guard.

### Notes

- W4's proposed "pin the statusline writer to repo root" was **NO-GO** on
  evidence: `settings.json` invokes it as `"$CLAUDE_PROJECT_DIR"/.claude/statusline.sh`,
  so `$PWD` IS the project root in production, and the PWD-relative resolution is
  a documented per-project design that a repo-root pin would break.
- The spec's stale version target (1.50.2 → 1.51.0) was superseded; version
  re-derived at ship time via `plan-w-team-next-version.sh --bump minor`.

## [1.55.1] — 2026-07-16 (26f83c7)

**Consumer-portable governance scenario.** `supervisor-merge-gate-governance.bats`
asserted `docs/specs/supervisor-merge-enforcement.md` exists — but `sync-to-project.sh`
intentionally never propagates `docs/specs/` (source-only design records), so the two
provenance tests were structurally un-passable in any consumer repo. Discovered when a
full-scenario pre-commit gate in a QA consumer (progressive-qa-initiative) blocked the
1.55.0 sync commit. The two tests now `skip` when `$SPEC` is absent (consumer) and still
enforce when present (source). The mechanism they guard — the gate script + protocol/
ship/governance wiring — is synced and remains enforced by AC1–AC7. Companion finding
(not a code change): the default `minimal` sync profile leaves non-core agent
definitions stale in consumers; a QA repo running the full scenario corpus must sync
with `--profile full`.

## [1.55.0] — 2026-07-15 (cc314c6)

**Agent-registry validity check — the roster could go silently dead.** The Cherny
automation audit ([`docs/operations/pwt-cherny-automation-audit-2026-07-15.md`](../../../docs/operations/pwt-cherny-automation-audit-2026-07-15.md))
found that **15 of 99 named agent definitions cannot be spawned**: their YAML
frontmatter does not parse, so the harness never registers them and
`Agent(subagent_type: …)` fails only at spawn time. Cross-tab evidence: all 75
YAML-valid agents are spawnable; all 15 unspawnable ones are YAML-invalid. The
dominant root cause is a plain-scalar `description:` ending in `Examples:` — a
trailing colon is a YAML mapping indicator (working agents use `description: |`).

This is not theoretical. **The skill dispatches to three of the dead agents:**
`system-architect` (`01-specification.md:309,335` — a *mandated* §1b-pre fan-out
reviewer), `unit-testing-specialist` (`04-fix-first-review.md:602` — Step-5
retroactive coverage), and `react-typescript-specialist` (the manifest's named
Hands lane, additionally pinned by `tests/skill/cases/model-tiering-v2.bats:25`,
a green test asserting a property of an unspawnable agent). The audit run itself
hit it: its §1b-pre fan-out silently degraded from 3 reviewers to 2. Nothing
warned — no test asserted roster ↔ disk ↔ spawnable parity.

Per the audit's P2 lens (Cherny: *"your agent could fix an issue every time it
sees that issue happen, but that uses tokens and might miss cases"*), the fix is a
rule that fires rather than a per-run rediscovery:

- **NEW** `.claude/scripts/plan-w-team-agent-registry-check.sh` — advisory,
  read-only, bash 3.2 compatible. Parses every `.claude/agents/**/*.md`
  frontmatter and reports agents that will not register, with the reason and the
  fix. `--json` for machine consumption; `--strict` (operator-only) to exit 1.
  **Never blocks** (design principles #3/#8; the audit brief forbids new hard
  gates), and deliberately reports the 3 harness-tolerated agents as at-risk
  rather than failing on them — that tolerance is undocumented and must not be
  relied on.
- **NEW** `tests/skill/cases/agent-registry-check.bats` — 8 fixture-based cases:
  valid/invalid detection, the block-scalar no-false-positive case, advisory-vs-
  `--strict` exit codes, non-agent skip, fail-open on a missing dir, plus a
  live-tree anchor that skips cleanly once the frontmatter is repaired.
- **Sync**: allowlisted in `sync-to-project.sh` (gotcha G11) — consumer repos
  carry the same roster and the same dispatch sites, so they inherit the same
  silent-failure class.

The audit's other four findings are DEFERs with recorded reopeners (see the
report's ranked gap list): `shared/gotchas.md` is unreachable (advertised once in
the manifest, referenced by **zero** stage files — while 8/8 briefs hand-restate
G7/G11 anyway); the `SUITE_EXIT` idiom is mis-encoded (`tests/skill/run.sh:499-506`
emits no such token — the caller must mint it); `governance-tags.md:18`'s
allowlist globs match no real allowlist file; and two decayed load-bearing doc
claims. P1 verdict: **ALREADY-SATISFIED**. The 2026-07-02 parallelism decision is
explicitly **NOT A REOPENER**.

## [1.54.0] — 2026-07-10 (8299d42)

**State-Truth Hardening — the goal-state must tell the truth.** Field audit of the
first 7 fully-1.53.0 autonomous runs (2026-07-09: cleanscale ×3, parts ×3, helm ×1)
found the WORK succeeded (6 merged PRs, verified via gh) while the STATE lied:
3 seeded goal-states stranded `terminal_state: null` after successful ships, one AC
flipped `met: true` while explicitly not performed, duplicate await-terminal watchers
polled dead workers, and zero Run-State Router evidence existed anywhere. Root causes
verified against source by a 6-reader + adversarial-verifier workflow before any fix
(2 proposed fixes REJECTED by the verifier: a ps-by-SID death leg that would false-kill
live bg workers, and a detector-internal write that would break the AC2 read-only
tree-hash contract).

- fix(F1 slug divergence, CRITICAL): pwt-goal.sh hoists `SLUG_GUESS` above the
  GOAL_TEXT heredoc and INJECTS `SLUG for ALL run artifacts: <slug>` into the /goal
  directive — the only channel that crosses the worker process boundary. Manifest
  PWT-T5b mandates verbatim adoption (+ never overwrite the dual-seeded file —
  create-if-absent guard), and the Step -1 routing table gains a "own pre-seeded
  slug → adopt, not resume/stand-down" row. Workers minting their own Step-1 slugs
  (calendar-timeout-fixes, qa-gate-receipt-controls, receipt-ocr-waf-carveout) was
  the #1 stranding cause.
- fix(F2 split-brain): PWT-TERM1 (07-retro) and §1.5 criteria injection (01-spec)
  DUAL-WRITE to the main checkout via the proven git-common-dir idiom
  (never-clobber-a-halt enforced per copy); retro-capture.sh PROJECT_ROOT
  `--show-toplevel` → git-common-dir (+ PWT_PROJECT_ROOT_OVERRIDE for tests).
- fix(F3 AC false-flip): §1.5 pattern `AC<N>.*PASS` → anchored
  `AC<N>:[[:space:]]*PASS` at the DERIVATION site (greedy `.*` spanned unrelated
  collapsed-transcript text — the helm AC9-met-while-PENDING flip). Deliberately
  NOT end-anchored (verifier proposed `PASS([[:space:]]|$)`; rejected here because
  "AC3: PASSED" must keep matching — a never-matching pattern re-arms the 2026-06-22
  blocked-stop runaway, the worse failure). New **AC Verification Line Contract**
  (04-review + 05-ship): emit exactly `AC<N>: PASS — <evidence>`, and never for an
  unverified AC. goal-conditions.md examples updated.
- fix(F4 emission-form schism): the evaluator regex accepts ONLY the JSON colon form
  while await-terminal TERTIARY accepted ONLY the hand-written shell-equals form —
  two detectors, two formats, docs priming the wrong one everywhere. TERTIARY now
  ALSO detects the canonical emitter's pretty-JSON block (same-line ```status fence
  shield against doc-read false positives; legacy regex kept verbatim). Priming
  sites corrected: 07-retro anchor prose (+ ALWAYS-use-the-emitter warning),
  pwt-goal.sh DONE_CRITERIA (all 4 types now name the canonical emitter) and the
  supervisor briefing SUCCESS bullet (greps both forms).
- fix(F5 watcher hygiene): await-terminal singleton — atomic mkdir lock keyed on
  slug+worker-sid, stale-lock (dead PID) reclaim, duplicate exits 0 with a distinct
  no-`terminal=` message. Two duplicate-watcher pairs observed in 24h. The planned
  PWT4 ps-by-SID QUATERNARY death leg is DROPPED per the adversarial verify (SID
  absent from bg argv → would false-fire on live workers; only-confirmed-death
  halts is invariant).
- feat(F6 router evidence): Step -1 emits one JSON audit line on EVERY invocation —
  including `no-prior` — to `plan-w-team-run-state-audit.jsonl` (persistent,
  NOT retro-deleted, registered in state-artifacts.md); detector script itself
  stays read-only (AC2 contract). pwt-goal.md cue table clarified: continue/status
  are ROUTING decisions, never `--type` values (script exits 1 on them).
- feat(strategy visibility): 03-execute strategy table — parallelizability, not
  task count, decides; "large feature ≥3 disjoint-file tasks → fan-out (Sonnet
  Hands lane) even at >5 tasks"; lead-direct requires a one-line justification via
  `pwt-manifest.sh set --justification/--difficulty-mix` (new optional args,
  fail-open contract intact); retro parallelism section reports lead-direct
  strategy rationale instead of self-excluding. Field driver: 7/7 runs lead-direct,
  Model Tiering v2 + effort pins + advisor consults got ZERO runtime exercise.
- test: `tests/skill/cases/state-truth-hardening.bats` — r10-BDD sandboxed cases
  (slug injection + idempotence, dual-write pins, anchored-pattern pin, TERTIARY
  both-forms functional probes, singleton live/stale functional probes,
  manifest justification round-trip, --type continue refusal).
- fix(diff-review hardening): a 3-lens adversarial review of the release diff caught
  and fixed pre-commit: (CRITICAL) the new TERTIARY same-line fence check false-fired
  SUCCESS when a worker merely READ goal-conditions.md (a whole file is ONE transcript
  JSONL line) — replaced with a single bounded-window adjacency regex (fence→stage
  ≤160 chars, stage→lock ≤120) that matches the real emission and rejects doc reads;
  (MAJOR) the retro-capture git-common-dir repoint split it from 07-retro's
  worktree-relative read-back/merge/cleanup — re-scoped so only DURABLE cross-run
  files (history, recursive-followups) live on main and per-run files stay
  caller-local; (MINOR×3) watcher duplicate now exits 4 with an explicit
  defer-don't-relaunch contract (exit 0 meant "terminal reached" and would loop a
  supervisor), the injected slug directive is mode-aware (derive mode no longer
  claims "pre-seeded/adopt-as-self", which could defeat concurrent-run stand-down
  on a later paste), and the run-state-audit registry row no longer claims a
  nonexistent code reader.
- No new scripts (sync allowlist unchanged); route hook untouched; no wall-clock or
  turn caps added; hard gates unweakened.

## [1.53.0] — 2026-07-09 (9b801d4)

**Run-State Router — continuation detection + status mode.** Routing was phrasing-only
(manifest NL Intent Detection) and never inspected disk state: a bare invocation on
in-progress or shipped work re-ran the full 0→8 pipeline, pwt-goal derivation treated
"continue X" as brand-new work (fresh hash-slug/worktree), and re-issued phrasing
clobbered a live run's goal-state (unconditional PWT-WT2 `>` seed). Measured cost in
cleanscale: 373 specs, 912 state artifacts, duplicate slugs. This feature routes on
`intent × run-state`. Strengthens design principle #11 (durable SLUG-keyed state).

- feat(Item 1): `.claude/scripts/plan-w-team-run-state.sh` — deterministic, read-only,
  fail-open run-state detector. Fuzzy topic→slug matching across specs/goal-states/
  scope-locks; per-candidate verdict JSON `{slug, verdict, score, artifacts, freshness}`
  with vocabulary `no-prior|specd|mid-execution|built-unreviewed|shipped-unretroed|
  complete|live-now`. GC-aware `complete` (retro deletes per-run files → absence + retro/
  SUCCESS is not "never ran"). `live-now` uses PROCESS liveness (live lock PID / fresh
  hook-spawn flag) — the discriminator vs. resumable `mid-execution`; the terminal_state
  reading mirrors `pwt-goal.sh:166-179` (reuse-by-pattern; the subprocess's branch-merge
  leg false-STALEs a 0-commit worktree branch, so it is deliberately not shelled out).
  bash 3.2, exit 0 always except usage (2).
- feat(Item 2): manifest **Step -1 State-Aware Routing** — `intent × verdict` routing
  table; every state-based stage skip emits a grep-able `run-state-router:` audit line +
  bypass-log entry (retro §8j-octies counts it). Kill switch
  `PLAN_W_TEAM_DISABLE_RUN_STATE_ROUTER=1`.
- feat(Item 3): manifest **Status / Readiness Mode (`--status`)** — read-only aggregation
  (tracker chain, TaskList, live goal/run-states, board, ship verdicts, AC snapshots) →
  one dated gap report `.claude/state/plan-w-team-status-<date>.md` + a recommended next
  run. HARD zero-write-outside-report / zero-TaskCreate / zero-fan-out invariants.
  Registered in `state-artifacts.md` (audit-trail).
- feat(Item 4): pwt-goal derivation continuation-awareness — `continue`/`status`
  type-inference cues + Continuation Awareness section (reuse matched slug, anchor
  `feature_specific_done_criteria` to the EXISTING ac-snapshot, stand down on `live-now`).
  **Seed guard (HARD):** `pwt-goal.sh __pwt_seed_guard_ok` + `--seed-guard-check` CLI mode
  refuse to clobber a goal-state whose `terminal_state` is null (a live run) unless the
  owning worker re-seeds or `PLAN_W_TEAM_FORCE_SEED=1` — closes the duplicate-run
  goal-state clobber (concurrent-duplicate-run stand-down).
- **HARD CONSTRAINT honored:** zero changes to `plan-w-team-route-prompt.sh` trigger logic
  — the detector is invoked from the manifest Step -1 and pwt-goal derivation only, never
  the hook (AC4). No new wall-clock/turn caps; hard gates byte-identical (AC6).
- test: `tests/skill/cases/run-state-router.bats` — 29 r10-BDD, sandboxed cases (AC1
  verdict matrix, AC3 seed guard, AC4 route-hook invariant, AC5 sync allowlist, AC6 caps,
  AC8 docs). Detector added to `sync-to-project.sh` allowlist; symmetry-check 45/45.
- docs: `docs/specs/run-state-router.md`; design-principles #11 cross-reference.

## [1.52.3] — 2026-07-09 (9167a8a)

Adversarial check on the 1.52.2 effort pins (3 refuting auditors: semantics,
regressions, consistency). The pin MECHANISM survived; the coverage claim and two
doc statements did not. All confirmed findings fixed:

- fix(coverage, MAJOR): 1.52.2 claimed the "entire builder fan-out" was insulated, but
  Step 2 routes routine tasks to roster SPECIALISTS first (builder is the fallback) and
  only 3 of the pipeline agents were pinned. Pins extended to the full pipeline set:
  team/validator, team/supervisor, team/silent-failure-hunter, plus the two named Hands
  specialists (react-typescript-specialist, rust-backend-specialist) — 8 pinned agents
  total. Documented residual: tasks routed to OTHER roster specialists (nodejs-specialist
  etc.) still inherit session effort — pinning all 159 agents would wrongly freeze
  interactive consults; prefer the builder lanes when fanning out at xhigh.
- fix(honesty, MAJOR): the pin is BIDIRECTIONAL — it also blocks deliberate session-level
  de-escalation (a /effort low lead still runs pinned agents at high). Manifest item 3 and
  §5 now say so, with the escape hatch (edit the pins in claude-pattern; consumer-repo
  edits are reverted on next sync) and a reconciliation note on manifest item 4's
  ship/retro Hands delegation.
- fix(honesty, MAJOR): the claim that `ultrathink` "works regardless of the pin" was
  unverified — prompt phrasing deepens adaptive thinking WITHIN the pinned effort level
  and is NOT verified to raise the effort parameter. Docs now state this and name the
  verified per-task escalation lever: the model bump (hard-lane re-dispatch).
  supervisor-protocol STALL-ALERT rung annotated (its /effort-xhigh leg raises the
  supervisor's own turn only).
- fix(docs, MINOR): 02-task-breakdown effort-field description no longer claims to control
  thinking depth (it steers the prompt-level approach; API effort is pinned); Sonnet-5
  default-high claim now cited (platform effort docs / migration guide).
- test: MT14 hardened — frontmatter-scoped via awk (body-prose/comment survivals can't
  satisfy it), exactly-one-effort-key assertion (catches last-wins YAML duplicates),
  extended to all 8 pinned agents.

## [1.52.2] — 2026-07-09 (02ee483)

Effort pins — the effort-axis twin of the 1.51.0 model pins, closing the last lever from
Anthropic's "knowing more vs. trying harder" article. Subagent effort INHERITS the
session effort by default (code.claude.com/docs/en/sub-agents, verified on CLI 2.1.205),
so a lead escalated to /effort xhigh or ultracode silently ran the entire Sonnet builder
fan-out and the throughput-sensitive evaluator loop at xhigh — the same silent-bleed
class as the Fable model-default incident.

- feat(plan-w-team): `effort: high` frontmatter pins on team/builder.md,
  team/builder-opus.md, and team/evaluator.md — `high` is the model default for both
  Sonnet 5 and Opus 4.8 (Anthropic: run the default effort for most work), and the
  evaluator pin enforces the §5 "evaluator stays at high" policy structurally.
  Per-task escalation is unchanged: the 04-fix-first prompt-phrasing rung
  (`ultrathink`) works regardless of the pin.
- docs: manifest pinning-mechanics item 3 + opus-4-7-practices §5 document the pins
  and the inherits-from-session default that motivates them.
- test: MT14 asserts all three pins.

## [1.52.1] — 2026-07-09 (d939c5e)

Adversarial-audit hardening pass over the 1.51.0/1.52.0 work (6 independent refuting
auditors: consistency, flow executability, test vacuity, language-agnosticism +
propagation, spawn argv, hooks harmony). All confirmed findings fixed:

- fix(CRITICAL, flow): claim-side routing race — the Sonnet builder could self-claim
  `difficulty: hard` / `builder-opus` tasks (routing was enforced one-way). builder.md
  Self-Claiming and the 03-execute spawn-prompt TASK CLAIMING block now SKIP hard-lane
  tasks unless explicitly re-dispatched.
- fix(CRITICAL, sync): `builder-opus.md` (and team/evaluator, team/supervisor,
  team/silent-failure-hunter) were absent from sync-to-project.sh profile allowlists —
  consumers were at VERSION 1.51.0 with docs routing to an agent type that did not
  exist there, and evaluator/supervisor stuck on retired pins. All team agents added
  to all three profiles; MT12 guards the symmetry.
- fix(MAJOR, flow): Lead Consults now executable on every dispatch path — supervisor.md
  gains SendMessage + a Builder Consults duty section; builder.md gains a no-reply
  degrade rule (`consult_unanswered` metadata; one-way-door tasks complete with
  `pending_review` instead of stalling) and a `wip:`-squash rule reconciling
  durable-first with bisectable commits.
- fix(MAJOR, flow): re-dispatch-to-hard-lane now has a concrete sequence (stop
  incumbent → reset task to pending with agent_type builder-opus → spawn if none
  running, pointing at salvageable WIP; fresh WTF score), referenced from Step 5.
- fix(MAJOR, docs): stale generation prose swept — 04-fix-first auto-fix builder label
  (was "Opus 4.7"), orchestrator.md ENFORCED delegation table (was 4.7/4.6, two
  generations stale; MT13 guards), stage-file tip labels → "Opus 4.7/4.8", practices
  ship-row default corrected to lead session, sdk-expert docs stamped HISTORICAL,
  CLAUDE.md agent counts 154/85 → 159/86.
- fix(MAJOR, argv): pwt-goal.sh fallback comment no longer overclaims — --fallback-model
  is documented print-only and the 2026-06-28 probe recorded it likely inert under
  --bg; the load-bearing protection is the --model primary pin (this correction also
  amends the 1.51.0 entry's fallback rationale). Durable degradation lever, if ever
  needed: settings.json fallbackModel.
- fix(MAJOR, hooks): pre-commit-quality test-skill gate + version-bump hook now trigger
  on pwt-goal.sh and the model-pinned agent files; both hooks' git-commit matchers
  tolerate `git -C <path> commit` (worktree/bg form); version-bump skips CHANGELOG
  sha-backfill commits explicitly.
- fix(flow, minor): `difficulty: hard` now implies `effort: high`; the 04-fix-first
  effort rung names prompt-phrasing (`ultrathink`) as the mechanism (the /effort
  slider is session-level); hard-lane precedence over specialist match stated
  explicitly; builder anti-pattern exemplars marked language-illustrative.
- test: MT2/MT4/MT5/MT6/MT8/MT9/MT10 re-anchored on load-bearing clauses (vacuity
  findings); new MT11 (claim-side exclusion), MT12 (sync allowlist symmetry), MT13
  (no retired generations in orchestrator); AC12 excludes comment lines.

## [1.52.0] — 2026-07-09 (0995a61)

Advisor-pattern lead consults for the Sonnet lane — the native /plan-w-team analog of
Anthropic's advisor tool (platform.claude.com/docs/en/agents-and-tools/tool-use/advisor-tool,
API-only beta, unusable on Max): a faster executor consulting a stronger model at the
moments where a plan matters most. Assessed the multi-agent sessions doc + advisor doc +
the @claudedevs "plan big, execute small" threads as a whole against 1.51.0: the
coordinator/roster/threads architecture and escalation lanes were already met; the one
gap was builder-initiated consults BEFORE a failed iteration (fix-first only catches
failures AFTER review).

- feat(plan-w-team): `team/builder.md` gains §"Lead Consults (Advisor Pattern)" — three
  scoped checkpoints (before committing to a non-obvious approach; when stuck with the
  same error twice, BEFORE the WTF caps force a stop; before declaring done on a
  `door_type: one-way` task), durable-first rule (commit WIP before consulting), and
  conflict-surfacing discipline (never silently switch; mirrors the GRD contradiction
  rule). Explicit anti-flood scope rule.
- feat(plan-w-team): 03-execute Execution item 9 gains the lead-side contract — answer
  consults promptly in under ~80 words (Anthropic's measured advisor-brevity guidance);
  a consult is NOT a fix-first failure signal; repeated consults on one task = difficulty
  misroute → re-dispatch to the hard lane.
- docs(plan-w-team): builder-opus deliberately does NOT carry the consult checkpoints
  (Anthropic measured consult nudges as net-negative on Opus executors; equal-capability
  consult adds latency, not insight) — mirror-comment and manifest rollover bullet updated
  to list this as the third deliberate divergence.
- Hooks reviewed for harmony with 1.51+: no hook hardcodes model IDs; tmux panes label
  agent types generically (builder-opus gets its own pane); pre-commit version-bump hook
  skips when VERSION is staged manually (by design — no double-bump); quality gate,
  naming ratchet, and sync-allowlist check all verified firing during the 1.51.0 ship.
- test: MT8-MT10 — consult section present in builder.md, deliberately absent in
  builder-opus.md, lead-side contract present in 03-execute.md.

## [1.51.0] — 2026-07-09 (24a45e3)

Model Tiering v2 — task-difficulty lane routing per Anthropic's "knowing more vs.
trying harder" (claude.com/blog/claude-model-and-effort-level-in-claude-code) and the
Managed Agents coordinator/roster economics. Trigger: the 2026-07 Fable-default
incident (unpinned bg spawn paths silently inherited a `claude-fable-5[1m]` session
default → ~2x burn, two-account weekly-limit lockout) plus the observation that the
Opus 4.7 Hands tier was strictly dominated (same usage weight as 4.8, worse output).

- feat(plan-w-team): Hands routine lane moves `claude-opus-4-7` → `claude-sonnet-5`
  (team/builder, react-typescript-specialist, rust-backend-specialist frontmatter).
  Near-Opus coding/agentic quality, same tokenizer as Opus 4.7/4.8, and on Max draws
  largely from the separate (larger) Sonnet weekly bucket.
- feat(plan-w-team): new Brain-tier hard lane `team/builder-opus` (`claude-opus-4-8`,
  mirrors builder.md body). Step 2 gains a `difficulty: routine|hard` metadata field;
  `hard` (novel architecture / cross-cutting / ambiguous / security-sensitive /
  concurrency) ⇒ `agent_type: builder-opus` at assignment time — on hard multi-step
  work the cost equation inverts (small model grinds, each failed iteration re-triggers
  Brain review), so known-hard tasks skip the Sonnet lane entirely. Calibration guard:
  >~20% hard ⇒ under-decomposed spec.
- feat(plan-w-team): 04-fix-first escalation rung upgraded from effort-only to the
  knowing-vs-trying diagnostic — skipped/bailed/unverified ⇒ effort bump same model
  (`ultrathink`/xhigh); confidently-wrong-with-full-context ⇒ model bump to the hard
  lane; Brain-tier still confidently wrong ⇒ surface as operator-only Fable-credits
  candidate (never auto-switch). Companion bullet in opus-4-7-practices §5.
- fix(pwt-goal): bg worker + supervisor spawns now pin `--model claude-opus-4-8`
  (PWT_PRIMARY_MODEL) so fleets never silently inherit the interactive session default
  (the Fable incident class); `--fallback-model` default moves `claude-opus-4-7` →
  `claude-sonnet-5` (PWT_FALLBACK_MODEL) so long autonomous runs survive Opus capacity
  exhaustion — a 4.7 fallback shares the exhausted pool and could not.
- docs: manifest Model Strategy table gains the hard-lane row + 2026-07-09 generation
  note; rollover procedure now tracks Brain (Opus) and Hands (Sonnet) generations
  separately and forbids demoting a previous Opus into Hands; root CLAUDE.md Models
  table updated; agent-roster gains builder-opus.
- test: `tests/skill/cases/model-tiering-v2.bats` (MT1-MT7) asserts the lane pins,
  builder-opus existence, difficulty routing docs, escalation diagnostic, and pwt-goal
  primary/fallback pins; opus48-uplift AC2/AC12 updated (Hands-pin and fallback-default
  assertions superseded by MT1/MT6).

## [1.50.2] — 2026-07-04 (ae74868)

Class sweep of the 1.50.1 grounding-gate bug: the identical hang signature — tolerant
`"${2:-…}"` value default + unguarded `shift 2` in a non-`set -e` script — existed in 16
more `.claude/scripts/` parsers, several of them long-lived supervisor-path processes
(await-terminal, supervisor-progress-check) where an orphaned spin is exactly as costly.

- fix(plan-w-team): apply the guarded consume (`shift; [ $# -gt 0 ] && shift`) to every
  unguarded value-taking `shift 2` in: retro-capture, reuse-overlap-scan,
  access-control-content-scan, doc-ship-gate, netnew-surface, await-terminal,
  pwt-manifest, credential-wall-gate, supervisor-progress-check, reuse-audit-gate,
  reuse-clone-scan, pwt-status, bypass-rate, credential-wall-detect, ship-preflight,
  next-version (63 arms; behavior for valid invocations unchanged). Scripts protected by
  `set -e` (failed shift aborts), a same-line `||` fallback, a preceding `$#` check, or
  bare `"$2"` under `set -u` (unbound expansion aborts first) were left as-is.
- test(plan-w-team): new `argparse-shift2-lint.test.sh` — corpus-wide static lint over
  `.claude/scripts/*.sh` + `.claude/hooks/**/*.sh` (119 files) enforcing the invariant
  "a value-consuming `shift 2` must terminate loudly when the value is missing"; fails
  with file:line list on any regression, plus a vacuity guard on corpus size. Added to
  the sync-to-project.sh test-file allowlist so consumers inherit the guard.
- Verified: all 11 existing suites for swept scripts pass (156 assertions); the 5 scripts
  without suites probed live with trailing-flag invocations under a watchdog — all
  terminate (no 137).
- Deferred (backlog, per handoff): systemic wall-clock cap / iteration ceiling so no
  gate can ever hang unbounded and orphan itself regardless of parser bugs — a design
  change, not part of this mechanical sweep.

## [1.50.1] — 2026-07-04 (f8f3fc4)

Field bug (helm dev laptop, 2026-07-04): three orphaned `plan-w-team-grounding-gate.sh`
processes pegged ~3 of 12 cores at 100% CPU for ~1d21h after their parent session died.
Not a memory leak — a pure arg-parse spin.

- fix(plan-w-team): **grounding gate infinite loop on a value-less trailing flag.**
  `--spec`/`--slug`/`--root`/`--phase` consumed their value with `shift 2`; when the
  flag was the LAST argument, `shift 2` shifts nothing and returns non-zero (which
  `set -u` does not catch), so `$#`/`$1` never change and `while [ $# -gt 0 ]` spins
  forever at 100% CPU. Fixed with the bash-3.2-safe guarded form
  `shift; [ $# -gt 0 ] && shift` — identical semantics when the value is present,
  clean loop exit when it is absent (`${2:-}` defaults already tolerated the missing
  value; only termination was broken).
- test(plan-w-team): grounding-gate Cases 17–19 replay the three real orphaned command
  lines (`--check --spec`, `--enumerate --root`, `--check --spec x.md --phase`) under a
  new `bounded` watchdog helper (no coreutils `timeout` dependency; 137 = hung+killed),
  so a regression FAILS the suite instead of hanging it. Verified red-then-green:
  all three hang-and-kill against the pre-fix script, pass (exits 2/0/2) after.

## [1.50.0] — 2026-07-02 (ed5e459)

Operator decision superseding the parallelism go/no-go run's Idea-B trial shape (record +
addendum: `docs/operations/pwt-parallelism-go-nogo-2026-07-02.md`): the attended-only
opt-in trial was rejected as too piecemeal ("not wrapped") — it also could not reach the
dominant bg-worker path at all. The trial's SUBSTANCE (collect real evidence, decide on
the §8j-nonies criterion) is preserved; the SHAPE becomes a right-sized default.

- feat(plan-w-team): **§1b-pre Multi-Angle Spec Fan-Out → AUTO mode.** Tri-state gate:
  unset (default) → AUTO — the fan-out fires automatically when the draft spec is
  non-trivial (≥3 requirement checkboxes OR any one-way-door decision) and auto-skips
  trivial specs (single-pass, the pre-1.50.0 behavior, where 3 Brain-tier reviewers
  cannot earn their cost); `PLAN_W_TEAM_SPEC_FANOUT=0` → hard OFF (operator opt-out);
  `=1` → force ON even for trivial specs. Zero per-run action; identical on attended and
  bg runs. Roster, fold-before-freeze ordering rule, and the advisory state record are
  unchanged.
- feat(plan-w-team): **pwt-goal.sh forwards the override only-when-set** — `=0`/`=1` now
  reach bg workers via LAUNCH_ENV (closes the B2 gap from the go/no-go record); unset
  forwards nothing and the worker resolves AUTO from the stage file.
- docs(plan-w-team): retro §8j-nonies advice text reframed from pilot-promotion to
  AUTO keep/park review (≈0 folded across ~5 auto-fired runs → restore default-off);
  state-artifacts registry row description updated; go/no-go decision record gains the
  superseding-addendum; followups-ledger trial row superseded by the AUTO keep/park
  checkpoint row.
- test(plan-w-team): `scenarios/spec-fanout-optin.bats` re-pinned to the AUTO contract
  (tri-state default, ≥3-requirements/one-way trigger, trivial auto-skip, only-when-set
  LAUNCH_ENV forward); the old default-OFF guard test name removed from the r10 legacy
  allowlist (ratchet shrink).

## [1.49.0] — 2026-07-02 (567c0e6)

Close the existing-repo drift failure mode (user-reported): a run planning against an
EXISTING repo without first reading its documentation/architecture, so wrong assumptions
about the current system get baked into the spec, propagate to builders, and are even
*trusted* by the Step-5 verifier filter ("intended behavior documented in the spec" was an
unconditional drop-reason for findings). Grounding was previously advisory-only prose
(Step 0 "read the relevant code" / taste calibration), and the context-blind bg worker's
goal directive said nothing about reading the target repo's docs. This release makes
grounding a deterministic two-phase gate with an adversarial second check — the same
floor+judgment split as the access-control scan (audit P9c: detection must not be LLM-only).
Full evaluation record (14-reader fleet + 4-skeptic verification, incident evidence,
residuals): `docs/operations/pwt-grounding-evaluation-2026-07-02.md`.

- feat(plan-w-team): **GRD Existing-System Grounding gate** (`plan-w-team-grounding-gate.sh`,
  bash 3.2, LC_ALL=C-deterministic, LOUD enumeration cap). `--enumerate` lists the repo's
  canonical entry-point docs (README*/CLAUDE.md/AGENTS.md/CONTRIBUTING*/ARCHITECTURE*/
  DESIGN*/GOVERNANCE*, top-level `docs/*.md`, `docs/{architecture,adr,decisions}/*.md`).
  `--check --phase spec` is a Step-1 freeze pre-condition beside the H1 reuse gate: the
  spec must carry a non-blank `## Existing-System Grounding Ledger` covering EVERY
  enumerated doc (consulted or skipped-with-reason) with ≥1 CONFIRMED/ASSUMED claim row or
  an explicit greenfield statement (a greenfield claim does NOT exempt coverage when docs
  exist). `--check --phase review` re-runs at Step 5 against the LIVE repo and fails any
  surviving ASSUMED row. Kill switch: `PLAN_W_TEAM_DISABLE_GROUNDING=1`.
- feat(plan-w-team): **Step 0 §0a-pre grounding duty** — enumerate + read/skip-with-reason
  every canonical doc BEFORE the premise challenge; CURRENT state, taste calibration, and
  every "X already handles Y" statement must derive from ledger evidence (`CONFIRMED`) or
  be honestly flagged `ASSUMED` — never silently asserted.
- feat(plan-w-team): **Step 1 spec template + Grounding Freeze Pre-Condition** — mandatory
  `## Existing-System Grounding Ledger` section (sources consulted + claim/evidence/status
  rows); freeze refuses without it.
- feat(plan-w-team): **Step 5 §5a-ter Grounding Re-Verification — the adversarial second
  check.** Layer 1 deterministic floor: gate re-run `--phase review` (catches ledger decay,
  docs added mid-run, surviving ASSUMED rows; exit 1 blocks review). Layer 2 semantic:
  reviewer re-reads ledger rows against the actual repo (all rows when ≤10, else every row
  the diff depends on); a REFUTED row the diff's design depends on is **Pass-1 CRITICAL**
  (new §5b table row) — fixed by correcting the SPEC (re-freeze per AC-snapshot rules),
  never by editing the ledger to match the code. The §5b-pre verifier-filter drop-reason
  "documented in the spec" is now valid ONLY when the claim traces to a CONFIRMED/VERIFIED
  ledger row; the reviewer fan-out envelope gains a Grounding line making spec claims about
  existing behavior explicitly untrusted. Status-block signal:
  `grounding-verification: verified | <N> refuted (<M> gating)`.
- feat(plan-w-team): **pwt-goal.sh goal-directive grounding clause** — every derived
  /goal sentence now ends "Ground in repo docs first (GRD).", giving the (context-blind)
  bg worker first-turn awareness (`feedback_route_hook_context_blind`). Deliberately
  inline + short: the wrapper must keep a 3000-char request under the 4000-char /goal
  cap (pwt-goal-cap-enforcement AC4); the deterministic freeze gate is the load-bearing
  fix, not this clause. Survives the overflow-to-disk rebuild (clause lives in the
  wrapper, not the request).
- fix(plan-w-team): **§5a-ter legacy grace** — a spec with NO Grounding Ledger section
  (pre-1.49.0, e.g. `--ship-only`/`--resume` on an in-flight run) warns and skips the
  re-verification instead of hard-blocking; a section deleted mid-run on a post-GRD spec
  is still caught by the §5a spec-SHA drift check.
- feat(plan-w-team): new canonical shared contract `shared/grounding.md` (manifest Shared
  Resources row added); retro §8i gains a refuted-rows spec-quality prompt.
- feat(plan-w-team): **builder grounding channel** — `.claude/agents/team/builder.md`
  gains a Grounding Ledger section: CONFIRMED rows are the authoritative baseline; a
  code-vs-ledger contradiction on a depended-on row is a STOP-and-report (WTF-stop
  discipline), and ASSUMED rows must be verified before building on them. Closes the
  execution-stage blind spot where a wrong assumption was only caught at Step 5 after
  the code was already built.
- fix(plan-w-team): **adversarial-verification hardening** (4-skeptic fan-out over the
  diff before ship): (1) claim-token matching is ROW-ANCHORED — only a table row whose
  status cell is CONFIRMED/ASSUMED counts, so the spec template's own guidance prose
  containing "ASSUMED" can no longer permanently block a template-following spec at
  `--phase review` (was a confirmed blocker); (2) the greenfield waiver requires the
  canonical phrase "no existing documentation" — a negation ("this is NOT a greenfield
  repo") no longer waives the claim-row requirement; (3) freeze-gate failure messages no
  longer coach the kill switch (C6 precedent), for BOTH the grounding and reuse gates;
  (4) §5a-ter resolves the spec via git toplevel so the legacy-grace grep and the gate
  can never disagree under a worktree/subdir CWD; (5) §5a-ter documents the
  skip-disposition audit and the spec-SHA tamper interplay (ledger edits post-freeze
  surface as §5a drift), and a legitimate ASSUMED→CONFIRMED flip re-runs the Step-1
  snapshot (tightening) so later §5a passes don't stall an unattended run on
  ambiguous-ASK; (6) coverage matching is BOUNDARY-ANCHORED — a longer path can no
  longer cover a shorter one (ledger says `docs/README.md`, root `README.md` counted as
  covered — the common root+docs README layout silently defeated the core promise);
  (7) the goal-directive clause is emitted as its own second line so
  `pwt-goal-preamble-strip.test.sh`'s exact first-line contract holds (16/16) while
  staying under the 4000-char cap (cap-enforcement 11/11); (8) mechanism label is
  **GRD**, not "G2" — G<N> was already claimed twice (gotchas index + gap-analyzer
  finding ids); (9) dry-run "Would copy" echoes added for the new gate (+ backfilled
  for the 1.38.0 reuse-* cluster).
- test(plan-w-team): `plan-w-team-grounding-gate.test.sh` — 20 cases green on bash 5.3 AND
  /bin/bash 3.2 (coverage miss names the doc, suffix false-pass regression, fake-greenfield
  fails, greenfield negation fails, prose-ASSUMED immunity at review, ASSUMED row passes
  spec phase / fails review phase, LOUD cap, kill switch, exit-code contract);
  `tests/skill/cases/grounding-gate.bats` — 13 prose-invariant cases pinning the
  cross-file wiring (r10-ratchet names). Sync allowlist: gate + test added to
  `sync-to-project.sh` (G11).

## [1.48.3] — 2026-06-29 (466321a)

Close a supervisor-wait blind spot surfaced while supervising the 1.48.2 run (and recorded in
the `feedback_pwt_supervision_watcher` learning): `plan-w-team-await-terminal.sh` could not detect
a `--worker-only` worker's SUCCESS. Such a worker is caller-supervised — it completes the lifecycle
and emits the canonical Step-8 retro status block in its TRANSCRIPT but, unlike
`--supervisor-goal`/`--launch` (PWT-TERM3), never writes `terminal_state` and lingers idle, so the
PRIMARY (`terminal_state`) and SECONDARY (`WORKER_GONE` — it never vanishes) paths both miss it and
the wait heartbeats forever on a successful run.

- fix(plan-w-team): **await-terminal TERTIARY transcript success-detector for `--worker-only`.**
  When `--worker-sid` is set, locate the worker's top-level session transcript (`$CLAUDE_PROJECTS_DIR`
  / `~/.claude/projects`, `find -maxdepth 2`, resolved-once + cached) and detect the emitted Step-8
  block `status stage="retro-complete" workflow_lock="done"`. The matcher keys on the ADJACENCY of
  `stage="retro-complete"` immediately followed by `workflow_lock="done"` (tolerant of JSONL `\"`
  escaping) — the discriminator that excludes the goal echo (which separates the tokens with
  "appears in transcript with") and planning mentions (backticks/commas between), validated against
  real transcripts. Purely ADDITIVE: runs after PRIMARY (never short-circuits it), gated on
  `--worker-sid`; the existing `terminal_state`, deleted-goal-state, `WORKER_GONE`-debounce, and
  heartbeat semantics are unchanged. Emits `terminal=SUCCESS source=transcript` so the source is
  distinguishable.
- test(plan-w-team): 3 new `await-terminal.bats` cases — fires on the emitted block; does NOT
  false-fire on goal-echo + planning mentions (the critical guard); PRIMARY `terminal_state` still
  wins when both are present. Full `make test-skill` green (bats + 83 shell + 1 TS).

## [1.48.2] — 2026-06-28 (2cd6e16)

Bundled adoption of validated 2.1.195 version-uplift changes + an unrelated Helm-reported
consumer bug fix. Net actionable surface from the uplift report after its regression-probe
revision: the breaking fix + one doc edit (candidates #1/#2 dropped, #3/#4 deferred).

- fix(plan-w-team): **TeamCreate/TeamDelete removed (2.1.178) — scrub dead-tool references.**
  The harness removed `TeamCreate`/`TeamDelete` (only those two; `SendMessage` + `Task*`/`Agent`
  survive). Real spawning was already Agent tool + worktree isolation + `TaskList` self-claim +
  fleet JSONL, so this is cleanup with **no capability loss**. Surgical edits: dropped the
  TeamCreate/TeamDelete steps from `03-execute.md` (renumbered) and reworded the resume-path step
  to keep the spawn instruction; removed only the `TeamCreate`/`TeamDelete` entries from
  `.claude/settings.json` `permissions.allow` (still valid JSON; `SendMessage` +
  `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` KEPT); dropped them from `setup.sh` `REQUIRED_PERMS`;
  reworded the `plan-w-team.md` example; kept `SendMessage` in `version-uplift/SKILL.md`. The
  version-uplift DETECTION CATALOG (`integration-points.json`) keeps the `TeamCreate`/`TeamDelete`
  keywords (classifier recall for future changelogs) — only its `description` was annotated.
  Synced docs that TEACH the dead tool are **annotated** "removed in 2.1.178" (not deleted):
  `CLAUDE_CODE_CLI_REFERENCE.md` §12, `SKILL_PERMISSION_CONVENTION.md`, `AGENT_TEAMS_AND_OBSERVABILITY.md`,
  `docs/operations/claude-code-compatibility.md`.
- docs(plan-w-team): **`workflow` → `ultracode` keyword rename (2.1.160).** `goal-conditions.md`
  PWT-WF1 rationale now anchors the durable guard on the env var `CLAUDE_CODE_DISABLE_WORKFLOWS`
  (keyword-independent), not prose-token avoidance; notes `/effort ultracode` stays excluded from
  bg/autonomous paths (`xhigh` remains the ceiling). The literal `CLAUDE_CODE_DISABLE_WORKFLOWS`
  string is unchanged (a test asserts it).
- fix(plan-w-team): **`plan-w-team-sync-allowlist-check.sh` consumer-repo failure (Helm report).**
  Bug-2 (silent abort): the `ALLOW` grep ran under `set -euo pipefail`, so a no-match `grep`
  aborted the whole script via pipefail before the diagnostic block — real source-repo drift never
  printed its offenders. Now wrapped `{ grep …|| true; }`. Bug-1 (consumer false-positive): a
  consumer carrying an older/different-format `sync-to-project.sh` (no `cp "$SOURCE_DIR/scripts/…"`
  lines) left `ALLOW` empty → every candidate flagged "missing" → hard fail. Now soft-skips
  (exit 0 + one-line stderr warning) when `ALLOW` is empty while candidates exist. Rewrote
  `plan-w-team-sync-allowlist-check.test.sh` into a BDD 3-scenario, fully `mktemp`-isolated
  regression (source-drift-reports-offenders + consumer-soft-skips + source-symmetry-verified);
  already in `sync-to-project.sh`'s allowlist + auto-discovered by `run.sh`. bash 3.2 safe.
- docs(ops): annotated `version-uplift-reports/2026-06-27-2.1.195.md` with a `Regression-probe
  revision (2026-06-28)` section (audit trail preserved): candidates #1 (multi-fallback chain) and
  #2 (bg `--permission-mode`) DROPPED (no-op under `--bg` / redundant under `bypassPermissions`);
  #3 (shell-rc guard) and #4 (`waitingFor` consumer) DEFERRED; summary + next-steps updated.

## [1.48.1] — 2026-06-25 (73554e8)

- fix(test): **complete the corpus goal-state isolation** started in 1.48.0. A full-suite
  before/after sweep of the SOURCE-repo `.claude/state` revealed two MORE leakers the 1.48.0
  named-script fix did not cover, both seeding `plan-w-team-{goal,…}-<slug>` FAMILIES to
  `MAIN_REPO_ROOT` (resolved via git-common-dir = the live source repo) because they ran the
  REAL `pwt-goal.sh` without redirecting its root:
  - `tests/skill/helpers/test_helper.bash` `sandbox()` now exports
    `PWT_PROJECT_ROOT_OVERRIDE="$SANDBOX_DIR"` — the systemic fix for the whole bats phase
    (any `sandbox`-using scenario that actually spawns, e.g. `worker-cascade-blocked.bats`).
    Same isolation intent as the existing `PWT_RAM_CLAIMS_PATH` export beside it.
  - `pwt-goal-heredoc-size.test.sh` exports `PWT_PROJECT_ROOT_OVERRIDE="$SANDBOX"`.
  Verified: a full `make test-skill` now introduces ZERO new families into the source
  `.claude/state` tree (was: ship-the-payment-api / trigger-the-abort-branch / test-request).
  Accumulated historical debris swept. This is the honest completion of the corpus-goalstate-leak
  follow-up — the 1.48.0 ledger note overstated coverage; corrected.

## [1.48.0] — 2026-06-25 (a047fd8)

- feat(test): **corpus goal-state isolation** — `plan-w-team-spawn-registry.test.sh` and
  `plan-w-team-surface-status.test.sh` no longer leak `plan-w-team-{goal,manifest,
  spawned-children,stage-events,skill-version}-<slug>` FAMILIES into the LIVE `.claude/state`
  tree. Each now redirects every helper's writes (incl. the REAL `pwt-goal.sh --launch` in
  spawn-registry U8, and `pwt-manifest.sh` in surface-status) into a per-test `mktemp`
  sandbox via `STATE_DIR` + `cd` + `CLAUDE_PROJECT_DIR` + `PWT_PROJECT_ROOT_OVERRIDE` (the
  test-only lever pwt-goal already exposes). Assertions unchanged; before/after live-state
  snapshots show ZERO new families. Resolves the recurring corpus-goalstate-leak follow-up
  (66 swept by hand 2026-06-25). New BDD regression `tests/skill/cases/corpus-state-isolation.bats`
  pins the redirect for both scripts.
- feat(test): **R6 state-leak guard extended to Phase 2** — `tests/skill/run.sh`'s before/after
  `.claude/state` additive diff now brackets the shell-test (`.test.sh`) phase as well as the
  bats phase, so a FUTURE `.test.sh` live-state leak fails the suite at authoring time (the
  corpus-goalstate-leak class lived exactly here and was previously uncaught).
- feat(test): **worktree-fragility fix** — `run.sh` pins `CLAUDE_PROJECT_DIR=$REPO_ROOT` for
  the shell-test phase so state-reading hooks (goal-evaluator, antipark-*, supervisor-state-detection)
  resolve the SAME checkout the suite runs in. Without it, a self-hosted run inside a
  `.claude/worktrees/<slug>/` checkout made those hooks read main's live state (active-run
  goal-state + leaked debris) while the test only stashed the worktree's — a false failure.
  No-op when run from main; tests that set their own `CLAUDE_PROJECT_DIR` still override it.
- feat(ship): **fail-safe empty-ship loop-breaker** (`plan-w-team-empty-ship-guard.sh`, wired
  into `05-ship.md` §6g before the push ack-gate). Halts Step 6 ONLY when it can POSITIVELY
  confirm there is nothing to ship (0 commits ahead of base AND a clean tracked tree) and
  PROCEEDS on a real ship or ANY ambiguity — so it can NEVER block a real ship. Breaks the
  pre-ship reset-loop (worker 5088e5f4, 2026-06-25: reset its own work then looped push on an
  empty worktree, which would also mint a false-positive `SHIP_PUSH_CONFIRMED` PASS). 8 BDD
  tests pin both directions. Resolves the preship-reset-loop follow-up.
- docs(scope): `00-scope-challenge.md` anti-pattern note — trivial/near-empty tasks must be
  right-sized DOWN by scope-challenge, not force-marched through the full lifecycle (the root
  condition that aggravated the reset-loop incident).
- New state artifact `plan-w-team-empty-ship-attempts-$SLUG.txt` (audit-trail) registered in
  `shared/state-artifacts.md`; both new scripts added to `sync-to-project.sh` allowlist.

## [1.47.2] — 2026-06-25 (b11e6ce)

- fix(test): de-flake `render-artifact-self-contained.bats` (1.45.0 visual-artifacts
  byte-for-byte invariant). Two volatile fields escaped masking and caused an
  intermittent (~1-in-3) failure: `elapsed_seconds` in the JSON (jq pretty-prints a
  space after the colon, so `[0-9]*` matched zero digits) and a BARE `**Generated:**
  <ISO>` in the MD (the mask only caught backtick-wrapped timestamps). Both now masked;
  verified deterministic 10/10. Removes non-determinism — does not loosen the invariant.

## [<semver>] — <YYYY-MM-DD> (<short-sha>)
- <bump kind>: <description>
````

Entries are newest-first.

---

## [1.47.1] — 2026-06-25 (025c6ff)

**PWT-TERM3: make the Step-6 ship-verdict write RELIABLE — close the
runaway-after-ship gap left open by 1.46.0.** The 1.46.0 deterministic-SUCCESS fix
(PWT-TERM1/TERM2) is sound but contingent on the ship-verdict artifact
(`.claude/state/plan-w-team-ship-verdict-<SLUG>.json`, `verdict==PASS`,
`ts>=started_at`) existing on disk. Pre-TERM3 that artifact was written ONLY by an
End-of-Stage inline block in `05-ship.md` — ~700 lines and several fail-soft
off-ramps AFTER `git push`. When a worker reached push but drifted before executing
that block (observed: the 1.47.0 run committed+pushed but produced NO ship-verdict;
three runs hit this — 3ce4f51f, 5b0e7042, ed9856e1), every SUCCESS path failed →
`/goal` kept the session alive → hang. The fix keeps the EXACT same trusted signal
(no new signal, no new artifact, no new gate) and makes the existing post-push write
reliable via an arm-flag + EXIT-trap re-assertion.

- PATCH: **deterministic post-push ship-verdict writer.** Three edits in
  `05-ship.md` ONLY: (1) §6-0a-bis defines `__pwt_write_ship_verdict()` + the
  `SHIP_PUSH_CONFIRMED=0` arm-flag alongside the §6-0a trap install (helper exists
  long before push); the writer fail-safes — it returns WITHOUT writing unless
  `SHIP_PUSH_CONFIRMED=1`. (2) Immediately after `git push -u origin "$BRANCH"`,
  `PUSH_RC=$?` is captured as the FIRST statement (else `$?` is clobbered); on
  `PUSH_RC -eq 0` the flag is armed and the writer is chained onto the EXIT trap via
  the §6-0a/§6g capture+append idiom (appended LAST — never clobbers the
  minimal-retro writer or the push-lock release). (3) The End-of-Stage inline
  `printf > "$SHIP_VERDICT"` is replaced by a call to `__pwt_write_ship_verdict`, so
  happy-path and trap re-assertion are ONE source of truth (exactly one
  PASS-writing printf now exists in the stage).
- WHY NOT THE REJECTED ALTERNATIVES (both adversaries proved these unsafe):
  **R1 — write the verdict pre-push (right after the last §6 gate):** FALSE-POSITIVE
  — would mint a PASS even if the subsequent `git push` / self-merge FAILED,
  terminating SUCCESS for work that never landed. The arm-flag's
  post-push-success-only gating is exactly the anti-false-positive property R1
  violates. **R2 — a merge-corroboration SUCCESS path / per-gate JSONL stamps:**
  new spoof surfaces (the C3 anti-spoof intent requires a single shell-written
  signal, not LLM-corroborated text). **R3 — move/duplicate the signal or touch the
  evaluator / 07-retro:** the evaluator + retro consume the verdict verbatim;
  changing them would break the C3 gate precondition. TERM3 leaves WHO writes it
  (gate/push shell, never the LLM), WHAT it attests (all six §6 ENFORCING gates
  passed AND `PUSH_RC==0`), and the spoof surface IDENTICAL to before — only the
  post-push timing footgun is removed.
- TEST: `tests/skill/scenarios/ship-verdict-post-push-reliability.bats` (20
  BDD-named cases per the r10 ratchet): helper-defined-before-push + flag-default-0;
  writer no-ops when flag=0 (pre-push fail-safe); writes PASS when flag=1; arm site
  is AFTER `git push` guarded by `PUSH_RC -eq 0`; EXIT-trap capture+append inside the
  post-push branch (no clobber); End-of-Stage calls the helper (single
  PASS-printf); **post-push drift → trap fires → PASS on disk (the liveness fix)**;
  **pre-push fail → flag 0 → NO verdict (anti-false-positive)**; idempotent
  overwrite; plus preserved-contract checks that the evaluator still consumes the
  same ship-verdict json and still requires `verdict==PASS`. Runtime cases source
  the helper EXTRACTED from `05-ship.md`, so the behavioral guarantees track the
  live stage source, not a divergent copy.
- INVARIANTS: PWT-TERM1/TERM2 deterministic-SUCCESS (1.46.0), the C3 anti-spoof
  contract, the evaluator foreign-slug/stale/dead-worker/API-HALT guards,
  `PLAN_W_TEAM_DISABLE_GOAL`, fail-open, no new hard gate, bash 3.2, and the
  no-external-deps floor are all preserved. `make test-skill` fully green (bats + 82
  shell + 1 TS); snippet-lint / symmetry-check / sync-allowlist / secret-doc-sync
  --check / sync-script-references all green. Brief:
  `.claude/state/pwt-brief-term3-shipverdict-reliability.md`.

---

## [1.47.0] — 2026-06-25 (923b311)

**Add an advisory root-cause / close-the-class check to Step 5 fix-first review.**
Provenance: principle #4 of Ray Amjad's "targeting machine" talk (model-agnostic;
we run Opus 4.8 only). Models default to lazy point-fixes — patching the symptom
where it surfaces and moving on even when a deeper root cause / meta-level pattern
produces the same CLASS of bug elsewhere — and are reluctant to propose
architectural change unless asked. New §5d-quater in `04-fix-first-review.md` makes
the countermeasure an explicit, repeatable review step for bug-fix-type runs: once a
fix is in hand, the reviewer asks whether it is a point-fix over a deeper pattern,
then takes ONE deliberate outcome. Purely a prompt/doc addition + a thin regression
test — no new subsystem, script, lifecycle gate, or dependency. Spec:
`docs/specs/root-cause-check.md`.

- MINOR: **§5d-quater advisory root-cause / close-the-class check.** Fires for
  bug-fix-type runs (skips pure features / trivial one-liners — right-sized,
  fail-open: no deeper pattern → no-op). Three deliberate outcomes: (1) within
  original scope → close the class now under §5-0 fix-immediately; (2) expands
  scope → route through the **existing** `scope-unlock-for-drift` pause (user-gated,
  reuse — invents no new gate); (3) deferred → record a follow-up in the **existing**
  `recursive-followups` ledger and ship the point-fix. ADVISORY, not a hard gate;
  never forces an architectural change.
- TEST: `tests/skill/cases/root-cause-check.bats` (5 BDD-named cases per the r10
  ratchet) pins the check, the three outcomes, the scope-unlock-for-drift gating
  reference, the recursive-followups ledger deferral, and the advisory/fail-open
  labelling — so a future edit cannot silently drop the gating or upgrade the
  advisory check into a hard gate.
- INVARIANTS: all pre-existing Step 5 gates (spec-integrity, writer↔reader symmetry,
  Pass 1/2, test-gap / security-gap analyzers, access-control content-signal scan),
  the `scope-unlock-for-drift` semantics, PWT-TERM1/TERM2 deterministic-SUCCESS
  (1.46.0), bash 3.2, and the no-new-deps floor are all preserved. `make test-skill`
  fully green (bats + 82 shell + 1 TS).

---

## [1.46.0] — 2026-06-25 (1886c0a)

**Fix the /plan-w-team ↔ /goal non-termination (runaway-after-ship) bug; harden
completion to be deterministic, not LLM-marker-dependent.** A run could fully ship
(origin push + `stage="retro-complete"`) yet leave `terminal_state` null, so `/goal`
kept the session alive and the model invented phantom work (observed: worker `3ce4f51f`
ran 48 min into a non-existent backlog after shipping 1.45.0). Root cause: SUCCESS was
written ONLY by the evaluator on a fragile paired-marker transcript match, and retro read
but never authoritatively wrote it. All changes additive / guarded / fail-open; the
evaluator foreign-slug/stale-skip/dead-worker/API-HALT/supervisor-mirror guards, 1.44.0
PWT-ANTIPARK, the worker-mode spoof-guard's intent, `PLAN_W_TEAM_DISABLE_GOAL`, and the
no-new-hard-gate / bash-3.2 / no-external-deps invariants are all preserved. Spec:
`docs/specs/goal-termination-handshake.md`.

- MINOR: **PWT-TERM1 — retro authoritatively writes SUCCESS.** `07-retro.md` now sets
  `terminal_state=SUCCESS` with `terminal_state_source=retro` on `RETRO_SUCCESS=1` + a PASS
  ship-verdict (never clobbering a halt state). The evaluator's worker-mode spoof-guard is
  extended to honor `retro`/`ship` provenance ONLY when corroborated by the same
  deterministic PASS ship-verdict artifact — preserving (not weakening) its anti-spoof intent.
- MINOR: **PWT-TERM2 — runaway guard.** The evaluator resolves SUCCESS when a PASS
  ship-verdict (ts ≥ the goal's `started_at`) exists for the slug even if the paired
  transcript marker is absent; a stale verdict from an aborted prior same-slug run is ignored
  (ts guard) and retro now retires the ship-verdict on success. The feature-AC AND-check and
  empty-AC PWT-ANTIPARK backlog check still gate, so an incomplete multi-AC / multi-epic run
  is never prematurely terminated.
- MINOR: **Empty-criteria safety.** A route-hook spawn with empty
  `feature_specific_done_criteria` plus a real ship now resolves SUCCESS instead of running
  forever (PWT-ANTIPARK still withholds when an unmet backlog is known).
- MINOR: **Supervisor auto stand-down on post-ship off-brief drift** documented in
  `shared/supervisor-protocol.md` — codifies the manual `3ce4f51f` stand-down; deterministically
  enforced by PWT-TERM2.
- test: new BDD-named regression scenario
  `tests/skill/scenarios/goal-evaluator-termination-handshake.bats` (9 cases) covering the
  runaway guard, stale-verdict rejection, retro-provenance honoring + spoof rejection,
  empty-criteria SUCCESS, antipark withholding, and the unchanged marker happy path.

## [1.45.0] — 2026-06-22 (9dd74e4)

**Visual artifacts woven across the lifecycle** — a single reusable
self-contained-HTML renderer substrate (`plan-w-team-render-artifact.sh`) plus
four lifecycle hook points. Max-safe local-HTML equivalent of Anthropic's
Artifacts-in-Claude-Code (no Artifact tool — plain `Write`s). Spec:
`docs/specs/weave-visual-artifacts-across-the-plan-w-team-lifecycle-as-specified-in-claude-s-da7bc931.md`;
ops doc: `docs/operations/plan-w-team-visual-artifacts.md`. All additive, OFF by
default, fail-open; bash 3.2; zero external deps; no new lifecycle gate.

- MINOR: new substrate `plan-w-team-render-artifact.sh` — emits ONE self-contained
  `.html` (inline CSS/JS/SVG, zero external requests; data values neutralized + a
  post-build self-check discards any leaky page) for four kinds:
  `completion` / `comparison` / `review` / `dashboard`. Design-token seeding: built-in
  defaults overridable from a CLAUDE.md `## Design system` block or `$PWT_DESIGN_TOKENS_FILE`.
- MINOR: Hook 1 (core) — `plan-w-team-completion-summary.sh` ALSO emits
  `.claude/state/plan-w-team-completion-<SLUG>.html` from the EXISTING completion JSON
  when `PWT_EMIT_HTML_REPORT=1` (default OFF). The existing `.md`/`.json` output is
  **byte-for-byte unchanged** when the toggle is unset (pinned regression test).
- MINOR: Hooks 2–4 — `comparison` (scope/spec design comparison), `review` (Step-5
  findings walkthrough), `dashboard` (supervisor live view) wired as OFF-by-default
  documented call-sites in `00-scope-challenge.md`, `01-specification.md`,
  `04-fix-first-review.md`, and `shared/supervisor-protocol.md`.
- MINOR: new state artifact `plan-w-team-completion-<SLUG>.html` (mode `audit-trail`,
  gitignored so it never leaks into a sync commit); registered in
  `shared/state-artifacts.md`, `sync-to-project.sh` cp wall, and
  `plan-w-team-sync-allowlist-check.sh`.
- Tests: `plan-w-team-render-artifact.test.sh` (12 assertions) + BDD-named
  `tests/skill/cases/render-artifact-self-contained.bats` (self-contained HTML,
  off-by-default, design-token override, fail-open, byte-for-byte invariant).

## [1.44.0] — 2026-06-10 (e5b0923)

Goal-state **test-leak + evaluator-blocks-on-stale** hardening (three prongs;
spec `docs/specs/goalstate-test-leak-hardening.md`). Closes the autonomy-substrate
foot-gun where a stale/foreign non-terminal goal-state could trap a legitimate Stop
and aborted runs orphaned run-state forever. All additive, kill-switched, fail-open.

- feat: **(A) evaluator stale-foreign skip** — `plan-w-team-goal-evaluator.sh` now
  SKIPS a non-terminal `plan-w-team-goal-*.json` that is provably not this run's live
  work (aged ≥ `PWT_GOAL_STALE_HOURS` [default 24] AND not-ours AND worker-not-live)
  before it can set `BLOCKING_GOAL_UNOWNABLE` and block the Stop. Reuses the
  `__antipark_state` foreign-slug+stale idiom and `ACTIVE_SIDS` dead-worker signal.
  Single-live-run path unchanged. Kill switch `PLAN_W_TEAM_DISABLE_STALE_SKIP=1`.
- feat: **(B) janitor orphan-family GC** — `plan-w-team-cleanup-stale-goal-states.sh`
  gains PASS 2: reaps a `terminal_state=null` goal + its sibling family (manifest /
  skill-version / spawned-children / stage-events, incl. goal-less families) ONLY
  when the worker is provably DEAD (owner SID absent from live `claude` sessions via
  the new `pwt-live-session-sids.sh`) AND aged ≥ `PWT_GOAL_STALE_HOURS`.
  `USER_ESCALATION_HALT`/`LOW_CONFIDENCE_STREAK`/`DEAD`/`API_HALT` preserved; SUCCESS
  path unchanged. Fail-CLOSED on liveness-query failure; `--dry-run` lists; kill
  switch `PLAN_W_TEAM_DISABLE_ORPHAN_GC=1`. Resolves cleanup-eval **SA-4**.
- feat: **`pwt-live-session-sids.sh`** — SID-emitting sibling of
  `pwt-live-session-cwds.sh` (same fail-CLOSED `claude agents --json` contract).
- test: **(C) corpus isolation** — CONVENTIONS.md gains an explicit "redirect
  run-state writes (goal/manifest/supervisor-progress) to per-test tmp" rule; R6
  state-leak guard verified green and pinned with bracketing + CONVENTIONS regressions.
- fix: correct the janitor header's false "non-terminal files don't block the
  evaluator" claim and the deep-audit **LOW** grep+sed-matches-evaluator comment.

## [1.43.0] — 2026-06-10 (ead76d4)

Sync-design review **ranks 4–8** (wave 2 of the 2026-06-09 sync-hardening review;
ranks 1–3 shipped in `bbb1b98`). Closes the residual drift gaps that produced the
A–G cleanscale incidents by making implicit, hand-maintained sync contracts
declared and machine-checked. All additive; the deferred manifest-loop inversion
was NOT attempted (it would blind both lint extractors).

- feat (R4): derived drift-detection lints — `sync-script-references.bats` gains
  an `all_tracked_runtime_scripts()` helper + a NOT_SYNCED carve-out (syncer trio
  - secrets + source-only tooling) + a stale-carve-out sentinel; new source-only
    `.claude/.sync-extra-manifest` (rsync-excluded) declares the 6 hand-cp'd
    non-.claude assets, with `sync-extra-manifest.bats` asserting each has a `cp`
    line AND a `Would copy:` echo plus a reverse unmanifested-hand-cp sentinel.
- feat (R5): `tests/skill/scenarios.local/` corpus ownership boundary — a SIBLING
  of `scenarios/` (the trailing-slash corpus gitignore can't match it, so it
  stays consumer-tracked), discovered by BOTH `run.sh` and `run-scenarios.sh`;
  one-shot idempotent reconciliation in `sync-to-project.sh` untracks only
  source-owned corpus the consumer tracks (live from the source's own
  `git ls-files`), fail-safe + self-sync-guarded + files kept on disk;
  CONVENTIONS.md + README document the boundary.
- feat (R6): state-leak guard brackets the single merged bats invocation in
  `run.sh` — additive `comm -13` diff of `.claude/state` before/after, folds
  `state_leaked`/`leaked_paths` into the verdict + archival JSON, skips without
  git, `SKILL_SKIP_STATE_LEAK_GUARD` escape hatch; fixes CONVENTIONS.md's
  previously-false "the harness verifies this" claim (would have caught the
  dmarc-monitor watermark at authoring time).
- feat (R7): shared commit discipline — source-only `.claude/scripts/sync-commit-lib.sh`
  (no cp line) extracts the dirty-refusal + scoped-commit with a CORRECTED writer
  manifest (drop dead repo-root `board*.sh`; add `Makefile.template` +
  `build-cleanup-preserve-installables.md` — both written by sync but never
  committed, a silent-dirt bug). Per-path `git add … || true` kills the
  all-or-nothing pathspec abort (incident C); `sync-all-projects.sh` sources it;
  `sync-to-project.sh` gains opt-in `--commit` (default OFF). `shared/shell-safety.md`
  (synced) gains the staging rule.
- feat (R8): setup-path safety parity — `setup-new-project.sh` gains `--checksum`,
  the `SECRET_GUARD_FILTERS` leak set, and an inline-duplicated gitignore
  self-heal (literal corpus patterns stay physically in `sync-to-project.sh` for
  its grep contract); thin-wrapper inversion rejected.

Regression coverage: 5 new BDD-named bats cases (r10 ratchet) + widened
`sync-script-references.bats`; full `make test-skill` green (bats + 79 shell + 1
TS) including the pre-1.42 corpus and the 11 rank-1-3 regressions (the ranks-1-3
`state-deny` pin was repointed to the lib's new home, invariant unchanged).

## [1.42.0] — 2026-06-09 (e0dd34e)

Full end-to-end skill evaluation (user-requested). A 118-agent audit workflow (18 scoped
auditors + adversarial 3-skeptic verification per high/critical finding + completeness-critic
extra round) confirmed 53 findings across every layer — stages, shared docs, scripts, hooks,
tests, sync, ops docs, agent definitions; 9 candidate findings were refuted and dropped. All
53 fixed by a 17-agent disjoint-file-ownership fix fleet + lead follow-ups. Highlights
(severity-ordered; full per-finding evidence lived in the audit run, summarized here):

- **fix(sync, CRITICAL F1)**: `supervisor-merge-gate.sh` — the MUST-invoke deterministic
  merge gate (supervisor-protocol §merge hierarchy, 05-ship §6g-ter) — was missing from the
  sync allowlist AND invisible to the drift checker (non-`plan-w-team-*`/`pwt-*` name).
  Every consumer-repo supervisor ran ungated merges (the 2026-05-22 cleanscale
  `--admin`-bypass class). Now cp'd in both sync branches + pinned in
  `REQUIRED_NONPREFIXED`. Same treatment for `secret-doc-sync.sh` (F18) and a pin for
  `supervisor-progress-check.sh` (X-coord-5). **Systemic guard**: new
  `tests/skill/cases/sync-script-references.bats` lints every runtime script referenced by
  skill md against the sync inventory, so no future non-prefixed script can slip past.
- **fix(pwt-goal, HIGH F2)**: the `--launch` path never seeded the anti-skip goal-state
  anchor (seed lived inside the `--worker-only` branch only) — a `--launch` worker could
  stop short after commit+push exactly like the pre-1.35.0 bug. The SEED THE GOAL-STATE
  block (incl. `__pwt_emit_goal_state`) is hoisted above the branch so `--launch`,
  `--worker-only`, and `--supervisor-goal` all dual-seed; launch-path seeding now asserted
  in `pwt-goal-launch.test.sh`.
- **fix(review, HIGH F3)**: §5a symmetry-check gate silently PASSED on exit 4 (orphan
  reader — the checker's own most-severe verdict). Added the `4)` arm + `*)` catch-all
  (fail-closed), matching the §8g-ter retro twin.
- **fix(hooks-docs, HIGH F8)**: documented-but-dormant pre-commit protections clarified:
  `versioning.md` now states the auto-bump hook fires only when installed into the active
  hooks path (manual VERSION+CHANGELOG bump is authoritative); `CONVENTIONS.md` no longer
  presents the dormant `.githooks/` guard as active (the live gate is
  `pre-commit-quality.sh`'s `make test-skill` block).
- **fix(gc-docs, HIGH X-docs-2 + X-docs-1/3/4/5)**: `worktree-lifecycle.md` reconciled to
  the live GC: 10-token `PWT_WORKTREE_GC_DIRTY_IGNORE` default (was documented as
  `.claude/state/`), fail-closed liveness guard (LIVE_QUERY_FAILED → UNSAFE-KEEP),
  `PWT_STALE_LOCK_HOURS` default 6 (was 24/legacy name), SAFE-PRUNE-PUSHED row, companion-GC
  build-daemon branch.
- **fix(capacity, X-coord-1)**: `pwt-claims-cleanup.sh` rewrote the shared cross-repo
  claims registry with NO lock, racing `pwt-ram-claim.sh`'s locked mutations on every
  fair-share gate — lost-update class. Cleanup now takes the same `${REGISTRY}.lock`
  mkdir-lock (fail-open skip on contention so spawn gates never block); concurrency
  regression tests added (34/34).
- **fix(pwt-goal, F23/X-e2e-1)**: directive-overflow file moved from the caller-worktree
  (`--show-toplevel`, GC-reapable mid-run) to `__pwt_main_repo_root` — same worktree-robust
  resolution the 1.35.0 seed fix used.
- **fix(ship, F11/F12/F4)**: `plan-w-team-next-version.sh` self-fetches the merge target
  before reading `origin/main:VERSION` (closing the stale-snapshot collision §6d claimed
  was already handled); duplicate §6g-bis renumbered (Build-Artifact Hygiene →
  §6g-quater); §6d rebump scoped to skill self-ship with an explicit consumer-repo
  project-version path (consumer ships no longer bump the synced skill VERSION).
- **feat(retro, F10/X-spawned-2/F36)**: Step 8 §8e gains the missing consumer for the
  gap-analyzer handoff: retroactive-task closure rate, per-OWASP gap counts, and the three
  token-cost rows (>40k pass-1 / >20k per analyzer) — advisory, never a gate. §5b-pre/
  §5c-bis/§5d-bis and both analyzer agent bodies now cite the exact §8e location.
- **feat(test-harness, F26)**: `run.sh` Phase 2b executes `*.test.ts`
  (import-coupling pre-fork gate) via tsx — failures fail the suite; loud per-file
  `[SKIP]` when no TS runner (consumer-safe), `SKILL_SKIP_TS_TESTS=1` escape hatch;
  single-runner anti-fragmentation preserved. CONVENTIONS.md counts un-hardcoded (F27),
  phantom R-10 naming-enforcement claim corrected (F28 — measured 19.9% compliance, so
  documented as by-policy-not-enforced).
- **fix(fleet, F16/F25)**: kill-switch/jq-absent summary shapes now key-identical to the
  active path (`max_concurrent:0`, `parallelism_pct` dropped — zero consumers); new
  writer→reader contract test `hooks/tests/plan-w-team-fleet-writer.test.sh` (12 cases).
- **fix(watch, F45+)**: NEW pre-existing production bug found by the new
  `pwt-watch.test.sh`: all five metric bullets used `printf "- …"` — bash printf parses
  the leading dash as an option and `2>/dev/null` swallowed it, so completion summaries
  NEVER carried AC/commit/task/file/score bullets. Fixed with `printf --` + regression
  assertions (the test's own `grep -qF` needed the same `--` fix).
- **fix(ram-budget, F17)**: PWT-RAM2 rollout completed in doc+tests: registry-first
  counting documented, `PWT_RAM_CLAIMS_PATH`/`PWT_RAM_CLAIMS_REGISTRY` rows added, exit-6
  fair-share row added; registry-fixture tests added (no more stub-only coverage).
- **fix(consistency sweep, mediums/lows)**: supervisor default-ON corrected in
  orchestrator-interception (phantom `PLAN_W_TEAM_SUPERVISOR=1` removed, F6); dollar-cost
  evaluator budget replaced with Max-relevant context-%/no-progress signals (F9); DS1
  window 60s→`PWT_DOUBLE_SPAWN_WINDOW_MIN` 3min in both docs (F21); `claude -p`→
  `claude --bg` everywhere (F22); §8j-quater captures terminal_state before deleting the
  goal state file §8j-quinquies reads (F13); slug-keyed `supervisor-progress-<slug>.json`
  references fixed in self-regulation.md + the evaluator block message (F20/X-coord-3);
  stale model-generation labels stripped to tier names per the manifest policy
  (F32/X-spawned-3/5); 18→19 secret-pattern counts (F40); dead spec pointers repointed
  (F19); line-number anchors converted to section-name anchors in gotchas/
  board-integration/goal-conditions (F33); `--dry-run` made actually dry (two leaked cp
  ops + one mkdir, F29); route-prompt header/injected-text drift fixed + mid-work-interrupt
  limitation documented in-hook (F43/F44); resume-staleness STALE/UNKNOWN paths tested
  (F42); event-schema 5→6 + field reconciliation (F39); CHANGELOG historical cites
  normalized (F47); ops root-cause doc banner for 1.34.0-pinned line cites (X-docs-6/7);
  10 shipped pwt-briefs archived to `docs/operations/briefs-archive/` with provenance
  README (F30); `pwt-goal-capacity-gates.test.sh` + `pwt-watch.test.sh` wired into sync.

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
  `PWT_WORKTREE_GC_DIRTY_IGNORE` default at both sites (`plan-w-team-worktree-gc.sh`,
  in `classify_one` + `preserve_then_reap`). Genuine product dirt still pins (only the
  synced layer is ignored), and only
  merged/pushed worktrees are eligible. Regression test `plan-w-team-worktree-gc.test.sh` T18b
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
    `shared/self-regulation.md` + `.claude/agents/team/builder.md`.
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
    `.claude/agents/team/builder.md` and `04-fix-first-review.md` with one-line `Good:` exemplars of the
    desired shape. Every pre-existing negative retained (defense-in-depth); positive exemplars
    per `opus-4-7-practices.md` §7.
  - **F6 — stale forward-looking phrasing (cosmetic)**: corrected `.claude/agents/team/supervisor.md:131`
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
  `plan-w-team.md` bypass-rate cross-ref (live anchor: §8j-octies).
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
  `assertQaScoped()`); referenced by `03-execute.md` + `.claude/agents/team/builder.md`.
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
