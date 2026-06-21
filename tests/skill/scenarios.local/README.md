# `tests/skill/scenarios.local/` — consumer-owned scenario corpus

This directory is the **ownership boundary** between the synced `/plan-w-team`
corpus and a consumer repo's own product scenarios (R5, 2026-06-09 design
review).

## Why this exists

`sync-to-project.sh` copies claude-pattern's source corpus — `tests/skill/cases/`
and `tests/skill/scenarios/` — into every consumer, then gitignores those two
paths (so the vendored copy is overwritable on checkout and never accidentally
committed). A consumer that authored its own scenario inside the synced
`tests/skill/scenarios/` therefore lands in a _tracked-yet-ignored_ trap: git
keeps a stale tracked copy and silently overwrites it on the next checkout. That
is exactly how the dmarc-monitor incident shipped — a consumer scenario stamped
a live `.claude/state` watermark and nobody owned it.

`scenarios.local/` is a **sibling** of `scenarios/` (never a child — a nested
dir would be reaped by the `tests/skill` rsync under GNU `--delete`). The
consumer-gitignore self-heal ignores `tests/skill/scenarios/` with a trailing
slash, which does **not** match `scenarios.local/`, so this dir stays **tracked
by the consumer** with zero gitignore change. The sync never untracks files
here: the reconciliation step computes the source-owned set live from
claude-pattern's own `git ls-files tests/skill/cases tests/skill/scenarios`, and
nothing in `scenarios.local/` is ever in that set.

## Rules for consumer scenarios placed here

1. **Author product/E2E scenarios here**, not in the synced `scenarios/` dir.
2. Both runners discover this dir: `tests/skill/run.sh` (canonical, gates
   `make test-skill`) and `tests/skill/run-scenarios.sh` (the consumer
   pre-commit's dev-iteration runner). A `.bats` file dropped here runs in both.
3. **Redirect product-script state to per-test tmp.** A scenario that drives a
   product script which writes repo state MUST point that script at a sandbox
   via the existing `sandbox` helper and the `PWT_PROJECT_ROOT_OVERRIDE`
   contract — never let it touch the live `.claude/state` tree (the R6
   state-leak guard fails the run if it does). See `../CONVENTIONS.md`
   §"Consumer scenarios (`scenarios.local/`)".

In claude-pattern itself this directory is intentionally empty of scenarios —
the source's own corpus lives in `cases/` and `scenarios/`. It ships as scaffold
so consumers inherit the boundary.
