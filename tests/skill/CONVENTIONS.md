# /plan-w-team Test Harness — Conventions

**Stack-agnostic by design**: this bats harness tests the `/plan-w-team` skill's own bash tooling — not your product. Product test runners (jest, pytest, cargo test, go test, etc.) are auto-detected by Step 6 ship; pattern names like `aws` in `secret-scan.sh` refer to leaked-credential shapes (AKIA-prefix), not deployment targets.

The test harness lives at `tests/skill/`. Anti-fragmentation lock-in: there is **one harness, one runner, one `make test-skill` target**. Do not add parallel runners, alternate frameworks, or "fast-only" test subsets — every variant fragments coverage and lets regressions hide.

## End-to-End Testing Framework (TESTING-FRAMEWORK)

```mermaid
flowchart LR
    Dev[Developer edits<br/>PWT script or stage file] --> Hook[.githooks/pre-commit<br/>guard for PWT-path changes]
    Hook -->|PWT path touched| Run[tests/skill/run.sh<br/>canonical entry point]
    Hook -->|other path| Skip[skip — exit 0]

    Run --> Bootstrap[bootstrap<br/>vendored bats-core under .bats/]
    Bootstrap --> Discover[discover .bats files]
    Discover --> Cases[cases/*.bats<br/>unit tests per script]
    Discover --> Scenarios[scenarios/*.bats<br/>E2E integration<br/>via harness-shim.sh]

    Cases --> Bats[bats runner<br/>TAP output]
    Scenarios --> Shim[harness-shim.sh<br/>fake Claude Code harness]
    Shim --> Bats

    Bats --> Archive[results/runs/-ts-.json<br/>+ latest.json pointer]
    Bats --> Verdict{all pass?}
    Verdict -->|yes| Green[exit 0 — commit proceeds]
    Verdict -->|no| Red[exit 1 — commit blocked]

    classDef dev fill:#e3f2fd,stroke:#1565c0
    classDef hook fill:#fff3e0,stroke:#e65100
    classDef run fill:#f3e5f5,stroke:#6a1b9a
    classDef test fill:#e8f5e9,stroke:#2e7d32
    classDef ok fill:#c8e6c9,stroke:#2e7d32
    classDef bad fill:#ffebee,stroke:#c62828
    class Dev dev
    class Hook,Skip hook
    class Run,Bootstrap,Discover,Bats,Archive run
    class Cases,Scenarios,Shim test
    class Green ok
    class Red bad
```

**Reading the diagram:** every PWT-touching edit goes through `tests/skill/run.sh`. The pre-commit hook (`.githooks/pre-commit`) is the gate; `harness-shim.sh` is the fake harness that lets scenarios test the route hook → worker spawn → systemMessage delivery flow without spinning up real `claude --bg` processes. As of 2026-05-21 the suite is at **99 tests** (8 case files + 5 scenario files). Adding a behavior that crosses the hook ↔ /goal boundary belongs in `scenarios/`; everything else belongs in `cases/<script>.bats`.

## Layout

```
tests/skill/
├── run.sh                    # single canonical entry point (auto-bootstraps bats-core)
├── run-scenarios.sh          # dev-iteration sub-runner for scenarios/ only (NOT canonical)
├── harness-shim.sh           # fake Claude Code harness used by scenarios/
├── CONVENTIONS.md            # this file
├── helpers/
│   ├── test_helper.bash      # sandbox, assertions, repo paths
│   └── scenario_helper.bash  # scenario-specific helpers (run_shim, assert_simctx_*)
├── cases/
│   ├── secret-doc-sync.bats  # one .bats file per script under test
│   ├── snippet-lint.bats
│   ├── symmetry-check.bats
│   ├── harness-shim.bats     # unit tests for harness-shim.sh
│   └── r2-sentinels.bats     # regression suite for known-fixed defects
├── scenarios/                # E2E integration scenarios (hook → harness → /goal)
│   ├── imperative-nl-one-worker.bats
│   ├── descriptive-prose-zero-workers.bats
│   ├── goal-cap-aborts-spawn.bats
│   └── worker-self-cleanup.bats
├── results/
│   ├── latest.json           # pointer to most recent run
│   └── runs/
│       └── 2026-04-18T19-50-00Z.json    # per-run archive
└── .bats/                    # vendored bats-core (gitignored, auto-cloned)
```

### `cases/` vs `scenarios/` — when to put a test where

- **`cases/<script>.bats`** — unit tests for one shell script under
  `.claude/scripts/` or `.claude/hooks/`. Sandbox the script, feed it
  fixtures, assert exit codes and output. Deterministic, no spawn,
  fast. The original 63+ tests live here.

- **`scenarios/<name>.bats`** — E2E integration tests that exercise
  the _path_ between hook, harness, manifest, `pwt-goal.sh`, and the
  `/goal` evaluator. They use `harness-shim.sh` (the fake Claude Code
  harness) to feed a real user-prompt fixture through the actual
  shipping hook and assert on the simulated assistant context the shim
  emits. Add a scenario when a bug ships past `cases/` — the scenario
  is the runnable regression test that proves the integration is
  preserved across hook/manifest/script refactors. Authored to mirror
  Playwright-style flow tests.

### `harness-shim.sh` — the authoritative simulator

`harness-shim.sh` is the fake Claude Code harness used by every scenario.
It pins the **harness delivery contract** that scenarios assert against:

| Hook stdout field   | Harness behavior                                                    |
| ------------------- | ------------------------------------------------------------------- |
| `systemMessage`     | DELIVERED to assistant as a `hook_system_message` attachment        |
| `additionalContext` | **DROPPED** (confirmed 2026-05-21 in v2.1.148 — 0 of 20 deliveries) |
| `decision`          | Pass-through metadata                                               |

If Claude Code's harness behavior changes in a future release, **update
the shim AND the contract table here in lockstep**. Scenarios are
authored against the shim, not against the real harness directly, so
the shim is the single point of contract maintenance.

## Running

```bash
# Run everything (default)
tests/skill/run.sh
# or
make test-skill

# Run a single file (DEV ITERATION ONLY — never replaces full run)
tests/skill/run.sh cases/secret-doc-sync.bats

# Run only the E2E scenarios subset (DEV ITERATION ONLY — pre-commit calls run.sh)
tests/skill/run-scenarios.sh
tests/skill/run-scenarios.sh imperative-nl-one-worker.bats   # single scenario

# Bootstrap bats without running tests
tests/skill/run.sh --setup
```

### Why `run-scenarios.sh` is NOT a parallel runner

It might look like `run-scenarios.sh` violates the anti-fragmentation
lock-in. It does not:

- `tests/skill/run.sh` is the **only** canonical runner. It discovers
  both `cases/` and `scenarios/` and runs them as one suite. Pre-commit
  (`.githooks/pre-commit`) and `make test-skill` invoke `run.sh`, not
  `run-scenarios.sh`.
- `run-scenarios.sh` exists for one purpose: fast iteration on the
  E2E subset while authoring a new scenario. It does not have an
  alternate discovery rule, an alternate filter ("only fast scenarios"),
  or an alternate archival format.
- Adding a `test-skill-fast`, `test-skill-changed-only`, or any other
  subset-with-filter target IS forbidden — that is the original
  anti-fragmentation rule unchanged.

If you find yourself wanting "just run X and skip Y", run
`tests/skill/run.sh path/to/file.bats` (the single-file dev shortcut
already supported by the canonical runner) — do not add a new
runner script.

### Pre-commit guard (`.githooks/pre-commit`)

Activate with:

```bash
git config core.hooksPath .githooks
```

The hook refuses commits that stage any file under:

- `.claude/commands/plan-w-team*`
- `.claude/hooks/plan-w-team-*`
- `.claude/scripts/pwt-goal*`

unless `tests/skill/run.sh` exits 0. Bypass with `git commit
--no-verify` (use sparingly — every bypass is an unprotected change to
the skill that runs your autonomous /plan-w-team sessions).

The runner archives every full run to `results/runs/<timestamp>.json` and updates `results/latest.json`. This produces a longitudinal record so you can answer "did this start failing today, or has it been flaky for a week?" without re-running history.

`make test-skill` is the contract used by pre-commit (when `/plan-w-team` files are staged) and by the ship-gate review. There is intentionally no `test-skill-quick` or `test-skill-changed-only` target — the cost of a full run is small and the cost of a missed regression is large.

## BDD Test Naming

Every `@test` description follows this shape:

```
@test "<component>: given <precondition>, when <action>, then <outcome>" {
  ...
}
```

Examples:

```bash
@test "secret-doc-sync: given scanner has 18 patterns, when sync runs, then doc shows 18 rows" { ... }
@test "secret-doc-sync: given doc is in sync, when --check runs, then exit code is 0" { ... }
@test "secret-doc-sync: given pattern added to scanner, when --check runs, then exit code is 1" { ... }
@test "snippet-lint: given a malformed bash block, when lint runs, then it reports file:block-index" { ... }
@test "symmetry-check: given orphan reader path, when check runs, then exit code is 4" { ... }
```

Why this shape:

- **`<component>`** scopes the test to one script, making failure triage instant. A failure in `secret-doc-sync: ...` points straight at `secret-doc-sync.sh` — no detective work.
- **`given/when/then`** forces the author to articulate the precondition (the setup the test needs) and the outcome (the assertion). If you can't state both clearly, the test is probably untestable as designed.
- **One assertion per concept** per test. Multi-assertion tests obscure which condition broke. If you need to verify three properties of one outcome, write three tests sharing a setup helper.

This convention is enforced by R-10 (the `r2-sentinels.bats` greps for the `<comp>: given X, when Y, then Z` pattern across all .bats files; tests not matching are flagged in CI). If you have a legitimate reason to break the convention, document it in the test body comment.

## Sandbox Discipline

Tests that mutate state MUST use the `sandbox` helper:

```bash
setup() {
  load "$BATS_TEST_DIRNAME/../helpers/test_helper.bash"
  sandbox            # cd to fresh tmp dir, exports SANDBOX_DIR
  sandbox_git_init   # if the script under test needs a git repo
}

teardown() {
  teardown_sandbox   # safety-checks path is under /tmp, then rm -rf
}
```

Never write to `$REPO_ROOT` from a test. The harness verifies this — any test that creates a file outside `$SANDBOX_DIR` fails the sandbox audit.

## What to Cover

- **Helper scripts** (`secret-scan.sh`, `secret-doc-sync.sh`, `plan-w-team-snippet-lint.sh`, `plan-w-team-symmetry-check.sh`, `board.sh`): every documented exit code, plus the happy path.
- **R2 sentinels** (`r2-sentinels.bats`): one test per known-fixed defect (R2-1 through R2-7 from the original `/plan-w-team-followups` retro). These guard against regression of bugs we've already paid to find.
- **NOT covered**: LLM-driven prompts, agent reasoning, scope-challenge subjective decisions. The harness is for deterministic shell behavior only.

## Adding a Test

1. Pick the right `.bats` file (or create `cases/<script>.bats` for a new script).
2. Use the BDD naming convention.
3. Use the sandbox helpers — never touch `$REPO_ROOT`.
4. Run `tests/skill/run.sh cases/<file>.bats` for fast iteration.
5. **Before commit**: run `tests/skill/run.sh` (full suite) — pre-commit will too.
