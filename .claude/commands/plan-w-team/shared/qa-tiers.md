# QA Tiers — Evidence Ledger Template

Single source of truth for test-tier definitions and the evidence ledger that UI features carry through `/plan-w-team` and `/qa-scaffold`. Ported and generalized from Progressive CIT.

**Consumed by:**

- `/qa-scaffold/01-select-profile.md` — profile picks which tiers are active
- `/plan-w-team/01-specification.md` — Test Plan section references the active tiers
- `/plan-w-team/05-ship.md` — Tier Evidence Ledger required in ship artifacts for UI features
- `.claude/agents/team/builder.md` — builders cite ledger rows when marking a task complete
- `.claude/agents/team/evaluator.md` — evaluator verifies ledger rows before verdict

---

## Tier definitions

| Tier    | Name                    | Scope                                               | Default runtime budget | When it runs                        |
| ------- | ----------------------- | --------------------------------------------------- | ---------------------- | ----------------------------------- |
| **T1**  | Local smoke             | 1× happy path on the affected area                  | < 60 s                 | Builder, before marking task done   |
| **T2**  | Local stability loop    | 10×–20× stability run on the affected tag/file      | < 10 min               | Builder, before opening PR          |
| **T3**  | Repo regression sweep   | Full `npm test` / `playwright test` across the repo | < 20 min               | Lead, before Step 5 review          |
| **T4**  | CI pipeline green       | Branch push → GitHub Actions / CI must pass         | CI-bound               | Automatic on push                   |
| **T5**  | Post-merge monitor      | 3–5 CI runs after merge (flake + integration drift) | over several hours     | Post-merge watch (solo repos: opt)  |
| **TO2** | Mutation / negative run | Mutation + adversarial path coverage                | < 10 min               | One-way-door or subtle-causality PR |

`TO*` tiers are optional overlays on top of T1–T5. Future `TO1`, `TO3` slots are reserved (e.g., accessibility scan) and deliberately out of scope for v1.

---

## Profile → active tiers

The profile selected in `/qa-scaffold/01-select-profile.md` (and stored in `.claude/qa-profile.json`) determines which tiers are enforced. A feature can override the profile in its `/plan-w-team` spec.

| Profile           | Trigger                     | Active tiers            | Notes                         |
| ----------------- | --------------------------- | ----------------------- | ----------------------------- |
| **Tier-Light**    | < 5k LOC, solo contributor  | T1, T3                  | Skip T2; T5 optional for solo |
| **Tier-Standard** | 5k–25k LOC OR multi-contrib | T1, T2, T3, T4          | BDD optional                  |
| **Tier-Full**     | > 25k LOC OR shared library | T1, T2, T3, T4, T5, TO2 | BDD (Cucumber.js) enabled     |

Profile is sticky per repo. A single feature can opt into a higher tier (e.g., a Tier-Light repo enforcing T4 for a risky change) but cannot opt out below its profile's minimum without a one-way-door unlock.

---

## Status glyphs

Every ledger cell uses one of these five glyphs. No prose in cells.

| Glyph | Meaning                                                                 |
| ----- | ----------------------------------------------------------------------- |
| ✅    | Passed within budget, evidence recorded                                 |
| ❌    | Failed — blocks ship; attach failure artifact path                      |
| ⏳    | In progress — not yet a final verdict                                   |
| 🚫    | Deliberately skipped with justification (cite reason in "Notes" column) |
| N/A   | Tier is not active under the current profile; no action expected        |

A ledger with any ❌ or ⏳ row is **not shippable**. `🚫` is acceptable when the Notes column cites a concrete reason (e.g., "T5 skipped — solo repo, Tier-Light").

---

## Evidence Ledger Template

Copy into the PR description / ship artifact for every UI feature. Fill in the active rows per the repo's profile; leave inactive rows as `N/A`.

```markdown
## Tier Evidence Ledger — <feature-slug>

**Profile:** Tier-<Light|Standard|Full>
**Spec:** docs/specs/<slug>.md
**Commit:** <short SHA>

| Tier | What was run                  | Result | Evidence (path / CI link / run count) | Notes |
| ---- | ----------------------------- | :----: | ------------------------------------- | ----- |
| T1   | Local smoke — affected area   |        |                                       |       |
| T2   | Local stability 10×–20×       |        |                                       |       |
| T3   | Repo regression sweep         |        |                                       |       |
| T4   | CI pipeline green             |        |                                       |       |
| T5   | Post-merge monitor (3–5 runs) |        |                                       |       |
| TO2  | Mutation / negative run       |        |                                       |       |
```

### Evidence column conventions

| Kind             | Accepted form                                                      |
| ---------------- | ------------------------------------------------------------------ |
| Local test run   | Path to Playwright HTML report or test output log                  |
| Stability loop   | Run count + pass count (e.g., `20/20`, `19/20 — see attached log`) |
| Regression sweep | Test runner summary line (`Tests: 142 passed, 0 failed`)           |
| CI               | Permalink to the green workflow run                                |
| Post-merge       | CI run IDs or dashboard link covering the observation window       |

If an evidence cell would be empty, the row is not done — use ⏳ until the evidence exists.

---

## Ledger authoring rules

1. **One ledger per feature.** Don't split across PRs unless the feature itself is split.
2. **Rows match the active profile.** Inactive rows are `N/A`, not blank.
3. **No retroactive green.** If a row flipped ❌ → ✅, cite the fix commit in Notes.
4. **Skips require a reason.** `🚫` without a Notes justification is treated as ❌ by the ship gate.
5. **CI is authoritative.** If T4 is ✅ locally but the CI link is missing, the row is ⏳.

---

## Failure routing

| Failing tier | First responder                               | Escalation                                  |
| ------------ | --------------------------------------------- | ------------------------------------------- |
| T1           | Builder fixes immediately before task done    | If >3 attempts, escalate to lead            |
| T2           | Builder investigates flake; fix or quarantine | Document quarantine in anti-pattern catalog |
| T3           | Lead triages; assigns to owning builder       | Block Step 5 review                         |
| T4           | Lead triages via CI logs                      | Block Step 5 review                         |
| T5           | Post-merge watcher; revert if regression      | Issue + revert commit                       |
| TO2          | Original builder, lead consults evaluator     | Treat one-way-door edits as blockers        |

---

## Interaction with `/plan-w-team` lifecycle

| Step                    | Ledger interaction                                                                     |
| ----------------------- | -------------------------------------------------------------------------------------- |
| Step 1 Specification    | Test Plan names the active tiers for the feature (from profile or spec override)       |
| Step 2 Task breakdown   | Paired test tasks (`N.a`) own the T1/T2 rows for their area                            |
| Step 3 Execute          | Builders update their paired test task's ledger cells as evidence lands                |
| Step 4 Evaluator        | Evaluator refuses to PASS a verdict if ledger has ❌ or empty active rows              |
| Step 5 Fix-first review | Pass 1 CRITICAL: ledger is complete; every active tier has a verdict and evidence      |
| Step 6 Ship             | Ledger copied into PR body / ship artifact; ship gate blocks on incomplete ledger      |
| Step 8 Retro            | Retro metrics: which tiers flaked, which were skipped, whether profile was appropriate |

---

## Profile override

To override the profile for one feature, set in the spec front-matter:

```yaml
qa_profile_override: Tier-Standard # or Tier-Full
qa_profile_override_reason: "Risky schema migration — enforce T4/TO2 despite Tier-Light baseline"
```

Lowering below the repo's baseline profile requires an explicit `.claude/state/qa-profile-unlock-<slug>` acknowledgement file — the same unlock mechanism used by the scope-lock in Step 2.
