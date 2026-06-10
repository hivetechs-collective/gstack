# Build cleanup — preserve installables, clean only intermediates

**Status:** active · **Since:** /plan-w-team 1.28.0 · **Origin:** cleanscale incident, 2026-06-02

A build-cleanup deleted an iOS Simulator `.app` together with its ~931 MB
`ios/build` intermediates, on the cofounder-demo critical path, forcing a 30-min
rebuild. The intermediates were ~90%+ of the footprint and _should_ be reclaimed;
the reusable `.app` should have been **kept**. This policy encodes that lesson so
cleanup never re-pays build time for a final artifact again.

## The rule

| Class                                                                                                                                                                  | Action                        | Why                                                                                                                                                        |
| ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **FINAL installables** — `*.app`, `*.ipa`, `*.apk`, `*.aab`                                                                                                            | **PRESERVE** (relocate, keep) | Small (tens–~150 MB), reusable for installs, demo recordings, Maestro/Playwright walks. Not regenerable without a multi-minute build on the critical path. |
| **INTERMEDIATES** — `ios/Pods`, `*/DerivedData`, `ios/build/*` intermediates, `android/.gradle`, `android/app/build/intermediates`, `*.o`, `target/`, `.next/cache`, … | **CLEAN** (and only these)    | These are the GBs and regenerate deterministically from source. Reclaiming them is the entire point of build hygiene.                                      |

> **Posture: preserve by default.** Treat anything matching an installable
> extension as keep-worthy "unless really qualified" as a pure intermediate.

## The kept-artifacts home

Final installables are relocated to a **protected kept-artifacts home** that
cleanup must **never** touch.

- **Configurable** via `PWT_KEPT_ARTIFACTS_HOME`.
  - Absolute path → used as-is.
  - Relative path → resolved under the **repo root** (the main checkout), so a
    relocated artifact survives a per-merge worktree removal.
- **Default:** `.playwright-mcp/` (mirrors cleanscale's choice — the same
  gitignored home already used for demo/QA assets).
- **Layout:** relocated artifacts land at
  `<home>/kept-build-artifacts/<worktree-name>/<path-relative-to-worktree>`, e.g.
  `.playwright-mcp/kept-build-artifacts/agent-a/ios/build/Debug-iphonesimulator/MyApp.app`.
- The home is **gitignored** and the newest build supersedes a prior one at the
  same relative path.

## Two enforcement layers

The same installable set (`*.app *.ipa *.apk *.aab`) and the same default home
name (`.playwright-mcp`) are used by both layers — kept consistent by a
cross-reference comment in each file and by this doc as the single source.

### 1. Proactive — `.claude/scripts/plan-w-team-build-artifact-clean.sh`

Before removing each allowlisted build dir, the cleaner scans it for installables
(`find … -prune`) and **relocates** each to the kept-artifacts home, then reclaims
the (now installable-free) intermediates. Properties:

- **Fail-safe:** if a relocation (`mv`) fails, the enclosing dir is **not**
  removed — we never lose an artifact we could not save.
- **Disk savings preserved:** reclaim is measured _after_ the small installable is
  moved out, so the reported GB figure reflects intermediates only. A `.app` inside
  a worktree `ios/build` survives a `--execute` run.
- **Home is preserve-only:** the cleaner refuses to clean the kept-artifacts home
  (or anything under it), in addition to its existing location invariant
  (worktrees only) and source invariant (never source / uncommitted work).

### 2. Reactive — `.claude/hooks/damage-control/damage-control.sh`

A hand-run or agent-run `rm -rf` is intercepted by the damage-control PreToolUse
hook. A **final-artifact guard** runs _before_ the `safe_rm_targets` allowlist
short-circuit:

- An `rm -rf` whose target **is or contains** a `*.app/*.ipa/*.apk/*.aab` →
  **ask** (require explicit confirmation/override), **even for** `build`/`dist`/`target`.
- An `rm -rf` of the **kept-artifacts home** → **block**.
- A pure-intermediate `rm -rf` (no installable present) → **allowed**, unchanged —
  the GB-reclaim path is not regressed.

The guard inspects the real filesystem, so it keys on what the target _contains_,
not on the directory's name.

## Invariants (extended, not replaced)

This policy **adds** a _final-artifact_ dimension to the cleaner's pre-existing
safety invariants; it does not weaken them:

1. **LOCATION** — cleaner operates only inside `<repo>/.claude/worktrees/`.
2. **SOURCE** — cleaner removes only the fixed regenerable-build-dir allowlist;
   never source, never uncommitted work, never the shared `node_modules` symlink.
3. **FINAL ARTIFACT** (new) — never delete a `*.app/*.ipa/*.apk/*.aab`; relocate it
   to the kept-artifacts home first; never clean that home.

## Tests

- `.claude/scripts/plan-w-team-build-artifact-clean.test.sh` — `.app`/`.ipa`/`.apk`/`.aab`
  survive `--execute`; intermediates still reclaimed (≥1 MB); home never cleaned;
  `PWT_KEPT_ARTIFACTS_HOME` override honored; dry-run moves nothing.
- `.claude/hooks/damage-control/damage-control.test.sh` — `ask` on installable-bearing
  dirs (incl. `build`/`dist`); `allow` on pure `node_modules`/`target`; `block` on the
  kept home; no false trigger on non-`rm` commands.

Both are part of the canonical skill suite (`make test-skill`).
