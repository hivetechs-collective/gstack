# /plan-w-team Versioning Policy

The `/plan-w-team` skill follows [Semantic Versioning 2.0](https://semver.org/).
The active version is the single line in
[`.claude/commands/plan-w-team/VERSION`](../VERSION); release notes live in
[`.claude/commands/plan-w-team/CHANGELOG.md`](../CHANGELOG.md).

Every `/plan-w-team` run records the version it was launched against, plus
the git short-SHA of the active commit, into the run's goal-state JSON:

```json
{
  "slug": "…",
  "skill_version": "1.0.0",
  "skill_commit_sha": "abc1234",
  "…": "…"
}
```

This lets any bug surfaced post-hoc be traced back to the exact /plan-w-team
release that produced it — across all spawn paths (`--launch`,
`--worker-only`, `--supervisor-goal`) — without needing to dig through the
worker session transcript.

## Bump Kinds

| Bump  | When                                                                                                                                                                                                                                                                                                                  |
| ----- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| MAJOR | A change breaks the pipeline contract: a stage file is removed, a hard-gate pause site changes its name/format, the supervisor decision protocol changes in a way that makes pre-bump worker sessions un-resumable, or a state-artifact schema field is renamed/removed without a back-compat read path.              |
| MINOR | A new stage is added; a new agent role is introduced; a new opt-in flag is added to `pwt-goal.sh`; a new hook is added to the supervisor/evaluator surface; a new state artifact is introduced; the AC roll-up format gains a new key. Pre-bump worker sessions continue to function — the change is purely additive. |
| PATCH | A bug is fixed without changing any documented contract; a test is added/strengthened; documentation in `shared/*.md` is clarified; a stage prompt is edited for tone without altering the prompt's behavioral instructions.                                                                                          |

## Conventional Commit Mapping

The `.claude/hooks/pre-commit-pwt-version-bump.sh` hook auto-bumps `VERSION`
based on the conventional-commit prefix of any commit that touches
`.claude/commands/plan-w-team/**` or `.claude/scripts/pwt-goal.sh`:

| Prefix                                                                                      | Bump  |
| ------------------------------------------------------------------------------------------- | ----- |
| `feat(...)!:` / `BREAKING CHANGE` body trailer                                              | MAJOR |
| `feat(...):`                                                                                | MINOR |
| `fix(...):` / `docs(...):` / `chore(...):` / `refactor(...):` / `test(...):` / `perf(...):` | PATCH |

A commit message that doesn't match any conventional-commit prefix is treated
as PATCH (the conservative default — never silently MAJOR).

If a commit explicitly bumps `VERSION` already (the hook detects this by
checking whether `VERSION` is staged), the hook is a no-op.

## Where the Version Surfaces

| Surface                                                                          | Field(s)                                                         |
| -------------------------------------------------------------------------------- | ---------------------------------------------------------------- |
| `.claude/state/plan-w-team-goal-<SLUG>.json` (supervisor mirror)                 | `skill_version`, `skill_commit_sha`                              |
| `.claude/state/plan-w-team-skill-version-<SLUG>.json` (spawn sidecar, all paths) | `skill_version`, `skill_commit_sha`, `recorded_at`, `spawn_path` |
| `.claude/state/plan-w-team-completion-<SLUG>.json` (retro)                       | `skill_version`, `skill_commit_sha`                              |
| `.claude/state/plan-w-team-completion-<SLUG>.md` (retro)                         | Listed in the "Skill version" header line                        |

## Backfill Policy

`CHANGELOG.md` was created at version `1.0.0` on 2026-05-22. Earlier work is
captured in `git log --oneline` but is not back-ported into the changelog —
the policy is forward-only from `1.0.0`.

## Why we don't bump on every commit

The hook only bumps when the commit touches:

- `.claude/commands/plan-w-team/**` (stages, shared docs, manifests, version files)
- `.claude/scripts/pwt-goal.sh` (the launcher itself)

State-only commits, hook tweaks unrelated to `/plan-w-team`, test infra, or
unrelated repo changes do **not** bump the version — bumping should reflect a
change in the skill's observable behavior.
