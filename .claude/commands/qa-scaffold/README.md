# `/qa-scaffold` — One-Time QA Setup for UI Repos

**Purpose:** Scaffold Playwright + page objects + ESLint `data-testid` enforcement into any UI repo that will later consume `/plan-w-team`. This is a **one-time per-repo setup** command, not a lifecycle activity.

**Why separate from `/plan-w-team`:** Setup happens once; per-feature enforcement happens on every run. Mixing them would force every `/plan-w-team` execution to re-check scaffold state. `/plan-w-team` Step 0 now surfaces this skill when it detects UI code without Playwright config — the bridge is suggestion-based, not coupled.

---

## Invocation

```
/qa-scaffold
```

No arguments. Stages run sequentially; a failed stage halts the pipeline and prints the fix. Re-invoking after a fix resumes cleanly (stages are idempotent).

---

## Tool Permissions

All tools used are covered by the base allow-list in `.claude/settings.json` — no per-project configuration needed. See [`.claude/docs/SKILL_PERMISSION_CONVENTION.md`](../../docs/SKILL_PERMISSION_CONVENTION.md) for the convention.

| Tool    | Use                                                                                  |
| ------- | ------------------------------------------------------------------------------------ |
| `Read`  | Inspect `package.json`, existing framework/test config, templates                    |
| `Write` | Emit `.claude/qa-profile.json`, Playwright config, page objects, ESLint rule         |
| `Edit`  | Register custom ESLint rule in repo's ESLint config (backup-first)                   |
| `Glob`  | Count `.tsx` / `.vue` / `.svelte` files for profile heuristic                        |
| `Grep`  | Detect existing Playwright/Cypress installs, scan for anti-patterns                  |
| `Bash`  | `mkdir -p`, `npx playwright install`, `pnpm add -D`, `npx playwright test` for smoke |

**State & output paths touched:**

- `.claude/qa-profile.json` — tier selection (light / standard / full) + override hooks
- `.claude/state/qa-scaffold-*.json` — stage outputs for resumable runs
- `<test_dir>/**` — Playwright config, helpers, page objects, first example spec
- `eslint-rules/require-data-testid.js` — custom lint rule

---

## Stage pipeline

| Stage                  | Purpose                                                                                                                               |
| ---------------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| `00-detect.md`         | Detect UI framework (Next/React/Vue/Svelte/Angular/Solid), existing test setup (Playwright/Cypress/none). Abort if no UI detected.    |
| `01-select-profile.md` | Pick Tier-Light / Tier-Standard / Tier-Full from LOC + contributor heuristic. Store in `.claude/qa-profile.json`. User-overridable.   |
| `02-scaffold.md`       | Render `templates/` into repo: Playwright config, page objects dir, helpers, locator hierarchy doc, anti-pattern catalog. Idempotent. |
| `03-enforce.md`        | Install the custom ESLint rule (`local/require-data-testid`) + register in the repo's ESLint config.                                  |
| `04-verify.md`         | Smoke test — run `npx playwright test --reporter=list` on a generated placeholder spec; lint with the new rule; confirm green.        |

Each stage file is self-contained and invocable in isolation for debugging. The README describes the sequence; the stages do the work.

---

## Idempotence contract

`/qa-scaffold` is safe to re-run. Stage 02 never overwrites existing files silently:

- **File does not exist**: written from template.
- **File exists and matches template**: no-op.
- **File exists and diverges**: a copy is saved at `<path>.backup-<UTC-timestamp>` before overwrite. The stage logs the backup path and exits with the diff so the user can resolve manually. No silent overwrite — ever.

Stage 03's ESLint config edit uses the same backup-first pattern. Stage 04 is pure verification and makes no changes.

---

## Outputs

After a clean run, the target repo gains:

```
.claude/qa-profile.json                      # tier selection + override hooks
playwright.config.ts                          # locked testIdAttribute = 'data-testid'
{{TEST_DIR}}/                                 # e2e/ or tests/e2e/ — detected at Stage 02
  ├── pages/                                  # page objects (page-object-first rule)
  ├── helpers.ts                              # waitForStable, selectOption, fillVerified, ...
  └── smoke.spec.ts                           # placeholder spec that Stage 04 runs
docs/testing/
  ├── locator-hierarchy.md                    # per-repo copy of canonical hierarchy
  └── anti-patterns.md                        # living catalog (7 starter entries)
eslint-rules/
  └── require-data-testid.js                  # custom rule; registered in ESLint config
```

Paths are the defaults. Stages record the actual paths used in `.claude/qa-profile.json` so downstream automation (including `/plan-w-team`) can find them.

---

## When this skill runs and when it doesn't

| Situation                                             | Outcome                                                                                                  |
| ----------------------------------------------------- | -------------------------------------------------------------------------------------------------------- |
| UI files present, no `playwright.config.*`            | Full pipeline runs.                                                                                      |
| UI files present, Playwright already configured       | Stage 00 reports "already scaffolded"; offers to **refresh** locator hierarchy + anti-pattern docs only. |
| No UI files detected (backend / CLI / docs-only repo) | Stage 00 aborts cleanly. Never scaffolds into a non-UI repo.                                             |
| Monorepo with multiple packages                       | v1 aborts with a clear message: monorepo support deferred. User must run per-package manually.           |

The detection rules and exclusion list live in `00-detect.md`.

---

## Integration with `/plan-w-team`

After `/qa-scaffold` completes successfully, any `/plan-w-team` run in the same repo will:

1. Read `.claude/qa-profile.json` to know which tier enforcement to apply.
2. Load `shared/ui-tdd-enforcement.md` into builder prompts when the feature touches UI files.
3. Pair tasks: `N.a Write Playwright tests` (no deps) → `N.b Implement UI` (blocks on N.a). Tier-Light skips pairing per `shared/qa-tiers.md`.
4. Require a Tier Evidence Ledger in PR descriptions at Step 6.

None of that requires `/qa-scaffold` to run again. This skill sets up the substrate once.

---

## Templates

Stage 02 and 03 render files from `.claude/commands/qa-scaffold/templates/`:

| Template                           | Rendered to (default)                 | Stage |
| ---------------------------------- | ------------------------------------- | ----- |
| `playwright.config.ts.template`    | `playwright.config.ts`                | 02    |
| `page-object.stub.ts.template`     | `{{TEST_DIR}}/pages/example.page.ts`  | 02    |
| `helpers.ts.template`              | `{{TEST_DIR}}/helpers.ts`             | 02    |
| `locator-hierarchy.md.template`    | `docs/testing/locator-hierarchy.md`   | 02    |
| `anti-pattern-catalog.md.template` | `docs/testing/anti-patterns.md`       | 02    |
| `eslint-testid-rule.js.template`   | `eslint-rules/require-data-testid.js` | 03    |

Template placeholders (`{{TEST_DIR}}`, `{{FEATURE}}`, `{{FeatureClass}}`, `{{BASE_URL}}`, `{{PROFILE}}`) are resolved per-repo at render time. See each stage file for the resolution rules.

---

## Failure modes

| Failure                                 | Recovery                                                                                      |
| --------------------------------------- | --------------------------------------------------------------------------------------------- |
| Stage 00 finds UI but framework unknown | User specifies `--framework=<name>`; re-invoke.                                               |
| Stage 02 backup fails (permissions)     | User runs `chmod` on affected paths; re-invoke. No partial state persists.                    |
| Stage 03 can't find ESLint config       | Stage prints exact snippet to add manually; marks 03 incomplete in `.claude/qa-profile.json`. |
| Stage 04 smoke test fails               | Stage dumps the Playwright output; user fixes root cause; re-invoke.                          |

**Never**: silently skip a stage, silently overwrite a file, or mark `.claude/qa-profile.json` complete when a stage failed. The profile file is authoritative for downstream tooling.
