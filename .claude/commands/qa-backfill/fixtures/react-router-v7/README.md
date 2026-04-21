# Fixture: React Router v7 (flat-file routes)

Minimal React Router v7 route shape used by `/qa-backfill` Stage 00 crawler tests. **Not a real app** — the files exist only so the crawler has something to enumerate.

## Layout

```
app/
└── routes/
    ├── _index.tsx              ← route "/"               slug: "index"
    ├── dashboard.tsx           ← route "/dashboard"      slug: "dashboard"
    ├── customers.tsx           ← route "/customers"      slug: "customers"     (pathful layout leaf)
    ├── customers.$id.tsx       ← route "/customers/:id"  slug: "customers-id"  (dynamic, segment_name: "id")
    ├── customers/
    │   └── new.tsx             ← route "/customers/new"  slug: "customers-new"
    ├── _protected.tsx          ← SKIPPED (pathless layout — first segment starts with "_")
    └── $.tsx                   ← route "/*"              slug: "catch-slug"    (bare splat)
```

## Expected Stage 00 output

Running `/qa-backfill` Stage 00 against this fixture with `.claude/qa-profile.json` `framework: "react-router"` should produce `.claude/state/qa-backfill-routes.json` with exactly these routes (order not significant):

| path             | slug            | has_dynamic_segment | segment_name | segment_placeholder |
| ---------------- | --------------- | ------------------- | ------------ | ------------------- |
| `/`              | `index`         | false               | null         | null                |
| `/dashboard`     | `dashboard`     | false               | null         | null                |
| `/customers`     | `customers`     | false               | null         | null                |
| `/customers/:id` | `customers-id`  | true                | `id`         | `"123"`             |
| `/customers/new` | `customers-new` | false               | null         | null                |
| `/*`             | `catch-slug`    | true                | `slug`       | `"anything"`        |

Plus `notes`: `["1 pathless layout (_protected.tsx) skipped"]`.

## Why these files

- `_index.tsx` — the `_index` exception to the "skip anything starting with `_`" rule. Emits slug `index`.
- `dashboard.tsx` — plain static leaf.
- `customers.tsx` + `customers.$id.tsx` — pathful layout parent plus dynamic child; confirms `.` → `/` path joining and `$id` → `:id` param conversion. Slugs `customers` and `customers-id` are distinct by construction, so the collision guard does not fire.
- `customers/new.tsx` — subfolder form equivalent to `customers.new.tsx`; confirms the crawler collapses directory separators into the flat namespace (`/` replaced with `.` in rel path).
- `_protected.tsx` — pathless layout wrapper. Has a real `export default` (Outlet) so the "no default export" skip doesn't fire — this file must be skipped specifically because of the underscore-prefix rule.
- `$.tsx` — bare splat. The root catch-all. Emits slug `catch-slug` per the universal catch-slug pinning in §0.4.

## Expected Stage 01 output

With `test_dir: "tests/e2e"`, Stage 01 should emit:

```
tests/e2e/backfilled/index.spec.ts
tests/e2e/backfilled/dashboard.spec.ts
tests/e2e/backfilled/customers.spec.ts
tests/e2e/backfilled/customers-id.spec.ts
tests/e2e/backfilled/customers-new.spec.ts
tests/e2e/backfilled/catch-slug.spec.ts
tests/e2e/pages/backfilled/index.page.ts
tests/e2e/pages/backfilled/dashboard.page.ts
tests/e2e/pages/backfilled/customers.page.ts
tests/e2e/pages/backfilled/customers-id.page.ts
tests/e2e/pages/backfilled/customers-new.page.ts
tests/e2e/pages/backfilled/catch-slug.page.ts
```

Regression tests (v2) can diff against this expected shape.
