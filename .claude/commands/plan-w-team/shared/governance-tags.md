# Governance Tags — One-Way-Door Surface Catalog

Closed list of repository surfaces that are **one-way doors** for the purposes of `/plan-w-team` automation. When a PR's diff touches any of these surfaces, the PR MUST carry the `DO NOT MERGE` label and the origin-chat supervisor's Decision Matrix MUST surface to the user instead of auto-merging.

Spec: `docs/specs/supervisor-protocol-autonomy.md`
Consumers: `shared/supervisor-protocol.md` Decision Matrix, `05-ship.md` PR labeling step.

## Why a Closed List

The Decision Matrix needs a deterministic answer to "is this PR reversible". A free-form LLM judgment would re-introduce the failure mode the matrix is meant to fix (every PR surfaced to user). A closed list of diff-path globs gives every supervisor invocation the same answer.

The list is intentionally narrow. Anything not enumerated here is presumed reversible. Adding a surface requires a spec — see §Adding a Surface below.

## Surface Catalog

| Surface                                       | Path glob(s)                                                                                                             | Rationale                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| --------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Security allowlist                            | `**/secret-allow.txt`, `**/.secret-allow*`, `**/secret-allowlist*`                                                       | Allowlist edits weaken the secret scanner. Wrong addition leaks credentials; needs human review.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| Billing / money                               | `**/billing/**`, `**/payments/**`, `**/stripe*`, `**/invoice*`                                                           | Financial side-effects are irreversible without manual reconciliation. Bad merge can cost real money.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| Schema migrations                             | `**/migrations/**`, `**/*.sql`, `apps/db/schema/**`, `apps/db/migrations/**`                                             | Forward-only. Bad migrations require either backfill or downtime to revert.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| Infra config                                  | `**/wrangler.toml`, `**/*.tf`, `**/*.tfvars`, `**/cloudformation/**`, `**/terraform/**`, `**/k8s/**`, `**/kubernetes/**` | Cloud resource changes have blast radius beyond the repo. Wrong merge can take production down.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| Secrets / env wiring                          | `**/.env`, `**/.env.*`, `**/secrets/**`, `**/*.pem`, `**/*.key`, `**/*.p12`, `**/*.jks`                                  | Secret rotation has out-of-band dependencies (keystores, vaults, services). Repo merge is one step of many.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| Fleet-delete manifest                         | `.claude/scripts/sync-retired-paths.txt`, `**/sync-retired-paths.txt`                                                    | Each line is a standing `rm` that runs unattended across the managed fleet (17, per `.claude/repos.json`) and every other checkout the sync is pointed at. A wrong line is a fleet-wide deletion, not a one-repo bug.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| Governor command execution + model policy     | `.claude/scripts/pwt-governor-lib.sh`                                                                                    | Governor Contract phase 2/3. (a) `pwt_governor_run_cmd`/`event_sink`/`liveness_cmd` execute a governor-supplied command string — a change can widen arbitrary command execution; the git-tracked-manifest refusal, the required timeout, and the `env -i` argv exec are the load-bearing guards. (b) Phase 3 `pwt_governor_model` is the **downward-only** model policy guard: its per-tier EXACT-STRING allow-list is what stops a governor `models` override from re-enabling the FORBIDDEN Opus 5, the bare `opus`/`inherit` alias, Fable in a non-design tier, or any tier-raise (Model Tiering v5). Weakening the allow-list to a rank comparison re-opens the 2026-07 Fable-into-lead lockout. Needs a security review. |
| Given-spec validation                         | `.claude/scripts/pwt-given-spec.sh`                                                                                      | Governor Contract phase 3 (C6). Validates + installs a governor-supplied spec that then drives build+ship WITHOUT re-authoring Step 0/1. The theater guard (non-symlink regular file ≥ floor), the clean-slug requirement, copy-into-tree (dest is always sanitized `docs/specs/<slug>.md`), the TRUTHFUL freshness-gate outcome, and the in-tree-only provenance write are the guards. Weakening any of them admits an unvetted/stale/symlinked spec into the pipeline (spec-injection); Step-5 adversarial re-verification is the backstop, not the entry gate. Needs a security review.                                                                                                                                    |
| Delegated approval / self-approval prevention | `.claude/hooks/plan-w-team-lane-guard.sh`, `.claude/scripts/pwt-approver.sh`                                             | Governor Contract phase 2 (C4). The lane-guard decision-file protected set prevents the worker/supervisor self-approving a hard gate; the approver creates the gate's operator file on a governor `approve` and enforces the one-way-`grant_ref` rule. Weakening either bypasses the human/governor gate on an irreversible push/allowlist/scope change. Needs a security review.                                                                                                                                                                                                                                                                                                                                             |

The list is matched via standard glob semantics (`**/` recurses, `*` matches any path segment, `?` matches a single char). Path comparison is case-sensitive on Linux/macOS (filesystem behavior aside).

### Infra-runbook documentation duty (C2, 1.33.0)

The **Infra config** and **Secrets / env wiring** rows above are not only merge
one-way-doors — they are also a **documentation** one-way-door. A change to
`wrangler.toml` / `*.tf` / `k8s/**` (or to `.env*` / `secrets/**` wiring) that ships
without a runbook or config-reference update leaves the next operator to
reverse-engineer the new infra surface from the diff (audit gap C2).

When a diff touches one of those two rows, the run MUST update a `docs/operations/*`
runbook or a config reference describing the changed surface. This is enforced at
post-ship via the net-new-surface mechanism
(`plan-w-team-netnew-surface.sh` — `06-post-ship.md §7a-bis`/§7f): an infra-glob
change with no operational-doc touch and no waiver is an UNDOCUMENTED residual that
blocks Step 7 completion. The companion secret-handling duty (a new secret-bearing
env var needs an `.env.example` row + provisioning/rotation note, C1) lives in
[`secret-safety.md §"Secret-Handling Documentation Duty"`](./secret-safety.md).

### Fleet-delete manifest — this row is a control, not a convenience (I-2 / C4)

Read this before you consider the **Fleet-delete manifest** row redundant with the
runtime guards, because it is not, and the reason is specific.

`.claude/scripts/sync-retired-paths.txt` is a list of paths that `sync-to-project.sh`
**deletes from every consumer repo on every sync**, unattended, at session start,
with no human reading the diff. Its 11-rule runtime guard set is genuinely strong for
paths the source ships: rule 6 aborts the whole pass if a line is, or is an ancestor
of, something still shipped.

But rule 6 only knows the **source** tree. A **consumer-authored** file — for example
`parts`' own `.claude/skills/audit/` and `.claude/skills/cobe-assistant/` — is by
definition absent from the source, so it collides with nothing, and rules 6 and 7 are
both silent. A line naming it would pass every runtime check and delete it fleet-wide.
The manifest's header previously claimed the ancestor guard covered this; the T8s
security review (findings I-2 and C4) established that it does not, and the false
claim has been corrected at the source.

With that claim gone, the control set for consumer-owned paths is exactly three, all
procedural:

1. **Manifest content** — the list itself is the control; never write such a path in.
2. **Governance review** — _this row_. It forces a Step-5 security review on any diff
   that touches the manifest.
3. **Static lint** — a bats case greps the manifest for known consumer-owned trees and
   fails the suite when one is named.

There is no structural backstop. Removing or weakening this row does not lose a nice-to-have
warning; it takes the control set from three to two on the one hazard class with no
runtime defence at all. Treat this row the way the catalog treats schema migrations.

```bash
# Pseudocode (origin-chat supervisor turn, Bash):
DIFF_PATHS=$(gh pr diff --name-only "$PR")
HAS_ONE_WAY_DOOR=0
while IFS= read -r path; do
    # Each glob in the catalog is checked against $path.
    for glob in "${GOVERNANCE_GLOBS[@]}"; do
        case "$path" in
            $glob) HAS_ONE_WAY_DOOR=1; ONE_WAY_PATH="$path"; ONE_WAY_GLOB="$glob"; break 2 ;;
        esac
    done
done <<< "$DIFF_PATHS"

if [ "$HAS_ONE_WAY_DOOR" = 1 ]; then
    surface "PR #$PR touches one-way-door surface: $ONE_WAY_PATH (matched $ONE_WAY_GLOB)"
fi
```

The supervisor builds `GOVERNANCE_GLOBS` from this file at run start. Adding a row here is sufficient to extend the check — no code changes required.

## How Ship Uses This

`05-ship.md` (Step 6) instructs the worker, after `gh pr create`, to walk the staged diff against this list and apply the `DO NOT MERGE` label when any surface matches. The label is what downstream `gh pr list --json labels` queries observe; the governance-tags check is the workers' compliance contract.

A worker that ships a PR touching a one-way-door surface WITHOUT the label is a Pass 1 CRITICAL review item — the Step 5 reviewer detects the missing label by re-running the same diff-vs-globs check.

## What This List Is NOT

- **Not a permission system.** Anyone with write access can still merge a PR labeled `DO NOT MERGE`. The label is a signal to the supervisor and to humans, not an ACL.
- **Not a security control.** A bad actor with merge rights can bypass it. The list exists to prevent good-faith automation from auto-merging into a foot-gun.
- **Not a code review substitute.** Reversible PRs still go through Pass 1/2 review in Step 5; the matrix only governs the MERGE decision after review passes.

## Adding a Surface

A new surface needs a spec and a `/plan-w-team` run. The flow:

1. Open a spec at `docs/specs/governance-tag-<surface>.md` explaining the irreversibility argument.
2. Add the row here. The path glob(s) MUST be conservative (false positives are tolerable; false negatives are the failure mode).
3. Update the 4 regression scenarios (`tests/skill/scenarios/supervisor-matrix-*.bats`) to cover the new surface IF it changes the matrix branch coverage.
4. Run `tests/skill/run.sh` and ship.

Removing a surface requires the same flow — never silently delete a row. The list is the supervisor's contract; changes are auditable.

## Failure Modes

| Failure                                       | Behavior                                                                                          |
| --------------------------------------------- | ------------------------------------------------------------------------------------------------- |
| `gh pr diff` returns empty / error            | Supervisor treats PR as one-way-door (fail-closed) → SURFACE. Better safe than auto-merged blind. |
| Glob syntax invalid                           | Supervisor logs to stderr, treats specific glob as no-match, continues with remaining globs.      |
| Glob matches every path (e.g., `**`)          | A row added in error blocks every auto-merge. Catch via the regression scenarios + Pass 1 review. |
| File is gone from the working tree at compare | `case "$path" in` works on string match; deleted files are still in the diff and still match.     |

## Worked Examples

### Reversible PR — no label, AUTO-MERGE eligible

```
apps/web/src/components/UserList.tsx
apps/web/src/styles/user-list.css
apps/web/tests/UserList.spec.tsx
```

No path matches any glob. PR carries no `DO NOT MERGE` label. CI green → matrix returns AUTO-MERGE.

### Irreversible PR — label required, SURFACE always

```
apps/db/migrations/2026_05_22_add_subscription_status.sql
apps/api/src/billing/subscription.ts
```

Two surfaces match: `**/migrations/**` (schema migrations) and `**/billing/**` (billing/money). Worker MUST apply `DO NOT MERGE` label at ship time. Supervisor SURFACES regardless of CI state.

### Borderline — broad glob, false positive

```
apps/web/src/payments-empty-state.tsx
```

Matches `**/payments*` (billing/money surface, since `**/payments**` is in the catalog as `**/payments/**`). Strictly speaking this is a UI component, not a money path. **False positive is the intended behavior** — the supervisor SURFACES; the user OKs the merge. Cost: one user prompt. Benefit: never silently auto-merges a real payment-path change.

If false-positive frequency becomes painful, tighten the glob (e.g., `**/payments/**/` requires a directory match, not a prefix). Do not loosen by removing surfaces.
