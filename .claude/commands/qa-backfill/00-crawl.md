# Stage 00 — Crawl routes in a scaffolded UI repo

**Invocation:** first stage in the `/qa-backfill` pipeline.
**Purpose:** read the repo's `.claude/qa-profile.json` and enumerate the UI routes that need Playwright stub specs.
**Exit behavior:** writes `.claude/state/qa-backfill-routes.json` for Stage 01; aborts cleanly if the repo is not scaffolded.

---

## 0.1 Prerequisites

Read `.claude/qa-profile.json` (created by `/qa-scaffold` Stage 01).

### Decision table

| State                             | Outcome                                                                                                                                                                 |
| --------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| File absent                       | Abort: "No `.claude/qa-profile.json` found. Run `/qa-scaffold` first to install Playwright + the QA profile, then re-run `/qa-backfill`." Exit 0 (clean, not an error). |
| File present but JSON parse fails | Abort with `ProfileParseError`: print the parse error + path, exit 2.                                                                                                   |
| File present + parses             | Extract `framework`, `test_dir`, `base_url`, `profile`. Proceed to 0.2.                                                                                                 |

---

## 0.2 Framework dispatch

Stage 00 supports file-convention frameworks in v1. Code-convention frameworks (React Router, Vue Router, Angular router) drop through to the `unsupported` branch in 0.6.

| `framework` value | Crawl root          | Route file glob                                                         |
| ----------------- | ------------------- | ----------------------------------------------------------------------- |
| `next`            | `app/`              | `app/**/page.{ts,tsx,js,jsx}` (App Router only)                         |
| `sveltekit`       | `src/routes/`       | `src/routes/**/+page.svelte`                                            |
| `svelte` (+ Kit)  | `src/routes/`       | `src/routes/**/+page.svelte` (treat Kit as sveltekit)                   |
| `nuxt`            | `pages/`            | `pages/**/*.vue`                                                        |
| `vue`             | — code-convention   | Emit `unsupported` fallback (Vue Router is code-based).                 |
| `react`           | — code-convention   | Emit `unsupported` fallback (React Router is code-based).               |
| `angular`         | — code-convention   | Emit `unsupported` fallback (Angular router is decorator-based).        |
| `solid`, `remix`  | — not yet supported | Emit `unsupported` fallback (deferred to v2 — see spec Deferred Items). |
| anything else     | —                   | Emit `unsupported` fallback.                                            |

If the dispatched crawl root does not exist on disk (e.g., `framework=next` but no `app/` directory — user might be on Pages Router), raise `RouteDirMissingError`: print which dir is missing, suggest re-running `/qa-scaffold` or manual path override, exit 2.

---

## 0.3 Exclusion lists per framework

Skip these files even when they match the route glob.

### Next.js App Router

| Skip                           | Reason                                 |
| ------------------------------ | -------------------------------------- |
| `layout.{ts,tsx,js,jsx}`       | Layout wrapper, not a navigable route. |
| `loading.{ts,tsx,js,jsx}`      | Loading UI, rendered alongside `page`. |
| `error.{ts,tsx,js,jsx}`        | Error boundary.                        |
| `not-found.{ts,tsx,js,jsx}`    | 404 boundary.                          |
| `template.{ts,tsx,js,jsx}`     | Template wrapper.                      |
| `default.{ts,tsx,js,jsx}`      | Parallel-route fallback.               |
| `global-error.{ts,tsx,js,jsx}` | Global error boundary.                 |
| `route.{ts,js}`                | API route handler, not a page.         |
| Anything under `app/api/**`    | API routes — not UI.                   |

### SvelteKit

| Skip                                                                 | Reason                                            |
| -------------------------------------------------------------------- | ------------------------------------------------- |
| `+layout.svelte`                                                     | Layout wrapper.                                   |
| `+layout.ts`, `+layout.js`, `+layout.server.ts`, `+layout.server.js` | Layout load functions.                            |
| `+error.svelte`                                                      | Error boundary.                                   |
| `+server.{ts,js}`                                                    | API route handler.                                |
| `+page.ts`, `+page.js`, `+page.server.ts`, `+page.server.js`         | Page load functions (paired with `+page.svelte`). |

### Nuxt 3

| Skip                                          | Reason                                            |
| --------------------------------------------- | ------------------------------------------------- |
| Files directly in `layouts/` or `components/` | Not pages.                                        |
| `pages/*.client.vue`, `pages/*.server.vue`    | Rendering-mode variants; pair with the base file. |
| `_middleware.{ts,js}`                         | Middleware; not a page.                           |

Record the count of skipped files as `notes` in the output JSON (AC11).

---

## 0.4 Slug derivation rules

The slug is the filename used for emitted spec + page-object (e.g., `users-id.spec.ts`, `users-id.page.ts`). Keep derivation deterministic and framework-agnostic.

Steps for each route path `p`:

1. Start from the cleaned route path (Next: strip `/page`; SvelteKit: strip `/+page`; Nuxt: strip the `.vue` extension).
2. If `p === "/"` → slug is `index`. Stop.
3. Strip leading `/`.
4. For each path segment:
   - `[id]` → `id`
   - `[[...slug]]` → `slug` (optional catch-all)
   - `[...slug]` → `slug` (catch-all)
   - `[slug]` (parameterized) → segment name inside brackets
   - Literal segment → keep as-is
5. Join segments with `-`.
6. Lowercase, replace any remaining non-kebab characters (e.g., `_`, `.`) with `-`. Collapse consecutive `-`.

### Pinned examples

| Route                     | Slug                 |
| ------------------------- | -------------------- |
| `/`                       | `index`              |
| `/about`                  | `about`              |
| `/users/[id]`             | `users-id`           |
| `/catch/[...slug]`        | `catch-slug`         |
| `/optional/[[...slug]]`   | `optional-slug`      |
| `/admin/users`            | `admin-users`        |
| `/blog/[category]/[post]` | `blog-category-post` |

### Slug collisions

If two different routes derive the same slug (e.g., `/users/[id]` and `/users/:id` in a mixed-convention repo), append a numeric suffix to the second one (`users-id-2`, `users-id-3`, …) and record the collision in `notes`.

---

## 0.5 Dynamic segment annotation

For each emitted route, Stage 01 needs to know whether to render the dynamic or static variant of the templates. Annotate with three fields.

| Field                 | Semantics                                                                                                                                                                            |
| --------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `has_dynamic_segment` | `true` if the route path contains at least one `[segment]`, `[...segment]`, or `[[...segment]]`.                                                                                     |
| `segment_name`        | The first dynamic segment's name (inside brackets, with `...` stripped). E.g., `/users/[id]/posts/[postId]` → `id`.                                                                  |
| `segment_placeholder` | A substitution-friendly string Stage 01 drops into `goto('...')`. Pick by heuristic: `id`/`postId`/`*Id` → `"123"`; `slug`/`...slug` → `"example"`; anything else → `"placeholder"`. |

Multi-dynamic-segment routes get only the first segment pinned in the annotation — the remaining placeholders are left as literal `[name]` inside the route string so the reader sees the TODO.

---

## 0.6 Unsupported-framework fallback

When the framework dispatch lands on an unsupported branch (0.2), write a single fallback entry so Stage 01 still has something to emit (graceful degradation per AC6):

```json
{
  "path": "/routes-unknown",
  "slug": "routes-unknown",
  "source_file": null,
  "has_dynamic_segment": false,
  "segment_name": null,
  "segment_placeholder": null,
  "framework_note": "Code-convention router (React/Vue/Angular) — enumerate routes manually."
}
```

Stage 01 renders this as a single "routes-unknown" stub whose header comment points the user to the deferred-items section of the spec.

Set `framework: "unsupported"` in the output JSON and include a `notes` entry: `"Framework <name> uses code-based routing; emitted 1 fallback stub. See docs/specs/qa-backfill.md Deferred Items."`

---

## 0.7 Path-traversal guard

Route paths and slugs flow into filesystem paths in Stage 01. Reject any input that would escape `{{test_dir}}/backfilled/`:

- After slug derivation, assert the slug matches `^[a-z0-9][a-z0-9-]*$` (kebab-case, must start alphanumeric).
- If a slug contains `..`, `/`, or backslashes after derivation, raise `PathTraversalError`, skip that route, and record it in `notes`.

The input pool is repo-local files, so traversal is unlikely, but emitting a defensive regex keeps the error surface small.

---

## 0.8 Artifact for downstream stages

Write `.claude/state/qa-backfill-routes.json`:

```json
{
  "crawled_at": "2026-04-20T23:58:00Z",
  "framework": "next",
  "test_dir": "tests/e2e",
  "base_url": "http://localhost:3000",
  "profile": "standard",
  "routes": [
    {
      "path": "/",
      "slug": "index",
      "source_file": "app/page.tsx",
      "has_dynamic_segment": false,
      "segment_name": null,
      "segment_placeholder": null
    },
    {
      "path": "/users/[id]",
      "slug": "users-id",
      "source_file": "app/users/[id]/page.tsx",
      "has_dynamic_segment": true,
      "segment_name": "id",
      "segment_placeholder": "123"
    },
    {
      "path": "/catch/[...slug]",
      "slug": "catch-slug",
      "source_file": "app/catch/[...slug]/page.tsx",
      "has_dynamic_segment": true,
      "segment_name": "slug",
      "segment_placeholder": "example"
    }
  ],
  "notes": ["3 layout.tsx files skipped", "2 loading.tsx files skipped"]
}
```

Stage 01 reads this file for template substitution. Stage 02 reads it to build the verification summary.

---

## 0.9 Verbose output

Before exiting, print a human-readable summary:

```
/qa-backfill — Stage 00 (crawl) complete
  Framework:       next
  Test dir:        tests/e2e
  Base URL:        http://localhost:3000
  Routes found:    8 (2 dynamic, 6 static)
  Files skipped:   5 (3 layout.tsx, 2 loading.tsx)
  Output:          .claude/state/qa-backfill-routes.json
  Next:            run Stage 01 to emit stub specs.
```

---

## 0.10 Exit conditions

| Condition                                          | Exit                                                                                 |
| -------------------------------------------------- | ------------------------------------------------------------------------------------ |
| `.claude/qa-profile.json` missing                  | Exit 0, clean abort with `/qa-scaffold` instruction (AC1).                           |
| `.claude/qa-profile.json` unparseable              | Exit 2 with `ProfileParseError`.                                                     |
| Crawl root missing (e.g., `app/` absent)           | Exit 2 with `RouteDirMissingError`.                                                  |
| Framework unsupported                              | Exit 0; write fallback JSON so Stage 01 still runs (AC6).                            |
| Zero matching route files in a supported framework | Exit 0; write JSON with empty `routes[]`; Stage 01 no-ops and prints a helpful note. |
| All checks pass                                    | Write routes JSON; proceed to Stage 01.                                              |

---

## 0.11 Error & Rescue Map (referenced by spec)

| Error type                    | When raised                                                       | Recovery action                             | User sees                                                    |
| ----------------------------- | ----------------------------------------------------------------- | ------------------------------------------- | ------------------------------------------------------------ |
| `ProfileNotFoundError`        | `.claude/qa-profile.json` absent                                  | Print `/qa-scaffold` instruction, exit 0    | "Run `/qa-scaffold` first, then re-run `/qa-backfill`"       |
| `ProfileParseError`           | JSON parse fails                                                  | Print parse error + path, exit 2            | "Invalid qa-profile.json: <parse error>"                     |
| `UnsupportedFrameworkWarning` | Framework is code-convention or unknown                           | Emit fallback stub, continue, exit 0        | "Framework <name> uses code-based routing; emitted fallback" |
| `RouteDirMissingError`        | Framework dispatched but expected dir is absent                   | Print which dir is missing, exit 2          | "Expected <dir>/ for framework <name> — not found"           |
| `SkipWithNoteWarning`         | A file matches the glob but hits the skip list                    | Skip, increment count, record in `notes`    | Summary shows "N files skipped"                              |
| `PathTraversalError`          | Derived slug contains `..`, `/`, or backslash after normalization | Skip the route, record in `notes`, continue | "1 route skipped — slug failed traversal check"              |
