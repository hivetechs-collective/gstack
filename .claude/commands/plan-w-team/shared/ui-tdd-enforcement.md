# UI-TDD Enforcement

Rules loaded into builder prompts when `/plan-w-team` detects UI work. Keep this file short — it is embedded verbatim into prompts and every line costs tokens.

**Activated by:** `/plan-w-team/00-scope-challenge.md` when repo has UI files AND `/qa-scaffold` scaffolding exists.
**Consumed by:** `/plan-w-team/03-execute.md` (builder prompt), `.claude/agents/team/builder.md` (UI Rules section).
**Companion files:** `shared/qa-tiers.md`, `shared/locator-hierarchy.md`.

---

## The four rules

1. **Test-first.** If your task description is paired `N.a Write Playwright tests` + `N.b Implement UI`, task `N.a` must be completed, committed, and failing for the right reason (assertion on missing UI) before any work begins on `N.b`. A green test before implementation is a wrong test.
2. **`data-testid` is mandatory** on every interactive element the test touches. No exceptions. ESLint enforces this; Pass 1 review catches what ESLint misses.
3. **Page-object-first.** All locators live inside page objects. Step definitions, specs, and test bodies call page-object methods — they never call `page.getByTestId()` or `page.locator()` directly.
4. **Locator hierarchy is non-negotiable.** See `shared/locator-hierarchy.md`. Reach for `data-testid` first, `getByRole` second, `getByText` third, CSS last (with an inline comment explaining why).

---

## `data-testid` naming convention

Format: `<feature>-<element>-<action>` — kebab-case, no numbers unless functionally meaningful.

| Example                         | Why                                                    |
| ------------------------------- | ------------------------------------------------------ |
| `submit-claim-button`           | feature=submit-claim, element=button, action=submit    |
| `claims-list-row`               | feature=claims, element=list, action=row (collection)  |
| `login-email-input`             | feature=login, element=email, action=input             |
| `dashboard-refresh-icon-button` | feature=dashboard, element=refresh, action=icon-button |

**Reject:**

- `submit-btn` (not kebab, abbreviated)
- `button-1` (ordinal — unstable across refactors)
- `SubmitClaimButton` (PascalCase — breaks grep and linter)
- `data-test`, `data-qa`, `data-cy`, `data-pgr-id` (use `data-testid`, industry standard)

---

## Paired task protocol

Step 2 emits paired tasks for UI features when profile ≥ Tier-Standard:

```
N.a Write Playwright tests for <feature>   — no dependencies
N.b Implement <feature>                    — blockedBy: [N.a]
```

Builder rules:

- Claim `N.a` first. Write page objects + spec against the intended surface. Run the test; it must fail with a clear locator or assertion miss (not a syntax error, not a timeout-on-empty-page). Commit.
- After `N.a` is marked complete, claim `N.b`. Implement the UI. Re-run `N.a`'s test; it must go green. Commit.
- If `N.a` goes green during `N.b` with zero assertion activity (e.g., the test never found the element but passed anyway), your test is broken — fix the test, not the UI.

**Tier-Light exception:** profile Tier-Light skips pairing. Builder does one task with tests in the same commit. The `data-testid` + locator rules still apply.

**Tier-Standard combined-task exception:** for features < 50 LOC, Step 2 may emit a single combined task. Same rule — tests must land in the same commit as the UI, and the test must reference `data-testid` locators.

---

## Anti-patterns (Pass 1 CRITICAL violations)

These are blocking violations at Step 5 fix-first review:

- Interactive element (`button`, `a`, `input`, `select`, `textarea`, `[role=button]`, `[role=link]`, custom controls) without `data-testid`
- `page.getByTestId(...)` or `page.locator(...)` inside a spec or step definition (must be inside a page object)
- CSS selector used as a locator without an inline comment explaining why `data-testid`/`getByRole` won't work
- Hard-coded text locator on content that is user-facing and translatable (`page.getByText('Submit')` for a button that will be i18n'd)
- `nth-child`, `nth-of-type`, or index-based selectors in page objects
- XPath (`//button[...]`) anywhere in test code
- Test that uses `waitForTimeout(ms)` instead of a deterministic wait (`waitForSelector`, `waitFor`, `expect(...).toBeVisible()`)

---

## Evidence of compliance

When a builder marks a paired task complete, the TaskUpdate metadata must include:

```
{
  "playwright_report": "test-results/<feature>-report/index.html",
  "testids_added": ["submit-claim-button", "claim-form-textarea"],
  "locator_hierarchy": "all-testid"   // or "mixed-testid-role" / "required-css:<reason>"
}
```

The evaluator (Step 4b) reads these fields before issuing a PASS verdict. Missing fields = ESCALATE.

---

## When these rules don't apply

- Tasks scoped as `DOCS`, `CONFIG`, `TESTS`, or `DATABASE` — no UI surface exists to enforce.
- Repos without `/qa-scaffold` run — UI detection flagged the repo, but scaffolding isn't installed. Step 0 suggests `/qa-scaffold`; the UI-TDD rules remain dormant until scaffolding lands.
- Non-user-facing components (Storybook-only primitives, internal dev tooling rendered only in local harnesses). These are still welcome to adopt `data-testid`, but their absence is not a blocking violation.
