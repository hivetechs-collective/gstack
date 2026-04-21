# Stage 01 — Emit stub specs and page objects from the route list

**Prerequisites:** Stage 00 completed; `.claude/state/qa-backfill-routes.json` exists and parses.
**Purpose:** render the two templates from `.claude/commands/qa-backfill/templates/` into per-route destination paths inside `{{test_dir}}`. Idempotent. Never silently overwrites.
**Outputs:** stub specs under `{{test_dir}}/backfilled/` + companion page objects under `{{test_dir}}/pages/backfilled/`.

---

## 1.1 Prerequisites

Read `.claude/state/qa-backfill-routes.json`.

| State                    | Outcome                                                                         |
| ------------------------ | ------------------------------------------------------------------------------- |
| File absent              | Exit 2 with "Stage 00 did not complete. Run `/qa-backfill` from the beginning." |
| JSON parse fails         | Exit 2 with the parse error + path.                                             |
| `routes` array empty     | Exit 0, print "No routes to backfill." Skip summary write (nothing to do).      |
| `routes` array populated | Proceed to 1.2.                                                                 |

Also read `.claude/qa-profile.json` for `test_dir` (defensive — the value is also in routes.json; re-read ensures the active profile, not a stale crawl, drives emission paths).

---

## 1.2 Templates consumed by this stage

| Template source                       | Default destination                              | Placeholders resolved                                                                                                                                                                                        |
| ------------------------------------- | ------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `templates/stub-spec.template`        | `{{TEST_DIR}}/backfilled/{{SLUG}}.spec.ts`       | `{{ROUTE}}`, `{{SLUG}}`, `{{SLUG_PASCAL}}`, `{{FEATURE}}`, `{{HAS_DYNAMIC_SEGMENT}}`, `{{SEGMENT_NAME}}`, `{{SEGMENT_PLACEHOLDER}}`, `{{GENERATED_AT}}`, `{{VERSION}}`, `{{DYNAMIC_ARG}}`, `{{ROUTE_REGEX}}` |
| `templates/page-object-stub.template` | `{{TEST_DIR}}/pages/backfilled/{{SLUG}}.page.ts` | Same set, plus `{{ROUTE_TEMPLATE_LITERAL}}` for the dynamic-segment variant                                                                                                                                  |

Both templates contain conditional block markers that Stage 01 honors:

| Marker pair                                                           | Meaning                                                               |
| --------------------------------------------------------------------- | --------------------------------------------------------------------- |
| `// {{HAS_DYNAMIC_SEGMENT_BEGIN}}` … `// {{HAS_DYNAMIC_SEGMENT_END}}` | Keep this block when `has_dynamic_segment === true`; drop otherwise.  |
| `// {{STATIC_ROUTE_BEGIN}}` … `// {{STATIC_ROUTE_END}}`               | Keep this block when `has_dynamic_segment === false`; drop otherwise. |

Remove the marker lines themselves after the decision. Never leave raw `{{HAS_DYNAMIC_SEGMENT_*}}` tokens in the emitted file.

---

## 1.3 Placeholder resolution rules

For each route entry, compute:

| Placeholder                  | Value source                                                                                                                                                                                                                |
| ---------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `{{ROUTE}}`                  | `route.path`                                                                                                                                                                                                                |
| `{{SLUG}}`                   | `route.slug`                                                                                                                                                                                                                |
| `{{SLUG_PASCAL}}`            | PascalCase of `slug`. Split on `-`, capitalize each part, rejoin. Examples: `index` → `Index`, `users-id` → `UsersId`, `blog-category-post` → `BlogCategoryPost`, `routes-unknown` → `RoutesUnknown`.                       |
| `{{FEATURE}}`                | `slug` lowercased, used as the `data-testid` prefix. Examples: `index` → `index`, `users-id` → `users-id`.                                                                                                                  |
| `{{HAS_DYNAMIC_SEGMENT}}`    | Not emitted as a literal; controls the conditional block selection described in 1.2.                                                                                                                                        |
| `{{SEGMENT_NAME}}`           | `route.segment_name`. For static routes this is unused (the static block is selected).                                                                                                                                      |
| `{{SEGMENT_PLACEHOLDER}}`    | `route.segment_placeholder`.                                                                                                                                                                                                |
| `{{GENERATED_AT}}`           | ISO 8601 UTC timestamp at emission time (e.g., `2026-04-20T23:58:00Z`).                                                                                                                                                     |
| `{{VERSION}}`                | Literal string `v1` (bump when template shape changes).                                                                                                                                                                     |
| `{{DYNAMIC_ARG}}`            | For the commented-out `@T2-critical-path` example: the goto argument to show. Dynamic → `'{{SEGMENT_PLACEHOLDER}}'` (literal-quoted inside the comment). Static → empty (no argument).                                      |
| `{{ROUTE_REGEX}}`            | A defensive regex for `toHaveURL`. Static routes: `^.*{{ROUTE}}/?$` with `/` escaped. Dynamic routes: replace each `[segment]` / `[...segment]` / `[[...segment]]` with `[^/]+` (or `.*` for catch-all); wrap in `^.*...$`. |
| `{{ROUTE_TEMPLATE_LITERAL}}` | For the dynamic-segment page-object `goto` variant: the route path with `[segment]` replaced by `${segmentName}`. Example: `/users/[id]` with `segment_name=id` → `/users/${id}`.                                           |

If any placeholder resolution fails (e.g., missing `segment_name` on a route marked `has_dynamic_segment: true`), exit 2 with `PlaceholderResolutionError` naming the route and missing field. Do not render a file containing unresolved `{{` tokens.

---

## 1.4 Output path derivation

For each route:

| Output           | Path template                                    |
| ---------------- | ------------------------------------------------ |
| Spec file        | `{{test_dir}}/backfilled/{{slug}}.spec.ts`       |
| Page object file | `{{test_dir}}/pages/backfilled/{{slug}}.page.ts` |

`{{test_dir}}` comes from qa-profile.json (canonical). Example: `tests/e2e/backfilled/users-id.spec.ts`.

### Path-traversal guard

Before opening any file for write, assert:

1. The normalized absolute path of the output is a descendant of the normalized absolute path of `{{test_dir}}/`.
2. Neither the slug nor the derived path contains `..`, `/`, or backslashes (slug already vetted in Stage 00 §0.7; re-assert here — defense in depth).

On failure raise `PathTraversalError`, hard-stop the stage (do not continue to the next route — a compromised route list is a stop-the-world event), record the offending route + computed path in `.claude/state/qa-backfill-emit-summary.json`, exit 2.

---

## 1.5 Idempotence & backup protocol (CRITICAL — mirrors qa-scaffold/02-scaffold.md §2.4)

Stage 01 accepts one flag: `--overwrite`. Default is OFF (skip-existing).

For every rendered destination (both spec and page object):

1. **Compute the rendered content** (template + resolved placeholders + conditional-block selection).
2. **Destination does not exist** → write it. Record `action: "written"` for this route.
3. **Destination exists AND `--overwrite` is OFF** → skip. Record `action: "skipped"`. Do NOT read the existing file, do NOT diff, do NOT back up. This is the common path on re-invocation and must be cheap.
4. **Destination exists AND `--overwrite` is ON**:
   a. Read the existing file.
   b. **Byte-identical to rendered content** → no-op. Record `action: "unchanged"`.
   c. **Differs** → back up **before** writing:
   - Backup path: `<destination>.backup-<UTC-timestamp>` (e.g., `tests/e2e/backfilled/users-id.spec.ts.backup-20260420T235900Z`). Use the exact same UTC timestamp for all files backed up in a single run (group rollback).
   - Copy the existing file to the backup path.
   - If the copy itself fails (disk full, permission denied) raise `BackupFailedError` and hard-stop the stage — never write without a successful backup.
   - After backup succeeds, write the rendered content to the destination. Record `action: "overwritten"` with `backup_path` included.

**Never**: overwrite a file without a backup; skip a file the user asked to overwrite with no explanation; silently continue after a failed backup.

### Atomicity

If the stage hard-stops mid-run (e.g., `BackupFailedError`), files already written remain on disk (new files) or have been safely backed up (overwrites). The user can restore overwrites from the `.backup-<timestamp>` siblings. Document this in the stage summary.

---

## 1.6 Unsupported-framework fallback rendering

When Stage 00 emitted `framework: "unsupported"` with a single `routes-unknown` entry:

- Render exactly one spec at `{{test_dir}}/backfilled/routes-unknown.spec.ts`.
- Skip the page object (there is no real route to instantiate).
- Header of the rendered spec includes: "Framework `<name>` uses code-based routing. Enumerate your routes manually and duplicate this file per route, or wait for v2 which will add router-config parsing. See `.claude/commands/qa-backfill/README.md` and `docs/specs/qa-backfill.md` Deferred Items."
- All other rules (idempotence, backup, path traversal) still apply.

This keeps the promise in AC6: unsupported frameworks get **something actionable** rather than a silent failure.

---

## 1.7 Per-route loop

Pseudo-algorithm (expressed in prose so stage-file readers don't need to debug shell):

1. Parse flags. `--overwrite` toggles the overwrite branch in §1.5.
2. Load routes.json and qa-profile.json.
3. Initialize counters: `written=0`, `skipped=0`, `overwritten=0`, `unchanged=0`, `failed=0`, `backups=[]`.
4. Compute a single run-UTC-timestamp for grouping backups.
5. For each route in `routes`:
   a. Resolve placeholders (§1.3). On failure → record `failed`, continue to next route.
   b. Compute output paths (§1.4). Run path-traversal guard. On failure → hard-stop (do not continue).
   c. For each output (spec + optional page object):
   - Apply idempotence protocol (§1.5). Update counters. Append to `backups` if an overwrite backed up a file.
     d. Append a per-route entry to the summary: `{route, slug, action, paths, backup_paths?}`.
6. After the loop, write `.claude/state/qa-backfill-emit-summary.json` (§1.8).
7. Print the summary to stdout (§1.9).

---

## 1.8 Artifact for downstream stages

Write `.claude/state/qa-backfill-emit-summary.json`:

```json
{
  "emitted_at": "2026-04-20T23:58:00Z",
  "run_timestamp": "20260420T235800Z",
  "test_dir": "tests/e2e",
  "overwrite_flag": false,
  "counts": {
    "written": 6,
    "skipped_existing": 2,
    "overwritten": 0,
    "unchanged": 0,
    "failed": 0
  },
  "backup_count": 0,
  "per_route": [
    {
      "route": "/",
      "slug": "index",
      "spec": {
        "path": "tests/e2e/backfilled/index.spec.ts",
        "action": "written"
      },
      "page_object": {
        "path": "tests/e2e/pages/backfilled/index.page.ts",
        "action": "written"
      }
    },
    {
      "route": "/users/[id]",
      "slug": "users-id",
      "spec": {
        "path": "tests/e2e/backfilled/users-id.spec.ts",
        "action": "skipped"
      },
      "page_object": {
        "path": "tests/e2e/pages/backfilled/users-id.page.ts",
        "action": "skipped"
      }
    }
  ]
}
```

Stage 02 (verify) reads this file for the final summary + acceptance checks.

---

## 1.9 Verbose output

Before exiting, print a human-readable summary to stdout:

```
/qa-backfill — Stage 01 (emit) complete
  Test dir:          tests/e2e
  Overwrite mode:    off
  Routes processed:  8
  Written:           6 (4 specs + 4 page objects — 2 routes previously stubbed)
  Skipped:           2 (already present — re-run with --overwrite to replace)
  Overwritten:       0
  Failed:            0
  Summary:           .claude/state/qa-backfill-emit-summary.json
  Next:              run Stage 02 to verify output.
```

---

## 1.10 Exit conditions

| Condition                                  | Exit                                                                                  |
| ------------------------------------------ | ------------------------------------------------------------------------------------- |
| routes.json missing                        | Exit 2 with pointer to Stage 00.                                                      |
| routes.json unparseable                    | Exit 2 with parse error.                                                              |
| `routes` array empty                       | Exit 0, informational message, no summary written.                                    |
| Placeholder resolution fails for one route | Record `failed`, continue with remaining routes; exit 0 if any succeeded else exit 2. |
| Path traversal detected                    | Hard-stop (do not continue); record offending route in summary; exit 2.               |
| Backup failure during overwrite            | Hard-stop; exit 2 with the failure detail.                                            |
| All routes processed successfully          | Write summary; exit 0; proceed to Stage 02.                                           |

---

## 1.11 Error & Rescue Map (referenced by spec)

| Error type                   | When raised                                                    | Recovery action                            | User sees                                          |
| ---------------------------- | -------------------------------------------------------------- | ------------------------------------------ | -------------------------------------------------- |
| `RoutesFileMissingError`     | routes.json absent at stage start                              | Abort, point to Stage 00                   | "Stage 00 did not complete — no routes.json"       |
| `PlaceholderResolutionError` | Route entry is missing a required field (e.g., `segment_name`) | Mark route failed, skip, continue          | "Route /users/[id] skipped — missing segment_name" |
| `PathTraversalError`         | Output path escapes `{{test_dir}}`                             | Hard-stop stage, record in summary, exit 2 | "Refusing to write outside test_dir — see summary" |
| `BackupFailedError`          | Cannot create `.backup-<timestamp>` sibling before overwrite   | Hard-stop stage, exit 2, do NOT write      | "Backup failed for <path> — overwrite aborted"     |
| `SkipExistingNote`           | File exists and `--overwrite` is OFF                           | Record `action: "skipped"`, continue       | Summary row: "skipped (exists)"                    |
| `UnsupportedFallbackRender`  | Processing `routes-unknown` fallback from Stage 00             | Render fallback spec only (no page object) | Summary row: "routes-unknown.spec.ts (fallback)"   |

---

## 1.12 Invocation examples

```
# Default — skip existing files (safe on re-run)
/qa-backfill

# Overwrite existing stubs with fresh templates (each overwrite creates a .backup-<timestamp>)
/qa-backfill --overwrite
```

Overwrite is a DEFENSE-IN-DEPTH operation, not routine: `/qa-backfill` is designed to be re-run idempotently as the user adds new routes to the app, not to replace human-edited specs. Users whose stubs have been promoted to `@backfilled` should NOT re-run with `--overwrite` — the backup sibling is a safety net, not a substitute for version control.
