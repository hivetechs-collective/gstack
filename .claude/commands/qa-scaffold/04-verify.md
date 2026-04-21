# Stage 04 — End-to-end smoke verification

**Prerequisites:** Stages 00–03 completed; `.claude/qa-profile.json` has all three of `02-scaffold`, `03-enforce`, and `04-verify` present, with `04-verify == "pending"`.
**Purpose:** confirm the scaffold actually works. No file rendering; Stage 04 is read-only against the scaffolded repo except for its own status write-back.
**Outcome:** `.claude/qa-profile.json` flips `04-verify` to `ok` (full success) or `warn` (scaffold usable but deferred items remain). Only `ok` allows `/qa-scaffold` to print "done."

---

## 4.1 Pre-verification manifest read

Read `.claude/qa-profile.json` and verify:

- `02-scaffold` status is `ok` (not `partial`, not `pending`).
- `03-enforce` status is `ok` or `partial` (partial is allowed here — manual steps don't block verification).
- `scaffold_manifest.rendered` lists the files Stage 04 expects to find.

If any prerequisite is not met → exit 2 with "Stage <N> incomplete. Re-run `/qa-scaffold`." Stage 04 does not attempt recovery.

---

## 4.2 File presence checks (hard)

For every path in `scaffold_manifest.rendered`, assert existence and non-emptiness:

```
playwright.config.ts                                 # > 0 bytes
tests/e2e/helpers.ts                                 # > 0 bytes
tests/e2e/pages/example.page.ts                      # > 0 bytes
tests/e2e/smoke.spec.ts                              # > 0 bytes
docs/testing/locator-hierarchy.md                    # > 0 bytes
docs/testing/anti-patterns.md                        # > 0 bytes
eslint-rules/require-data-testid.js                  # > 0 bytes (from Stage 03)
```

Missing or empty file → hard fail. Exit 2 with the missing path list.

---

## 4.3 Dependency install check

Check whether Playwright is actually installed:

```bash
# Match the detected package manager from Stage 02 §2.5
<pkg-manager> list @playwright/test 2>/dev/null | grep -q "@playwright/test"
```

If not installed → print the install command and mark `04-verify` status `pending` with reason `deps_not_installed`. Do NOT run the install ourselves; the user runs package-manager commands.

If installed but browsers missing:

```bash
npx playwright install --dry-run chromium firefox webkit
```

If any browser is reported missing → print `npx playwright install chromium firefox webkit` and mark `04-verify` `pending` with reason `browsers_not_installed`.

Both situations are recoverable — the user runs the command, then re-invokes `/qa-scaffold` (Stages 00-03 no-op on clean state; Stage 04 re-runs). No data loss.

---

## 4.4 Playwright config sanity check

Parse the rendered `playwright.config.ts`:

```bash
node -e "const c = require('./playwright.config.ts'); console.log(JSON.stringify(c.default || c, null, 2))" 2>/dev/null
```

Assert the parsed config contains:

- `testIdAttribute === 'data-testid'` (the whole point of this scaffold — must not drift)
- `testDir` matching `{{TEST_DIR}}` from qa-profile.json
- `use.baseURL` matching `{{BASE_URL}}` from qa-profile.json
- At least one entry in `projects` with `name: 'chromium'`

Any assertion failure → exit 2 with the config diff. The scaffold rendered wrong content and needs a re-scaffold.

---

## 4.5 Lint smoke — positive case

Create a temporary fixture **outside the repo's normal test paths** (e.g., `/tmp/qa-scaffold-fixture-<pid>/sample.tsx`) and lint it against the repo's ESLint config via `npx eslint --resolve-plugins-relative-to <repo>`:

```tsx
// Should PASS — button has data-testid with correct shape
export const A = () => <button data-testid="demo-submit-button">Submit</button>;
```

Expected: 0 problems. If ESLint reports anything on this fixture → the rule is over-reporting or mis-configured. Exit 2 with the eslint output.

## 4.6 Lint smoke — negative cases

Same fixture approach, three files this time:

```tsx
// Case 1: SHOULD FAIL — missing data-testid
export const B = () => <button>Submit</button>;
```

```tsx
// Case 2: SHOULD FAIL — wrong attribute (data-test instead of data-testid)
export const C = () => <button data-test="submit-btn">Submit</button>;
```

```tsx
// Case 3: SHOULD FAIL — malformed testid (not kebab, no <element>-<action>)
export const D = () => <button data-testid="SubmitBtn">Submit</button>;
```

Expected: ESLint reports exactly one error per file, with the `local/require-data-testid` rule id. Messages should be the ones from the rule template (`missing`, `wrongAttr`, `malformed`).

If ESLint reports fewer than 3 failures → the rule is under-reporting. Exit 2 with the full eslint output.
If ESLint reports MORE than one error per file from this rule → the rule is over-reporting. Exit 2 likewise.

For Vue/Svelte/Angular projects where Stage 03 required manual paste-in, Stage 04 still runs positive + negative smoke using framework-native fixtures. If the manual step was skipped, the negative smoke will under-report — stage exits 2 with "Manual step from Stage 03 is not yet applied."

---

## 4.7 Playwright smoke run

Run the placeholder spec rendered by Stage 02:

```bash
npx playwright test {{TEST_DIR}}/smoke.spec.ts --project=chromium --reporter=list
```

Notes:

- Only chromium is required for smoke; firefox/webkit add 30-60s with no additional signal at this stage.
- If the target app's dev server is **not running** the spec will fail on `page.goto('/')`. Detect the connection error specifically and print: "Dev server not running at {{BASE_URL}}. Start your dev server and re-invoke `/qa-scaffold` to finish verification." — then mark `04-verify` status `pending` with reason `dev_server_not_running`. This is NOT a scaffold failure.
- If Playwright itself reports a runner error (e.g., config syntax error) → exit 2 with the output.

On success → Stage 04 has proven the toolchain works end-to-end.

---

## 4.8 Plan-w-team interoperability check

Read the three shared files Stage 01-03 depend on:

- `.claude/commands/plan-w-team/shared/qa-tiers.md`
- `.claude/commands/plan-w-team/shared/ui-tdd-enforcement.md`
- `.claude/commands/plan-w-team/shared/locator-hierarchy.md`

If any of the three is missing → the consuming repo is pulling from a claude-pattern sync that predates the QA framework. Print: "Your claude-pattern sync is out of date. Re-sync via scripts/sync-all-repos.sh then re-invoke `/qa-scaffold`." Exit 2.

If all three are present but the per-repo copy at `docs/testing/locator-hierarchy.md` has diverged from the canonical source → warn (not error). Print the diff and recommend re-running Stage 02 in refresh mode. Mark `04-verify` `ok` with `warnings: ["locator-hierarchy per-repo copy diverged from canonical"]`.

---

## 4.9 Update qa-profile.json (final)

```json
{
  "stage_status": {
    "00-detect": "ok",
    "01-select-profile": "ok",
    "02-scaffold": "ok",
    "03-enforce": "ok",
    "04-verify": "ok"
  },
  "verify_manifest": {
    "verified_at": "2026-04-21T00:04:12Z",
    "lint_positive": "pass",
    "lint_negative_count": 3,
    "playwright_smoke": "pass",
    "playwright_browsers_installed": ["chromium", "firefox", "webkit"],
    "shared_files_present": true,
    "warnings": []
  }
}
```

If any sub-check failed with an unrecoverable error → do NOT write `ok`. Leave stage as `pending` (for recoverable issues) or `failed` (for unrecoverable ones), with a `reason` field.

---

## 4.10 Cleanup

On `ok`:

- Delete `.claude/state/qa-scaffold-detection.json` (scratch state; qa-profile.json is now authoritative).
- Delete temporary ESLint fixture directory created in §4.5-4.6.
- Print the "done" summary (see 4.11).

On anything other than `ok`:

- Leave scratch state so a re-invocation resumes without re-scanning.
- Print the specific recovery command for the failure.

---

## 4.11 Done summary

On success:

```
✅ /qa-scaffold complete.

Profile:   Tier-Standard
Tiers:     T1, T2, T3
Framework: Next.js (React/JSX)
Tests:     tests/e2e/ (run: npm run test:e2e)
Lint:      eslint-rules/require-data-testid.js (rule: local/require-data-testid)
Docs:      docs/testing/locator-hierarchy.md
           docs/testing/anti-patterns.md

Next:
1. Commit the scaffold: git add . && git commit -m "chore(qa): scaffold Playwright + data-testid enforcement"
2. Run /plan-w-team for your next UI feature — UI-TDD enforcement activates automatically.
3. On a CI run, keep an eye on the Tier Evidence Ledger in the PR description.
```

The summary is shown to the user once. After this, `/qa-scaffold` exits 0 and `/plan-w-team` takes over for subsequent feature-level work.

---

## 4.12 Exit conditions

| Condition                              | Exit                                                           |
| -------------------------------------- | -------------------------------------------------------------- |
| All verifications pass                 | Exit 0; qa-profile.json marked fully `ok`.                     |
| Deps/browsers/dev-server not installed | Exit 0 with `pending` status + recovery command; no data loss. |
| Rule over/under-reports                | Exit 2; stage `failed`; user inspects rendered rule file.      |
| Shared files missing                   | Exit 2; prompt to re-sync claude-pattern.                      |
| Playwright runner error                | Exit 2 with full output; stage `failed`.                       |
