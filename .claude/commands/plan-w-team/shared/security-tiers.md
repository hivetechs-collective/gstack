# Security Tiers — Evidence Ledger Template

Single source of truth for security-tier definitions and the evidence ledger that security-touching features carry through `/plan-w-team`. Analogous to `shared/qa-tiers.md` for tests. Installed by the 2026-05 Security Review Extension (mirrors the 2026-05 STE extension's shape for security).

**Consumed by:**

- `/plan-w-team/01-specification.md` — Test Plan section references active security tiers when security surfaces are present
- `/plan-w-team/02-task-breakdown.md` — Paired `N.s` security-review task references the tier set per the OWASP coverage map
- `/plan-w-team/04-fix-first-review.md` — §5d-bis Retroactive Security-Gap Analysis enforces tier coverage
- `/plan-w-team/05-ship.md` — §6c-bis Security Tier Gate enforces the auto-default floor (T1+T3+T4 baseline) when no policy declared
- `.claude/agents/research-planning/security-gap-analyzer.md` — emits `tier:` field on each finding referencing this table
- `.claude/agents/security-expert.md` — primary executor for `N.s` and `N.t` tasks; ledger rows are its compliance contract

---

## Tier definitions

| Tier    | Name                | Scope                                                                                                            | Default runtime budget | When it runs                          |
| ------- | ------------------- | ---------------------------------------------------------------------------------------------------------------- | ---------------------- | ------------------------------------- |
| **T1**  | Lint scan           | `eslint-plugin-security` (JS/TS), `bandit` (Python), `gosec` (Go), `cargo-clippy --warn=clippy::security` (Rust) | < 60 s                 | Local fast — builder before task done |
| **T2**  | SAST                | `semgrep` against project ruleset; `sonarqube` hooks if configured                                               | < 10 min               | Step 5 review                         |
| **T3**  | Dependency audit    | `npm audit`, `cargo audit`, `pip-audit`, `osv-scanner`                                                           | < 5 min                | Step 6 ship gate                      |
| **T4**  | Secret scan         | Existing `.claude/scripts/secret-scan.sh` (18 patterns)                                                          | < 30 s                 | Pre-commit AND Step 6                 |
| **T5**  | SBOM generation     | `syft` or `cyclonedx-bom`; attach to ship artifact                                                               | < 2 min                | Post-ship documentation               |
| **TO1** | Pen-test simulation | OWASP ZAP baseline scan                                                                                          | < 15 min               | Opt-in for user-facing endpoints      |
| **TO2** | Fuzz testing        | `cargo-fuzz` (Rust), `AFL++` (C/C++), `atheris` (Python), `jazzer` (JVM)                                         | minutes to hours       | Opt-in for parser/protocol code       |

`TO*` tiers are optional overlays on top of T1–T5. Future `TO3` slots are reserved (e.g., supply-chain attestation) and deliberately out of scope for v1.

---

## Profile → active tiers

The profile selected by the ship gate (or explicitly declared in `.claude/state/security-policy.txt`) determines which tiers are enforced. A feature can override the profile in its `/plan-w-team` spec.

| Profile               | Trigger                                                                 | Active tiers                 | Notes                                                                                            |
| --------------------- | ----------------------------------------------------------------------- | ---------------------------- | ------------------------------------------------------------------------------------------------ |
| **SecBaseline**       | Default for any repo                                                    | T1, T3, T4                   | Always-on baseline; auto-proposed by Step 6 when no `security-policy.txt` declared               |
| **SecStandard**       | Repo LOC > 5k OR security-touching surfaces present (per OWASP map)     | T1, T2, T3, T4               | T2 SAST is the only addition; runs in Step 5 review                                              |
| **SecHardened**       | User-facing public endpoints detected (`routes/`, `api/`, `pages/api/`) | T1, T2, T3, T4, TO1          | TO1 ZAP baseline opt-in (one-time consent file: `.claude/state/security-policy.txt: enable-to1`) |
| **SecHigh-Assurance** | Parser/protocol code OR cryptography surfaces (per OWASP map A02/A08)   | T1, T2, T3, T4, T5, TO1, TO2 | Full ladder; T5 SBOM ships every release; TO2 fuzz runs nightly via CI                           |

Profile is sticky per repo. A single feature can opt into a higher profile (e.g., a SecBaseline repo enforcing SecHardened for a risky public-facing change) but cannot opt out below SecBaseline without a one-way-door unlock.

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

A ledger with any ❌ or ⏳ row is **not shippable**. `🚫` is acceptable when the Notes column cites a concrete reason (e.g., "T5 skipped — no `syft` available in CI image").

---

## Evidence Ledger Template

Copy into the PR description / ship artifact for every feature touching security surfaces. Fill in the active rows per the repo's profile; leave inactive rows as `N/A`.

```markdown
## Security Tier Evidence Ledger — <feature-slug>

**Profile:** Sec<Baseline|Standard|Hardened|High-Assurance>
**Spec:** docs/specs/<slug>.md
**Commit:** <short SHA>

| Tier | What was run         | Result | Evidence (path / CI link / run count) | Notes |
| ---- | -------------------- | :----: | ------------------------------------- | ----- |
| T1   | Lint scan (security) |        |                                       |       |
| T2   | SAST (semgrep)       |        |                                       |       |
| T3   | Dependency audit     |        |                                       |       |
| T4   | Secret scan          |        |                                       |       |
| T5   | SBOM generation      |        |                                       |       |
| TO1  | OWASP ZAP baseline   |        |                                       |       |
| TO2  | Fuzz testing         |        |                                       |       |
```

### Evidence column conventions

| Kind             | Accepted form                                              |
| ---------------- | ---------------------------------------------------------- |
| Lint scan        | Path to `eslint`/`bandit`/`gosec` output log               |
| SAST             | Path to semgrep findings JSON OR `0 findings` summary line |
| Dependency audit | `npm audit` summary line OR path to detailed report        |
| Secret scan      | `secret-scan.sh` exit code 0 + commit SHA scanned          |
| SBOM             | Path to `sbom.spdx.json` or `sbom.cdx.xml` artifact        |
| ZAP              | Path to ZAP HTML report; baseline alerts triaged in Notes  |
| Fuzz             | Corpus size + run-hours + crashes-found summary            |

If an evidence cell would be empty, the row is not done — use ⏳ until the evidence exists.

---

## Ledger authoring rules

1. **One ledger per feature.** Don't split across PRs unless the feature itself is split.
2. **Rows match the active profile.** Inactive rows are `N/A`, not blank.
3. **No retroactive green.** If a row flipped ❌ → ✅, cite the fix commit in Notes.
4. **Skips require a reason.** `🚫` without a Notes justification is treated as ❌ by the ship gate.
5. **Policy is authoritative.** If `.claude/state/security-policy.txt` declares `security-tiers: T1,T3,T4`, ONLY those rows are required; the rest are `N/A`.

---

## Failure routing

| Failing tier | First responder                            | Escalation                                                                            |
| ------------ | ------------------------------------------ | ------------------------------------------------------------------------------------- |
| T1           | Builder fixes immediately before task done | If lint flags a true positive in N.b code, escalate to N.s reviewer                   |
| T2           | Step 5 reviewer (security-expert agent)    | SAST high-severity = Pass 1 CRITICAL                                                  |
| T3           | Step 6 ship gate (security-expert)         | High-severity CVE in dep tree blocks ship                                             |
| T4           | Pre-commit hook + Step 6                   | Real secret = immediate halt; pause site `secret-scan-allow` if allowlist edit needed |
| T5           | Post-ship documentation step               | Missing SBOM = INFORMATIONAL, not blocking                                            |
| TO1          | Repo opt-in only                           | ZAP high-severity blocks ship if profile includes TO1                                 |
| TO2          | Original builder + security-expert         | Treat fuzz-found crash as one-way-door blocker                                        |

---

## Interaction with `/plan-w-team` lifecycle

| Step                    | Ledger interaction                                                                                                                                                                             |
| ----------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Step 1 Specification    | Test Plan names the active security tiers for the feature (from profile or spec override)                                                                                                      |
| Step 2 Task breakdown   | Paired `N.s` security-review task is emitted for code-adding tasks on security-relevant surfaces. The task references this file for its tier-set scope. Refactor/docs/config remain unchanged. |
| Step 3 Execute          | Builders run T1 locally before marking N.b done; N.s runs against the implemented surface                                                                                                      |
| Step 4 Evaluator        | Evaluator refuses to PASS a verdict if security ledger has ❌ or empty active rows                                                                                                             |
| Step 5 Fix-first review | §5d-bis Retroactive Security-Gap Analysis: `security-gap-analyzer` runs and queues `N.t` retroactive security-coverage tasks. Ledger row T2 fills with SAST results.                           |
| Step 6 Ship             | §6c-bis Security Tier Gate: ledger copied into PR body / ship artifact; ship gate blocks on incomplete ledger; auto-default proposes profile if no `.claude/state/security-policy.txt`         |
| Step 7 Post-ship docs   | T5 SBOM row filled if active profile includes it                                                                                                                                               |
| Step 8 Retro            | Retro metrics: which tiers flaked, which were skipped, retroactive `N.t` task closure rate, security-gap-analyzer report finding count                                                         |

---

## Paired Security-Review Tasks (Security Review Extension)

The `N.s` security-review task is the security-domain counterpart to STE's `N.a` test task. Tasks are emitted by Step 2 when the trigger condition holds:

| Scope                                                            | N.s paired?                         | N.s agent default | N.s scope        | Notes                                                                                      |
| ---------------------------------------------------------------- | ----------------------------------- | ----------------- | ---------------- | ------------------------------------------------------------------------------------------ |
| BACKEND / INFRASTRUCTURE / SCRIPTS / LIBRARY / API (mode == add) | yes (when surfaces match OWASP map) | `security-expert` | `TESTS` (review) | Blocked by `N.b`; runs security-expert against the implemented code before retro           |
| UI / FRONTEND with `**/render*` / `**/template*` / form-handling | yes (A03 XSS surface)               | `security-expert` | `TESTS` (review) | Blocked by `N.b`                                                                           |
| Refactor-only (any scope)                                        | no                                  | —                 | —                | Refactor changes constrained by existing security tests                                    |
| Docs-only                                                        | no                                  | —                 | —                | Docs have no behavioral surface                                                            |
| Config-only with \*_/.env_ / secret wiring                       | yes (A05 misconfig)                 | `security-expert` | `TESTS` (review) | Special case: config touching secrets/credentials gets security review even if pure-config |
| DATABASE schema migrations                                       | no (covered by Step 5 one-way-door) | —                 | —                | Schema-level security (RLS, GRANT) is reviewed in Step 5 one-way-door scrutiny             |

Retroactive `N.t` tasks (created by Step 5 §5d-bis from `security-gap-analyzer` findings):

- `N.t` — `security-expert` writes the missing security test/assertion. Runs after Step 6 ship and before Step 8 retro.

## Profile override

To override the auto-default profile for one feature, set in the spec front-matter:

```yaml
security_profile_override: SecHardened # or SecStandard / SecHigh-Assurance
security_profile_override_reason: "Risky public-endpoint change — enforce TO1 despite SecBaseline default"
```

Lowering below `SecBaseline` (e.g., disabling T4 secret scan for one feature) requires an explicit `.claude/state/security-profile-unlock-<slug>` acknowledgement file — the same unlock mechanism used by scope-lock in Step 2.
