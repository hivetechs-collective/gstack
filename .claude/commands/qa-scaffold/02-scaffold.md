# Stage 02 — Render scaffold templates into the repo

**Prerequisites:** Stage 01 completed; `.claude/qa-profile.json` has `stage_status["02-scaffold"] == "pending"` and `profile`, `test_dir`, `base_url`, `framework` populated.
**Purpose:** render the 5 scaffold templates from `.claude/commands/qa-scaffold/templates/` into their destination paths in the target repo. Idempotent. Never silently overwrite.
**Scope exclusion:** the ESLint rule is rendered by **Stage 03**, not here. This stage stays focused on configuration, test scaffold, and documentation.

---

## 2.1 Templates consumed by this stage

| Template source                              | Default destination                  | Placeholders resolved                                           |
| -------------------------------------------- | ------------------------------------ | --------------------------------------------------------------- |
| `templates/playwright.config.ts.template`    | `playwright.config.ts`               | `{{BASE_URL}}`, `{{TEST_DIR}}`, `{{REPORT_DIR}}`, `{{PROFILE}}` |
| `templates/page-object.stub.ts.template`     | `{{TEST_DIR}}/pages/example.page.ts` | `{{FEATURE}}`, `{{FeatureClass}}` — see 2.3                     |
| `templates/helpers.ts.template`              | `{{TEST_DIR}}/helpers.ts`            | none                                                            |
| `templates/locator-hierarchy.md.template`    | `docs/testing/locator-hierarchy.md`  | none                                                            |
| `templates/anti-pattern-catalog.md.template` | `docs/testing/anti-patterns.md`      | none                                                            |

The ESLint rule template (`templates/eslint-testid-rule.js.template`) is handled by Stage 03.

---

## 2.2 Placeholder resolution

Read `.claude/qa-profile.json` and `.claude/state/qa-scaffold-detection.json`:

| Placeholder        | Value source                                                 |
| ------------------ | ------------------------------------------------------------ |
| `{{BASE_URL}}`     | `base_url` in qa-profile.json                                |
| `{{TEST_DIR}}`     | `test_dir` in qa-profile.json (e.g., `tests/e2e`)            |
| `{{REPORT_DIR}}`   | `{{TEST_DIR}}/playwright-report` unless overridden           |
| `{{PROFILE}}`      | `profile` in qa-profile.json (`light` / `standard` / `full`) |
| `{{FEATURE}}`      | `example` for the stub — user edits on first real feature    |
| `{{FeatureClass}}` | `Example` — PascalCase form of `{{FEATURE}}`                 |

Escape all placeholder values for the destination file type: paths stay quoted in TS config; markdown gets raw values. If a placeholder is missing, exit 2 with a clear diagnostic — do not render a file with unresolved `{{` tokens.

---

## 2.3 Page-object stub rendering

The stub is a starting point, not a completed page object. Render:

- Class named `{{FeatureClass}}Page` (default `ExamplePage`).
- Three locators: `submitButton`, `cancelButton`, `pageHeading` — using the exact patterns from `shared/locator-hierarchy.md`.
- Header comment lists the rules (locator hierarchy, page-object-only, data-testid mandatory) so the file doubles as a teaching artifact.

After rendering, print the next-step hint:

```
Rendered page-object stub at {{TEST_DIR}}/pages/example.page.ts.
Rename to your actual feature (e.g., submit-claim.page.ts) on first real feature.
```

The stub is intentionally kept — deleting it on first real feature is the user's call.

---

## 2.4 Idempotence & backup protocol (CRITICAL)

For every destination path, follow this exact sequence:

1. **Compute the rendered content** (template + resolved placeholders).
2. **If destination does not exist** → write it. Done.
3. **If destination exists** → read it.
   - **Byte-identical to rendered content** → no-op. Log "unchanged: <path>".
   - **Differs** → do NOT overwrite blindly. Create a backup first:
     - Backup path: `<destination>.backup-<UTC-timestamp>` (e.g., `playwright.config.ts.backup-20260420T235900Z`).
     - Copy the existing file to the backup path.
     - Compute a diff between existing and rendered content; print the diff.
     - Prompt: "Overwrite <path>? [y/N/keep]"
       - `y` → overwrite with rendered content; log "backed up and replaced: <path>".
       - `N` (default) → abort the whole stage. Leave all prior files untouched. Exit 2 with the backup path.
       - `keep` → keep existing file unchanged, log "kept existing: <path>". Continue to next template.

**Never**: overwrite a file without a backup; skip a file silently; prompt user per-template in a way that lets a wrong answer corrupt subsequent templates.

**Atomicity note:** if the user answers `N` mid-way, already-written NEW files stay on disk (they had no prior content to destroy). Already-backed-up-and-overwritten files are rolled back using the backup. This is the contract the README's idempotence statement refers to.

---

## 2.5 `package.json` edits

Stage 02 adds exactly three things to `package.json`, each conditionally:

### Dev dependencies

```json
{
  "devDependencies": {
    "@playwright/test": "^1.54.0",
    "@types/node": "^22.0.0"
  }
}
```

If `@playwright/test` already appears at any version → leave it; record "existing Playwright version preserved" in the run log.

### Scripts

```json
{
  "scripts": {
    "test:e2e": "playwright test",
    "test:e2e:ui": "playwright test --ui",
    "test:e2e:report": "playwright show-report"
  }
}
```

If any of these script keys already exist with different values → follow the same backup protocol as files: diff, prompt, default to NOT overwrite.

### Install step

Stage 02 does NOT auto-run `npm install` / `pnpm install`. It prints the command the user should run:

```
Scaffold complete. Next:
  $ <detected-package-manager> install
  $ npx playwright install chromium firefox webkit
```

Detected package manager: look for `pnpm-lock.yaml` (→ `pnpm`), `yarn.lock` (→ `yarn`), `bun.lockb` (→ `bun`), else `npm`.

---

## 2.6 `.gitignore` edits

Append (if not already present):

```
# Playwright
/playwright-report/
/test-results/
/{{TEST_DIR}}/playwright-report/
/{{TEST_DIR}}/test-results/
```

Resolve `{{TEST_DIR}}` before writing. If `.gitignore` doesn't exist, create it with just these lines — don't add other conventional entries. Stage 02's job is QA scaffold, not general-purpose gitignore management.

---

## 2.7 Placeholder smoke spec

Write a **minimal placeholder spec** to `{{TEST_DIR}}/smoke.spec.ts`:

```ts
import { test, expect } from "@playwright/test";

test("scaffold placeholder — replace on first real feature", async ({
  page,
}) => {
  // This spec exists so Stage 04 has something to run. Delete on first real feature.
  await page.goto("/");
  await expect(page).toHaveURL(/.*/);
});
```

This spec passes against any running server (the URL regex matches anything) — its only job is to let Stage 04 confirm the toolchain works end-to-end. If a `smoke.spec.ts` already exists, apply the backup protocol from 2.4.

---

## 2.8 Profile-dependent adjustments

| Profile       | Stage 02 adjustment                                                                                                                                           |
| ------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Tier-Light    | Skip the `playwright-report` HTML output; use `reporter: 'list'` in config to keep it lean.                                                                   |
| Tier-Standard | Default: `reporter: [['list'], ['html']]`.                                                                                                                    |
| Tier-Full     | Add `['json', { outputFile: 'test-results/results.json' }]` for CI consumption + BDD hint comment in the config pointing at a future Cucumber.js integration. |

Resolution: read `profile` from qa-profile.json and render the correct reporter block into `playwright.config.ts` via the `{{PROFILE}}` placeholder switch handled in the template.

---

## 2.9 Update qa-profile.json

On successful completion:

```json
{
  "stage_status": {
    "02-scaffold": "ok"
  },
  "scaffold_manifest": {
    "rendered": [
      "playwright.config.ts",
      "tests/e2e/pages/example.page.ts",
      "tests/e2e/helpers.ts",
      "tests/e2e/smoke.spec.ts",
      "docs/testing/locator-hierarchy.md",
      "docs/testing/anti-patterns.md"
    ],
    "backups": ["playwright.config.ts.backup-20260420T235900Z"],
    "unchanged": [],
    "package_json_touched": true,
    "gitignore_touched": true
  }
}
```

The manifest lets Stage 04 know exactly which files to verify, and lets downstream users audit what was scaffolded vs. preserved.

---

## 2.10 Exit conditions

| Condition                               | Exit                                                                                    |
| --------------------------------------- | --------------------------------------------------------------------------------------- |
| All templates rendered or no-oped       | Stage 02 marked ok; proceed to Stage 03.                                                |
| User declines any overwrite             | Exit 2. Manifest records files written so far; re-invoke resumes where left off.        |
| Template file missing from `templates/` | Exit 2 with "Template missing: <name>. Re-sync claude-pattern." — never render partial. |
| Placeholder unresolved                  | Exit 2 with the unresolved placeholder name.                                            |
