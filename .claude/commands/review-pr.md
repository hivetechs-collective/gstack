Review the changes on the current branch compared to main, or review a specific branch/PR.

## Usage

```
/review-pr              # Review current branch vs main
/review-pr <branch>     # Review specific branch vs main
/review-pr <pr-url>     # Review a GitHub PR (uses gh CLI)
```

## Process

### Step 1: Gather the diff

Determine what to review based on the argument:

- **No argument**: Run `git diff main...HEAD --stat` then `git diff main...HEAD` to get all changes on the current branch
- **Branch name**: Run `git diff main...<branch> --stat` then `git diff main...<branch>`
- **GitHub PR URL** (contains `github.com`): Run `gh pr diff <url>` and `gh pr view <url>`

If on `main` with no argument, review uncommitted changes instead: `git diff --stat` and `git diff`.

### Step 2: Understand context

For each changed file:

1. Read the full file (not just the diff) to understand surrounding context
2. Note the purpose of the change from commit messages: `git log main..HEAD --oneline`

### Step 3: Focused review

Review for these categories only (skip nitpicks — this is a solo dev sanity check, not a team PR review):

**Bugs & Logic Errors** (P0)

- Off-by-one errors, incorrect conditionals, null/undefined paths
- Race conditions in async code
- State mutations that could cause unexpected behavior

**Security** (P0)

- Injection vulnerabilities (SQL, XSS, command)
- Secrets or credentials in code
- Missing auth/authz checks on new endpoints
- Unsafe deserialization

**Breaking Changes** (P1)

- Changed function signatures that callers depend on
- Removed exports or renamed public APIs
- Database schema changes without migration
- Changed config formats

**Missing Edge Cases** (P1)

- Empty arrays/objects, null values, zero-length strings
- Network failures, timeouts, partial responses
- Concurrent access patterns

**Dead Code & Leftovers** (P2)

- Console.log/debug statements left in
- Commented-out code blocks
- Unused imports or variables
- TODO comments that should be resolved before merge

### Step 4: Report

Output a concise review:

```markdown
## Branch Review: <branch-name>

**Changes**: <N files changed, +X/-Y lines>
**Commits**: <N commits>

### Issues Found

<list issues with file:line, severity [P0/P1/P2], and one-line description>
<if no issues: "No issues found.">

### Verdict

**SHIP IT** — No blocking issues found.
or
**FIX FIRST** — <N> blocking issues need attention before merging.
```

Keep the report short. No praise, no style suggestions, no architecture commentary. Just issues and a verdict.

## Notes

- This is a **quick sanity check** (~2-5 minutes), not a comprehensive audit
- For thorough security review, use the `code-review-standards` skill instead
- For simple code cleanup, use `/simplify` instead
- Works without GitHub PRs — just compares branches locally
