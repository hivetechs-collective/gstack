# Stage 00 — Detect UI framework and existing test setup

**Invocation:** runs first in the `/qa-scaffold` pipeline.
**Purpose:** decide whether this repo is a valid target for UI QA scaffolding, and if so, which framework it uses.
**Exit behavior:** writes findings to a scratch file for Stage 01; aborts cleanly if no UI detected.

---

## 0.1 UI file detection

Glob pattern:

```
**/*.{tsx,jsx,vue,svelte}
```

Plus Angular component signatures (since Angular uses `.ts`, not a unique extension):

```
# Grep for Angular component decorators in *.ts files
@Component\s*\(
```

**Exclusion list** (hard-coded; prevents false positives):

```
**/node_modules/**
**/dist/**
**/build/**
**/.next/**
**/out/**
**/coverage/**
**/docs/**
**/*.mdx
**/storybook/**
**/.storybook/**
**/stories/**
**/*.stories.{tsx,jsx,ts,js}
```

### Decision table

| Finding                          | Outcome                                                                |
| -------------------------------- | ---------------------------------------------------------------------- |
| 0 matching files after exclusion | Abort: "No UI files detected. `/qa-scaffold` is for UI repos." Exit 0. |
| 1–4 matching files               | Warn: "Only N UI files found. Scaffold anyway? (y/n)" — user confirms. |
| 5+ matching files                | Proceed without prompt.                                                |

The 5-file threshold prevents scaffolding a backend repo that happens to have a couple of utility `.tsx` files (e.g., email templates).

---

## 0.2 Framework detection

Read `package.json` `dependencies` and `devDependencies`. First match wins:

| Detected package                      | Framework       | Preferred entrypoint signature             |
| ------------------------------------- | --------------- | ------------------------------------------ |
| `next`                                | `next`          | `app/` or `pages/` dir present             |
| `@remix-run/react`, `@remix-run/node` | `remix`         | `app/root.tsx`                             |
| `@angular/core`                       | `angular`       | `angular.json`                             |
| `vue`, `nuxt`                         | `vue` or `nuxt` | `vite.config.*` + `.vue` files             |
| `svelte`, `@sveltejs/kit`             | `svelte`        | `svelte.config.*`                          |
| `solid-js`, `solid-start`             | `solid`         | `*.tsx` with `solid-js` import             |
| `react` (no Next/Remix)               | `react`         | `vite.config.*` or `craco.config.*` or CRA |

If none of the above match but `.tsx`/`.jsx` files exist:

- Prompt the user: "UI files detected but framework unclear. Specify: `next`, `react`, `vue`, `svelte`, `angular`, `solid`, or `other`."
- `other` still proceeds but Stage 02 renders only the framework-agnostic templates (Playwright config, helpers, docs); page-object stub is skipped with a note.

---

## 0.3 Existing test setup detection

Check for existing configuration files in this order:

1. `playwright.config.{ts,js,mjs,cjs}` → **already scaffolded**
2. `cypress.config.{ts,js,mjs,cjs}` or `cypress.json` → **Cypress present**; scaffold Playwright alongside with a warning (see 0.4)
3. Neither → **greenfield**

### Decision table

| State              | Stage 00 outcome                                                                                                                                                                       |
| ------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Greenfield         | Proceed to Stage 01. Standard pipeline.                                                                                                                                                |
| Already scaffolded | Print summary (profile from `.claude/qa-profile.json` if present). Offer **refresh mode**: re-render only `docs/testing/*.md` and re-run the ESLint rule install. Skip config + stubs. |
| Cypress present    | Warn: "Cypress detected. This scaffold installs Playwright in parallel — not a migration. Recommend archiving Cypress tests after Playwright is green." Continue on confirmation.      |

---

## 0.4 Test directory choice

Scan for an existing convention (in priority order):

1. `tests/e2e/` → use it
2. `e2e/` → use it
3. `test/e2e/` → use it
4. `__tests__/e2e/` → use it
5. None → default to `tests/e2e/`

Record the chosen directory as `{{TEST_DIR}}` — Stage 02 templates consume this placeholder.

---

## 0.5 Base URL hint

Check for dev-server conventions:

| Signal                             | Inferred `{{BASE_URL}}`                      |
| ---------------------------------- | -------------------------------------------- |
| `next`, `remix` in deps            | `http://localhost:3000`                      |
| `vue` + `vite` in deps             | `http://localhost:5173`                      |
| `svelte` + `@sveltejs/kit` in deps | `http://localhost:5173`                      |
| `angular` in deps                  | `http://localhost:4200`                      |
| `solid-start` in deps              | `http://localhost:3000`                      |
| `vite` only                        | `http://localhost:5173`                      |
| Unknown                            | Prompt user; default `http://localhost:3000` |

---

## 0.6 Artifact for downstream stages

Write `.claude/state/qa-scaffold-detection.json` with the findings. This file is **scratch state** — Stage 04 deletes it after a successful run; a failed run leaves it for the next invocation.

```json
{
  "detected_at": "2026-04-20T23:58:00Z",
  "framework": "next",
  "ui_file_count": 34,
  "existing_test_setup": "none",
  "test_dir": "tests/e2e",
  "base_url": "http://localhost:3000",
  "already_scaffolded": false,
  "cypress_present": false,
  "notes": []
}
```

Stage 01 reads this file for profile heuristics. Stage 02 reads it for placeholder resolution. Stage 03 reads it to pick the correct ESLint parser.

---

## 0.7 Exit conditions

| Condition                                       | Exit                                                                                     |
| ----------------------------------------------- | ---------------------------------------------------------------------------------------- |
| No UI detected                                  | Exit 0 with clean abort message.                                                         |
| Monorepo (multiple `package.json` with UI deps) | Exit 2 with "Monorepo support deferred in v1; run per-package." Print detected packages. |
| Framework prompt declined                       | Exit 2 with "User declined framework input."                                             |
| All checks pass                                 | Write detection JSON; proceed to Stage 01.                                               |
