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

Stage 00 supports file-convention frameworks. Code-convention frameworks (classic React Router `<Route>` JSX, Vue Router, Angular router) drop through to the `unsupported` branch in 0.6.

| `framework` value | Crawl root          | Route file glob                                                                                 |
| ----------------- | ------------------- | ----------------------------------------------------------------------------------------------- |
| `next`            | `app/`              | `app/**/page.{ts,tsx,js,jsx}` (App Router only)                                                 |
| `sveltekit`       | `src/routes/`       | `src/routes/**/+page.svelte`                                                                    |
| `svelte` (+ Kit)  | `src/routes/`       | `src/routes/**/+page.svelte` (treat Kit as sveltekit)                                           |
| `nuxt`            | `pages/`            | `pages/**/*.vue`                                                                                |
| `react-router`    | `app/routes/`       | `app/routes/**/*.{ts,tsx,js,jsx}` (React Router v7 flat-file convention)                        |
| `astro`           | `src/pages/`        | `src/pages/**/*.astro` (Astro pages convention; endpoint extensions skipped — see 0.3)          |
| `vue`             | — code-convention   | Emit `unsupported` fallback (Vue Router is code-based).                                         |
| `react`           | — code-convention   | Emit `unsupported` fallback. Use `react-router` for RRv7; classic `<Route>` JSX is deferred P2. |
| `angular`         | — code-convention   | Emit `unsupported` fallback (Angular router is decorator-based).                                |
| `solid`, `remix`  | — not yet supported | Emit `unsupported` fallback (deferred — see spec Deferred Items). Remix v2+ migrated to RRv7.   |
| anything else     | —                   | Emit `unsupported` fallback.                                                                    |

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

### React Router v7

React Router v7 flat-file routes live at `app/routes/**`. The convention encodes route shape in the filename via dots (`.`) for path separators and `$` for dynamic segments. Skip files that do not represent a navigable leaf route.

| Skip                                                                                                          | Reason                                                                                                                             |
| ------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| Files whose first dotted segment starts with `_` and is **not** `_index` (e.g., `_protected.tsx`, `_app.tsx`) | Pathless layout — wraps children without adding a URL segment. `_index.tsx` is a valid index leaf and must NOT be skipped.         |
| Files with no `export default`                                                                                | Shared module (loader-only helper, type file, util). Detect by scanning for `export default` anywhere in the file; absence → skip. |
| Files outside `app/routes/**`                                                                                 | `app/root.tsx`, `app/entry.client.tsx`, `app/entry.server.tsx`, `app/lib/**`, etc. Not routes.                                     |
| `*.test.{ts,tsx,js,jsx}`, `*.spec.{ts,tsx,js,jsx}`                                                            | Co-located tests.                                                                                                                  |
| `*.css`, `*.module.css`, `*.scss`                                                                             | Stylesheets that happen to live in `app/routes/`.                                                                                  |

### Astro

Astro pages live under `src/pages/**`. Astro treats every `.astro` file as a page unless the filename begins with `_`, and treats any file whose name ends in `.xml.ts` / `.json.ts` / `.ts` / `.js` as a non-HTML **endpoint** (API route / feed / sitemap). Skip endpoints and underscore-prefixed partials.

| Skip                                                                  | Reason                                                                                                          |
| --------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------- |
| Files under `src/pages/**` starting with `_` (e.g., `_partial.astro`) | Astro ignores underscore-prefixed files for routing — treated as partials/fragments.                            |
| `src/pages/**/*.xml.ts`, `*.xml.js`, `*.json.ts`, `*.json.js`         | Endpoints emitting XML/JSON (sitemap, RSS, Open Search). Not HTML pages — omit from Playwright smoke coverage.  |
| `src/pages/**/*.ts`, `*.js` without a paired `.astro`                 | Endpoint-only route (API handler). Skip — `/qa-backfill` targets HTML-rendered pages.                           |
| Files outside `src/pages/**`                                          | Components, layouts, and content collections (`src/components/`, `src/layouts/`, `src/content/`) are not pages. |

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

### React Router v7 slug derivation

RRv7 slugs come from the **filename**, not a path-string. The flat-file convention encodes routing in the filename itself via three sigils:

| Sigil                                 | Meaning                                                                            |
| ------------------------------------- | ---------------------------------------------------------------------------------- |
| `.` (dot)                             | Path separator between URL segments.                                               |
| `$name`                               | Dynamic segment named `name` (matches `:name` in path-string form).                |
| `$` (bare, with no name)              | Splat / catch-all segment. Always normalized to slug `slug`.                       |
| `_prefix` as **first** dotted segment | Pathless layout — skip the file entirely per §0.3. `_index` is the only exception. |

Steps for each RRv7 route file at `app/routes/<basename>.<ext>` (and for index files nested in sub-directories like `app/routes/customers/_index.tsx`):

1. Compute the relative path from `app/routes/` to the file (strip the extension). For nested directories, keep the directory separators as-is for a moment.
2. Replace directory separators (`/`) with `.` — nested folders collapse into the same flat-file namespace.
3. Split the resulting string by `.`.
4. Reject (skip) if any segment starts with `_` and is **not** `_index` (redundant with §0.3 but keep the check here as a belt-and-braces guard — if the file slips past §0.3, §0.4 still drops it).
5. Per-segment transform, in order:
   - `_index` → empty string (the segment contributes nothing to the slug; an index leaf under `customers/` yields `customers-index`, an index at the routes root yields `index`).
   - `$name` (where `name` is not empty) → `name`.
   - `$` (bare) → `slug`.
   - Any other literal → keep as-is.
6. Filter out empty segments, lowercase, join the remainder with `-`.
7. If the resulting slug is empty (a pure index at the routes root), emit `index`.
8. Apply the same non-kebab normalization as above (replace stray `_` / `.` with `-`, collapse consecutive `-`).

#### RRv7 pinned examples

| Source file                         | Route path            | Slug                       |
| ----------------------------------- | --------------------- | -------------------------- |
| `app/routes/_index.tsx`             | `/`                   | `index`                    |
| `app/routes/about.tsx`              | `/about`              | `about`                    |
| `app/routes/dashboard.tsx`          | `/dashboard`          | `dashboard`                |
| `app/routes/customers.tsx`          | `/customers`          | `customers`                |
| `app/routes/customers.$id.tsx`      | `/customers/:id`      | `customers-id`             |
| `app/routes/customers.$id.edit.tsx` | `/customers/:id/edit` | `customers-id-edit`        |
| `app/routes/customers/_index.tsx`   | `/customers`          | `customers-index`          |
| `app/routes/customers/new.tsx`      | `/customers/new`      | `customers-new`            |
| `app/routes/$.tsx`                  | `/*`                  | `catch-slug`               |
| `app/routes/docs.$.tsx`             | `/docs/*`             | `docs-slug`                |
| `app/routes/_protected.tsx`         | —                     | **skip** (pathless layout) |

**Note on `customers.tsx` + `customers/_index.tsx` coexisting**: in RRv7 they are two distinct leaves (a layout-style parent route and an index child). The crawler emits a stub for each — `customers` and `customers-index`. The spec collision guard in the next section catches the case where two files _derive_ the same slug (not this case, they are different by construction).

### Astro slug derivation

Astro slugs come from the **relative path under `src/pages/`**. The convention uses bracket syntax (`[param]` for single segments, `[...rest]` for catch-all) identical to Next.js — no new per-segment transforms are required beyond the shared §0.4 steps. The only Astro-specific rule is how to produce the cleaned route path from a pages file:

1. Compute the relative path from `src/pages/` to the file.
2. Strip the file extension (`.astro`).
3. If the resulting stem is `index`, drop it (so `src/pages/blog/index.astro` → `/blog`; `src/pages/index.astro` → `/`).
4. Prepend a leading `/`. This yields the canonical route path — feed it into the framework-agnostic rules above.

#### Astro pinned examples

| Source file                      | Route path     | Slug                      |
| -------------------------------- | -------------- | ------------------------- |
| `src/pages/index.astro`          | `/`            | `index`                   |
| `src/pages/about.astro`          | `/about`       | `about`                   |
| `src/pages/[slug].astro`         | `/[slug]`      | `slug`                    |
| `src/pages/[...rest].astro`      | `/[...rest]`   | `catch-slug`              |
| `src/pages/blog/index.astro`     | `/blog`        | `blog`                    |
| `src/pages/blog/[slug].astro`    | `/blog/[slug]` | `blog-slug`               |
| `src/pages/sitemap-index.xml.ts` | —              | **skip** (endpoint, §0.3) |

**Catch-slug pinning (applies to all frameworks)**: every catch-all / splat / rest-parameter route — regardless of framework — must normalize to a slug whose final token is the literal string `slug`. The rule is enforced uniformly:

| Framework       | Source form                                     | Slug final token |
| --------------- | ----------------------------------------------- | ---------------- |
| Next.js         | `[...slug]` or `[[...slug]]` or `[...anything]` | `slug`           |
| SvelteKit       | `[...rest]` (any name)                          | `slug`           |
| Nuxt 3          | `[...slug]` (any name)                          | `slug`           |
| React Router v7 | Bare `$` segment, e.g., `$.tsx` / `docs.$.tsx`  | `slug`           |
| Astro           | `[...rest]` (any name)                          | `slug`           |

Root catch-all → `catch-slug` (three names normalize to the same output: `/catch/[...slug]`, `/[...rest]`, and `$.tsx` all emit slug `catch-slug`). Nested catch-all → `<parent>-slug` (e.g., `/docs/[...rest]` → `docs-slug`; `docs.$.tsx` → `docs-slug`). This pinning closes the v1 evaluator-rubric-3 gap: the convention is now explicit in the spec, not implied by example.

### Slug collisions

If two different routes derive the same slug (e.g., `/users/[id]` and `/users/:id` in a mixed-convention repo), append a numeric suffix to the second one (`users-id-2`, `users-id-3`, …) and record the collision in `notes`.

---

## 0.5 Dynamic segment annotation

For each emitted route, Stage 01 needs to know whether to render the dynamic or static variant of the templates. Annotate with three fields.

| Field                 | Semantics                                                                                                                                                                                       |
| --------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `has_dynamic_segment` | `true` if the route path contains at least one `[segment]`, `[...segment]`, `[[...segment]]`, RRv7 `$name`, or RRv7 bare `$`.                                                                   |
| `segment_name`        | The first dynamic segment's name. Next/SvelteKit/Nuxt: inside brackets, with `...` stripped. RRv7 `$name` → `name`; RRv7 bare `$` → `slug`. E.g., `customers.$id.tsx` → `id`.                   |
| `segment_placeholder` | A substitution-friendly string Stage 01 drops into `goto('...')`. Pick by heuristic: `id`/`postId`/`*Id` → `"123"`; `slug`/`...slug`/bare-splat → `"example"`; anything else → `"placeholder"`. |

Multi-dynamic-segment routes get only the first segment pinned in the annotation — the remaining placeholders are left as literal `[name]` (or `$name` for RRv7) inside the route string so the reader sees the TODO.

**RRv7 segment name extraction**: when scanning the split-by-`.` filename segments in order, the first segment matching `^\$[a-zA-Z_][a-zA-Z0-9_]*$` yields `segment_name` = the identifier after `$`. The first segment that is exactly `$` (bare splat) yields `segment_name` = `"slug"` and is always a catch-all — pair with `segment_placeholder` = `"example"`.

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

| Error type                    | When raised                                                                                                                                                                                                                        | Recovery action                             | User sees                                                                                                                              |
| ----------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| `ProfileNotFoundError`        | `.claude/qa-profile.json` absent                                                                                                                                                                                                   | Print `/qa-scaffold` instruction, exit 0    | "Run `/qa-scaffold` first, then re-run `/qa-backfill`"                                                                                 |
| `ProfileParseError`           | JSON parse fails                                                                                                                                                                                                                   | Print parse error + path, exit 2            | "Invalid qa-profile.json: <parse error>"                                                                                               |
| `UnsupportedFrameworkWarning` | Framework is code-convention or unknown                                                                                                                                                                                            | Emit fallback stub, continue, exit 0        | "Framework <name> uses code-based routing; emitted fallback"                                                                           |
| `RouteDirMissingError`        | Framework dispatched but expected dir is absent                                                                                                                                                                                    | Print which dir is missing, exit 2          | "Expected <dir>/ for framework <name> — not found"                                                                                     |
| `SkipWithNoteWarning`         | A file matches the glob but hits the skip list (per-framework §0.3: Next layouts/loading; SvelteKit `+layout`/`+server`; Nuxt `.client.vue`/`_middleware`; RRv7 pathless-layout `_prefix.*`, no-default-export, co-located tests). | Skip, increment count, record in `notes`    | Summary shows "N files skipped" with a one-line breakdown per trigger (e.g., "3 pathless-layout skipped, 1 no-default-export skipped") |
| `PathTraversalError`          | Derived slug contains `..`, `/`, or backslash after normalization                                                                                                                                                                  | Skip the route, record in `notes`, continue | "1 route skipped — slug failed traversal check"                                                                                        |
