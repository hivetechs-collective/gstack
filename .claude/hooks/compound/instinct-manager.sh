#!/bin/bash
# Compound: Instinct Manager
# Manages instinct-based confidence scoring and project-scoped learnings
# Instincts are small YAML files representing learned behavioral patterns

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTINCTS_DIR="$SCRIPT_DIR/instincts"
GLOBAL_DIR="$INSTINCTS_DIR/global"
PROJECTS_DIR="$INSTINCTS_DIR/projects"

# Ensure directories exist
mkdir -p "$GLOBAL_DIR" "$PROJECTS_DIR"

# Detect project name from git root
detect_project_name() {
    local project_root
    project_root="$(cd "$SCRIPT_DIR/../../.." && pwd)"
    basename "$project_root"
}

# Generate 8-char ID from trigger+action
generate_id() {
    local trigger="$1"
    local action="$2"
    echo -n "${trigger}${action}" | shasum -a 256 | cut -c1-8
}

# Get the file path for an instinct by ID
find_instinct_file() {
    local instinct_id="$1"
    local found=""

    # Search global
    if [ -f "$GLOBAL_DIR/${instinct_id}.yaml" ]; then
        found="$GLOBAL_DIR/${instinct_id}.yaml"
    fi

    # Search all project directories
    if [ -z "$found" ]; then
        for proj_dir in "$PROJECTS_DIR"/*/; do
            if [ -f "${proj_dir}${instinct_id}.yaml" ]; then
                found="${proj_dir}${instinct_id}.yaml"
                break
            fi
        done
    fi

    echo "$found"
}

# Read a field value from a YAML instinct file
# Simple parser for our flat YAML format
read_yaml_field() {
    local file="$1"
    local field="$2"
    grep "^${field}:" "$file" 2>/dev/null | sed "s/^${field}: *//" | sed 's/^"//' | sed 's/"$//'
}

# Write/update a field in a YAML instinct file
update_yaml_field() {
    local file="$1"
    local field="$2"
    local value="$3"

    if grep -q "^${field}:" "$file" 2>/dev/null; then
        # Use a temp file for portable sed -i
        local tmpfile="${file}.tmp"
        sed "s|^${field}:.*|${field}: ${value}|" "$file" > "$tmpfile"
        mv "$tmpfile" "$file"
    fi
}

# Create a new instinct
# Args: trigger action confidence domain scope [project_name]
create_instinct() {
    local trigger="$1"
    local action="$2"
    local confidence="$3"
    local domain="$4"
    local scope="$5"
    local project_name="${6:-$(detect_project_name)}"

    # Validate confidence range (0.3 to 0.9)
    local conf_int
    conf_int=$(echo "$confidence" | sed 's/0\.//')
    if [ "$conf_int" -lt 3 ] 2>/dev/null || [ "$conf_int" -gt 9 ] 2>/dev/null; then
        echo "ERROR: confidence must be between 0.3 and 0.9" >&2
        return 1
    fi

    # Validate domain
    case "$domain" in
        code-style|testing|git|workflow|security) ;;
        *)
            echo "ERROR: domain must be one of: code-style, testing, git, workflow, security" >&2
            return 1
            ;;
    esac

    # Validate scope
    case "$scope" in
        project|global) ;;
        *)
            echo "ERROR: scope must be 'project' or 'global'" >&2
            return 1
            ;;
    esac

    local instinct_id
    instinct_id=$(generate_id "$trigger" "$action")

    # Check if instinct already exists
    local existing
    existing=$(find_instinct_file "$instinct_id")
    if [ -n "$existing" ]; then
        echo "Instinct $instinct_id already exists at $existing"
        echo "Use 'strengthen $instinct_id' instead."
        return 0
    fi

    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Determine target directory
    local target_dir
    if [ "$scope" = "global" ]; then
        target_dir="$GLOBAL_DIR"
    else
        target_dir="$PROJECTS_DIR/$project_name"
        mkdir -p "$target_dir"
    fi

    local target_file="$target_dir/${instinct_id}.yaml"

    # Write the YAML file
    {
        echo "---"
        echo "id: $instinct_id"
        echo "trigger: \"$trigger\""
        echo "confidence: $confidence"
        echo "domain: $domain"
        echo "scope: $scope"
        if [ "$scope" = "project" ]; then
            echo "project: $project_name"
        fi
        echo "created: $timestamp"
        echo "last_applied: null"
        echo "applications: 0"
        echo "evidence:"
        echo "  - \"First observed in session ${CLAUDE_SESSION_ID:-$(date +%s)}\""
        echo "---"
        echo "# Action"
        echo "$action"
    } > "$target_file"

    echo "Created instinct $instinct_id ($domain/$scope) at $target_file"
}

# Strengthen an instinct (increase confidence by 0.1, max 0.9)
# Args: instinct_id
strengthen_instinct() {
    local instinct_id="$1"

    local file
    file=$(find_instinct_file "$instinct_id")

    if [ -z "$file" ]; then
        echo "ERROR: Instinct $instinct_id not found" >&2
        return 1
    fi

    local current_confidence
    current_confidence=$(read_yaml_field "$file" "confidence")

    # Calculate new confidence (increment by 0.1, max 0.9)
    local new_confidence
    if command -v bc &> /dev/null; then
        new_confidence=$(echo "$current_confidence + 0.1" | bc)
        # Normalize leading zero (bc outputs .6 instead of 0.6)
        case "$new_confidence" in .*) new_confidence="0$new_confidence" ;; esac
        # Clamp to 0.9
        local over
        over=$(echo "$new_confidence > 0.9" | bc)
        if [ "$over" = "1" ]; then
            new_confidence="0.9"
        fi
    else
        # Fallback: integer arithmetic on tenths
        local tenths
        tenths=$(echo "$current_confidence" | sed 's/0\.//')
        tenths=$((tenths + 1))
        if [ "$tenths" -gt 9 ]; then
            tenths=9
        fi
        new_confidence="0.${tenths}"
    fi

    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Get current applications count
    local current_apps
    current_apps=$(read_yaml_field "$file" "applications")
    current_apps=${current_apps:-0}
    local new_apps=$((current_apps + 1))

    update_yaml_field "$file" "confidence" "$new_confidence"
    update_yaml_field "$file" "last_applied" "$timestamp"
    update_yaml_field "$file" "applications" "$new_apps"

    echo "Strengthened instinct $instinct_id: $current_confidence -> $new_confidence (applications: $new_apps)"
}

# Weaken an instinct (decrease confidence by 0.1, remove if < 0.3)
# Args: instinct_id
weaken_instinct() {
    local instinct_id="$1"

    local file
    file=$(find_instinct_file "$instinct_id")

    if [ -z "$file" ]; then
        echo "ERROR: Instinct $instinct_id not found" >&2
        return 1
    fi

    local current_confidence
    current_confidence=$(read_yaml_field "$file" "confidence")

    # Calculate new confidence (decrement by 0.1)
    local new_confidence
    local below_threshold=0

    if command -v bc &> /dev/null; then
        new_confidence=$(echo "$current_confidence - 0.1" | bc)
        # Normalize leading zero (bc outputs .4 instead of 0.4)
        case "$new_confidence" in .*) new_confidence="0$new_confidence" ;; esac
        below_threshold=$(echo "$new_confidence < 0.3" | bc)
    else
        # Fallback: integer arithmetic on tenths
        local tenths
        tenths=$(echo "$current_confidence" | sed 's/0\.//')
        tenths=$((tenths - 1))
        if [ "$tenths" -lt 3 ]; then
            below_threshold=1
        fi
        new_confidence="0.${tenths}"
    fi

    if [ "$below_threshold" = "1" ]; then
        rm -f "$file"
        echo "Removed instinct $instinct_id (confidence dropped below 0.3)"
        return 0
    fi

    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    update_yaml_field "$file" "confidence" "$new_confidence"
    update_yaml_field "$file" "last_applied" "$timestamp"

    echo "Weakened instinct $instinct_id: $current_confidence -> $new_confidence"
}

# Promote a project instinct to global scope
# Args: instinct_id
promote_instinct() {
    local instinct_id="$1"

    local file
    file=$(find_instinct_file "$instinct_id")

    if [ -z "$file" ]; then
        echo "ERROR: Instinct $instinct_id not found" >&2
        return 1
    fi

    local current_scope
    current_scope=$(read_yaml_field "$file" "scope")

    if [ "$current_scope" = "global" ]; then
        echo "Instinct $instinct_id is already global"
        return 0
    fi

    local target_file="$GLOBAL_DIR/${instinct_id}.yaml"

    # Copy to global, then update scope and remove project field
    cp "$file" "$target_file"
    update_yaml_field "$target_file" "scope" "global"

    # Remove the project field line
    local tmpfile="${target_file}.tmp"
    grep -v "^project:" "$target_file" > "$tmpfile"
    mv "$tmpfile" "$target_file"

    # Remove old project-scoped file
    rm -f "$file"

    echo "Promoted instinct $instinct_id to global scope"
}

# List instincts by domain, sorted by confidence (descending)
# Args: [domain] [scope]
list_instincts() {
    local filter_domain="${1:-}"
    local filter_scope="${2:-}"

    local all_files=()

    # Collect from global
    if [ -z "$filter_scope" ] || [ "$filter_scope" = "global" ]; then
        for f in "$GLOBAL_DIR"/*.yaml; do
            [ -f "$f" ] && all_files+=("$f")
        done
    fi

    # Collect from projects
    if [ -z "$filter_scope" ] || [ "$filter_scope" = "project" ]; then
        for proj_dir in "$PROJECTS_DIR"/*/; do
            [ -d "$proj_dir" ] || continue
            for f in "${proj_dir}"*.yaml; do
                [ -f "$f" ] && all_files+=("$f")
            done
        done
    fi

    if [ ${#all_files[@]} -eq 0 ]; then
        echo "No instincts found."
        return 0
    fi

    # Collect entries: confidence|id|trigger for sorting
    local entries=()
    for f in "${all_files[@]}"; do
        local id confidence trigger domain
        id=$(read_yaml_field "$f" "id")
        confidence=$(read_yaml_field "$f" "confidence")
        trigger=$(read_yaml_field "$f" "trigger")
        domain=$(read_yaml_field "$f" "domain")

        # Apply domain filter
        if [ -n "$filter_domain" ] && [ "$domain" != "$filter_domain" ]; then
            continue
        fi

        entries+=("${confidence}|${id}|${trigger}")
    done

    if [ ${#entries[@]} -eq 0 ]; then
        echo "No instincts found matching filters."
        return 0
    fi

    # Sort by confidence descending and output
    printf '%s\n' "${entries[@]}" | sort -t'|' -k1 -rn | while IFS='|' read -r conf id trig; do
        echo "$id | $conf | $trig"
    done
}

# Surface relevant instincts for current context
# Args: domain keywords (space-separated)
# Returns instincts matching those domains, sorted by confidence
# Only returns instincts with confidence >= 0.5
surface_instincts() {
    local keywords=("$@")

    if [ ${#keywords[@]} -eq 0 ]; then
        echo "Usage: surface_instincts <domain1> [domain2] ..." >&2
        return 1
    fi

    local all_files=()

    # Collect all instinct files
    for f in "$GLOBAL_DIR"/*.yaml; do
        [ -f "$f" ] && all_files+=("$f")
    done
    for proj_dir in "$PROJECTS_DIR"/*/; do
        [ -d "$proj_dir" ] || continue
        for f in "${proj_dir}"*.yaml; do
            [ -f "$f" ] && all_files+=("$f")
        done
    done

    if [ ${#all_files[@]} -eq 0 ]; then
        return 0
    fi

    local entries=()
    for f in "${all_files[@]}"; do
        local id confidence trigger domain action scope
        id=$(read_yaml_field "$f" "id")
        confidence=$(read_yaml_field "$f" "confidence")
        trigger=$(read_yaml_field "$f" "trigger")
        domain=$(read_yaml_field "$f" "domain")
        scope=$(read_yaml_field "$f" "scope")

        # Check confidence threshold (>= 0.5)
        local meets_threshold=0
        if command -v bc &> /dev/null; then
            meets_threshold=$(echo "$confidence >= 0.5" | bc)
        else
            local tenths
            tenths=$(echo "$confidence" | sed 's/0\.//')
            if [ "$tenths" -ge 5 ] 2>/dev/null; then
                meets_threshold=1
            fi
        fi

        if [ "$meets_threshold" != "1" ]; then
            continue
        fi

        # Check if domain matches any keyword
        local matches=0
        for kw in "${keywords[@]}"; do
            if [ "$domain" = "$kw" ]; then
                matches=1
                break
            fi
        done

        if [ "$matches" -eq 0 ]; then
            continue
        fi

        # Extract the action text (everything after "# Action" line)
        action=$(sed -n '/^# Action$/,$ { /^# Action$/d; p; }' "$f" | head -1 | xargs)

        entries+=("${confidence}|${id}|${trigger}|${action}|${domain}|${scope}")
    done

    if [ ${#entries[@]} -eq 0 ]; then
        return 0
    fi

    # Sort by confidence descending
    printf '%s\n' "${entries[@]}" | sort -t'|' -k1 -rn | while IFS='|' read -r conf id trig act dom scp; do
        echo "[instinct:${conf}] ${trig} -> ${act} (domain: ${dom}, scope: ${scp})"
    done
}

# Find an existing instinct by trigger text (exact match)
# Returns the instinct ID if found, empty string otherwise
find_instinct_by_trigger() {
    local search_trigger="$1"

    local all_files=()
    for f in "$GLOBAL_DIR"/*.yaml; do
        [ -f "$f" ] && all_files+=("$f")
    done
    for proj_dir in "$PROJECTS_DIR"/*/; do
        [ -d "$proj_dir" ] || continue
        for f in "${proj_dir}"*.yaml; do
            [ -f "$f" ] && all_files+=("$f")
        done
    done

    for f in "${all_files[@]}"; do
        local trigger
        trigger=$(read_yaml_field "$f" "trigger")
        # Exact match on trigger text
        if [ "$trigger" = "$search_trigger" ]; then
            read_yaml_field "$f" "id"
            return 0
        fi
    done

    echo ""
}

# Main dispatch - allows calling functions by name from command line
# Usage: instinct-manager.sh <command> [args...]
if [ $# -gt 0 ]; then
    cmd="$1"
    shift
    case "$cmd" in
        create)          create_instinct "$@" ;;
        strengthen)      strengthen_instinct "$@" ;;
        weaken)          weaken_instinct "$@" ;;
        promote)         promote_instinct "$@" ;;
        list)            list_instincts "$@" ;;
        surface)         surface_instincts "$@" ;;
        find-by-trigger) find_instinct_by_trigger "$@" ;;
        *)
            echo "Unknown command: $cmd" >&2
            echo "Available: create, strengthen, weaken, promote, list, surface, find-by-trigger" >&2
            exit 1
            ;;
    esac
fi
