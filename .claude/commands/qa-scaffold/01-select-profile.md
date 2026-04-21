# Stage 01 — Select QA profile (Light / Standard / Full)

**Prerequisites:** Stage 00 completed; `.claude/state/qa-scaffold-detection.json` exists.
**Purpose:** pick the QA profile that governs tier enforcement in downstream `/plan-w-team` runs. Profile drives which tiers are required in the Evidence Ledger.
**Outcome:** writes `.claude/qa-profile.json` — authoritative, user-overridable, read by `/plan-w-team`.

---

## 1.1 Profile options

From `shared/qa-tiers.md` (canonical source):

| Profile           | Trigger                     | Tiers enforced               | BDD?                    |
| ----------------- | --------------------------- | ---------------------------- | ----------------------- |
| **Tier-Light**    | < 5k LOC, solo contributor  | T1 smoke + T3 regression     | No (vanilla Playwright) |
| **Tier-Standard** | 5k–25k LOC OR multi-contrib | T1 + T2 (10x stability) + T3 | Optional                |
| **Tier-Full**     | > 25k LOC OR shared library | T1–T5 + TO2                  | Yes (Cucumber.js)       |

The qa-tiers file is the source of truth. If the table above drifts from `shared/qa-tiers.md`, re-sync before continuing.

---

## 1.2 Auto-selection heuristic

The stage computes two signals and picks the more-enforcing profile if they disagree.

### Signal A: Lines of code

Count non-blank, non-comment lines in source files — respecting the same exclusion list from Stage 00:

```
Globs: **/*.{ts,tsx,js,jsx,vue,svelte,css,scss}
Exclude: **/node_modules/**, **/dist/**, **/build/**, **/.next/**,
         **/out/**, **/coverage/**, **/*.stories.{ts,tsx,js,jsx},
         **/*.d.ts
```

Use `cloc` if available; otherwise fall back to a wc-based count filtered by the extension glob. Record the number verbatim — no rounding.

| LOC            | Suggests      |
| -------------- | ------------- |
| < 5,000        | Tier-Light    |
| 5,000 – 25,000 | Tier-Standard |
| > 25,000       | Tier-Full     |

### Signal B: Contributor count

Run `git shortlog -sne --all --since="1 year ago" | wc -l`. Treat as zero for repos without a year of history (brand-new repos → 1 contributor counted).

| Contributors | Suggests      |
| ------------ | ------------- |
| 1 (solo)     | Tier-Light    |
| 2–5          | Tier-Standard |
| 6+           | Tier-Full     |

### Signal C: Shared-library heuristic

If `package.json` has `"main"` or `"exports"` pointing at a `dist/` path AND no `"private": true` → this is a publishable library. Force **Tier-Full** regardless of LOC/contributors. Rationale: a single consumer regression is a downstream blast radius.

### Combining signals

```
if shared-library  → Tier-Full
else if max(LOC_signal, contributor_signal) is Tier-Full     → Tier-Full
else if max(LOC_signal, contributor_signal) is Tier-Standard → Tier-Standard
else                                                          → Tier-Light
```

The MORE enforcing profile wins. Drift toward discipline, not laxness.

---

## 1.3 User override

Print the suggestion with the reasoning:

```
Suggested profile: Tier-Standard
  Reason: 12,400 LOC (Tier-Standard) + 4 contributors (Tier-Standard)
  Tiers enforced: T1 smoke + T2 10x stability + T3 regression

Accept suggestion? [Y/n/light/standard/full]
```

| Response   | Outcome                                           |
| ---------- | ------------------------------------------------- |
| `Y` or ↵   | Use suggested profile.                            |
| `n`        | Re-prompt with `light / standard / full` options. |
| `light`    | Tier-Light (record as user override).             |
| `standard` | Tier-Standard (record as user override).          |
| `full`     | Tier-Full (record as user override).              |

**Downgrade warning:** if the user picks a LESS enforcing profile than suggested, the stage prints "Downgrading from <suggested> to <chosen>. This is recorded in qa-profile.json with a timestamp." and requires a second confirmation. This friction is intentional — it makes a conscious choice auditable.

---

## 1.4 Per-feature override hook

`.claude/qa-profile.json` also declares the key that `/plan-w-team` will check in feature spec front-matter:

```yaml
# In a spec's front-matter
qa_profile_override: "full" # bump a specific feature to Tier-Full
```

The skill does not enforce this at scaffold time — it only records that the override key is recognized. `/plan-w-team` Step 1 reads the front-matter; Step 2 adjusts task pairing accordingly.

---

## 1.5 Output artifact

Write `.claude/qa-profile.json`:

```json
{
  "profile": "standard",
  "selected_at": "2026-04-20T23:58:30Z",
  "selected_by": "auto|user",
  "override_history": [],
  "signals": {
    "loc": 12400,
    "loc_signal": "standard",
    "contributors_last_year": 4,
    "contributor_signal": "standard",
    "shared_library": false
  },
  "tiers_enforced": ["T1", "T2", "T3"],
  "bdd_enabled": false,
  "test_dir": "tests/e2e",
  "base_url": "http://localhost:3000",
  "framework": "next",
  "stage_status": {
    "00-detect": "ok",
    "01-select-profile": "ok",
    "02-scaffold": "pending",
    "03-enforce": "pending",
    "04-verify": "pending"
  }
}
```

Downstream:

- **Stage 02** reads `profile`, `tiers_enforced`, `test_dir`, `base_url`, `framework`.
- **Stage 03** reads `framework` for the ESLint parser choice.
- **Stage 04** reads the whole file to confirm all stages transition to `ok`.
- **`/plan-w-team`** reads `profile`, `tiers_enforced`, `bdd_enabled`, `test_dir`.

If the file already exists from a prior run:

- Preserve `override_history`.
- Append the previous `profile` + `selected_at` to `override_history` if the new selection differs.
- Reset `stage_status` for stages 02/03/04 to `pending` so a re-run actually re-scaffolds.

---

## 1.6 Exit conditions

| Condition                                          | Exit                                                                                       |
| -------------------------------------------------- | ------------------------------------------------------------------------------------------ |
| Profile written and signals recorded               | Proceed to Stage 02.                                                                       |
| User aborts at prompt                              | Exit 2. Detection JSON preserved; re-invoke resumes at Stage 01.                           |
| LOC count fails (no source files after exclusions) | Exit 2 with "Unexpected: Stage 00 passed but LOC count is zero. Check the exclusion list." |
