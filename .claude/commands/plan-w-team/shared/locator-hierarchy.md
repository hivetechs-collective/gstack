# Locator Hierarchy

Framework-agnostic priority order for element selection in Playwright (and any compatible E2E library). Single source of truth — cite this file, don't re-derive the rules.

**Consumed by:** builders authoring page objects, reviewers in `/plan-w-team/04-fix-first-review.md` Pass 1 CRITICAL, `/qa-scaffold/templates/locator-hierarchy.md.template` (per-repo copy), `.claude/agents/team/builder.md` UI Rules section.

---

## Priority order

```
1. data-testid                     ← primary, ESLint-enforced on interactive elements
2. getByRole('role', { name })     ← accessibility-first fallback
3. getByText('exact text')         ← content-stable elements only
4. CSS selector                    ← last resort; requires inline comment explaining why
```

Higher = preferred. Reach lower only when the higher option genuinely cannot satisfy the test (not when it's merely inconvenient).

### Why this order

| Layer         | Why it's here                                                                    | When to drop a layer                                                   |
| ------------- | -------------------------------------------------------------------------------- | ---------------------------------------------------------------------- |
| `data-testid` | Author-controlled, refactor-stable, no i18n coupling, zero ambiguity             | Only when the element is literally non-interactive (static text)       |
| `getByRole`   | Reinforces accessibility; stable across visual redesigns that preserve semantics | When role is ambiguous (custom components without ARIA) or unavailable |
| `getByText`   | Good for prose/banner elements where content IS the identity                     | When text is i18n'd or dynamic                                         |
| CSS selector  | Escape hatch for third-party widgets, shadow DOM, hard-to-attr elements          | Preferred only with inline comment; never without                      |

---

## Usage rule: page objects only

All locators live inside page objects. **Inline locators in step definitions or specs are a Pass 1 CRITICAL violation.**

```ts
// ✅ correct — locator in page object
class ClaimsPage {
  readonly submitClaimButton = this.page.getByTestId("submit-claim-button");

  async submit() {
    await this.submitClaimButton.click();
  }
}

// In spec / step definition:
await claimsPage.submit();
```

```ts
// ❌ wrong — inline locator in spec
test("submits claim", async ({ page }) => {
  await page.getByTestId("submit-claim-button").click(); // Pass 1 CRITICAL violation
});
```

The page-object rule is non-negotiable because:

- It keeps locators in one place per feature; a UI rename touches one file, not N.
- It makes tests read like user stories, not DOM queries.
- It makes the `data-testid` convention auditable — grepping `getByTestId` in test files instantly flags inline violations.

---

## Decision examples

| Element                                       | Correct locator                                                                           | Why                                       |
| --------------------------------------------- | ----------------------------------------------------------------------------------------- | ----------------------------------------- |
| `<button data-testid="submit-claim-button">`  | `page.getByTestId('submit-claim-button')`                                                 | Primary — always preferred                |
| `<h1>Welcome back, {user}</h1>`               | `page.getByRole('heading', { level: 1 })`                                                 | No testid needed on prose; role is stable |
| `<p>Lost your password? Contact support.</p>` | `page.getByText('Lost your password?', { exact: false })`                                 | Content IS the identity; non-interactive  |
| Third-party date picker with no attrs         | `page.locator('.mui-datepicker-input')` **// third-party widget; no attr hook available** | Last resort with inline comment           |
| `<a href="/settings">Settings</a>`            | `page.getByRole('link', { name: 'Settings' })`                                            | Links: role is preferred unless i18n'd    |

If the link text `Settings` is translated (`Paramètres`, `Einstellungen`), add `data-testid="settings-nav-link"` and switch to `getByTestId`.

---

## Framework-specific notes

Locators are consumed via Playwright's Locator API regardless of UI framework. The framework only affects _how_ you attach `data-testid`:

| Framework | Attribute syntax                                      |
| --------- | ----------------------------------------------------- |
| React/JSX | `<button data-testid="submit-claim-button">`          |
| Vue       | `<button :data-testid="'submit-claim-button'">`       |
| Svelte    | `<button data-testid="submit-claim-button">`          |
| Angular   | `<button [attr.data-testid]="'submit-claim-button'">` |
| Solid     | `<button data-testid="submit-claim-button">`          |

`data-testid` renders as a plain HTML attribute in all five frameworks — the locator call is identical downstream.

---

## CSS-selector escape hatch

When CSS is unavoidable, the page object must include an inline comment justifying it. The comment is machine-readable for Pass 1 review:

```ts
// Accepted forms (any of these satisfies the CRITICAL gate):
//   third-party widget; no attr hook available
//   shadow-DOM boundary; data-testid not observable from light DOM
//   legacy component; scheduled for refactor in <ticket-ref>
//   framework injects class we cannot override (e.g., Next.js <Link> underlying <a>)
readonly datePicker = this.page.locator('.mui-datepicker-input'); // third-party widget; no attr hook available
```

Reviewers reject CSS selectors without one of these justifications.

---

## Do-not-use list

These selectors are **never acceptable** in page objects:

| Pattern                                  | Why                                             |
| ---------------------------------------- | ----------------------------------------------- |
| `nth-child`, `nth-of-type`               | Breaks on any sibling reorder                   |
| `eq(n)`, `.nth(n)`                       | Same — index-based                              |
| XPath (`//button[...]`)                  | Brittle, unreadable, Playwright has better APIs |
| `.btn`, `.btn-primary` (utility class)   | Styling classes change on theme updates         |
| Generated IDs (`#__next-route-0_123`)    | Hash regenerates on build                       |
| `text=` without exact match for controls | Matches substrings; accidental collisions       |

Any of these in code triggers a Pass 1 CRITICAL review failure.

---

## Adding `data-testid` during implementation

When you need a `data-testid` that doesn't exist yet (paired tests `N.a` assert on `submit-claim-button`, but the button has no attr):

1. Do **not** inline the attribute during a test-only commit — add it in the implementation task (`N.b`).
2. Follow the naming convention from `shared/ui-tdd-enforcement.md`: `<feature>-<element>-<action>`.
3. Place the attribute on the outermost interactive element, not on a wrapper div.
4. For lists/collections, add `data-testid` on the list container AND on each row: `claims-list`, `claims-list-row`, `claims-list-row-checkbox`.

The ESLint rule from `/qa-scaffold/03-enforce.md` will flag a missing attribute at lint time; this hierarchy is what reviewers compare against when the lint rule is silent (e.g., new framework not covered, third-party components).
