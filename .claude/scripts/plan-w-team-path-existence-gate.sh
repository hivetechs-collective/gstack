#!/usr/bin/env bash
# plan-w-team-path-existence-gate.sh  (GRD — Step-2 grounding floor, G2 follow-on)
#
# Deterministic path-existence gate for the Step-2 task breakdown. It closes the
# recursive-followups row-24 defect: files_touched/creates_types annotations are
# LLM-guessed and never validated against the working tree, so a `(create)`
# target that already exists — or a `(modify)` path that does not exist — passes
# straight into the ENFORCING scope-lock and the builder prompts.
#
# It is the deterministic-floor sibling of the import-coupling analyzer
# (plan-w-team-import-coupling.ts) — same tasks-json input, same exit-code
# contract, same ack escape hatch — and it shares the grounding family kill
# switch with plan-w-team-grounding-gate.sh. Implemented in bash + jq (no node
# dependency) so it runs in a bg worker whose PATH lacks tsx/node.
#
# The check (intra-breakdown-aware — the load-bearing subtlety):
#   1. Build CREATED_SET = every files_touched entry annotated `(create)`
#      PLUS every creates_types[].location, across ALL tasks.
#   2. `(create)` target that EXISTS on disk           → violation create-exists
#   3. `(modify)` target that is MISSING on disk AND
#      is NOT in CREATED_SET (i.e. no sibling task
#      creates it first)                               → violation modify-missing
#   4. unannotated bare paths                          → recorded, not asserted
# Step 3's CREATED_SET carve-out is what prevents the obvious false positive
# (Task 3 modifies a file Task 1 creates) while still catching the real defect.
#
# Kill switch (consistent with the PLAN_W_TEAM_DISABLE_* / G2 family):
#   PLAN_W_TEAM_DISABLE_GROUNDING=1 → exit 0 with a grep-able notice, never blocks.
#
# Usage:
#   plan-w-team-path-existence-gate.sh --slug <slug> [--tasks-json <path>] \
#       [--root <dir>] [--report <path>] [--ack]
#   (default tasks-json: /tmp/tasks-<slug>.json ; default report:
#    <root>/.claude/state/plan-w-team-path-existence-<slug>.json)
#
# Exit codes (mirror plan-w-team-import-coupling.ts):
#   0 — clean (no violations) OR kill switch active
#   1 — violations detected, no ack present
#   2 — violations detected AND acknowledged (--ack flag or ack file)
#   3 — environment error (missing jq, missing/invalid tasks-json, bad args)
#
# Env:
#   PWT_PROJECT_ROOT_OVERRIDE — working-tree root when --root is not given
#                               (worktree-safe; honored before git/pwd).
#
# bash 3.2 compatible (no associative arrays, no mapfile).

set -u

PROG="plan-w-team-path-existence-gate"

# ── Kill switch ──────────────────────────────────────────────────────────────
if [ "${PLAN_W_TEAM_DISABLE_GROUNDING:-}" = "1" ]; then
  echo "[$PROG] PLAN_W_TEAM_DISABLE_GROUNDING=1 — path-existence gate disabled (exit 0)"
  exit 0
fi

# ── Arg parsing (safe shift — see grounding-gate.sh for the trailing-flag hang) ─
SLUG=""
TASKS_JSON=""
ROOT=""
REPORT=""
ACK_FLAG=0
while [ $# -gt 0 ]; do
  case "$1" in
    --slug)       SLUG="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
    --tasks-json) TASKS_JSON="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
    --root)       ROOT="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
    --report)     REPORT="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
    --ack)        ACK_FLAG=1; shift ;;
    -h|--help)    grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -60; exit 0 ;;
    *)            shift ;;
  esac
done

if [ -z "$SLUG" ]; then
  echo "[$PROG] ✗ --slug is required" >&2
  exit 3
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "[$PROG] ✗ jq not found on PATH (required)" >&2
  exit 3
fi

# ── Resolve working-tree root ────────────────────────────────────────────────
if [ -z "$ROOT" ]; then
  if [ -n "${PWT_PROJECT_ROOT_OVERRIDE:-}" ]; then
    ROOT="$PWT_PROJECT_ROOT_OVERRIDE"
  else
    ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  fi
fi
[ -d "$ROOT" ] || { echo "[$PROG] ✗ root not a directory: $ROOT" >&2; exit 3; }

[ -n "$TASKS_JSON" ] || TASKS_JSON="/tmp/tasks-${SLUG}.json"
[ -n "$REPORT" ] || REPORT="$ROOT/.claude/state/plan-w-team-path-existence-${SLUG}.json"

if [ ! -f "$TASKS_JSON" ]; then
  echo "[$PROG] ✗ tasks-json not found: $TASKS_JSON" >&2
  echo "[$PROG]   (produce it at Step 2: TaskList → this run's tasks → /tmp/tasks-$SLUG.json)" >&2
  exit 3
fi
if ! jq empty "$TASKS_JSON" >/dev/null 2>&1; then
  echo "[$PROG] ✗ tasks-json is not valid JSON: $TASKS_JSON" >&2
  exit 3
fi

# ── Extract annotated path stream: "kind<TAB>task_id<TAB>path" ───────────────
# Normalizes a bare Task[] array OR an object with a .tasks array. Annotation
# parse: trailing "(create)"/"(modify)" (case-insensitive); everything else is
# "unchecked". creates_types[].location contributes to CREATED_SET as "typeloc".
JQ_EXTRACT='
  def norm: if type=="array" then . else (.tasks // []) end;
  def trim: gsub("^\\s+|\\s+$"; "");
  def parse_entry:
    (. | trim) as $t
    | if ($t | test("\\((create|modify)\\)\\s*$"; "i"))
      then ($t | capture("^(?<p>.*?)\\s*\\((?<a>create|modify)\\)\\s*$"; "i"))
           | { kind: (.a | ascii_downcase), path: (.p | trim) }
      else { kind: "unchecked", path: $t }
      end;
  norm
  | .[]
  | (.id // "?") as $id
  | (
      ((.files_touched // [])[] | parse_entry | "\(.kind)\t\($id)\t\(.path)"),
      ((.creates_types // [])[] | select(.location != null) | "typeloc\t\($id)\t\(.location)")
    )
'
STREAM="$(jq -r "$JQ_EXTRACT" "$TASKS_JSON" 2>/dev/null)" || {
  echo "[$PROG] ✗ failed to parse tasks from $TASKS_JSON" >&2
  exit 3
}

TASK_COUNT="$(jq -r 'if type=="array" then length else ((.tasks // []) | length) end' "$TASKS_JSON" 2>/dev/null || echo 0)"

# ── Pass 1: build CREATED_SET (newline-delimited; bash 3.2 has no assoc arrays) ─
# A path is "created" if any task annotates it (create) or lists it as a type
# location. Leading "./" is stripped so annotations and disk paths compare 1:1.
strip_dot() { printf '%s' "${1#./}"; }
CREATED_SET=""
while IFS="$(printf '\t')" read -r kind tid path; do
  [ -n "$path" ] || continue
  path="$(strip_dot "$path")"
  case "$kind" in
    create|typeloc) CREATED_SET="${CREATED_SET}${path}
" ;;
  esac
done <<EOF
$STREAM
EOF

in_created_set() {
  # grep -Fxq: fixed-string, whole-line match against the set.
  printf '%s\n' "$CREATED_SET" | grep -Fxq -- "$1"
}

# ── Pass 2: evaluate violations ──────────────────────────────────────────────
VIOL_TSV=""   # "reason<TAB>task_id<TAB>path" lines
CHECKED=0
while IFS="$(printf '\t')" read -r kind tid path; do
  [ -n "$path" ] || continue
  path="$(strip_dot "$path")"
  case "$kind" in
    create)
      CHECKED=$((CHECKED + 1))
      if [ -e "$ROOT/$path" ]; then
        VIOL_TSV="${VIOL_TSV}create-exists	${tid}	${path}
"
      fi
      ;;
    modify)
      CHECKED=$((CHECKED + 1))
      if [ ! -e "$ROOT/$path" ] && ! in_created_set "$path"; then
        VIOL_TSV="${VIOL_TSV}modify-missing	${tid}	${path}
"
      fi
      ;;
  esac
done <<EOF
$STREAM
EOF

VIOL_COUNT=0
if [ -n "$(printf '%s' "$VIOL_TSV" | tr -d '[:space:]')" ]; then
  VIOL_COUNT="$(printf '%s' "$VIOL_TSV" | grep -c '	' || true)"
fi

# ── Ack resolution ───────────────────────────────────────────────────────────
ACK_FILE="$ROOT/.claude/state/plan-w-team-path-existence-ack-${SLUG}"
ACKED=0
if [ "$ACK_FLAG" = "1" ] || [ -f "$ACK_FILE" ]; then
  ACKED=1
fi
ACK_REQUIRED="false"
[ "$VIOL_COUNT" -gt 0 ] && [ "$ACKED" != "1" ] && ACK_REQUIRED="true"

# ── Write JSON report ────────────────────────────────────────────────────────
COMPUTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$(dirname "$REPORT")"
VIOL_JSON="$(printf '%s' "$VIOL_TSV" | jq -R -s '
  split("\n") | map(select(length > 0) | split("\t"))
  | map({ reason: .[0], task_id: .[1], path: .[2] })
')"
CREATED_JSON="$(printf '%s' "$CREATED_SET" | jq -R -s '
  split("\n") | map(select(length > 0)) | unique
')"
jq -n \
  --arg slug "$SLUG" \
  --arg computed_at "$COMPUTED_AT" \
  --argjson task_count "${TASK_COUNT:-0}" \
  --argjson checked "${CHECKED:-0}" \
  --argjson violations "$VIOL_JSON" \
  --argjson created_set "$CREATED_JSON" \
  --argjson ack_required "$ACK_REQUIRED" \
  '{
    schema_version: 1,
    slug: $slug,
    computed_at: $computed_at,
    task_count: $task_count,
    paths_checked: $checked,
    created_set: $created_set,
    violations: $violations,
    ack_required: $ack_required
  }' > "$REPORT"

# ── Human-readable summary + verdict ─────────────────────────────────────────
REL_REPORT="${REPORT#$ROOT/}"
if [ "$VIOL_COUNT" -eq 0 ]; then
  echo "[$PROG] ✓ $CHECKED annotated path(s) validated against the working tree, no violations"
  echo "[$PROG]   report: $REL_REPORT"
  exit 0
fi

echo "[$PROG] ✗ $VIOL_COUNT path-existence violation(s):" >&2
printf '%s' "$VIOL_TSV" | while IFS="$(printf '\t')" read -r reason tid path; do
  [ -n "$path" ] || continue
  if [ "$reason" = "create-exists" ]; then
    echo "  [T$tid] (create) target already exists: $path" >&2
  else
    echo "  [T$tid] (modify) target does not exist: $path" >&2
  fi
done
echo "[$PROG]   report: $REL_REPORT" >&2

if [ "$ACKED" = "1" ]; then
  echo "[$PROG]   acknowledged (ack present) — exit 2" >&2
  exit 2
fi
echo "[$PROG]   Fix the breakdown annotations and re-run, OR write a one-line" >&2
echo "[$PROG]   justification to: .claude/state/plan-w-team-path-existence-ack-$SLUG" >&2
exit 1
