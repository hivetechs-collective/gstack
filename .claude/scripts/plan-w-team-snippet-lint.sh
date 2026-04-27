#!/usr/bin/env bash
# plan-w-team-snippet-lint.sh
#
# Extracts fenced ```bash blocks from /plan-w-team stage files and runs
# `bash -n` (parse-only) on each. Catches stage-file shell snippets that
# would fail at runtime due to syntax errors — a recurring class of defect
# where an example block in a stage file has unbalanced quotes, missing
# `done`/`fi`, or a malformed heredoc.
#
# Scope:
#   - .claude/commands/plan-w-team.md
#   - .claude/commands/plan-w-team/**/*.md
#
# Output: per-failure file:block-index summary, exit 1 on any parse error.
#
# Exit codes:
#   0 — all bash blocks parse cleanly
#   1 — one or more blocks failed `bash -n`
#   2 — internal error (no markdown stage files found, bash missing, etc.)
#
# Notes:
#   - Only ```bash and ```sh fenced blocks are checked. Other fences (```yaml,
#     ```ts) are ignored.
#   - Some stage-file blocks contain placeholder syntax like `<feature-name>`
#     or `$SLUG` references that would expand differently at runtime. `bash -n`
#     does NOT execute the script, so these placeholders pass parse.
#   - Heredocs that span multiple fenced blocks would not be caught (each
#     block is parsed in isolation). This is a documented limitation.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

command -v bash >/dev/null 2>&1 || { echo "✗ bash not found in PATH" >&2; exit 2; }

STAGE_FILES=(
  ".claude/commands/plan-w-team.md"
)
while IFS= read -r f; do
  STAGE_FILES+=("$f")
done < <(find .claude/commands/plan-w-team -name '*.md' -type f 2>/dev/null | sort)

if [ "${#STAGE_FILES[@]}" -eq 0 ]; then
  echo "✗ no stage files found" >&2
  exit 2
fi

failures=0
total_blocks=0
fail_log=$(mktemp)
trap 'rm -f "$fail_log"' EXIT

for f in "${STAGE_FILES[@]}"; do
  [ -f "$f" ] || continue

  # Two-pass extraction (portable across BSD awk):
  #   Pass 1: emit "open_line close_line" pairs for each ```bash / ```sh block.
  #   Pass 2: sed each pair into a tmp file and `bash -n` it.
  #
  # The opening fence regex demands `bash` or `sh` immediately after ```;
  # the closing fence regex matches a bare ``` (any language) — but the FSM
  # only counts a close while in_block, so other-language closes are inert.
  pairs=$(awk '
    BEGIN { in_block=0; open=0 }
    /^```(bash|sh)[[:space:]]*$/ && !in_block {
      in_block=1
      open=NR
      next
    }
    /^```[[:space:]]*$/ && in_block {
      printf "%d %d\n", open, NR
      in_block=0
      next
    }
  ' "$f")

  [ -z "$pairs" ] && continue

  # Index for reporting (block #1, #2 within this file)
  block_idx=0
  while IFS= read -r pair; do
    [ -z "$pair" ] && continue
    block_idx=$((block_idx + 1))
    total_blocks=$((total_blocks + 1))

    open=$(echo "$pair" | awk '{print $1}')
    close=$(echo "$pair" | awk '{print $2}')

    # Body excludes the fence lines themselves.
    body_start=$((open + 1))
    body_end=$((close - 1))

    # Skip empty bodies (open immediately followed by close — degenerate but real).
    if [ "$body_end" -lt "$body_start" ]; then
      continue
    fi

    tmp=$(mktemp)
    err=$(mktemp)
    sed -n "${body_start},${body_end}p" "$f" > "$tmp"

    # Opt-out: blocks containing `# snippet-lint: skip` (anywhere in the body)
    # are illustrative-only and not meant to be executable. The directive must
    # appear as a comment line so it is invisible to the reader who copy-pastes
    # the snippet — bash will ignore it.
    if grep -q '^[[:space:]]*#[[:space:]]*snippet-lint:[[:space:]]*skip' "$tmp"; then
      rm -f "$tmp" "$err"
      continue
    fi

    if ! bash -n "$tmp" 2>"$err"; then
      err_text=$(cat "$err")
      printf '✗ %s :: bash block #%d (lines %d-%d)\n%s\n\n' \
        "$f" "$block_idx" "$open" "$close" "$err_text" >> "$fail_log"
      failures=$((failures + 1))
    fi
    rm -f "$tmp" "$err"
  done <<<"$pairs"
done

echo "Snippet-lint: ${total_blocks} bash blocks across ${#STAGE_FILES[@]} stage files"

if [ "$failures" -gt 0 ]; then
  echo "✗ ${failures} block(s) failed bash -n"
  echo ""
  cat "$fail_log"
  exit 1
fi

echo "✓ all blocks parse cleanly"
exit 0
