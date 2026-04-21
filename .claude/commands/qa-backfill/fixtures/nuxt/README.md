# Fixture: Nuxt 3

Minimal Nuxt 3 shape used by `/qa-backfill` Stage 00 crawler tests. **Not a real app**.

## Layout

```
pages/
├── index.vue        ← route "/"         slug: "index"
└── contact.vue      ← route "/contact"  slug: "contact"
```

## Expected Stage 00 output

Running `/qa-backfill` Stage 00 against this fixture with `.claude/qa-profile.json` `framework: "nuxt"` should produce `.claude/state/qa-backfill-routes.json` with exactly these routes:

| path       | slug      | has_dynamic_segment | segment_name | segment_placeholder |
| ---------- | --------- | ------------------- | ------------ | ------------------- |
| `/`        | `index`   | false               | null         | null                |
| `/contact` | `contact` | false               | null         | null                |

No skipped-file notes for this fixture (no layouts or middleware present).

## Expected Stage 01 output

With `test_dir: "tests/e2e"`:

```
tests/e2e/backfilled/index.spec.ts
tests/e2e/backfilled/contact.spec.ts
tests/e2e/pages/backfilled/index.page.ts
tests/e2e/pages/backfilled/contact.page.ts
```
