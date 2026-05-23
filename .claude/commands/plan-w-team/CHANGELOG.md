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
