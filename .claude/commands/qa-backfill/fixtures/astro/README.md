# Fixture: Astro (file-based pages convention)

Minimal Astro page shape used by `/qa-backfill` Stage 00 crawler tests. **Not a real app** — the files exist only so the crawler has something to enumerate.

## Layout

```
src/
└── pages/
    ├── index.astro                 ← route "/"              slug: "index"
    ├── about.astro                 ← route "/about"         slug: "about"
    ├── [slug].astro                ← route "/[slug]"        slug: "slug"        (dynamic, segment_name: "slug")
    ├── [...rest].astro             ← route "/[...rest]"     slug: "catch-slug"  (splat)
    ├── blog/
    │   ├── index.astro             ← route "/blog"          slug: "blog"
    │   └── [slug].astro            ← route "/blog/[slug]"   slug: "blog-slug"   (dynamic)
    └── sitemap-index.xml.ts        ← SKIPPED (endpoint — emits XML)
```

## Expected Stage 00 output

Running `/qa-backfill` Stage 00 against this fixture with `.claude/qa-profile.json` `framework: "astro"` should produce `.claude/state/qa-backfill-routes.json` with exactly these routes (order not significant):

| path           | slug         | has_dynamic_segment | segment_name | segment_placeholder |
| -------------- | ------------ | ------------------- | ------------ | ------------------- |
| `/`            | `index`      | false               | null         | null                |
| `/about`       | `about`      | false               | null         | null                |
| `/[slug]`      | `slug`       | true                | `slug`       | `"hello-world"`     |
| `/[...rest]`   | `catch-slug` | true                | `slug`       | `"anything"`        |
| `/blog`        | `blog`       | false               | null         | null                |
| `/blog/[slug]` | `blog-slug`  | true                | `slug`       | `"hello-world"`     |

Plus `notes`: `["1 endpoint (sitemap-index.xml.ts) skipped"]`.

## Why these files

- `index.astro` — root index; confirms the `index.astro` → `/` drop-trailing-index rule and slug `index` fallback.
- `about.astro` — plain static page.
- `[slug].astro` — top-level dynamic route; confirms bracket-syntax single-segment handling and the `slug` segment-name extraction.
- `[...rest].astro` — top-level splat; confirms the universal **catch-slug pinning** rule (any rest-parameter name normalizes to slug `catch-slug` at the root).
- `blog/index.astro` — nested index; confirms trailing-`index` is dropped before the path is turned into a slug (→ `blog`, not `blog-index`).
- `blog/[slug].astro` — nested dynamic; confirms slug generation combines parent segment with the dynamic `[slug]` → `blog-slug`.
- `sitemap-index.xml.ts` — endpoint route emitting XML. §0.3 skips files whose names end in `.xml.ts` / `.json.ts` because they do not render HTML pages and `/qa-backfill` targets human-visible routes only.

## Expected Stage 01 output

With `test_dir: "tests/e2e"`, Stage 01 should emit:

```
tests/e2e/backfilled/index.spec.ts
tests/e2e/backfilled/about.spec.ts
tests/e2e/backfilled/slug.spec.ts
tests/e2e/backfilled/catch-slug.spec.ts
tests/e2e/backfilled/blog.spec.ts
tests/e2e/backfilled/blog-slug.spec.ts
tests/e2e/pages/backfilled/index.page.ts
tests/e2e/pages/backfilled/about.page.ts
tests/e2e/pages/backfilled/slug.page.ts
tests/e2e/pages/backfilled/catch-slug.page.ts
tests/e2e/pages/backfilled/blog.page.ts
tests/e2e/pages/backfilled/blog-slug.page.ts
```

Regression tests (v2) can diff against this expected shape.
