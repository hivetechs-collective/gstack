# No GitHub Actions for Build / CI / Deploy — Governance Rule

**Status**: ENFORCING. This is a `/plan-w-team` governance rule, not advice.

GitHub Actions MUST NOT be used as a build, CI, or deploy path. The canonical path
is the **local Makefile + admin-squash-merge** workflow (see `scripts/Makefile.template`,
shipped to every repo via the sync allowlist). Documenting or invoking
`gh workflow run` / `.github/workflows/*.yml` as a build/CI/deploy path is **off-policy
drift and MUST be treated as a defect and fixed** under the fix-immediately rule
(`04-fix-first-review.md` §Fix-Immediately, Never Defer).

## Why

GitHub Actions' free-tier minutes were exhausted in a single high-throughput session
(~50 PRs). The lead built a $0 local replacement that runs the same gates
(`typecheck` / `lint` / `test`) locally and merges via admin-squash. Reintroducing GH
Actions for build/CI/deploy re-incurs the cost this workflow was built to eliminate.

This rule codifies the standing memories `project_no_github_actions` and
`user_workflow_local_ci_workaround` into the skill so the policy travels with every
synced repo instead of living only in per-machine memory.

## The Canonical Path

| Capability                           | Local replacement               | Command                                                           |
| ------------------------------------ | ------------------------------- | ----------------------------------------------------------------- |
| Build / typecheck / lint / test (CI) | `make ci` / `make test`         | runs `typecheck && lint && test` locally                          |
| Merge                                | admin-squash-merge              | `gh pr merge <n> --admin --squash --delete-branch`                |
| Deploy                               | `make deploy` (per-repo target) | repo-specific deploy command (e.g. `wrangler`, `pnpm run deploy`) |

`make ci` runs the identical gate set a CI workflow would run — the work happens
locally for $0 ongoing cost. Merges go through with `--admin` because there are no
GH Actions producing required status checks to wait on. The same `make test` /
`make test-all` gate is wired into `.husky/pre-push` (or equivalent) so the
admin-squash-merge push still passes through a green gate.

## What Counts as a Violation (a defect to fix)

- A new `.github/workflows/*.yml` whose job runs build/test/lint or a deploy step
  (`wrangler deploy`, `pnpm run deploy`, `eas build`, etc.).
- A doc, runbook, or spec that instructs the reader to "re-enable the GH Actions
  workflow" or "trigger the deploy workflow" as the deploy path.
- A `gh workflow run <build-or-deploy-workflow>` invocation in a script or stage file.

When found, fix it: move the gate to the local Makefile path (or delete the workflow /
move it to `.github/workflows-disabled/`), and update any doc that pointed at it. Do
not log it as "noted" and advance (see fix-immediately rule).

## Explicit Exemptions (NOT violations)

These are **lightweight alerting / housekeeping observers**, not build/CI/deploy paths.
They run no build, no test gate, and no deploy step, so they do not consume the budget
the rule protects:

- **`scripts/ci-alert.yml.template`** — the `workflow_run` observer that opens/closes a
  GitHub Issue and pushes a notification when _another_ workflow fails. It observes; it
  does not build, test, or deploy. EXEMPT.
- **`scripts/board-auto-add.yml`** — auto-enrolls new issues/PRs onto the project board.
  Housekeeping, no build/deploy. EXEMPT.
- **Manual-dispatch infra-bootstrap workflows** that a repo has deliberately retained as
  a one-shot operation (e.g. a portal-infra setup that is run by hand, not on push).
  These are not a recurring build/CI/deploy path. EXEMPT, but prefer a local script
  where practical.

If you are unsure whether a workflow is exempt, apply the test: **does it run a build,
a test gate, or a deploy on push / PR / schedule?** If yes → violation. If it only
observes, notifies, or labels → exempt.

## How `/plan-w-team` Enforces This

- **Step 6 Ship** (`05-ship.md`) checks the run's diff for new `.github/workflows/*.yml`
  build/deploy paths and for `gh workflow run` build/deploy invocations; a match is a
  ship-blocking defect (not a "noted" item).
- **Step 5 Fix-First Review** treats an introduced GH-Actions build/deploy path as a
  CRITICAL Pass 1 finding to fix immediately.
- **Step 8 Retro** records whether any GH-Actions drift was introduced and fixed.

## Related

- `scripts/Makefile.template` — the shipped local build/merge/deploy capability.
- `04-fix-first-review.md` §Fix-Immediately, Never Defer — how a detected violation is repaired.
- Memories: `project_no_github_actions`, `user_workflow_local_ci_workaround`.
