# `/qa-backfill` — Stub Spec Generator for Existing UI

Companion to [`/qa-scaffold`](../qa-scaffold/README.md). After a repo is scaffolded, `/qa-backfill` crawls the app's existing routes and emits skeleton Playwright specs + page objects — one pair per route — so legacy UI that predates `/plan-w-team` gets a T1 smoke harness ready for humans or `/plan-w-team` to promote to real assertions.

```
/qa-scaffold  → one-time install (config + first page object + lint rule)
/qa-backfill  → generate stubs for every existing route (re-runnable as routes are added)
/plan-w-team  → author the real T2+ tests for features you care about
```

---

## Why is this separate from `/qa-scaffold`?

| Aspect        | `/qa-scaffold`                                                 | `/qa-backfill`                                                      |
| ------------- | -------------------------------------------------------------- | ------------------------------------------------------------------- |
| Shape         | One-time install                                               | Re-runnable, additive                                               |
| Writes        | Playwright config, helpers, one example page object, lint rule | Per-route spec + page-object stubs under `{{test_dir}}/backfilled/` |
| Input         | `package.json` + `.tsx`/`.vue`/`.svelte` file count            | `.claude/qa-profile.json` + filesystem route enumeration            |
| Output volume | Fixed (~5 files)                                               | O(N) where N = route count                                          |
| Idempotence   | Backup-on-overwrite with prompt                                | Skip-by-default, `--overwrite` backs up first                       |

Splitting them keeps `/qa-scaffold` fast and deterministic — you don't want the scaffolding path branching on "how many routes does this app have?" And it lets `/qa-backfill` be re-invoked safely as the app grows: new routes get stubs, existing stubs are untouched, stubs the user promoted to real specs stay promoted.

---

## Invocation

```
# Default — skip existing files (safe on every re-run)
/qa-backfill

# Replace existing stubs with fresh templates (each overwrite creates a .backup-<UTC-timestamp> sibling)
/qa-backfill --overwrite
```

`--overwrite` is not a routine flag. Use it when:

- The template shape has changed (`v1` → `v2`) and you want the new header.
- A stub was promoted to real assertions and is now wrong for the updated route — the `.backup-*` siblings are a safety net, **not** a substitute for git.

Do **not** run `--overwrite` against a repo whose stubs have already been retagged from `@stub` → `@backfilled`. Use `/plan-w-team` to evolve those specs instead.

---

## Tool Permissions

All tools used are covered by the base allow-list in `.claude/settings.json` — no per-project configuration needed. See [`.claude/docs/SKILL_PERMISSION_CONVENTION.md`](../../docs/SKILL_PERMISSION_CONVENTION.md) for the convention.

| Tool    | Use                                                                                 |
| ------- | ----------------------------------------------------------------------------------- |
| `Read`  | Read `.claude/qa-profile.json`, route files, spec + page-object templates           |
| `Write` | Emit per-route specs + page objects, state files, summary JSON                      |
| `Edit`  | Update existing stubs when `--overwrite` is passed (backup-first)                   |
| `Glob`  | Enumerate routes for Next / SvelteKit / Nuxt / React Router v7 / Astro              |
| `Grep`  | Locate existing stubs to preserve (skip-by-default idempotence)                     |
| `Bash`  | `mkdir -p`, `cp` for `.backup-<UTC>` siblings, optional `tsc --noEmit` verification |

**State & output paths touched:**

- `.claude/state/qa-backfill-routes.json` — Stage 00 route enumeration
- `.claude/state/qa-backfill-emit-summary.json` — Stage 01 emit record
- `<test_dir>/backfilled/*.spec.ts` — per-route stub specs
- `<test_dir>/pages/backfilled/*.page.ts` — per-route page objects
- `<any-file>.backup-<UTC-timestamp>` — backup siblings when `--overwrite` differs

---

## Stage pipeline

| Stage                               | Responsibility                                                            | Writes                                                                                                                        |
| ----------------------------------- | ------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------- |
| [`00-crawl`](00-crawl.md)           | Read `.claude/qa-profile.json`; enumerate routes per framework            | `.claude/state/qa-backfill-routes.json`                                                                                       |
| [`01-emit-stubs`](01-emit-stubs.md) | Render per-route spec + page-object from templates, with idempotence      | `{{test_dir}}/backfilled/*.spec.ts`, `{{test_dir}}/pages/backfilled/*.page.ts`, `.claude/state/qa-backfill-emit-summary.json` |
| [`02-verify`](02-verify.md)         | Confirm disk matches summary, best-effort `tsc --noEmit`, print AC10 line | (nothing — reads both state files, prints summary)                                                                            |

See [`templates/stub-spec.template`](templates/stub-spec.template) and [`templates/page-object-stub.template`](templates/page-object-stub.template) for the exact shape emitted per route. The stub-spec shape is a **one-way door** — pinned in the spec under `docs/specs/qa-backfill.md` §Scope Inputs.

---

## Idempotence contract

1. **Skip by default.** A second run writes nothing if no new routes have been added.
2. **`--overwrite` backs up first.** Every existing file that differs from the freshly-rendered template is copied to `<path>.backup-<UTC-timestamp>` **before** the destination is overwritten. Backup failures hard-stop the stage — nothing is ever written without a successful backup.
3. **Path traversal is refused.** Any derived slug or output path containing `..`, `/`, or backslashes hard-stops Stage 01 with a `PathTraversalError`.
4. **Orphans are reported, not deleted.** Files found under `{{test_dir}}/backfilled/` that are not in the current emit summary are called out in Stage 02's output but never removed — they're the user's call.

---

## Outputs after a clean run

```
{{test_dir}}/
├── backfilled/
│   ├── index.spec.ts
│   ├── about.spec.ts
│   ├── users-id.spec.ts
│   └── catch-slug.spec.ts
└── pages/
    └── backfilled/
        ├── index.page.ts
        ├── about.page.ts
        ├── users-id.page.ts
        └── catch-slug.page.ts

.claude/state/
├── qa-backfill-routes.json         # Stage 00 output
└── qa-backfill-emit-summary.json   # Stage 01 output
```

Every emitted spec starts with the `@T1-smoke @stub` describe tag. Retag to `@backfilled` once the TODOs inside are replaced with real data-testid attributes and the `@T2-critical-path` block is promoted from `test.skip` to a passing assertion.

---

## When does `/qa-backfill` run (and when does it skip)?

| `.claude/qa-profile.json` | Framework                                | Routes found | Existing stubs      | Outcome                                                                          |
| ------------------------- | ---------------------------------------- | ------------ | ------------------- | -------------------------------------------------------------------------------- |
| absent                    | —                                        | —            | —                   | Clean abort: "Run `/qa-scaffold` first." Exit 0.                                 |
| present, malformed        | —                                        | —            | —                   | Exit 2 with `ProfileParseError`.                                                 |
| present                   | next/sveltekit/nuxt/react-router/astro   | 0            | —                   | Exit 0; informational "No routes to backfill."                                   |
| present                   | next/sveltekit/nuxt/react-router/astro   | N            | none                | Emit N specs + N page objects.                                                   |
| present                   | next/sveltekit/nuxt/react-router/astro   | N            | all N already exist | Skip all. Final summary: `W=0, S=N`. Hint: "Re-run with --overwrite to refresh." |
| present                   | next/sveltekit/nuxt/react-router/astro   | N            | M of N exist        | Emit `N-M` new; skip `M`. Clean additive run.                                    |
| present                   | vue/angular/solid/tanstack/remix-classic | —            | —                   | Emit single `routes-unknown.spec.ts` fallback stub. See §Unsupported below.      |

---

## Unsupported frameworks

`/qa-backfill` supports **file-convention** routing only:

- **Next.js App Router** (`app/**/page.tsx`) — since v1
- **SvelteKit** (`src/routes/**/+page.svelte`) — since v1
- **Nuxt 3** (`pages/**/*.vue`) — since v1
- **React Router v7 flat-file routes** (`app/routes/**/*.{tsx,jsx,ts,js}`) — since v1.1
- **Astro** (`src/pages/**/*.astro`) — since v1.1

All five file-convention frameworks share the universal **catch-slug pinning** rule (any catch-all / splat / rest-parameter route emits a slug ending in literal `slug`, e.g. `catch-slug`, `docs-slug`). See [`00-crawl.md` §0.4](00-crawl.md) for the full pinning table.

Code-convention routers enumerate routes at runtime via a router config object, which requires AST analysis to trace statically:

| Framework            | Router library                        | Status         |
| -------------------- | ------------------------------------- | -------------- |
| React (non-RRv7)     | `react-router` v6, `@tanstack/router` | Deferred to v2 |
| Vue                  | `vue-router`                          | Deferred to v2 |
| Angular              | `@angular/router`                     | Deferred to v2 |
| Solid                | `@solidjs/router`                     | Deferred to v2 |
| Next.js Pages Router | Legacy `pages/*.tsx`                  | Deferred to v2 |
| Remix (classic)      | `remix.config.js` routes fn           | Deferred to v2 |

> **Note**: React Router v7 in its flat-file convention mode (`app/routes/*.tsx`) IS supported as of v1.1 — the crawler walks the filesystem directly and handles the `.`-as-separator / `$name` / bare `$` / `_prefix` conventions. Earlier React Router versions (v6 and prior) and TanStack Router still require AST analysis and remain deferred.

When the framework dispatch hits any of the above, Stage 00 emits a single `routes-unknown` fallback entry and Stage 01 renders one `routes-unknown.spec.ts` whose header directs the user to either:

1. Duplicate the file manually per route, or
2. Run `/plan-w-team` with a feature description like "AST-based route backfill for react-router" — the planner will author real assertions and can generate per-route stubs by reading the router config.

Full details in the spec's Deferred Items: `docs/specs/qa-backfill.md`.

---

## Integration with `/qa-scaffold` and `/plan-w-team`

`/qa-backfill` is a **bridge** between the scaffold and the planner:

- **Prereq gate**: `/qa-backfill` refuses to run without `.claude/qa-profile.json`, which only `/qa-scaffold` creates.
- **Handoff to planner**: Every emitted stub is tagged `@stub`. `/plan-w-team`'s Step 0 `ui_scope_flag` can key on this tag to ensure new features consume (or replace) the skeleton rather than writing a parallel spec in a different directory.
- **Retag signal**: When a stub has been promoted to real assertions, retag the describe from `@stub` to `@backfilled`. Future audits (and `/plan-w-team` Step 5 review) use the retag to distinguish "stub from /qa-backfill" from "handwritten by an engineer."

This three-command sequence — scaffold → backfill → plan — gets a legacy UI repo from "no tests anywhere" to "every route has a smoke check + the important features have real assertions" in about an hour of human time plus the planner's execution time.

---

## Monorepo adoption (per-app profile)

`/qa-backfill` has no monorepo-native dispatcher — Stage 00 crawls one app at a time. In a monorepo you get monorepo coverage by running the command once per app, each with its own `.claude/qa-profile.json`. No schema changes, no flags.

**Setup** (example: a monorepo with `apps/admin`, `apps/web`, `apps/website`):

```
apps/
├── admin/                          # React Router v7 flat-file routes
│   ├── .claude/qa-profile.json    # framework="react-router", test_dir="tests/e2e"
│   └── app/routes/**
├── web/                            # React Router v7 flat-file routes
│   ├── .claude/qa-profile.json    # framework="react-router", test_dir="tests/e2e"
│   └── app/routes/**
└── website/                        # Astro
    ├── .claude/qa-profile.json    # framework="astro", test_dir="tests/e2e"
    └── src/pages/**
```

**Usage**:

```bash
# From the monorepo root
for app in apps/admin apps/web apps/website; do
  (cd "$app" && /qa-backfill)
done

# Or run against a single app when only one changed
(cd apps/admin && /qa-backfill)
```

Each app's specs land under that app's `{{test_dir}}/backfilled/` — no cross-app leakage, no shared state. The three apps can sit on different QA profiles (e.g., `apps/admin` on `full`, `apps/website` on `light`) because each profile is read from its own app root.

**When this breaks down**: if the same route path exists in two apps (e.g., both `apps/admin` and `apps/web` serve `/dashboard`), the emitted spec slug (`dashboard.spec.ts`) is identical. Because specs live under _each app's_ test_dir, they don't collide — but test runners aggregated across the whole monorepo (e.g., a root-level Playwright project) will need distinct test IDs. The `data-testid` convention `<feature>-<element>-<action>` is app-agnostic; prefix per-app (`admin-dashboard-…`, `web-dashboard-…`) when the aggregator can't disambiguate by directory.

A native monorepo dispatcher (one command, discovers all `.claude/qa-profile.json` files, fans out) is tracked in `docs/specs/qa-backfill.md` Deferred Items as P2 — it remains deferred because the per-app loop covers the 80% case with zero command-shape complexity.

---

## Error & Rescue Map (cross-reference)

Per-stage error tables are in each stage file:

- [`00-crawl.md` §0.11](00-crawl.md) — profile/route-dir/framework errors
- [`01-emit-stubs.md` §1.11](01-emit-stubs.md) — placeholder, path-traversal, backup errors
- [`02-verify.md` §2.6](02-verify.md) — drift and typecheck outcomes

The top-level spec at `docs/specs/qa-backfill.md` aggregates these into a single Error & Rescue Map and Shadow Path Analysis.
