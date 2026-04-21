# Fixture: Next.js App Router

Minimal Next.js App Router shape used by `/qa-backfill` Stage 00 crawler tests. **Not a real app** — the files exist only so the crawler has something to enumerate.

## Layout

```
app/
├── page.tsx                 ← route "/"               slug: "index"
├── layout.tsx               ← SKIPPED (layout wrapper)
├── loading.tsx              ← SKIPPED (loading UI)
├── dashboard/
│   └── page.tsx             ← route "/dashboard"      slug: "dashboard"
└── users/
    └── [id]/
        └── page.tsx         ← route "/users/[id]"    slug: "users-id"  (dynamic)
```

## Expected Stage 00 output

Running `/qa-backfill` Stage 00 against this fixture with `.claude/qa-profile.json` `framework: "next"` should produce `.claude/state/qa-backfill-routes.json` with exactly these routes (order not significant):

| path          | slug        | has_dynamic_segment | segment_name | segment_placeholder |
| ------------- | ----------- | ------------------- | ------------ | ------------------- |
| `/`           | `index`     | false               | null         | null                |
| `/dashboard`  | `dashboard` | false               | null         | null                |
| `/users/[id]` | `users-id`  | true                | `id`         | `"123"`             |

Plus `notes`: `["1 layout.tsx skipped", "1 loading.tsx skipped"]`.

## Expected Stage 01 output

With `test_dir: "tests/e2e"`, Stage 01 should emit:

```
tests/e2e/backfilled/index.spec.ts
tests/e2e/backfilled/dashboard.spec.ts
tests/e2e/backfilled/users-id.spec.ts
tests/e2e/pages/backfilled/index.page.ts
tests/e2e/pages/backfilled/dashboard.page.ts
tests/e2e/pages/backfilled/users-id.page.ts
```

Regression tests can diff against this expected shape.
