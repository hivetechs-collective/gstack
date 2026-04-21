# Fixture: SvelteKit

Minimal SvelteKit shape used by `/qa-backfill` Stage 00 crawler tests. **Not a real app** — only enough structure for the crawler to enumerate.

## Layout

```
src/routes/
├── +page.svelte             ← route "/"         slug: "index"
├── +layout.svelte           ← SKIPPED (layout wrapper)
└── about/
    └── +page.svelte         ← route "/about"    slug: "about"
```

## Expected Stage 00 output

Running `/qa-backfill` Stage 00 against this fixture with `.claude/qa-profile.json` `framework: "sveltekit"` should produce `.claude/state/qa-backfill-routes.json` with exactly these routes:

| path     | slug    | has_dynamic_segment | segment_name | segment_placeholder |
| -------- | ------- | ------------------- | ------------ | ------------------- |
| `/`      | `index` | false               | null         | null                |
| `/about` | `about` | false               | null         | null                |

Plus `notes`: `["1 +layout.svelte skipped"]`.

## Expected Stage 01 output

With `test_dir: "tests/e2e"`:

```
tests/e2e/backfilled/index.spec.ts
tests/e2e/backfilled/about.spec.ts
tests/e2e/pages/backfilled/index.page.ts
tests/e2e/pages/backfilled/about.page.ts
```
