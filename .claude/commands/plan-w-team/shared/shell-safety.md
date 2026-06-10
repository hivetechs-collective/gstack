# Shell Safety — Primer for Stage-File Authors

Stage files and helpers invoked by `/plan-w-team` routinely pass LLM-authored
strings into bash, Python, GraphQL, and `gh` subprocesses. Every one of those
boundaries is a potential injection site. This doc is the canonical reference
for the safe patterns used across `scripts/board.sh`,
`.claude/scripts/board-preflight.sh`, and future stage files.

## The Core Rule

**Never interpolate LLM-authored strings into shell, Python, or GraphQL source
without a quoting/escaping mechanism.**

If a variable came from a model (issue title, task body, sprint name, slug,
comment) or from untrusted user input, it MUST cross the language boundary via
a dedicated channel — not via naive string concatenation into the subprocess
source.

## Safe Patterns

### bash → bash (argv)

`printf %q` produces a shell-safe quoted form of any string:

```bash
safe=$(printf %q "$user_input")
eval "some_cmd $safe"   # still discouraged, but at least quoted
```

Prefer passing variables directly as argv rather than reconstructing a command
string:

```bash
# GOOD — argv, no re-parsing
gh issue create --title "$title" --body "$body"

# BAD — string-concat then eval
cmd="gh issue create --title \"$title\""
eval "$cmd"
```

### bash → Python (env vars + single-quoted heredoc)

Use environment variables to ferry data across the boundary. A single-quoted
heredoc (`<<'PYEOF'`) disables all shell expansion inside the body — the Python
source is literally what you wrote:

```bash
VAR="$untrusted" python3 <<'PYEOF'
import os
value = os.environ["VAR"]
# … do things with value — no quoting issues, no injection
PYEOF
```

Multiple variables:

```bash
CFG="$BOARD_CONFIG" KEY="$1" LIMIT="$count" python3 <<'PYEOF'
import json, os
with open(os.environ["CFG"]) as f:
    data = json.load(f)
print(data[os.environ["KEY"]][: int(os.environ["LIMIT"])])
PYEOF
```

### bash → GraphQL (`gh api graphql -f`)

`gh api graphql` supports parameterized variables via repeated `-f` flags.
Values are sent as a JSON `variables` object alongside the query — the server
parses them, so nothing is interpolated into the query text:

```bash
gh api graphql \
  -f query='query($login: String!) { organization(login: $login) { id } }' \
  -f login="$org"
```

Multiple variables in a mutation:

```bash
gh api graphql \
  -f query='mutation($projectId: ID!, $ownerId: ID!, $title: String!) {
    copyProjectV2(input: { projectId: $projectId, ownerId: $ownerId, title: $title }) {
      projectV2 { id number }
    }
  }' \
  -f projectId="$template_id" \
  -f ownerId="$owner_id" \
  -f title="$title"
```

Use GraphQL's declared variable types (`String!`, `ID!`, `Boolean!`, `Int!`)
rather than embedding values into the query body.

### Heredoc quoting semantics

```bash
<<EOF      # shell EXPANDS $var, `cmd`, and \ — DO NOT use for untrusted data
<<'EOF'    # shell does NOT expand anything — SAFE for raw bodies
<<"EOF"    # same as <<EOF — avoid when you mean <<'EOF'
```

Single-quote the opening token for any heredoc containing an LLM-authored body.

### `git commit -F <file>` and `gh pr create --body-file <file>`

Commit messages and PR bodies often contain markdown, backticks, and dollar
signs — all of which are shell-active. Avoid passing them as argv. Write to a
temp file first:

```bash
msg_file=$(mktemp)
cat > "$msg_file" <<'MSG'
feat: some change

Body with $dangerous `backticks` and "quotes".
MSG

git commit -F "$msg_file"
gh pr create --body-file "$msg_file"
rm -f "$msg_file"
```

Or use a process-substitution / in-place heredoc with `-F -`:

```bash
git commit -F - <<'MSG'
feat: some change
MSG
```

### Staging: never `git add` a fixed multi-path list

A `git add a b c` is **all-or-nothing**: if any one argument is a non-existent
pathspec, git aborts the entire stage and nothing is added (sync-all incident
"C" — a repo without `docs/operations/` killed the whole sync commit). Two rules:

1. **Add per path with `|| true`** so a missing path cannot abort the rest:

   ```bash
   # ✅ each path isolated
   for p in scripts/Makefile.template docs/operations/BOARD.md; do
     git -C "$dir" add "$p" 2>/dev/null || true
   done
   # ❌ one bad pathspec aborts all of them
   git -C "$dir" add scripts/Makefile.template docs/operations/BOARD.md
   ```

2. **Never stage a fixed path list that may include a source-only sibling.** A
   recursive `git add .claude/` (or a hand-listed set) can sweep in paths that
   must never ride the commit — per-run `.claude/state/*`, or a source-only
   sibling like `.githooks/`. Scope the add with negative pathspecs and an
   explicit allowlist:

   ```bash
   git -C "$dir" add -- .claude/ ':!.claude/state'   # state never rides a sync commit
   ```

   The shared sync-commit discipline (`.claude/scripts/sync-commit-lib.sh`)
   encodes both rules — reuse it instead of hand-rolling a `git add` list.

### Canonical SLUG validator

Feature names, branch-safe identifiers, and anything that lands in a filesystem
path must match this regex:

```
^[a-z0-9][a-z0-9-]{0,63}$
```

- Lowercase alphanumerics plus hyphens only
- Must start with an alphanumeric (no leading hyphen)
- 1–64 characters

The bash helper below is the reference implementation — source it into any
stage file that accepts an identifier.

## Anti-Patterns to Grep For

Before committing a new stage file, run these greps and eliminate hits:

```bash
# Python source built via string interpolation
grep -rn 'python3 -c ".*\$' .claude/ scripts/

# GraphQL query with embedded shell expansions
grep -rnE "query='[^']*\"'\\\"\\\$" .claude/ scripts/

# Unquoted heredoc delimiter (expansion enabled)
grep -rnE '<<[A-Z_]+$' .claude/ scripts/   # look for <<EOF without quotes

# Commit messages with LLM-authored vars inline
grep -rn 'git commit -m ".*\$' .claude/ scripts/
```

Any hit is a potential injection site. Review and convert to the safe patterns
above.

## Reference Helpers

Source these at the top of any stage file that accepts untrusted input:

```bash
# Validate SLUG/feature-name: lowercase alnum + hyphens, 1-64 chars, no leading hyphen
assert_safe_slug() {
  local candidate="${1:-}"
  local label="${2:-slug}"
  if [[ ! "$candidate" =~ ^[a-z0-9][a-z0-9-]{0,63}$ ]]; then
    echo "ERROR: invalid $label: '$candidate' (must match ^[a-z0-9][a-z0-9-]{0,63}\$)" >&2
    return 1
  fi
}

# Truncate an LLM-authored string to max_len, with a warning on truncation.
# Usage: result=$(assert_max_len "$body" 60000 "comment body")
assert_max_len() {
  local value="${1:-}"
  local max_len="${2:-0}"
  local label="${3:-value}"
  if [[ "${#value}" -gt "$max_len" ]]; then
    echo "WARN: $label exceeds $max_len chars (${#value}), truncating" >&2
    printf '%s' "${value:0:$max_len}"
  else
    printf '%s' "$value"
  fi
}
```

Call sites:

```bash
assert_safe_slug "$feature_name" "feature name" || return 1
assert_safe_slug "$sprint_id" "sprint"           || return 1

body=$(assert_max_len "$body" 60000 "comment body")
title=$(assert_max_len "$title" 256 "issue title")
```

## When to Validate

- **Validate slugs** at every entry point where an identifier flows into a
  filesystem path, a branch name, a directory, or a shell-interpolated context.
- **Do not validate free-text bodies** (issue titles, descriptions, comments) —
  they're expected to contain punctuation, spaces, and non-ASCII characters.
  Instead, pass them via env vars, heredocs, or `-F <file>` so the content
  never touches a shell parser.
- **Do cap lengths** of free-text bodies. GitHub enforces its own limits
  (~65k chars on comments and issue bodies); truncate with a warning so we
  surface the issue rather than silently hitting an API error.

## Binary discovery

PATH-based discovery of CLI binaries is fragile in subshells. When a hook or
script runs under the Claude Code harness, its inherited `$PATH` may not
include the install dir of binaries it depends on (most importantly the
`claude` CLI itself — installed at `/Users/$USER/.local/bin/claude` by the
official Claude Code installer). The symptom is identical for every consumer:

```
env: claude: No such file or directory
```

This is the failure mode behind the production incident on 2026-05-23 where
`pwt-goal.sh` failed to spawn the worker bg session because the agent's Bash
tool subshell did not have `/Users/$USER/.local/bin` on PATH. Every direct
`claude --bg` / `claude agents` / `claude stop` / `claude --version` call in
the codebase has the same exposure if invoked from a PATH-stripped subshell.

### The fix: `.claude/scripts/locate-claude.sh`

The helper resolves an absolute path to the claude binary, tried in this
order:

1. `command -v claude` — honors caller-installed PATH overrides and test stubs.
2. `/Users/$USER/.local/bin/claude` — official installer default on macOS.
3. `/opt/homebrew/bin/claude` — Homebrew on Apple Silicon.
4. `/usr/local/bin/claude` — Homebrew on Intel / general `/usr/local`.
5. `$HOME/.npm-global/bin/claude` — npm global install without sudo.

Contract: stdout is the absolute path (exit 0) or empty + clear stderr
enumeration of every searched location (exit 1). POSIX `sh`, no bashisms.
Tested by `.claude/scripts/locate-claude.test.sh` (TC1–TC4 + EC1/EC3).

### Usage patterns

**Pattern A — short-lived script (`pwt-goal.sh`)**: define a helper that
resolves once at the top of the launch block, then reuse:

```bash
__locate_claude() {
    local locator="$PROJECT_ROOT/.claude/scripts/locate-claude.sh"
    [ -x "$locator" ] || { echo "FATAL: locate-claude.sh missing" >&2; exit 127; }
    "$locator" || { echo "FATAL: locate-claude.sh exited non-zero" >&2; exit 127; }
}
CLAUDE_BIN=$(__locate_claude) || exit $?

env $LAUNCH_ENV "$CLAUDE_BIN" --bg "$GOAL_TEXT"
```

**Pattern B — long-lived hook (`session-start.sh`, `goal-evaluator.sh`)**:
resolve once and export `CLAUDE_BIN` so transitively-spawned subscripts
inherit a resolved path:

```bash
LOCATE_CLAUDE="$PROJECT_ROOT/.claude/scripts/locate-claude.sh"
if [ -x "$LOCATE_CLAUDE" ]; then
    CLAUDE_BIN="$("$LOCATE_CLAUDE" 2>/dev/null)" || CLAUDE_BIN=""
    [ -n "$CLAUDE_BIN" ] && export CLAUDE_BIN
fi
```

Downstream scripts then prefer `"${CLAUDE_BIN:-claude}"` to inherit the
resolved path when running under the hook, and fall back to bare `claude`
when invoked standalone with a normal PATH.

**Pattern C — graceful gate (`plan-w-team-route-prompt.sh` PWG)**: when a
block is best-effort and should degrade silently if claude can't be found,
use the helper output as a gate condition rather than failing hard:

```bash
PWG_LOCATE="$PROJECT_ROOT/.claude/scripts/locate-claude.sh"
PWG_CLAUDE_BIN=""
if [ -x "$PWG_LOCATE" ]; then
    PWG_CLAUDE_BIN=$("$PWG_LOCATE" 2>/dev/null) || PWG_CLAUDE_BIN=""
fi
if [ -n "$PWG_CLAUDE_BIN" ]; then
    PWG_AGENTS_RAW=$("$PWG_CLAUDE_BIN" agents --json 2>/dev/null || echo "[]")
fi
```

### Why not just `command -v claude`?

`command -v` only consults `$PATH`. If the inheriting subshell's PATH doesn't
include the install dir, `command -v claude` returns nothing — and code that
guards a block with `if command -v claude` silently skips the work it was
meant to do. The helper is preferred because it cascades through known
install locations regardless of PATH state.

## Further Reading

- `shared/board-integration.md` — how board.sh is invoked from stage files
- `shared/untracked-hygiene.md` — ship-gate rules, including staged-work safety
- `scripts/board.sh` — reference implementation of all patterns above
- `.claude/scripts/locate-claude.sh` — claude-binary discovery helper
- `docs/specs/locate-claude-binary.md` — spec for the helper + refactor
