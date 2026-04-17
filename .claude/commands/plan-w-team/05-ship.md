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

## 6b. Run Full Test Suite

```bash
# Detect and run project's test framework
npm test / cargo test / pytest / etc.
```

If the browse binary is available and any task has `scope: "FRONTEND"`, read `shared/browser-qa.md` for browser smoke test instructions.

## 6c. Test Coverage Audit

Rate test quality with stars, not just percentages:

| Rating | Meaning       | Criteria                                    |
| ------ | ------------- | ------------------------------------------- |
| ★★★    | Comprehensive | Behavior + edge cases + error paths covered |
| ★★     | Adequate      | Happy path + basic error cases              |
| ★      | Minimal       | Smoke test or trivial assertions only       |

A module with 90% line coverage but all ★ tests is worse than 60% coverage with ★★★ tests. Flag the distinction.

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

## 6g. Push and Create PR (if on a branch)

```bash
git push -u origin <branch>
```

### Link PR to Board Issue

Use `closes #N` in the PR body to automatically link the PR to the board Issue. When the PR merges, GitHub will close the Issue and the board workflow moves it to Done.

```bash
# Get the issue number from the spec header or board search
ISSUE_NUM=$(grep -o '#[0-9]*' docs/specs/<feature-name>.md | head -1)

gh pr create --title "<title>" --body "$(cat <<EOF
## Summary
<1-3 bullet points describing what changed>

## Test Plan
- [ ] All unit tests pass
- [ ] Integration tests pass
- [ ] Manual QA verified (if frontend)

Closes $ISSUE_NUM

---
**Spec:** docs/specs/<feature-name>.md
**Board:** https://github.com/<owner>/<repo>/issues/${ISSUE_NUM#\#}

Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

The `Closes #N` keyword creates a bidirectional link:

- The PR shows which Issue it resolves
- The Issue shows which PR implements it
- Merging the PR auto-closes the Issue and triggers the board Done workflow

Read `shared/artifact-storage.md` for review log and streak tracking formats.
