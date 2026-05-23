#!/bin/bash
# pwt-conflict-detector — detect file-overlap conflicts between pending
# /plan-w-team task directives.
#
# Sits alongside ram-budget.sh (machine-wide RAM cap) and pwt-fair-share.sh
# (cross-repo fairness). Where those two gate on capacity, this one gates on
# inter-task file overlap inside a single repo's spawn batch.
#
# Input: one or more task-directive file paths as argv.
#
# Output (always JSON to stdout; soft errors → fail-open advisory JSON):
#
#   {
#     "parallel_safe_groups": [["C"], ["A", "B"]],
#     "reasons": {
#       "A": ["shared file shared/supervisor-protocol.md with task B"],
#       "B": ["shared file shared/supervisor-protocol.md with task A"],
#       "C": []
#     },
#     "tasks_with_unknown_scope": [],
#     "skipped": []
#   }
#
# Semantics:
#   - Tasks within the same group must run SERIAL (they share at least one file).
#   - Tasks across different groups are PARALLEL-SAFE.
#   - Grouping is transitive (A↔B and B↔C ⇒ {A,B,C} share one group).
#   - Empty file-set ("unknown scope") is reported but always parallel-safe.
#
# See docs/specs/task-conflict-detector.md and shared/supervisor-protocol.md
# §CAPACITY & CONFLICT ANALYSIS.

set -u

if [ "$#" -eq 0 ]; then
    cat <<'EOF'
{
  "parallel_safe_groups": [],
  "reasons": {},
  "tasks_with_unknown_scope": [],
  "skipped": [],
  "note": "no directive files supplied"
}
EOF
    exit 0
fi

# Working dirs.
WORK_DIR=$(mktemp -d -t pwt-cd.XXXXXX 2>/dev/null) || {
    echo '{"parallel_safe_groups":[],"reasons":{},"tasks_with_unknown_scope":[],"skipped":[],"note":"mktemp_failed"}'
    exit 0
}
trap 'rm -rf "$WORK_DIR"' EXIT

TASK_IDS_FILE="$WORK_DIR/task_ids"          # one id per line
FILES_DIR="$WORK_DIR/files"                  # one file per task: list of paths
SKIPPED_FILE="$WORK_DIR/skipped"
mkdir -p "$FILES_DIR"
: > "$TASK_IDS_FILE"
: > "$SKIPPED_FILE"

# ─── Derive task_id from filename (basename without extension, sanitized) ──
sanitize_task_id() {
    local raw="$1"
    raw=$(basename -- "$raw")
    raw="${raw%.*}"
    # Replace any char outside [A-Za-z0-9._-] with '_'.
    printf '%s' "$raw" | sed -E 's/[^A-Za-z0-9._-]/_/g'
}

# ─── Extract anticipated paths from a directive ──────────────────────────────
# Patterns recognized:
#   .claude/scripts/<name>.sh
#   .claude/commands/<path>.md
#   .claude/hooks/<name>.sh
#   shared/<path>.md
#   docs/specs/<name>.md
#   tests/skill/<path>.bats
extract_paths() {
    local file="$1"
    grep -oE '(\.claude/scripts/[A-Za-z0-9_.-]+\.sh|\.claude/commands/[A-Za-z0-9_./-]+\.md|\.claude/hooks/[A-Za-z0-9_.-]+\.sh|shared/[A-Za-z0-9_./-]+\.md|docs/specs/[A-Za-z0-9_.-]+\.md|tests/skill/[A-Za-z0-9_./-]+\.bats)' \
        "$file" 2>/dev/null \
        | sort -u
}

# ─── Pass 1: collect files per task ──────────────────────────────────────────
for directive in "$@"; do
    if [ ! -r "$directive" ]; then
        sanitize_task_id "$directive" >> "$SKIPPED_FILE"
        printf '\n' >> "$SKIPPED_FILE"
        echo "WARN: cannot read directive '$directive' — skipping" >&2
        continue
    fi
    tid=$(sanitize_task_id "$directive")
    # Disambiguate duplicate ids by appending a sequence number.
    if grep -qxF "$tid" "$TASK_IDS_FILE" 2>/dev/null; then
        n=1
        while grep -qxF "${tid}_${n}" "$TASK_IDS_FILE" 2>/dev/null; do
            n=$(( n + 1 ))
        done
        tid="${tid}_${n}"
    fi
    echo "$tid" >> "$TASK_IDS_FILE"
    extract_paths "$directive" > "$FILES_DIR/$tid"
done

# ─── Pass 2: pairwise intersection + union-find grouping ─────────────────────
# Bash 3.2-safe — no associative arrays. Parent map is a flat file:
# one "tid<TAB>parent_tid" row per task.
PARENT_FILE="$WORK_DIR/parent"
: > "$PARENT_FILE"
while IFS= read -r tid; do
    printf '%s\t%s\n' "$tid" "$tid" >> "$PARENT_FILE"
done < "$TASK_IDS_FILE"

uf_find() {
    local x="$1"
    while :; do
        local p
        p=$(awk -F'\t' -v k="$x" '$1==k {print $2; exit}' "$PARENT_FILE")
        [ -z "$p" ] && { printf '%s' "$x"; return; }
        if [ "$p" = "$x" ]; then
            printf '%s' "$x"
            return
        fi
        x="$p"
    done
}

uf_union() {
    local a="$1" b="$2"
    local ra rb
    ra=$(uf_find "$a")
    rb=$(uf_find "$b")
    [ "$ra" = "$rb" ] && return
    # Point ra's root at rb.
    local tmp
    tmp=$(mktemp -t pwt-cd-parent.XXXXXX 2>/dev/null) || return
    awk -F'\t' -v k="$ra" -v v="$rb" \
        'BEGIN{OFS="\t"} { if ($1==k) print $1, v; else print $0 }' \
        "$PARENT_FILE" > "$tmp" && mv "$tmp" "$PARENT_FILE"
}

# Reasons map: a JSONL-ish flat file, "tid<TAB>peer<TAB>shared_file" per row.
REASONS_FILE="$WORK_DIR/reasons"
: > "$REASONS_FILE"

# Read task ids into a bash array (Bash 3.2-safe — no mapfile).
TIDS=()
while IFS= read -r line; do
    [ -n "$line" ] && TIDS+=("$line")
done < "$TASK_IDS_FILE"

N=${#TIDS[@]}

# Pairwise compare.
i=0
while [ "$i" -lt "$N" ]; do
    a="${TIDS[$i]}"
    j=$(( i + 1 ))
    while [ "$j" -lt "$N" ]; do
        b="${TIDS[$j]}"
        # Intersection via comm -12. Both inputs already sorted.
        intersection=$(comm -12 "$FILES_DIR/$a" "$FILES_DIR/$b" 2>/dev/null)
        if [ -n "$intersection" ]; then
            uf_union "$a" "$b"
            while IFS= read -r shared; do
                [ -z "$shared" ] && continue
                printf '%s\t%s\t%s\n' "$a" "$b" "$shared" >> "$REASONS_FILE"
                printf '%s\t%s\t%s\n' "$b" "$a" "$shared" >> "$REASONS_FILE"
            done <<< "$intersection"
        fi
        j=$(( j + 1 ))
    done
    i=$(( i + 1 ))
done

# ─── Build groups by following each task's root ──────────────────────────────
GROUPS_FILE="$WORK_DIR/groups"  # root<TAB>tid
: > "$GROUPS_FILE"
for tid in "${TIDS[@]}"; do
    root=$(uf_find "$tid")
    printf '%s\t%s\n' "$root" "$tid" >> "$GROUPS_FILE"
done

# Distinct roots in insertion order.
ROOTS_FILE="$WORK_DIR/roots"
awk -F'\t' '!seen[$1]++ {print $1}' "$GROUPS_FILE" > "$ROOTS_FILE"

# ─── Tasks with unknown scope (empty file set) ───────────────────────────────
UNKNOWN_FILE="$WORK_DIR/unknown"
: > "$UNKNOWN_FILE"
for tid in "${TIDS[@]}"; do
    if [ ! -s "$FILES_DIR/$tid" ]; then
        echo "$tid" >> "$UNKNOWN_FILE"
    fi
done

# ─── Emit JSON ────────────────────────────────────────────────────────────────
# JSON array of arrays for parallel_safe_groups.
json_array_of_strings() {
    local file="$1"
    local first=1
    printf '['
    while IFS= read -r v; do
        [ -z "$v" ] && continue
        if [ "$first" -eq 1 ]; then first=0; else printf ', '; fi
        printf '"%s"' "$v"
    done < "$file"
    printf ']'
}

printf '{\n'
printf '  "parallel_safe_groups": ['
first_group=1
while IFS= read -r root; do
    [ -z "$root" ] && continue
    if [ "$first_group" -eq 1 ]; then first_group=0; else printf ', '; fi
    members_tmp="$WORK_DIR/members.$$"
    awk -F'\t' -v r="$root" '$1==r {print $2}' "$GROUPS_FILE" > "$members_tmp"
    json_array_of_strings "$members_tmp"
    rm -f "$members_tmp"
done < "$ROOTS_FILE"
printf '],\n'

# reasons object
printf '  "reasons": {'
first_reason=1
for tid in "${TIDS[@]}"; do
    if [ "$first_reason" -eq 1 ]; then first_reason=0; else printf ', '; fi
    printf '"%s": [' "$tid"
    # Unique "shared file <path> with task <peer>" strings.
    awk -F'\t' -v t="$tid" '$1==t {printf "shared file %s with task %s\n", $3, $2}' "$REASONS_FILE" \
        | sort -u > "$WORK_DIR/r.$tid.$$"
    first_msg=1
    while IFS= read -r msg; do
        [ -z "$msg" ] && continue
        if [ "$first_msg" -eq 1 ]; then first_msg=0; else printf ', '; fi
        printf '"%s"' "$msg"
    done < "$WORK_DIR/r.$tid.$$"
    rm -f "$WORK_DIR/r.$tid.$$"
    printf ']'
done
printf '},\n'

# unknown scope list
printf '  "tasks_with_unknown_scope": '
json_array_of_strings "$UNKNOWN_FILE"
printf ',\n'

# skipped list
printf '  "skipped": '
json_array_of_strings "$SKIPPED_FILE"
printf '\n'
printf '}\n'
