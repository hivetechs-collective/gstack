# Step 6: Ship

After review passes, execute the ship pipeline.

## 6-0. Ship Gate: Untracked File Classification (MANDATORY)

**This runs before any commit work.** Load `.claude/commands/plan-w-team/shared/untracked-hygiene.md` if you have not already — it contains the full decision matrix, IGNORE pattern guidance, the DISCARD value-carrier guard, and worked examples for the two real-world cases (parts pipeline, claude-pattern obs-\*.png).

### Compute the classification set

```bash
SLUG="<feature-slug>"  # same slug used in preflight
BASELINE=".claude/state/plan-w-team-untracked-baseline-$SLUG.txt"

if [ ! -f "$BASELINE" ]; then
  echo "⚠ Ship gate skipped: no baseline at $BASELINE"
  echo "  Reason: likely --ship-only or --resume run. Hygiene cannot be verified."
  echo "  Retro will note: hygiene-skipped"
  # Continue ship in degraded mode — do not fail
else
  CURRENT=$(git ls-files --others --exclude-standard | sort)
  CLASSIFICATION_SET=$(echo "$CURRENT" | comm -23 - "$BASELINE")

  if [ -z "$CLASSIFICATION_SET" ]; then
    echo "✓ untracked hygiene: clean (0 new untracked files)"
    # Silent pass, proceed to 6a
  else
    COUNT=$(echo "$CLASSIFICATION_SET" | wc -l | tr -d ' ')
    echo "Ship gate: $COUNT new untracked files need classification"
    echo "$CLASSIFICATION_SET"
    # Enter classification loop below
  fi
fi
```

### Classify every entry

For EACH file in the classification set, pick exactly ONE of: **COMMIT**, **IGNORE**, **DISCARD**, **DEFER**. The decision matrix, guidance, and guard rules live in `shared/untracked-hygiene.md` — do not reinvent them here.

Apply decisions as you go:

- **COMMIT** → `git add <path>`
- **IGNORE** → append the narrowest covering pattern to `.gitignore` (check for duplicates first), stage `.gitignore`, do NOT stage the file
- **DISCARD** → `rm <path>` subject to the value-carrier guard (extensions `.md .txt .json .html .yml .yaml .sql .py .ts .tsx .rs .go` require a second explicit "discard anyway?" confirmation)
- **DEFER** → leave untouched, record `{path, reason}` for Step 8 retro

### Verify and refuse

After applying all decisions, recompute the diff and confirm nothing is left unclassified (except DEFER entries):

```bash
REMAINING=$(git ls-files --others --exclude-standard | sort | comm -23 - "$BASELINE")
# Subtract known DEFER set (tracked in retro state file)
# If REMAINING still has entries not in DEFER set → fail:
```

```
✗ Cannot ship: N untracked files undecided:
  - path/to/file1
  - path/to/file2
Every entry must be COMMIT, IGNORE, DISCARD, or DEFER. Refusing final commit.
```

**Do not proceed to 6a if the gate fails.** Loop back, resolve the remaining entries, and re-verify. DEFER is the escape hatch, not the default — heavy use of DEFER scores poorly in the retro.

### Record the classification summary

Write the summary to `.claude/state/plan-w-team-retro-$SLUG.json` (or append to the existing retro artifact if one exists):

```json
{
  "untracked_hygiene": {
    "baseline_size": 0,
    "classification_set_size": 12,
    "resolved": { "commit": 0, "ignore": 12, "discard": 0, "defer": 0 },
    "gitignore_patterns_added": ["/obs-*.png"],
    "deferrals": []
  }
}
```

Step 8 retro reads this file to score the hygiene dimension.

## Board Update (Auto)

After successful ship (tests pass, committed, pushed), move the feature card to Done and add a ship summary. Fire-and-forget — failures must NOT block the ship.

```bash
scripts/board.sh move "<feature-name>" "Done" || true

# Add ship summary with PR link and test results
scripts/board.sh comment "<feature-name>" "## Shipped

**PR:** <PR URL or 'committed directly to main'>
**Tests:** <pass count> passing, coverage ★★★/★★/★
**Commits:** <count> bisectable commits
**Version:** <version if bumped>
**Shipped:** $(date -u +%Y-%m-%dT%H:%M:%SZ)" || true
```

## 6a. Review Readiness Check

Verify Step 5 review is complete. If not, run it first. Track review completion in task metadata.

If the user wants to override a missing review, store the override decision (read `shared/artifact-storage.md` for override persistence format) so re-runs of `/plan-w-team` on the same branch do not re-ask.

### Re-read persisted review findings (ENFORCING)

Step 5 §5h wrote `.claude/state/plan-w-team-review-findings-$SLUG.md` with frontmatter declaring whether every Pass-1 CRITICAL was resolved. Verify the contract before proceeding to any other gate.

```bash
FINDINGS=".claude/state/plan-w-team-review-findings-$SLUG.md"

if [ ! -f "$FINDINGS" ]; then
  cat <<'EOF'
✗ SHIP BLOCKED: no review-findings artifact found.
  Step 5 must have written .claude/state/plan-w-team-review-findings-$SLUG.md
  before Step 6 runs. Either re-run Step 5, or — if you intentionally skipped
  review — write the file by hand and set all_critical_resolved: true.
EOF
  exit 1
fi

ALL_RESOLVED=$(awk '/^all_critical_resolved:/{print $2}' "$FINDINGS")
CRITICAL_COUNT=$(awk '/^critical_count:/{print $2}' "$FINDINGS")

if [ "$ALL_RESOLVED" != "true" ]; then
  cat <<EOF
✗ SHIP BLOCKED: review findings declare unresolved CRITICAL items.
  $FINDINGS shows critical_count=$CRITICAL_COUNT but all_critical_resolved=$ALL_RESOLVED.
  Resolve each CRITICAL with a "→ resolved in <sha>" marker or "→ DEFERRED" with user ack,
  then re-run Step 5 §5h to refresh the file before retrying ship.
EOF
  exit 1
fi

echo "✓ review findings: $CRITICAL_COUNT critical, all resolved"
```

**Why this gate exists**: prior to this artifact, "review is complete" was a verbal claim that died at session boundaries. A compaction between Step 5 and Step 6 meant Step 6 had no way to verify CRITICALs were addressed and would happily ship a branch with known blockers.

## 6a-bis. Scope Lock Enforcement (ENFORCING GATE)

Step 2 wrote `.claude/state/plan-w-team-scope-lock-$SLUG.json` with the task set at planning time. Before shipping, verify no silent scope expansion occurred.

```bash
LOCK=".claude/state/plan-w-team-scope-lock-$SLUG.json"
UNLOCK=".claude/state/plan-w-team-scope-unlock-$SLUG"

if [ ! -f "$LOCK" ]; then
  echo "⚠ No scope lock at $LOCK (likely --ship-only or pre-lock feature)"
  echo "  Scope drift cannot be verified. Retro will note: scope-unverified"
else
  LOCKED_COUNT=$(jq -r '.task_count' "$LOCK")
  # Count tasks actually shipped in this feature.
  # Three concrete strategies (pick the one your task tooling supports — all read-only, no pseudocode):
  #
  # Strategy A (preferred — works without a task DB): grep commit messages on the feature branch
  # for the locked task IDs. Each task gets at least one commit referencing its ID; count unique IDs.
  BASE_REF="origin/${BASE_BRANCH:-main}"
  LOCKED_IDS=$(jq -r '.tasks[].id' "$LOCK")
  SHIPPED_COUNT=$(
    git log "$BASE_REF..HEAD" --pretty=%B \
      | grep -oE '(task[-_]?[0-9]+|#[0-9]+|T[0-9]+)' \
      | sort -u \
      | grep -cFf <(printf '%s\n' $LOCKED_IDS)
  )
  # Strategy B (if you persist task metadata): list tasks whose metadata.spec_path matches the
  # current spec, e.g. `jq -r '.[] | select(.metadata.spec_path=="'"$SPEC"'") | .id' ~/.claude/tasks/*.json | wc -l`
  # Strategy C (last resort): count commits with the spec slug in the subject line:
  #   git log "$BASE_REF..HEAD" --pretty=%s | grep -cE "(\($SLUG\)|: $SLUG[: ])"
  # Strategy A is preferred because it survives task-DB migration and works on a fresh clone.

  if [ "$SHIPPED_COUNT" -ne "$LOCKED_COUNT" ]; then
    if [ -f "$UNLOCK" ]; then
      echo "✓ Scope expanded from $LOCKED_COUNT → $SHIPPED_COUNT tasks (unlock ack present)"
    else
      cat <<EOF
✗ SHIP BLOCKED: scope drift detected
  Locked at planning: $LOCKED_COUNT tasks
  Shipping now:       $SHIPPED_COUNT tasks
  New tasks added mid-flight — confirm this was intentional.
  To override: touch "$UNLOCK"
EOF
      exit 1
    fi
  fi

  # Verify scoped files — did any task modify files outside its declared scope?
  # (Compares git diff to the locked tasks[].scope tags)
  LOCKED_SCOPES=$(jq -r '.tasks[].scope' "$LOCK" | sort -u)
  # Inspect `git diff --name-only origin/<base>...HEAD` against scope-to-path heuristics
  # (e.g. FRONTEND should not touch src/db/, DATABASE should not touch components/)
  # Flag any crossover as ASK — do not auto-fail (heuristics have false positives).
fi
```

The gate is **enforcing** on task count drift (exit 1) and **advisory** on scope-tag crossover (ASK prompt). Scope-tag heuristics are too lossy to fail-close on — flag them for the user.

## 6a-ter. Secret Leak Scan (ENFORCING GATE)

Before committing or pushing, scan the about-to-ship content for live-shape credentials. This is the third and final layer of the defense-in-depth model (pre-commit hook → ship gate → sync filter) described in `shared/secret-safety.md`.

The gate runs the shared scanner at `.claude/scripts/secret-scan.sh` in two modes:

1. **`--staged`** — anything currently staged for the final commit
2. **`--diff origin/<base>..HEAD`** — every added line across the feature branch that is about to be pushed

Both must pass. The scanner fails closed on pattern shape — it cannot distinguish a revoked key from a live one, and that is the correct posture.

```bash
SCANNER=".claude/scripts/secret-scan.sh"
BASE_REF="origin/${BASE_BRANCH:-main}"
ALLOW_FILE=".claude/state/plan-w-team-secret-scan-allow-$SLUG"
ALLOW_ARGS=()
[ -f "$ALLOW_FILE" ] && ALLOW_ARGS=(--allow "$ALLOW_FILE")

# Layer 1: staged content
if ! "$SCANNER" "${ALLOW_ARGS[@]}" --staged; then
  echo "✗ Ship gate 6a-ter: live-shape secret(s) detected in staged content."
  echo "  This is fail-closed on pattern shape. If you believe this is a false"
  echo "  positive (for example a test fixture for a revoked key that must"
  echo "  remain in the repo), see 'Override for false positives' below."
  exit 1
fi

# Layer 2: diff range across the branch
if ! "$SCANNER" "${ALLOW_ARGS[@]}" --diff "$BASE_REF..HEAD"; then
  echo "✗ Ship gate 6a-ter: live-shape secret(s) detected in commits $BASE_REF..HEAD."
  echo "  A prior commit on this branch introduced a secret. This is not"
  echo "  fixable by un-staging — git history must be rewritten before push."
  echo "  See shared/secret-safety.md §'History rewrite' for the runbook."
  exit 1
fi
```

### Failure modes and what they mean

| Scanner output               | What it means                                           | What to do                                                                                                                                |
| ---------------------------- | ------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------- |
| `LIVE SECRET: <file>:<line>` | Pattern-shape match not suppressed by placeholder rules | Remove the value, rotate the credential upstream, re-stage. If test fixture, see override below.                                          |
| Exit 1 on `--staged` only    | Secret is in the final commit's staging area            | `git reset HEAD <file>` + remediate, then re-stage clean content.                                                                         |
| Exit 1 on `--diff` only      | Secret is in an earlier commit on this branch           | History rewrite required. Run `git filter-repo --replace-text` or rebase to edit the offending commit. Force-push must be explicit.       |
| Exit 2                       | Scanner itself errored (bad args, internal failure)     | Read stderr. This is a scanner bug or a bad invocation — do NOT bypass by touching the allow file. Fix the scanner invocation and re-run. |

### Override for false positives (documented, rare)

Some test fixtures legitimately embed revoked pattern-shape credentials (for example, a regression test that asserts the scanner still catches a known-revoked Stripe test key). For these, create an allow file naming the exact `file:line:pattern` triples to suppress:

```bash
# .claude/state/plan-w-team-secret-scan-allow-<slug>
# One finding per line, format: path:line:pattern-name
# Every entry MUST carry an inline justification.
tests/fixtures/revoked-stripe.txt:7:stripe-live-secret  # revoked 2026-01-01, kept for regression test
```

**Allow-file comment sanitization (MANDATORY)**: comments inside the allow file must NOT contain literal pattern-shape values — describe them indirectly. Example: write `# AWS-published documentation example access key`, not the same string with the actual key identifier inlined. Reason: the scanner reads the entire allow file when staged, and a literal value in a descriptive comment will match the same pattern as a real leak — blocking the very commit that documents the exception. The justification must convey _why_ the entry is safe, not duplicate the value the entry already references. (This paragraph avoids embedding the literal example for the same reason — older downstream pre-commit hooks are not comment-aware and will block any document quoting the raw token.)

Before bypassing:

1. Rotate the credential upstream anyway (belt and suspenders — shape might still be valid).
2. Add a comment explaining why this file/line is safe to keep — using indirect language only (see sanitization rule above).
3. Re-run the gate with the allow file in place.

The allow file is checked into the repo (it documents intentional exceptions) but the entries must be reviewed during Step 5 Fix-First Review. A reviewer adding entries silently is itself a red flag.

## 6b. Run Full Test Suite (ENFORCING GATE — not a prose request)

Detect the project's test framework and run it. **The exit code is the gate.** If any command fails, refuse to ship.

```bash
# Detect test framework based on manifests (handles monorepos by recursing)
run_tests() {
  local rc=0
  if [ -f package.json ] && grep -q '"test"' package.json; then
    npm test || rc=$?
  elif [ -f Cargo.toml ]; then
    cargo test || rc=$?
  elif [ -f pyproject.toml ] || [ -f setup.py ] || [ -f pytest.ini ]; then
    pytest || rc=$?
  elif [ -f go.mod ]; then
    go test ./... || rc=$?
  else
    # Recurse into workspace subdirs (monorepos)
    local found=0
    for manifest in $(find . -maxdepth 3 -name "package.json" -o -name "Cargo.toml" -o -name "pyproject.toml" 2>/dev/null); do
      local dir
      dir=$(dirname "$manifest")
      [ "$dir" = "." ] && continue
      echo "→ running tests in $dir"
      ( cd "$dir" && run_tests ) || rc=$?
      found=1
    done
    if [ "$found" = "0" ]; then
      echo "✗ No test framework detected. Refusing to ship blind."
      return 1
    fi
  fi
  return $rc
}

if ! run_tests; then
  echo "✗ Ship gate 6b: tests failed (exit code non-zero). Refusing to ship."
  echo "  Fix the failures, then re-run /plan-w-team --ship-only."
  exit 1
fi
```

If the browse binary is available and any task has `scope: "FRONTEND"`, read `shared/browser-qa.md` for browser smoke test instructions. **Browser smoke tests are also gates** — a non-zero exit code from the browse binary blocks the ship.

## 6c. Test Coverage Audit

Rate test quality with stars, not just percentages:

| Rating | Meaning       | Criteria                                    |
| ------ | ------------- | ------------------------------------------- |
| ★★★    | Comprehensive | Behavior + edge cases + error paths covered |
| ★★     | Adequate      | Happy path + basic error cases              |
| ★      | Minimal       | Smoke test or trivial assertions only       |

A module with 90% line coverage but all ★ tests is worse than 60% coverage with ★★★ tests. Flag the distinction.

### Minimum Coverage Gate (ENFORCING)

If the project declares a coverage floor (in `package.json` `jest.coverageThreshold`, `pyproject.toml` `[tool.coverage.report] fail_under`, or `Cargo.toml` metadata `coverage_min`), **run coverage and enforce it**. Do not ship below the declared floor:

```bash
# Example: npm projects with coverage script
if [ -f package.json ] && grep -q '"coverage"' package.json; then
  if ! npm run coverage; then
    echo "✗ Ship gate 6c: coverage below declared floor. Refusing to ship."
    exit 1
  fi
fi
```

If no coverage floor is declared, this gate is skipped (the star-rating audit above is the softer check). Declaring a floor is how a project opts in to strict coverage enforcement.

**Cognitive framework**: Error budgets (Google SRE) — read `shared/cognitive-frameworks.md`.

## 6d. Version Bump (if applicable)

| Change Size       | Bump        | Decision     |
| ----------------- | ----------- | ------------ |
| <50 lines changed | MICRO/PATCH | Auto-decided |
| 50+ lines changed | PATCH       | Auto-decided |
| New feature/API   | MINOR       | Ask user     |
| Breaking change   | MAJOR       | Ask user     |

## 6e. CHANGELOG Generation

Write entries in **user-facing voice**. Apply the "sell test": would a user reading this think "oh nice, I want to try that"?

- "You can now upload photos directly from your phone" (passes sell test)
- "Refactored internal upload module" (fails sell test — rewrite)

CRITICAL: Never clobber existing CHANGELOG entries. Only add new entries and polish wording of entries from this release.

## 6f. Create Bisectable Commits

If the working tree has multiple logical changes, split into ordered commits:

1. Infrastructure/config changes
2. Models/services
3. Controllers/views
4. Tests
5. VERSION + CHANGELOG + docs

Each commit must compile and pass tests independently.

### Use `-o` for path-scoped commits (avoid grabbing staged drift)

A `git add`/`git commit` pair can accidentally include files that another process staged (editor, watcher, parallel session). Use `git commit -o <pathspec>` to commit **only** the listed paths, ignoring everything else in the index:

```bash
# Commits ONLY src/api/ and tests/ — even if other files are staged
git commit -o src/api/ tests/ -m "feat(api): add rate limiting"
```

This is the pattern Round 4 audit flagged for all stage-file-driven commits. Never rely on `git add .` inside a pipeline. Always name the paths you mean.

## 6g-bis. Tier Evidence Ledger (UI repos only)

Runs only when `.claude/qa-profile.json` exists in the target repo AND the feature contains at least one FRONTEND or TESTS task. Skip for non-UI repos and non-UI features.

Build the ledger by iterating over completed tasks and reading their `tier_evidence` metadata from Step 4 TaskUpdate calls. Tier glyphs are defined in `shared/qa-tiers.md`:

| Glyph | Meaning                                                    |
| ----- | ---------------------------------------------------------- |
| ✅    | Evidence captured; tier enforced and passing.              |
| ❌    | Evidence expected but missing or failing. Blocks merge.    |
| ⏳    | Deferred to a follow-up task — must link to that task.     |
| 🚫    | Not applicable to this feature (justify in the ledger).    |
| N/A   | Tier is above the repo's profile (e.g., T5 on Tier-Light). |

Render the ledger as a fenced block in the PR body, immediately after the ## Summary section:

```
## Tier Evidence Ledger

| Tier                  | Status | Evidence                                                                              |
| --------------------- | ------ | ------------------------------------------------------------------------------------- |
| T1 (smoke)            | ✅     | `tests/e2e/<feature>.smoke.spec.ts` passing in CI run #<run-id>                       |
| T2 (10x stability)    | ✅     | `scripts/run-stability.sh` — 10/10 passes logged at `test-results/stability-<sha>.json` |
| T3 (regression)       | ✅     | Added `tests/e2e/<feature>.spec.ts`; ran full suite locally + CI                      |
| T4 (BDD)              | 🚫     | Not applicable — Tier-Standard profile does not enforce T4.                           |
| T5 (visual)           | N/A    | Tier-Standard profile does not include T5.                                            |
| TO2 (team objectives) | ⏳     | Deferred to task #<n>: "Add accessibility audit for dashboard."                       |
```

**Gate**: if any row is ❌, block the push. Either fix the evidence (rerun §6b tests, add the missing spec) or downgrade to ⏳ with a tracked follow-up task on the board. A PR cannot ship with ❌ in the ledger — that is the entire point of the tier discipline.

For non-UI features on the same repo (e.g., a backend-only PR), omit the ledger entirely. The board still records the PR; only the tier discipline is conditional.

## 6g. Push and Create PR (if on a branch)

### Ack gate — confirm before pushing

`git push` is a shared-state action. Require an explicit acknowledgment file or user confirmation before pushing. This guards against spurious `--ship-only` re-runs pushing partial state.

```bash
ACK_FILE=".claude/state/plan-w-team-ack-$SLUG"
if [ ! -f "$ACK_FILE" ]; then
  echo "Ship gate 6g: no push acknowledgment."
  echo "Create $ACK_FILE (empty) or confirm with the user before pushing."
  echo "  touch $ACK_FILE    # opt-in once per ship"
  exit 1
fi
```

### mkdir lock — prevent concurrent push races

Parallel `/plan-w-team --ship-only` sessions on the same branch can race. Serialize with an atomic `mkdir` lock — POSIX-ubiquitous, no `flock(1)` dependency (macOS ships without it), no `exec <fd>>` file-descriptor tricks that break under `zsh`:

```bash
PUSH_LOCK_DIR=".claude/state/plan-w-team-push.lock"
mkdir -p .claude/state

# Stale-lock auto-recovery (F-3.1): if the lock dir exists but is older than 30 minutes
# AND its recorded PID is not running, treat it as abandoned and clear it before re-attempting.
# 30 min is generous — the longest legitimate push (LFS, large repo, slow uplink) finishes well under that.
if [ -d "$PUSH_LOCK_DIR" ]; then
  # Portable mtime: stat -f on macOS, stat -c on Linux. `find` is the lowest-common-denominator alt.
  LOCK_AGE_MIN=$(find "$PUSH_LOCK_DIR" -maxdepth 0 -mmin +30 -print 2>/dev/null | wc -l | tr -d ' ')
  HOLDER_PID=$(awk -F= '/^pid=/{print $2}' "$PUSH_LOCK_DIR/holder" 2>/dev/null)
  if [ "$LOCK_AGE_MIN" -gt 0 ] && [ -n "$HOLDER_PID" ] && ! kill -0 "$HOLDER_PID" 2>/dev/null; then
    echo "⚠ stale push lock detected (>30min, holder pid=$HOLDER_PID not running) — clearing"
    rm -f "$PUSH_LOCK_DIR/holder"
    rmdir "$PUSH_LOCK_DIR" 2>/dev/null
  fi
fi

if ! mkdir "$PUSH_LOCK_DIR" 2>/dev/null; then
  HOLDER=$(cat "$PUSH_LOCK_DIR/holder" 2>/dev/null || echo "unknown")
  echo "✗ Another ship is in progress (lock held by $HOLDER). Aborting."
  echo "  If stale, remove: rmdir $PUSH_LOCK_DIR"
  exit 1
fi
# Record holder for diagnostics; release on any exit (success, error, signal).
printf 'pid=%s ts=%s\n' "$$" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$PUSH_LOCK_DIR/holder"
trap 'rm -f "$PUSH_LOCK_DIR/holder"; rmdir "$PUSH_LOCK_DIR" 2>/dev/null' EXIT

# WARNING: any subsequent `trap … EXIT` in this script MUST chain rather than
# replace this handler. Bash `trap CMD EXIT` *replaces* the existing handler
# unconditionally — a naked `trap 'rm -f /tmp/foo' EXIT` later in the script
# silently drops this push-lock cleanup, causing the lock dir to leak until
# the 30-min stale-recovery branch fires on the *next* run. See §"Link PR"
# below for the chain pattern (`trap -p EXIT` capture + append).

git push -u origin "$BRANCH"
# Lock released by trap on script exit.
```

`mkdir` is atomic on every POSIX filesystem: it either creates the directory (lock acquired) or fails with `EEXIST` (lock held). Stale locks (>30min + dead holder PID) auto-clear at the top of the block; manual `rmdir` is the escape hatch for younger locks the operator knows are abandoned.

After push succeeds, delete the ack file so the next ship run requires a fresh opt-in:

```bash
rm -f "$ACK_FILE"
```

### Link PR to Board Issue

Use `closes #N` in the PR body to automatically link the PR to the board Issue. When the PR merges, GitHub will close the Issue and the board workflow moves it to Done.

```bash
# Get the issue number from the spec header or board search
ISSUE_NUM=$(grep -o '#[0-9]*' docs/specs/<feature-name>.md | head -1)

# Write the PR body to a file first — avoids shell expansion of any user-authored
# fragments (spec links, issue titles, commit messages) and lets gh read directly.
# See shared/shell-safety.md for why `<<EOF` on LLM-authored content is unsafe.
PR_BODY_FILE=$(mktemp -t plan-w-team-pr-body.XXXXXX)
# Chain cleanup onto the existing push-lock trap — do NOT replace it.
# `trap -p EXIT` returns the existing handler in re-evaluable form (`trap -- 'CMD' EXIT`).
# Strip the wrapper, append our cleanup, set the combined trap.
EXISTING_TRAP=$(trap -p EXIT | sed -E "s/^trap -- '(.*)' EXIT$/\\1/")
trap "${EXISTING_TRAP}; rm -f \"$PR_BODY_FILE\"" EXIT

cat > "$PR_BODY_FILE" <<'EOF'
## Summary
<1-3 bullet points describing what changed>

## Test Plan
- [ ] All unit tests pass
- [ ] Integration tests pass
- [ ] Manual QA verified (if frontend)

EOF

# Append dynamic fields using printf (no shell expansion of PR content)
printf 'Closes %s\n\n---\n**Spec:** docs/specs/%s.md\n**Board:** https://github.com/%s/%s/issues/%s\n\nGenerated with [Claude Code](https://claude.com/claude-code)\n' \
  "$ISSUE_NUM" "$FEATURE_SLUG" "$REPO_OWNER" "$REPO_NAME" "${ISSUE_NUM#\#}" \
  >> "$PR_BODY_FILE"

gh pr create --title "$PR_TITLE" --body-file "$PR_BODY_FILE"
```

The `Closes #N` keyword creates a bidirectional link:

- The PR shows which Issue it resolves
- The Issue shows which PR implements it
- Merging the PR auto-closes the Issue and triggers the board Done workflow

Read `shared/artifact-storage.md` for review log and streak tracking formats.
