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

## Further Reading

- `shared/board-integration.md` — how board.sh is invoked from stage files
- `shared/untracked-hygiene.md` — ship-gate rules, including staged-work safety
- `scripts/board.sh` — reference implementation of all patterns above
