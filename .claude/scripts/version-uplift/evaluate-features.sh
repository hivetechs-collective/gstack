#!/usr/bin/env bash
# evaluate-features.sh — classify changelog entries against integration points.
#
# Input: structured changelog JSON (output of fetch-changelog.sh).
# Output: markdown + JSON report classifying each entry as one of:
#   - already-adopted
#   - candidate-for-adoption
#   - not-applicable
#   - breaking-change-required
#
# Decision matrix (matches §6.1 of the spec):
#   matched_surface=No                                  -> not-applicable
#   matched_surface=Yes + used_in_repo=Yes + breaking=Y -> breaking-change-required
#   matched_surface=Yes + used_in_repo=Yes + breaking=N -> already-adopted
#   matched_surface=Yes + used_in_repo=No               -> candidate-for-adoption
#
# Dependencies: jq.
#
# Flags:
#   --changelog=PATH       Path to changelog JSON (default: stdin).
#   --catalog=PATH         Path to integration-points.json.
#   --repo-root=PATH       Root used for repo probes (default: $PWD).
#   --output-json=PATH     Write JSON report to PATH.
#   --output-md=PATH       Write markdown report to PATH.
#
# Exit codes:
#   0  success
#   2  missing/unreadable input
#   3  malformed flag
#   4  jq not installed

set -euo pipefail

CHANGELOG=""
CATALOG=".claude/scripts/version-uplift/integration-points.json"
REPO_ROOT="$PWD"
OUTPUT_JSON=""
OUTPUT_MD=""

for arg in "$@"; do
    case "$arg" in
        --changelog=*) CHANGELOG="${arg#*=}" ;;
        --catalog=*) CATALOG="${arg#*=}" ;;
        --repo-root=*) REPO_ROOT="${arg#*=}" ;;
        --output-json=*) OUTPUT_JSON="${arg#*=}" ;;
        --output-md=*) OUTPUT_MD="${arg#*=}" ;;
        --help|-h)
            sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "evaluate-features.sh: unknown arg: $arg" >&2
            exit 3
            ;;
    esac
done

if ! command -v jq >/dev/null 2>&1; then
    echo "evaluate-features.sh: jq is required but not in PATH" >&2
    exit 4
fi

if [ ! -f "$CATALOG" ]; then
    echo "evaluate-features.sh: catalog not found: $CATALOG" >&2
    exit 2
fi

# --- read changelog JSON ---
RAW=""
if [ -n "$CHANGELOG" ]; then
    if [ ! -f "$CHANGELOG" ]; then
        echo "evaluate-features.sh: changelog not found: $CHANGELOG" >&2
        exit 2
    fi
    RAW=$(cat "$CHANGELOG")
else
    RAW=$(cat)
fi

if [ -z "$RAW" ]; then
    echo "evaluate-features.sh: empty changelog input" >&2
    exit 2
fi

# Validate it's parseable JSON early.
if ! printf '%s' "$RAW" | jq empty 2>/dev/null; then
    echo "evaluate-features.sh: input is not valid JSON" >&2
    exit 2
fi

TMPDIR=$(mktemp -d -t uplift-eval-XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

# --- flatten entries: version<TAB>entry ---
ENTRIES_TSV="$TMPDIR/entries.tsv"
printf '%s' "$RAW" | jq -r '
    .versions[] as $v
    | $v.entries[]
    | [$v.version, .] | @tsv
' > "$ENTRIES_TSV"

if [ ! -s "$ENTRIES_TSV" ]; then
    echo "evaluate-features.sh: 0 entries parsed from changelog" >&2
    exit 2
fi

# --- flatten catalog: surface_id\tdescription\tkeyword (one row per keyword) ---
CATALOG_TSV="$TMPDIR/catalog.tsv"
jq -r '
    .surfaces[] as $s
    | $s.keywords[]
    | [$s.id, $s.description, .] | @tsv
' "$CATALOG" > "$CATALOG_TSV"

# Probe map: surface_id\tprobe_path (one row per probe).
PROBES_TSV="$TMPDIR/probes.tsv"
jq -r '
    .surfaces[] as $s
    | $s.repo_probes[]
    | [$s.id, .] | @tsv
' "$CATALOG" > "$PROBES_TSV"

# Per-surface auto_integrate_safe lookup. Missing field => false (defensive).
AUTOSAFE_TSV="$TMPDIR/autosafe.tsv"
jq -r '
    .surfaces[]
    | [.id, (.auto_integrate_safe // false | tostring)] | @tsv
' "$CATALOG" > "$AUTOSAFE_TSV"

auto_safe_for_surface() {
    awk -F'\t' -v s="$1" '$1==s{print $2; exit}' "$AUTOSAFE_TSV"
}

# Migration-risk keyword scan. Returns "true" if entry text contains any
# of: BREAKING, deprecat, remove, replace, api change, schema, config rename,
# env var rename. Case-insensitive on all but BREAKING (which must be uppercase
# per Claude Code changelog convention).
has_migration_risk() {
    local entry="$1"
    if printf '%s' "$entry" | grep -qE '\bBREAKING\b'; then
        printf 'true\n'
        return
    fi
    local lo
    lo=$(printf '%s' "$entry" | tr '[:upper:]' '[:lower:]')
    case "$lo" in
        *deprecat*|*remove*|*replace*|*"api change"*|*schema*|*"config rename"*|*"env var rename"*)
            printf 'true\n'
            ;;
        *)
            printf 'false\n'
            ;;
    esac
}

# --- cache "used in repo" verdict per surface_id ---
USED_FILE="$TMPDIR/used.tsv"
: > "$USED_FILE"
sort -u -k1,1 "$PROBES_TSV" | cut -f1 | sort -u | while IFS= read -r sid; do
    [ -z "$sid" ] && continue
    used="false"
    while IFS=$'\t' read -r psid path; do
        [ "$psid" = "$sid" ] || continue
        full="$REPO_ROOT/$path"
        if [ -e "$full" ]; then
            used="true"
            break
        fi
    done < "$PROBES_TSV"
    printf '%s\t%s\n' "$sid" "$used" >> "$USED_FILE"
done

used_for() {
    awk -F'\t' -v s="$1" '$1==s{print $2; exit}' "$USED_FILE"
}

# --- classification ---
REPORT_TSV="$TMPDIR/report.tsv"
: > "$REPORT_TSV"

# Lowercase helper.
lower() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

# For each entry, scan the catalog keywords (first match wins).
while IFS=$'\t' read -r ver entry; do
    [ -z "$ver" ] && continue
    entry_lo=$(lower "$entry")

    matched_id=""
    while IFS=$'\t' read -r sid _sdesc kw; do
        [ -z "$kw" ] && continue
        kw_lo=$(lower "$kw")
        case "$entry_lo" in
            *"$kw_lo"*)
                matched_id="$sid"
                break
                ;;
        esac
    done < "$CATALOG_TSV"

    # Determine BREAKING flag.
    breaking="false"
    if printf '%s' "$entry" | grep -qE '\bBREAKING\b'; then
        breaking="true"
    fi

    if [ -z "$matched_id" ]; then
        classification="not-applicable"
        surface="(none)"
        rationale="No integration-point keyword matched."
    else
        surface="$matched_id"
        used=$(used_for "$matched_id")
        if [ "$used" = "true" ]; then
            if [ "$breaking" = "true" ]; then
                classification="breaking-change-required"
                rationale="Surface '$matched_id' is in use AND changelog marks BREAKING — migration required."
            else
                classification="already-adopted"
                rationale="Surface '$matched_id' is in use; informational."
            fi
        else
            classification="candidate-for-adoption"
            rationale="Surface '$matched_id' matched but no repo probe matched — not yet adopted."
        fi
    fi

    # Compute auto_integrate_safe (defensive: defaults to false).
    # Criteria for true (all must hold):
    #   - classification == candidate-for-adoption
    #   - surface's auto_integrate_safe field == true
    #   - entry text contains no BREAKING/deprecat/remove/replace/migration-risk keywords
    auto_safe="false"
    if [ "$classification" = "candidate-for-adoption" ]; then
        surface_safe=$(auto_safe_for_surface "$matched_id")
        if [ "$surface_safe" = "true" ]; then
            risk=$(has_migration_risk "$entry")
            if [ "$risk" = "false" ]; then
                auto_safe="true"
            fi
        fi
    fi

    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$ver" "$classification" "$surface" "$entry" "$rationale" "$auto_safe" >> "$REPORT_TSV"
done < "$ENTRIES_TSV"

# --- emit reports ---
emit_md() {
    printf '# Claude Code Version Uplift Report\n\n'
    printf 'Generated: %s\n\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '## Summary\n\n'
    printf '| Classification | Count |\n'
    printf '| --- | ---: |\n'
    for cls in already-adopted candidate-for-adoption not-applicable breaking-change-required; do
        n=$(awk -F'\t' -v c="$cls" '$2==c{n++} END{print n+0}' "$REPORT_TSV")
        printf '| %s | %s |\n' "$cls" "$n"
    done
    printf '\n## Per-Entry Findings\n\n'
    cur_ver=""
    while IFS=$'\t' read -r ver cls surface entry rationale auto_safe; do
        if [ "$ver" != "$cur_ver" ]; then
            printf '\n### Version %s\n\n' "$ver"
            cur_ver="$ver"
        fi
        printf -- '- **[%s]** _(surface: %s)_ — %s\n' "$cls" "$surface" "$entry"
        printf '  - rationale: %s\n' "$rationale"
        printf '  - auto_integrate_safe: %s\n' "$auto_safe"
    done < "$REPORT_TSV"
    printf '\n## Next Steps\n\n'
    printf '1. Review **candidate-for-adoption** entries — each is a candidate for a follow-up `/plan-w-team` run to adopt the surface.\n'
    printf '2. **breaking-change-required** entries indicate a migration is needed in already-adopted surfaces — schedule immediately.\n'
    printf '3. **not-applicable** entries can be ignored.\n'
    printf '4. **already-adopted** entries are informational — confirm the `Features Adopted` table in `docs/operations/claude-code-compatibility.md` mentions them.\n'
}

emit_json() {
    # Build via jq to avoid hand-escaping.
    local generated_at
    generated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    awk -F'\t' '
        BEGIN { printf "{"
                printf "\"generated_at\":\"%s\",", "'"$generated_at"'"
                printf "\"summary\":{"
                # placeholders, refilled below
                printf "},"
                printf "\"findings\":["
                first=1
        }
        {
            if (!first) printf ",";
            first=0
            # Escape backslashes then quotes for JSON safety.
            ver=$1; cls=$2; sur=$3; ent=$4; rat=$5; safe=$6
            gsub(/\\/,"\\\\",ent); gsub(/"/,"\\\"",ent)
            gsub(/\\/,"\\\\",rat); gsub(/"/,"\\\"",rat)
            # auto_integrate_safe is a bare bool ("true" | "false")
            if (safe != "true") safe="false"
            printf "{\"version\":\"%s\",\"classification\":\"%s\",\"surface\":\"%s\",\"entry\":\"%s\",\"rationale\":\"%s\",\"auto_integrate_safe\":%s}",
                ver, cls, sur, ent, rat, safe
        }
        END { printf "]}\n" }
    ' "$REPORT_TSV" \
    | jq --arg generated_at "$generated_at" \
        --argjson aa "$(awk -F'\t' '$2=="already-adopted"{n++} END{print n+0}' "$REPORT_TSV")" \
        --argjson ca "$(awk -F'\t' '$2=="candidate-for-adoption"{n++} END{print n+0}' "$REPORT_TSV")" \
        --argjson na "$(awk -F'\t' '$2=="not-applicable"{n++} END{print n+0}' "$REPORT_TSV")" \
        --argjson bc "$(awk -F'\t' '$2=="breaking-change-required"{n++} END{print n+0}' "$REPORT_TSV")" \
        '.summary = {"already-adopted":$aa,"candidate-for-adoption":$ca,"not-applicable":$na,"breaking-change-required":$bc}'
}

if [ -n "$OUTPUT_MD" ]; then
    mkdir -p "$(dirname "$OUTPUT_MD")"
    emit_md > "$OUTPUT_MD"
fi
if [ -n "$OUTPUT_JSON" ]; then
    mkdir -p "$(dirname "$OUTPUT_JSON")"
    emit_json > "$OUTPUT_JSON"
fi
if [ -z "$OUTPUT_MD" ] && [ -z "$OUTPUT_JSON" ]; then
    emit_md
fi
