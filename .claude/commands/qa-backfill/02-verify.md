# Stage 02 — Verify emitted stubs and print the final summary

**Prerequisites:** Stage 01 completed; `.claude/state/qa-backfill-emit-summary.json` exists and parses.
**Purpose:** confirm the emit summary matches files on disk, best-effort type-check the rendered specs, and print the one-line final status (the AC10 contract).

---

## 2.1 Prerequisites

Read `.claude/state/qa-backfill-emit-summary.json`.

| State                 | Outcome                                                                            |
| --------------------- | ---------------------------------------------------------------------------------- |
| File absent           | Exit 2 with "Stage 01 did not complete. Re-run `/qa-backfill` from the beginning." |
| JSON parse fails      | Exit 2 with parse error + path.                                                    |
| File present + parses | Proceed.                                                                           |

Also read `.claude/qa-profile.json` to confirm `framework` matches the framework in `.claude/state/qa-backfill-routes.json` (drift sentinel — if someone edited qa-profile between Stage 00 and Stage 02, warn but do not fail).

---

## 2.2 Drift check — summary vs disk

For every `per_route[].spec.path` and `per_route[].page_object.path` in the summary:

1. Assert the file exists on disk (unless `action == "failed"`).
2. Assert the file size > 0 bytes.
3. Record any missing/empty files as `drift_entries[]`.

If `drift_entries` is non-empty after the sweep, downgrade the run status to `fail`: the summary said a file was written but the filesystem disagrees.

Also glob `{{test_dir}}/backfilled/*.spec.ts` and `{{test_dir}}/pages/backfilled/*.page.ts` for **orphans** — files that exist on disk but are NOT in the summary (possible from a previous run with different routes). Record but do NOT delete — orphans are the user's call. Note them in the final summary.

---

## 2.3 Best-effort type check

Run TypeScript compilation on the emitted specs. This is best-effort and never the sole reason to fail the stage.

### Probe for `tsc`

| Check                          | Outcome                                                                   |
| ------------------------------ | ------------------------------------------------------------------------- |
| `node_modules/.bin/tsc` exists | Use it directly.                                                          |
| `npx tsc --version` succeeds   | Use `npx tsc`.                                                            |
| Neither                        | Emit `TscMissingWarning`: record `typecheck: "skipped_no_tsc"`. Continue. |

### Execute

When `tsc` is available, run:

```
<tsc> --noEmit --skipLibCheck \
      --jsx preserve --moduleResolution bundler --module esnext --target es2022 \
      --strict false \
      <every spec path from summary> <every page object path from summary>
```

Rationale: `--noEmit` prevents accidental `.js` output. `--skipLibCheck` keeps runtime under ~5s on medium repos. We pass CLI flags (not the repo's tsconfig) to avoid surprise failures from unrelated project strictness — the goal is "did our stubs parse as valid TypeScript," not "does the whole repo compile."

Capture stdout+stderr. Classify:

| tsc exit code | Interpretation                                         | verify outcome                           |
| ------------- | ------------------------------------------------------ | ---------------------------------------- |
| 0             | All stubs parse cleanly                                | `typecheck: "pass"`                      |
| ≠ 0           | At least one stub has a type error                     | `typecheck: "fail"` + error list printed |
| timeout (30s) | Type check ran long — record but do not fail the stage | `typecheck: "timeout"` — warn only       |

Type-check failure is informational — the fallback-stub framework path (`routes-unknown`) or un-renamed `@playwright/test` imports can legitimately error before the user installs deps. Record, print, and continue to the final summary.

---

## 2.4 Final summary (AC10 contract)

This line's format is **load-bearing** — changing it breaks AC10. Read the spec before editing.

Count from the emit summary:

- `N` = total routes discovered (len of `per_route`)
- `W` = count where `spec.action == "written"` (counted once per route — page-object written alongside is implied)
- `S` = count where `spec.action == "skipped"`
- `O` = count where `spec.action == "overwritten"`
- `U` = count where `spec.action == "unchanged"`
- `E` = count where `spec.action == "failed"`

Print the one-line status:

```
qa-backfill complete: <N> routes discovered, <W> stubs written, <S> stubs skipped (existing), <E> stubs failed. Next: <next-command>
```

`<next-command>` is selected via this decision order:

| Condition                                          | `<next-command>` value                                                                                                                             |
| -------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------- |
| Framework is `unsupported`                         | `Manually document routes (see README §unsupported) or run `/plan-w-team` with a 'routes-unknown backfill' feature to fill in via AST analysis.`   |
| `W == 0` and `S == N` (every stub already existed) | `All routes already have stubs. Re-run with --overwrite to refresh, or use `/plan-w-team` to author assertions.`                                   |
| `W > 0` (anything written) with framework known    | `Run `npx playwright test {{test_dir}}/backfilled/`to confirm smoke tests pass, then use`/plan-w-team` to author assertions for the @stub specs.`  |
| `E > 0`                                            | Above next-command is still printed, but prefix with `⚠ <E> stubs failed — inspect .claude/state/qa-backfill-emit-summary.json before proceeding.` |

`O` (overwritten) and `U` (unchanged) are reported in a supplemental line when non-zero:

```
  overwritten: <O> (backups in .backup-<timestamp>)   unchanged: <U>
```

---

## 2.5 Verbose output

Full stage output:

```
/qa-backfill — Stage 02 (verify) complete
  Emit summary:      .claude/state/qa-backfill-emit-summary.json
  Drift sweep:       OK (no missing files, 0 orphans)
  Type check:        pass (via node_modules/.bin/tsc)

qa-backfill complete: 8 routes discovered, 6 stubs written, 2 stubs skipped (existing), 0 stubs failed. Next: Run `npx playwright test tests/e2e/backfilled/` to confirm smoke tests pass, then use `/plan-w-team` to author assertions for the @stub specs.
```

On an unsupported run:

```
/qa-backfill — Stage 02 (verify) complete
  Emit summary:      .claude/state/qa-backfill-emit-summary.json
  Drift sweep:       OK (1 routes-unknown stub written)
  Type check:        skipped_no_tsc

qa-backfill complete: 1 routes discovered, 1 stubs written, 0 stubs skipped (existing), 0 stubs failed. Next: Manually document routes (see README §unsupported) or run `/plan-w-team` with a 'routes-unknown backfill' feature to fill in via AST analysis.
```

---

## 2.6 Exit conditions

| Condition                                                        | Exit                                             |
| ---------------------------------------------------------------- | ------------------------------------------------ |
| `emit-summary.json` missing                                      | Exit 2 with Stage 01 pointer.                    |
| `emit-summary.json` unparseable                                  | Exit 2 with parse error.                         |
| Drift entries present (summary says written, file missing/empty) | Exit 1 (fail).                                   |
| Any `per_route[].action == "failed"`                             | Exit 1 (fail) — but print final summary first.   |
| Type check fails                                                 | Exit 0 (warn) — type failures are informational. |
| All clean                                                        | Exit 0. Print summary + next-command hint.       |

Deliberate choice: Stage 02 does **not** delete the state artifacts. They remain under `.claude/state/` for the user or `/plan-w-team` to consult. A subsequent invocation of `/qa-backfill` overwrites them cleanly.
