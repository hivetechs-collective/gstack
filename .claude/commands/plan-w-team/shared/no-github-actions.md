# No GitHub Actions for Build / CI / Deploy — Governance Rule

**Status**: ENFORCING — backed by a real mechanism, not just prose (audit P9b). Write-time enforcement is the `block-gh-actions-build.sh` PreToolUse hook: it blocks creating/editing a `.github/workflows/*.ya?ml` that runs build/CI/deploy steps (a `jobs:` block with `run:`/`uses:`). Observer-only workflows (`ci-alert*`, `board-auto-add*`) are exempt; kill switch `PLAN_W_TEAM_DISABLE_GH_ACTIONS_GUARD=1`. The Step 6 §6b-bis check is git-level defense-in-depth (catches a workflow introduced outside the Write/Edit path). This is a `/plan-w-team` governance rule, not advice.

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

## Deploy Secret Access (Headless / Autonomous) — the Standard

Moving deploy off GitHub Actions removes the place CI used to read deploy secrets
from (`secrets.*` injected into the runner). The local Makefile path needs its own
secret source — and because autonomous `/plan-w-team` workers run **headless** (no
GUI, no human at the keyboard), that source must be **prompt-free and durable**.
This is the standard for ANY provider (Cloudflare, Fly, Vercel-via-token, AWS, …),
not specific to one project.

**The model (parameterize `<project>` and `<provider>`):**

| Component                             | What it is                                                                                                                                                                                    |
| ------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `~/.config/<project>/deploy.env`      | `0600` file, **outside the repo**, holding the provider token (+ account/target id). The single durable secret store.                                                                         |
| `scripts/load-deploy-env.sh`          | Sourceable. Loads that file into the env **only when the token var is unset** (an injected env always wins). Sourced by the deploy preflight **and** by every `make deploy-*` recipe.         |
| `scripts/setup-<provider>-token.sh`   | One-time bootstrap: writes the `0600` file atomically (never echoes the token) and **verifies** the token resolves to the expected account/target before declaring success. Re-run to rotate. |
| `scripts/preflight-deploy-account.sh` | Optional but recommended guardrail: refuses to deploy when the resolved token/login points at the **wrong** account/target. The env-file is NOT a bypass — the guardrail still runs.          |

**Why a `0600` file and not the obvious alternatives:**

- **OS keychain** (macOS Keychain, etc.) → triggers a GUI "allow access" prompt that
  **hangs a headless worker** (nothing to click). Disqualified for autonomous runs.
- **`launchctl setenv` / shell-rc export** → **evaporates on reboot**; the recurring
  "token missing → deploy blocked" symptom. Not durable.
- **GitHub Actions secrets** → only readable by GH Actions, which this rule forbids.

Security comes from **least-privilege token scope + `0600` perms + rotation**, not
from at-rest encryption that needs an interactive unlock.

**Token scope: least privilege, always.** Mint a token scoped to the **single**
deploy capability on the **single** target account — never a global/admin key, never
multi-account. (Cloudflare worked example: `Account › Workers Scripts:Edit` +
`Account › Cloudflare Pages:Edit`, Account Resources → the one prod account only.)

**Makefile wiring (the recipe must source the loader inline):** a preflight prereq
runs in a _separate_ process, so a token it loads does **not** propagate to the
recipe. Each deploy recipe loads it again so the child deploy CLI inherits it:

```make
deploy-api: preflight-deploy-account
	. scripts/load-deploy-env.sh && <provider-deploy-cmd>   # e.g. pnpm run deploy → wrangler
```

**Hygiene:** add `deploy.env` / `.deploy.env` to `.gitignore`; the canonical path is
outside the repo so it can't be committed; never echo the token when verifying.

### Escalate, never skip (the enforced half of this standard)

The standard above tells you WHERE the deploy credential lives. This subsection is
the ENFORCED rule for what happens when it is **missing** at deploy time. The
2026-06-02 cleanscale report surfaced the gap: a deploy hit `wrangler`'s
non-interactive wall ("set a `CLOUDFLARE_API_TOKEN`"), and the run **stopped short
of the operator step** — it neither completed the deploy nor escalated, and the
missing secret was never surfaced. Documenting the `deploy.env` standard did not by
itself stop a deploy step from being silently skipped.

**The rule:** a deploy/ship step that hits a CLI non-interactive credential wall
**escalates, it does not skip**. This is a `blocked-external` operator escalation —
the CLI sibling of the browser-console guardrail, codified in
[`secret-safety.md §REQ-6`](./secret-safety.md). It is backed by a real mechanism,
not prose:

- **Detector** — `.claude/scripts/credential-wall-detect.sh` classifies the wall and
  extracts the EXACT missing secret name.
- **Hook** — `.claude/hooks/plan-w-team-credential-wall-detect.sh` (PostToolUse /
  PostToolUseFailure) persists `.claude/state/plan-w-team-credwall-<SLUG>.json`
  (missing secret + the documented operator action, resolved from
  `docs/operations/DEPLOY_RUNBOOK.md` when present; survives compaction) and emits a
  `USER_ESCALATION_HALT` block.
- **Gate** — `.claude/scripts/plan-w-team-credential-wall-gate.sh`, wired ENFORCING
  at `05-ship.md §6a-quinquies`, **fails closed** while the artifact is unresolved.
  The deploy/ship step **cannot be marked complete or skipped** until the operator
  provisions the secret (into the `0600` `deploy.env` above) or completes the login,
  then sets `"resolved": true`.

This is the step-completeness invariant: advancing past an incomplete deploy step
that is blocked on a credential is impossible. Treat a credential wall the same way
§Fix-Immediately treats a red gate — surface and resolve, never "note and advance".

**Reference implementation:** CleanRev (`cleanscale`) — `scripts/load-deploy-env.sh`,
`scripts/setup-deploy-token.sh`, `scripts/preflight-deploy-account.sh`, the Makefile
`deploy-*` recipes, and `docs/operations/DEPLOY_RUNBOOK.md` §"Non-Interactive
(Headless) Deploy Credential". A repo adopting this copies that shape and swaps in
its own `<project>` dir, `<provider>` token, and account/target id. Per-repo deploy
recipes belong in that repo's Makefile (seeded from `scripts/Makefile.template`); only
this _standard_ lives in the skill.

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
