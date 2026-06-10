#!/usr/bin/env bash
# .claude/scripts/supervisor-merge-gate.sh
#
# Deterministic merge-gate the origin-chat supervisor MUST consult before
# any merge action. Replaces ad-hoc LLM judgment for the safety-critical
# "should I merge with --auto or --admin or surface to user" question.
#
# Spec:    docs/specs/supervisor-merge-enforcement.md
# Matrix:  shared/supervisor-protocol.md §Decision Matrix → CI-Aware Action Hierarchy
# Tags:    shared/governance-tags.md (closed list of one-way-door surface globs)
#
# Inputs:  $1 = PR number (required). Optional env REPO_ROOT (auto-detected).
# Output:  JSON to stdout. Exit 0 always — supervisor reads recommended_action.
# Failure: gh/parse errors emit recommended_action=SURFACE_TO_USER with rationale.
#
# Decision hierarchy (mirrors the matrix in supervisor-protocol.md):
#   row 1: governance_surfaces_matched non-empty → SURFACE_TO_USER
#   row 2: label=true  + local-makefile          → ADMIN_MERGE (supervisor-reviewer)
#   row 3: label=true  + github-actions          → SURFACE_TO_USER (real CI needs human)
#   row 4: label=true  + none                    → SURFACE_TO_USER (conservative)
#   row 5: label=false + github-actions          → AUTO_MERGE (--auto waits for CI)
#   row 6: label=false + local-makefile          → ADMIN_MERGE (no --auto target)
#   row 7: label=false + none                    → ADMIN_MERGE (no CI to wait on)

set -uo pipefail

PR="${1:-}"
if [ -z "$PR" ] || ! [[ "$PR" =~ ^[0-9]+$ ]]; then
  echo "usage: $0 <PR-number>" >&2
  exit 2
fi

REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || echo .)}"
GOVERNANCE_TAGS="${REPO_ROOT}/.claude/commands/plan-w-team/shared/governance-tags.md"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# ── Fail-closed emitter ─────────────────────────────────────────────────────
emit_surface() {
  local rationale="$1"
  jq -n \
    --arg pr "$PR" \
    --arg rationale "$rationale" \
    --arg now "$NOW" \
    '{
      pr: ($pr | tonumber),
      branch: null,
      ci_mode: "unknown",
      has_do_not_merge_label: null,
      governance_surfaces_matched: [],
      recommended_action: "SURFACE_TO_USER",
      rationale: $rationale,
      governance_globs_consulted: 0,
      diff_paths_examined: 0,
      scanned_at: $now
    }'
}

# ── Step 1: gather PR data via gh ───────────────────────────────────────────
PR_JSON=$(gh pr view "$PR" --json number,headRefName,labels 2>/dev/null) || {
  warn="gh pr view failed for PR #$PR — supervisor must verify PR exists and surface"
  echo "[supervisor-merge-gate] $warn" >&2
  emit_surface "$warn"
  exit 0
}

BRANCH=$(echo "$PR_JSON" | jq -r '.headRefName')
HAS_LABEL=$(echo "$PR_JSON" | jq -r '[.labels[].name] | any(. == "DO NOT MERGE")')

DIFF_PATHS=$(gh pr diff "$PR" --name-only 2>/dev/null) || {
  warn="gh pr diff failed for PR #$PR — surfacing"
  echo "[supervisor-merge-gate] $warn" >&2
  emit_surface "$warn"
  exit 0
}

DIFF_COUNT=$(printf '%s\n' "$DIFF_PATHS" | grep -c . || true)

# ── Step 2: parse governance-tags.md → glob list ────────────────────────────
# The catalog table rows look like:
#   | Surface label | `glob1`, `glob2`, ... | rationale |
# Extract all backticked tokens in the Path-glob column of the Surface Catalog.
GLOBS=()
if [ -f "$GOVERNANCE_TAGS" ]; then
  # Read rows between "## Surface Catalog" and the next "## " heading.
  # Then pull all backticked tokens out of column 2 (the Path glob(s) column).
  while IFS= read -r tok; do
    [ -n "$tok" ] && GLOBS+=("$tok")
  done < <(
    awk '
      /^## Surface Catalog/{flag=1; next}
      /^## [^S]/ && flag {exit}
      flag && /^\|/ {
        # split row by | and look at second data column (index 3 due to leading |)
        n = split($0, cols, "|")
        if (n >= 4) print cols[3]
      }
    ' "$GOVERNANCE_TAGS" \
      | grep -oE '`[^`]+`' \
      | tr -d '`'
  )
fi

GLOB_COUNT=${#GLOBS[@]}
if [ "$GLOB_COUNT" -eq 0 ]; then
  warn="governance-tags.md missing or no globs extracted — surfacing"
  echo "[supervisor-merge-gate] $warn" >&2
  emit_surface "$warn"
  exit 0
fi

# ── Step 3: match diff paths against globs ──────────────────────────────────
MATCHED=()
while IFS= read -r path; do
  [ -z "$path" ] && continue
  for glob in "${GLOBS[@]}"; do
    # shellcheck disable=SC2254  # intentional unquoted glob
    case "$path" in
      $glob)
        MATCHED+=("${path} (matched ${glob})")
        break
        ;;
    esac
  done
done <<< "$DIFF_PATHS"

# Build JSON array of matched paths
MATCHED_JSON='[]'
for m in "${MATCHED[@]}"; do
  MATCHED_JSON=$(echo "$MATCHED_JSON" | jq --arg v "$m" '. + [$v]')
done

# ── Step 4: detect ci_mode ──────────────────────────────────────────────────
detect_ci_mode() {
  local has_pr_workflow=0
  local has_makefile_test=0

  # github-actions: any workflow file mentions `pull_request` trigger
  if [ -d "$REPO_ROOT/.github/workflows" ]; then
    if grep -lE '^\s*pull_request\s*:' "$REPO_ROOT"/.github/workflows/*.y*ml 2>/dev/null | head -1 | grep -q .; then
      has_pr_workflow=1
    fi
  fi

  # local-makefile: Makefile at root has a test/check/lint/test-skill target
  if [ -f "$REPO_ROOT/Makefile" ]; then
    if grep -qE '^(test|test-skill|check|lint)\s*:' "$REPO_ROOT/Makefile"; then
      has_makefile_test=1
    fi
  fi

  if [ "$has_pr_workflow" = 1 ]; then
    echo "github-actions"
  elif [ "$has_makefile_test" = 1 ]; then
    echo "local-makefile"
  else
    echo "none"
  fi
}

CI_MODE=$(detect_ci_mode)

# ── Step 5: apply decision hierarchy ────────────────────────────────────────
MATCHED_COUNT=${#MATCHED[@]}

if [ "$MATCHED_COUNT" -gt 0 ]; then
  ACTION="SURFACE_TO_USER"
  RATIONALE="row 1: governance-tag surface matched ($MATCHED_COUNT path(s)) → one-way door requires explicit user consent"
elif [ "$HAS_LABEL" = "true" ]; then
  case "$CI_MODE" in
    local-makefile)
      ACTION="ADMIN_MERGE"
      RATIONALE="row 2: DO NOT MERGE label + local-makefile CI → supervisor-reviewer pattern, admin merge acceptable"
      ;;
    github-actions)
      ACTION="SURFACE_TO_USER"
      RATIONALE="row 3: DO NOT MERGE label + github-actions CI → real required checks need a real human reviewer"
      ;;
    *)
      ACTION="SURFACE_TO_USER"
      RATIONALE="row 4: DO NOT MERGE label + ci_mode=none → conservative default to user"
      ;;
  esac
else
  case "$CI_MODE" in
    github-actions)
      ACTION="AUTO_MERGE"
      RATIONALE="row 5: no DO NOT MERGE label + github-actions CI → gh pr merge --auto --squash waits for required checks"
      ;;
    local-makefile)
      ACTION="ADMIN_MERGE"
      RATIONALE="row 6: no DO NOT MERGE label + local-makefile CI → no --auto target exists, admin merge"
      ;;
    *)
      ACTION="ADMIN_MERGE"
      RATIONALE="row 7: no DO NOT MERGE label + ci_mode=none → no CI to wait on, admin merge"
      ;;
  esac
fi

# ── Step 6: emit final JSON ─────────────────────────────────────────────────
jq -n \
  --arg pr "$PR" \
  --arg branch "$BRANCH" \
  --arg ci_mode "$CI_MODE" \
  --argjson has_label "$HAS_LABEL" \
  --argjson matched "$MATCHED_JSON" \
  --arg action "$ACTION" \
  --arg rationale "$RATIONALE" \
  --argjson globs "$GLOB_COUNT" \
  --argjson diff_count "$DIFF_COUNT" \
  --arg now "$NOW" \
  '{
    pr: ($pr | tonumber),
    branch: $branch,
    ci_mode: $ci_mode,
    has_do_not_merge_label: $has_label,
    governance_surfaces_matched: $matched,
    recommended_action: $action,
    rationale: $rationale,
    governance_globs_consulted: $globs,
    diff_paths_examined: $diff_count,
    scanned_at: $now
  }'
