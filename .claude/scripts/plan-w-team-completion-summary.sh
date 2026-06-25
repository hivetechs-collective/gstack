#!/usr/bin/env bash
# plan-w-team-completion-summary.sh
#
# Aggregates the final state of a /plan-w-team run into two artifacts:
#   .claude/state/plan-w-team-completion-<SLUG>.json (machine-readable)
#   .claude/state/plan-w-team-completion-<SLUG>.md   (human-readable + grep anchors)
#
# Invoked from 07-retro.md §8k before the End-of-Stage Status Block so the
# summary is captured in the same transcript window as retro-complete.
#
# Spec: docs/specs/retro-completion-summary.md
# Holistic-check contract: docs/specs/reporting-holistic-check.md
#
# Safety contract (R10): never fail the retro. On any internal error,
# emit a stub summary with HOLISTIC_CHECK_UNKNOWN and exit 0.
# Exit 2 only for caller-bug conditions (missing SLUG arg).

set -uo pipefail

WRITER_VERSION="1.0"

SLUG="${1:-}"
if [ -z "$SLUG" ]; then
  echo "usage: $0 <SLUG>" >&2
  exit 2
fi

STATE_DIR=".claude/state"
mkdir -p "$STATE_DIR"

JSON_OUT="${STATE_DIR}/plan-w-team-completion-${SLUG}.json"
MD_OUT="${STATE_DIR}/plan-w-team-completion-${SLUG}.md"
SPEC_PATH="docs/specs/${SLUG}.md"
AC_SNAPSHOT="${STATE_DIR}/plan-w-team-ac-snapshot-${SLUG}.md"
GOAL_FILE="${STATE_DIR}/plan-w-team-goal-${SLUG}.json"

GENERATED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# -----------------------------------------------------------------------------
# Transcript discovery
# -----------------------------------------------------------------------------
# Heuristic order:
#   1. $CLAUDE_TRANSCRIPT_PATH (explicit override — used by tests)
#   2. $CLAUDE_PROJECT_DIR + *.jsonl matching SLUG in last 24h
#   3. ~/.claude/projects/*/*.jsonl modified in last 24h containing SLUG
discover_transcript() {
  if [ -n "${CLAUDE_TRANSCRIPT_PATH:-}" ] && [ -f "${CLAUDE_TRANSCRIPT_PATH}" ]; then
    echo "${CLAUDE_TRANSCRIPT_PATH}"
    return 0
  fi
  local candidate=""
  if [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -d "${CLAUDE_PROJECT_DIR}" ]; then
    candidate=$(find "${CLAUDE_PROJECT_DIR}" -maxdepth 2 -name "*.jsonl" -type f -mtime -1 2>/dev/null \
      | xargs grep -l "${SLUG}" 2>/dev/null \
      | head -1)
    if [ -n "$candidate" ]; then
      echo "$candidate"
      return 0
    fi
  fi
  candidate=$(find "${HOME}/.claude/projects" -maxdepth 3 -name "*.jsonl" -type f -mtime -1 2>/dev/null \
    | xargs grep -l "${SLUG}" 2>/dev/null \
    | head -1)
  if [ -n "$candidate" ]; then
    echo "$candidate"
    return 0
  fi
  return 1
}

TRANSCRIPT=""
if T=$(discover_transcript); then
  TRANSCRIPT="$T"
fi

# -----------------------------------------------------------------------------
# Extract declared ACs from the snapshot
# -----------------------------------------------------------------------------
declared_acs() {
  if [ ! -f "$AC_SNAPSHOT" ]; then
    return 0
  fi
  # Only count `AC<N>:` introducers — checkbox bullets in the snapshot
  grep -oE 'AC[0-9]+:' "$AC_SNAPSHOT" \
    | sed 's/://' \
    | sort -uV
}

# -----------------------------------------------------------------------------
# Extract observed AC verdicts from transcript
# -----------------------------------------------------------------------------
# Strict format: requires `AC<N>:` followed by optional whitespace then PASS/FAIL.
# This is the canonical verdict format emitted by Step 5/6 status blocks and
# the goal evaluator anchors. Looser matches catch incidental mentions of ACs
# in spec/snapshot prose and were causing false positives.
observed_acs_with_verdict() {
  local verdict="$1"
  if [ -z "$TRANSCRIPT" ] || [ ! -f "$TRANSCRIPT" ]; then
    return 0
  fi
  grep -oE "AC[0-9]+:[[:space:]]*${verdict}" "$TRANSCRIPT" 2>/dev/null \
    | grep -oE 'AC[0-9]+' \
    | sort -uV
}

DECLARED=$(declared_acs)
PASSED=$(observed_acs_with_verdict "PASS")
FAILED=$(observed_acs_with_verdict "FAIL")

# Intersect: only count PASS/FAIL for ACs that were actually declared.
intersect() {
  comm -12 <(echo "$1" | sort -u) <(echo "$2" | sort -u) | sort -uV
}
missing_acs() {
  local declared="$1"
  local seen="$2"
  comm -23 <(echo "$declared" | sort -u) <(echo "$seen" | sort -u) | sort -uV
}

# `count` returns 0 when input is empty (avoids the `grep -c || echo 0` two-line bug)
count() {
  local n
  n=$(echo "$1" | grep -c '^AC' || true)
  echo "${n:-0}"
}

DECLARED_LIST=$(echo "$DECLARED" | grep -v '^$' || true)
PASSED_IN_DECLARED=$(intersect "$DECLARED_LIST" "$PASSED")
FAILED_IN_DECLARED=$(intersect "$DECLARED_LIST" "$FAILED")
SEEN=$(printf "%s\n%s\n" "$PASSED_IN_DECLARED" "$FAILED_IN_DECLARED" | sort -u | grep -v '^$' || true)
MISSING=$(missing_acs "$DECLARED_LIST" "$SEEN")

DECLARED_COUNT=$(count "$DECLARED_LIST")
PASSED_COUNT=$(count "$PASSED_IN_DECLARED")
FAILED_COUNT=$(count "$FAILED_IN_DECLARED")
MISSING_COUNT=$(count "$MISSING")

# -----------------------------------------------------------------------------
# Determine HOLISTIC_CHECK outcome
# -----------------------------------------------------------------------------
HOLISTIC_CHECK="HOLISTIC_CHECK_SKIPPED"
if [ -z "$TRANSCRIPT" ] || [ ! -f "$TRANSCRIPT" ]; then
  HOLISTIC_CHECK="HOLISTIC_CHECK_UNKNOWN"
elif [ "$DECLARED_COUNT" -eq 0 ]; then
  HOLISTIC_CHECK="HOLISTIC_CHECK_SKIPPED"
elif [ "$MISSING_COUNT" -gt 0 ]; then
  HOLISTIC_CHECK="HOLISTIC_CHECK_FAIL"
else
  HOLISTIC_CHECK="HOLISTIC_CHECK_PASS"
fi

# -----------------------------------------------------------------------------
# Stage transitions
# -----------------------------------------------------------------------------
STAGES_JSON='[]'
if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
  STAGES_TEXT=$(grep -oE 'stage="[a-z][a-z0-9-]*"' "$TRANSCRIPT" 2>/dev/null \
    | sort -u \
    | sed -E 's/stage="(.*)"/\1/' || true)
  if [ -n "$STAGES_TEXT" ]; then
    STAGES_JSON=$(printf '%s\n' "$STAGES_TEXT" | jq -R . | jq -cs 'map({label: ., ts: null})' 2>/dev/null || echo '[]')
  fi
fi

# -----------------------------------------------------------------------------
# Duration — derived from goal state started_at + now
# -----------------------------------------------------------------------------
STARTED_AT=""
if [ -f "$GOAL_FILE" ]; then
  STARTED_AT=$(jq -r '.started_at // empty' "$GOAL_FILE" 2>/dev/null || echo "")
fi

# -----------------------------------------------------------------------------
# Skill version + commit SHA — recorded by pwt-goal.sh at spawn time.
# Prefer the goal-state JSON (set by --supervisor-goal mirror); fall back to
# the spawn-time sidecar (always written by pwt-goal.sh for all spawn paths).
# Degrades silently to "unknown" so retros for pre-versioning runs still ship.
# -----------------------------------------------------------------------------
SKILL_VERSION=""
SKILL_COMMIT_SHA=""
if [ -f "$GOAL_FILE" ] && command -v jq >/dev/null 2>&1; then
  SKILL_VERSION=$(jq -r '.skill_version // empty' "$GOAL_FILE" 2>/dev/null || echo "")
  SKILL_COMMIT_SHA=$(jq -r '.skill_commit_sha // empty' "$GOAL_FILE" 2>/dev/null || echo "")
fi
SKILL_VERSION_SIDECAR="${STATE_DIR}/plan-w-team-skill-version-${SLUG}.json"
if [ -z "$SKILL_VERSION" ] && [ -f "$SKILL_VERSION_SIDECAR" ] && command -v jq >/dev/null 2>&1; then
  SKILL_VERSION=$(jq -r '.skill_version // empty' "$SKILL_VERSION_SIDECAR" 2>/dev/null || echo "")
fi
if [ -z "$SKILL_COMMIT_SHA" ] && [ -f "$SKILL_VERSION_SIDECAR" ] && command -v jq >/dev/null 2>&1; then
  SKILL_COMMIT_SHA=$(jq -r '.skill_commit_sha // empty' "$SKILL_VERSION_SIDECAR" 2>/dev/null || echo "")
fi
[ -z "$SKILL_VERSION" ] && SKILL_VERSION="unknown"
[ -z "$SKILL_COMMIT_SHA" ] && SKILL_COMMIT_SHA="unknown"

ENDED_AT="$GENERATED_AT"
ELAPSED_SECONDS=0
if [ -n "$STARTED_AT" ]; then
  if command -v gdate >/dev/null 2>&1; then
    S=$(gdate -u -d "$STARTED_AT" +%s 2>/dev/null || echo 0)
    E=$(gdate -u -d "$ENDED_AT" +%s 2>/dev/null || echo 0)
  else
    S=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$STARTED_AT" +%s 2>/dev/null || echo 0)
    E=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$ENDED_AT" +%s 2>/dev/null || echo 0)
  fi
  if [ "$S" -gt 0 ] && [ "$E" -gt 0 ]; then
    ELAPSED_SECONDS=$((E - S))
  fi
fi

# -----------------------------------------------------------------------------
# Git: base commit, head, commits, diff stat
# -----------------------------------------------------------------------------
HEAD_COMMIT=""
BASE_COMMIT=""
DIFF_STAT_SUMMARY=""
FILES_CHANGED=0
INSERTIONS=0
DELETIONS=0
COMMITS_JSON='[]'

if git rev-parse --git-dir >/dev/null 2>&1; then
  HEAD_COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo "")
  # Try to find the worktree's base commit (parent of the worktree branch creation point).
  # In a worktree, the merge-base against origin/main approximates the worktree start.
  DEFAULT_BRANCH=$(git remote show origin 2>/dev/null | awk '/HEAD branch/ {print $NF}' || echo "main")
  [ -z "$DEFAULT_BRANCH" ] && DEFAULT_BRANCH="main"
  BASE_COMMIT=$(git merge-base "origin/${DEFAULT_BRANCH}" HEAD 2>/dev/null \
    || git merge-base "${DEFAULT_BRANCH}" HEAD 2>/dev/null \
    || git rev-parse "HEAD~10" 2>/dev/null \
    || echo "")
  if [ -n "$BASE_COMMIT" ]; then
    BASE_COMMIT_SHORT=$(git rev-parse --short "$BASE_COMMIT" 2>/dev/null || echo "$BASE_COMMIT")
    DIFF_STAT_SUMMARY=$(git diff --shortstat "${BASE_COMMIT}..HEAD" 2>/dev/null | sed 's/^ *//' || echo "")
    FILES_CHANGED=$(echo "$DIFF_STAT_SUMMARY" | grep -oE '[0-9]+ files? changed' | grep -oE '[0-9]+' || echo 0)
    INSERTIONS=$(echo "$DIFF_STAT_SUMMARY" | grep -oE '[0-9]+ insertions?' | grep -oE '[0-9]+' || echo 0)
    DELETIONS=$(echo "$DIFF_STAT_SUMMARY" | grep -oE '[0-9]+ deletions?' | grep -oE '[0-9]+' || echo 0)
    [ -z "$FILES_CHANGED" ] && FILES_CHANGED=0
    [ -z "$INSERTIONS" ] && INSERTIONS=0
    [ -z "$DELETIONS" ] && DELETIONS=0
    COMMITS_JSON=$(git log --pretty=format:'{"hash":"%h","subject":"%s"}' "${BASE_COMMIT}..HEAD" 2>/dev/null \
      | jq -s '.' 2>/dev/null \
      || echo '[]')
    BASE_COMMIT="$BASE_COMMIT_SHORT"
  fi
fi

# -----------------------------------------------------------------------------
# Test count delta
# -----------------------------------------------------------------------------
TEST_FILES_JSON='[]'
TEST_FILES_COUNT=0
if [ -n "$BASE_COMMIT" ] && git rev-parse --git-dir >/dev/null 2>&1; then
  TEST_FILES_LIST=$(git diff --name-only "${BASE_COMMIT}..HEAD" 2>/dev/null \
    | grep -E '\.(test|spec)\.[a-z]+$|\.bats$|_test\.go$|_test\.py$' \
    || echo "")
  if [ -n "$TEST_FILES_LIST" ]; then
    TEST_FILES_COUNT=$(echo "$TEST_FILES_LIST" | grep -c . || echo 0)
    TEST_FILES_JSON=$(echo "$TEST_FILES_LIST" | jq -R . | jq -s '.' 2>/dev/null || echo '[]')
  fi
fi

# -----------------------------------------------------------------------------
# Ship verdict
# -----------------------------------------------------------------------------
SHIP_VERDICT="UNKNOWN"
SHIP_EVIDENCE=""
if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
  # Require literal verdict tokens (PASS|FAIL|BLOCK) within a few words of the
  # phrase. Strict to avoid matching the regex literal itself in spec/docs prose.
  EVIDENCE_LINE=$(grep -oE 'ship-readiness-gate verdict[: ]+(PASS|FAIL|BLOCK)' "$TRANSCRIPT" 2>/dev/null | tail -1 || true)
  if [ -n "$EVIDENCE_LINE" ]; then
    SHIP_EVIDENCE="$EVIDENCE_LINE"
    if echo "$EVIDENCE_LINE" | grep -q 'PASS'; then
      SHIP_VERDICT="PASS"
    elif echo "$EVIDENCE_LINE" | grep -qE 'FAIL|BLOCK'; then
      SHIP_VERDICT="FAIL"
    fi
  fi
fi

# -----------------------------------------------------------------------------
# Build JSON output
# -----------------------------------------------------------------------------
to_json_array() {
  # Returns a JSON array from newline-delimited stdin input (one quoted string per
  # input line). Empty input → []. We awk-filter empty lines instead of `grep -v`
  # because grep exits 1 on no-match, which under pipefail collides with the
  # `|| fallback` and produces duplicate output.
  local result
  result=$(printf '%s\n' "$1" | awk 'NF' | jq -R . 2>/dev/null | jq -cs '.' 2>/dev/null)
  if [ -z "$result" ]; then
    echo '[]'
  else
    echo "$result"
  fi
}

DECLARED_ARR=$(to_json_array "$DECLARED_LIST")
PASSED_ARR=$(to_json_array "$PASSED_IN_DECLARED")
FAILED_ARR=$(to_json_array "$FAILED_IN_DECLARED")
MISSING_ARR=$(to_json_array "$MISSING")

# Strip HOLISTIC_CHECK_ prefix for the json field so the literal value matches the
# four documented outcomes (PASS|FAIL|SKIPPED|UNKNOWN).
HC_SHORT=${HOLISTIC_CHECK#HOLISTIC_CHECK_}

if command -v jq >/dev/null 2>&1; then
  jq -n \
    --arg slug "$SLUG" \
    --arg generated_at "$GENERATED_AT" \
    --arg writer_version "$WRITER_VERSION" \
    --arg skill_version "$SKILL_VERSION" \
    --arg skill_commit_sha "$SKILL_COMMIT_SHA" \
    --arg spec_path "$SPEC_PATH" \
    --arg ac_snapshot_path "$AC_SNAPSHOT" \
    --arg transcript_path "${TRANSCRIPT:-}" \
    --arg started_at "$STARTED_AT" \
    --arg ended_at "$ENDED_AT" \
    --argjson elapsed_seconds "$ELAPSED_SECONDS" \
    --argjson declared "$DECLARED_ARR" \
    --argjson passed "$PASSED_ARR" \
    --argjson failed "$FAILED_ARR" \
    --argjson missing "$MISSING_ARR" \
    --arg holistic_check "$HC_SHORT" \
    --argjson stages "$STAGES_JSON" \
    --arg base_commit "$BASE_COMMIT" \
    --arg head_commit "$HEAD_COMMIT" \
    --argjson commits "$COMMITS_JSON" \
    --argjson files_changed "${FILES_CHANGED:-0}" \
    --argjson insertions "${INSERTIONS:-0}" \
    --argjson deletions "${DELETIONS:-0}" \
    --arg diff_stat_summary "$DIFF_STAT_SUMMARY" \
    --argjson test_files_count "$TEST_FILES_COUNT" \
    --argjson test_files "$TEST_FILES_JSON" \
    --arg ship_verdict "$SHIP_VERDICT" \
    --arg ship_evidence "$SHIP_EVIDENCE" \
    '{
      slug: $slug,
      generated_at: $generated_at,
      writer_version: $writer_version,
      skill_version: $skill_version,
      skill_commit_sha: $skill_commit_sha,
      spec_path: $spec_path,
      ac_snapshot_path: $ac_snapshot_path,
      transcript_path: $transcript_path,
      duration: {
        started_at: $started_at,
        ended_at: $ended_at,
        elapsed_seconds: $elapsed_seconds
      },
      ac_rollup: {
        declared: $declared,
        passed: $passed,
        failed: $failed,
        missing: $missing,
        holistic_check: $holistic_check
      },
      stages: $stages,
      git: {
        base_commit: $base_commit,
        head_commit: $head_commit,
        commits: $commits,
        files_changed: $files_changed,
        insertions: $insertions,
        deletions: $deletions,
        diff_stat_summary: $diff_stat_summary
      },
      tests: {
        added_or_modified_files: $test_files_count,
        files: $test_files
      },
      ship: {
        verdict: $ship_verdict,
        evidence_line: $ship_evidence
      }
    }' > "$JSON_OUT" 2>/dev/null || {
      # jq fallback — emit minimal stub
      printf '{"slug":"%s","generated_at":"%s","writer_version":"%s","ac_rollup":{"holistic_check":"UNKNOWN"},"error":"jq-failed"}\n' \
        "$SLUG" "$GENERATED_AT" "$WRITER_VERSION" > "$JSON_OUT"
    }
else
  printf '{"slug":"%s","generated_at":"%s","writer_version":"%s","ac_rollup":{"holistic_check":"UNKNOWN"},"error":"jq-missing"}\n' \
    "$SLUG" "$GENERATED_AT" "$WRITER_VERSION" > "$JSON_OUT"
fi

# -----------------------------------------------------------------------------
# Build Markdown output
# -----------------------------------------------------------------------------
declared_md=$(echo "$DECLARED_LIST" | sed 's/^/- /' | grep -v '^- $' || echo "- _(none declared)_")
passed_md=$(echo "$PASSED_IN_DECLARED" | sed 's/^/- /' | grep -v '^- $' || echo "- _(none)_")
failed_md=$(echo "$FAILED_IN_DECLARED" | sed 's/^/- /' | grep -v '^- $' || echo "- _(none)_")
missing_md=$(echo "$MISSING" | sed 's/^/- /' | grep -v '^- $' || echo "- _(none)_")
commits_md=""
if command -v jq >/dev/null 2>&1; then
  commits_md=$(echo "$COMMITS_JSON" | jq -r '.[] | "- `\(.hash)` \(.subject)"' 2>/dev/null || echo "")
fi
[ -z "$commits_md" ] && commits_md="- _(none)_"
tests_md=""
if command -v jq >/dev/null 2>&1; then
  tests_md=$(echo "$TEST_FILES_JSON" | jq -r '.[]? | "- `\(.)`"' 2>/dev/null || echo "")
fi
[ -z "$tests_md" ] && tests_md="- _(none)_"

cat > "$MD_OUT" <<EOF
# /plan-w-team Completion Summary — \`${SLUG}\`

- **Generated:** ${GENERATED_AT}
- **Writer version:** ${WRITER_VERSION}
- **Skill version:** ${SKILL_VERSION} (commit \`${SKILL_COMMIT_SHA}\`)
- **Spec:** \`${SPEC_PATH}\`
- **Transcript:** \`${TRANSCRIPT:-(not found — discovery fell through)}\`

## Duration

- Started: \`${STARTED_AT:-unknown}\`
- Ended:   \`${ENDED_AT}\`
- Elapsed: \`${ELAPSED_SECONDS}s\`

## AC Roll-Up

**Declared (${DECLARED_COUNT}):**
${declared_md}

**Passed (${PASSED_COUNT}):**
${passed_md}

**Failed (${FAILED_COUNT}):**
${failed_md}

**Missing (${MISSING_COUNT}):**
${missing_md}

## Spec Compliance Check

Outcome: **${HOLISTIC_CHECK}**

EOF

case "$HOLISTIC_CHECK" in
  HOLISTIC_CHECK_PASS)
    echo "All ${DECLARED_COUNT} declared acceptance criteria appeared as PASS or FAIL in the transcript. Spec contract honored." >> "$MD_OUT"
    ;;
  HOLISTIC_CHECK_FAIL)
    {
      echo "${MISSING_COUNT} declared AC(s) had no PASS or FAIL verdict in the transcript:"
      echo ""
      echo "$MISSING" | sed 's/^/- /' | grep -v '^- $' || true
      echo ""
      echo "These ACs were promised by the spec but never verified. Either:"
      echo "1. The run shipped without testing them — open a follow-up."
      echo "2. The verdict was emitted with non-standard wording — fix the AC trigger phrasing."
    } >> "$MD_OUT"
    ;;
  HOLISTIC_CHECK_SKIPPED)
    echo "Spec declares no \`AC<N>:\` entries (e.g., docs-only or pure-refactor feature). Holistic check is not applicable." >> "$MD_OUT"
    ;;
  HOLISTIC_CHECK_UNKNOWN)
    echo "Could not locate the worker transcript via known discovery heuristics. AC verdicts cannot be cross-checked. The summary's other fields (git, tests, duration) are still authoritative; only the AC roll-up is best-effort." >> "$MD_OUT"
    ;;
esac

cat >> "$MD_OUT" <<EOF

## Git Activity

- Base commit: \`${BASE_COMMIT:-unknown}\`
- HEAD: \`${HEAD_COMMIT:-unknown}\`
- Files changed: ${FILES_CHANGED} (+${INSERTIONS} / -${DELETIONS})
- Diff stat: \`${DIFF_STAT_SUMMARY:-(empty)}\`

### Commits

${commits_md}

## Tests Added or Modified (${TEST_FILES_COUNT})

${tests_md}

## Ship Verdict

- **Verdict:** ${SHIP_VERDICT}
- **Evidence line:** \`${SHIP_EVIDENCE:-(not found in transcript)}\`

---

_Generated by \`.claude/scripts/plan-w-team-completion-summary.sh\`. See \`docs/specs/retro-completion-summary.md\` for the schema contract and \`docs/specs/reporting-holistic-check.md\` for the HOLISTIC_CHECK semantics._
EOF

# -----------------------------------------------------------------------------
# Hook 1 (additive, OFF by default) — emit a self-contained HTML run-report
# alongside the .md/.json above. Gated behind PWT_EMIT_HTML_REPORT (default OFF).
# Reads the EXISTING completion JSON ($JSON_OUT) — invents no new telemetry.
# Two layers of fail-open: the `|| true` here AND the renderer's own `exit 0`.
# The existing .md/.json output above is byte-for-byte unchanged when disabled.
# Spec: docs/specs/weave-visual-artifacts-*.md
# -----------------------------------------------------------------------------
if [ "${PWT_EMIT_HTML_REPORT:-0}" = "1" ]; then
  HTML_OUT="${STATE_DIR}/plan-w-team-completion-${SLUG}.html"
  # Resolve the renderer as a SIBLING of this script (CWD-independent) — the
  # writer may run from any CWD (retro stage, tests). Fall back to the
  # CWD-relative path only if the sibling is somehow absent.
  RENDERER="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/plan-w-team-render-artifact.sh"
  [ -x "$RENDERER" ] || RENDERER=".claude/scripts/plan-w-team-render-artifact.sh"
  if [ -x "$RENDERER" ]; then
    "$RENDERER" --kind completion --data "$JSON_OUT" --out "$HTML_OUT" \
      --title "plan-w-team run report — ${SLUG}" >/dev/null 2>&1 || true
  fi
fi

# Always exit 0 — never break the retro.
exit 0
