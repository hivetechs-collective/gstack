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

| `.claude/qa-profile.json` | Framework                     | Routes found | Existing stubs      | Outcome                                                                          |
| ------------------------- | ----------------------------- | ------------ | ------------------- | -------------------------------------------------------------------------------- |
| absent                    | —                             | —            | —                   | Clean abort: "Run `/qa-scaffold` first." Exit 0.                                 |
| present, malformed        | —                             | —            | —                   | Exit 2 with `ProfileParseError`.                                                 |
| present                   | next/sveltekit/nuxt           | 0            | —                   | Exit 0; informational "No routes to backfill."                                   |
| present                   | next/sveltekit/nuxt           | N            | none                | Emit N specs + N page objects.                                                   |
| present                   | next/sveltekit/nuxt           | N            | all N already exist | Skip all. Final summary: `W=0, S=N`. Hint: "Re-run with --overwrite to refresh." |
| present                   | next/sveltekit/nuxt           | N            | M of N exist        | Emit `N-M` new; skip `M`. Clean additive run.                                    |
| present                   | react/vue/angular/solid/remix | —            | —                   | Emit single `routes-unknown.spec.ts` fallback stub. See §Unsupported below.      |

---

## Unsupported frameworks

`/qa-backfill` v1 supports **file-convention** routing only:

- **Next.js App Router** (`app/**/page.tsx`)
- **SvelteKit** (`src/routes/**/+page.svelte`)
- **Nuxt 3** (`pages/**/*.vue`)

Code-convention routers enumerate routes at runtime via a router config object, which requires AST analysis to trace statically:

| Framework            | Router library                           | Status         |
| -------------------- | ---------------------------------------- | -------------- |
| React                | `react-router`, `@tanstack/router`       | Deferred to v2 |
| Vue                  | `vue-router`                             | Deferred to v2 |
| Angular              | `@angular/router`                        | Deferred to v2 |
| Solid                | `@solidjs/router`                        | Deferred to v2 |
| Next.js Pages Router | Legacy `pages/*.tsx`                     | Deferred to v2 |
| Remix                | v2 file convention (close to file-based) | Deferred to v2 |

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

## Error & Rescue Map (cross-reference)

Per-stage error tables are in each stage file:

- [`00-crawl.md` §0.11](00-crawl.md) — profile/route-dir/framework errors
- [`01-emit-stubs.md` §1.11](01-emit-stubs.md) — placeholder, path-traversal, backup errors
- [`02-verify.md` §2.6](02-verify.md) — drift and typecheck outcomes

The top-level spec at `docs/specs/qa-backfill.md` aggregates these into a single Error & Rescue Map and Shadow Path Analysis.
