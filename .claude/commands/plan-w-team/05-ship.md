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
  # Count tasks actually shipped in this feature (metadata.spec_path matches)
  SHIPPED_COUNT=$(TaskList by spec_path | wc -l)  # pseudocode — use your task tooling

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

### flock — prevent concurrent push races

Parallel `/plan-w-team --ship-only` sessions on the same branch can race. Serialize with a per-repo lock:

```bash
PUSH_LOCK=".claude/state/plan-w-team-push.lock"
mkdir -p .claude/state
exec 200>"$PUSH_LOCK"
if ! flock -n 200; then
  echo "✗ Another ship is in progress (lock held on $PUSH_LOCK). Aborting."
  exit 1
fi

git push -u origin "$BRANCH"
# Lock released on exec 200>&- or script exit
```

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
trap 'rm -f "$PR_BODY_FILE"' EXIT

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
