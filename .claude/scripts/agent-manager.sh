#!/bin/bash
# Agent Configuration Manager
# Helps manage agent sets and configurations

set -e

PATTERN_REPO="/Users/veronelazio/Developer/Private/claude-pattern"
AGENT_SETS_DIR="${PATTERN_REPO}/.claude/agent-sets"
AGENTS_DIR="${PATTERN_REPO}/.claude/agents"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Display header
header() {
    echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  Claude Code Agent Configuration Manager${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"
}

# List all available agent sets
list_sets() {
    echo -e "\n${GREEN}Available Agent Sets:${NC}\n"

    for set_file in "${AGENT_SETS_DIR}"/*.json; do
        [ -f "$set_file" ] || continue

        name=$(jq -r '.name' "$set_file")
        desc=$(jq -r '.description' "$set_file")
        count=$(jq -r '.agents | length' "$set_file")
        tokens=$(jq -r '.estimatedTokens' "$set_file")

        echo -e "${YELLOW}${name}${NC} (${count} agents, ~${tokens} tokens)"
        echo -e "  ${desc}"
        echo ""
    done
}

# Show details of a specific set
show_set() {
    local set_name="$1"
    local set_file="${AGENT_SETS_DIR}/${set_name}.json"

    if [ ! -f "$set_file" ]; then
        echo -e "${RED}Error: Set '${set_name}' not found${NC}"
        echo "Available sets:"
        ls -1 "${AGENT_SETS_DIR}"/*.json | xargs -n1 basename | sed 's/.json$//' | sed 's/^/  - /'
        return 1
    fi

    echo -e "\n${GREEN}Agent Set: ${set_name}${NC}\n"

    local desc=$(jq -r '.description' "$set_file")
    local count=$(jq -r '.agents | length' "$set_file")
    local tokens=$(jq -r '.estimatedTokens' "$set_file")
    local notes=$(jq -r '.notes' "$set_file")

    echo -e "${YELLOW}Description:${NC} ${desc}"
    echo -e "${YELLOW}Agent Count:${NC} ${count}"
    echo -e "${YELLOW}Est. Tokens:${NC} ${tokens}"
    echo -e "${YELLOW}Notes:${NC} ${notes}"
    echo ""
    echo -e "${YELLOW}Agents:${NC}"
    jq -r '.agents[]' "$set_file" | sed 's/^/  - /'
    echo ""
}

# Generate settings.local.json snippet for a set
generate_config() {
    local set_name="$1"
    local set_file="${AGENT_SETS_DIR}/${set_name}.json"

    if [ ! -f "$set_file" ]; then
        echo -e "${RED}Error: Set '${set_name}' not found${NC}"
        return 1
    fi

    echo -e "\n${GREEN}Copy this to your project's .claude/settings.local.json:${NC}\n"

    cat <<'EOF'
{
  "$schema": "https://json.schemastore.org/claude-code-settings.json",
  "agentDescriptions": {
    "enabled": [
EOF

    jq -r '.agents[]' "$set_file" | sed 's/^/      "/' | sed 's/$/",/' | sed '$ s/,$//'

    cat <<'EOF'
    ]
  }
}
EOF
    echo ""
}

# Merge multiple sets
merge_sets() {
    echo -e "\n${GREEN}Merging agent sets: $@${NC}\n"

    local set_files=()
    for set_name in "$@"; do
        local set_file="${AGENT_SETS_DIR}/${set_name}.json"
        if [ ! -f "$set_file" ]; then
            echo -e "${RED}Error: Set '${set_name}' not found${NC}"
            return 1
        fi
        set_files+=("$set_file")
    done

    # Merge and deduplicate
    local merged=$(jq -s 'map(.agents) | flatten | unique' "${set_files[@]}")
    local count=$(echo "$merged" | jq 'length')

    echo -e "${YELLOW}Combined Agent List:${NC} (${count} unique agents)\n"
    echo "$merged" | jq -r '.[]' | sed 's/^/  - /'
    echo ""

    echo -e "${GREEN}Config snippet:${NC}\n"
    cat <<'EOF'
{
  "agentDescriptions": {
    "enabled": [
EOF

    echo "$merged" | jq -r '.[]' | sed 's/^/      "/' | sed 's/$/",/' | sed '$ s/,$//'

    cat <<'EOF'
    ]
  }
}
EOF
    echo ""
}

# Check current configuration
check_config() {
    echo -e "\n${GREEN}Current Configuration:${NC}\n"

    # Global config
    local global_config="$HOME/.claude/settings.json"
    if [ -f "$global_config" ]; then
        local global_count=$(jq -r '.agentDescriptions.enabled | length' "$global_config" 2>/dev/null || echo "0")
        echo -e "${YELLOW}Global config:${NC} ${global_count} agents enabled"
        if [ "$global_count" -gt 0 ]; then
            jq -r '.agentDescriptions.enabled[]' "$global_config" 2>/dev/null | sed 's/^/  - /'
        fi
    else
        echo -e "${RED}Global config not found${NC}"
    fi
    echo ""

    # Project config
    if [ -f ".claude/settings.local.json" ]; then
        local project_count=$(jq -r '.agentDescriptions.enabled | length' ".claude/settings.local.json" 2>/dev/null || echo "0")
        echo -e "${YELLOW}Project config:${NC} ${project_count} agents enabled"
        if [ "$project_count" -gt 0 ]; then
            jq -r '.agentDescriptions.enabled[]' ".claude/settings.local.json" 2>/dev/null | sed 's/^/  - /'
        fi

        # Estimate tokens
        if [ "$project_count" -gt 0 ]; then
            local est_tokens=$((project_count * 750))
            echo ""
            echo -e "${YELLOW}Estimated tokens:${NC} ~${est_tokens}"
            if [ "$est_tokens" -gt 15000 ]; then
                echo -e "${RED}⚠️  Token bloat warning (over 15k)${NC}"
            elif [ "$est_tokens" -gt 12000 ]; then
                echo -e "${YELLOW}⚠️  High token usage (over 12k)${NC}"
            else
                echo -e "${GREEN}✅ Token usage OK${NC}"
            fi
        fi
    else
        echo -e "${YELLOW}No project config found${NC}"
    fi
    echo ""
}

# Verify symlink setup
verify_setup() {
    echo -e "\n${GREEN}Verifying Agent Setup:${NC}\n"

    local global_agents="$HOME/.claude/agents"

    if [ -L "$global_agents" ]; then
        local target=$(readlink "$global_agents")
        echo -e "${GREEN}✅ Symlink exists:${NC} $global_agents"
        echo -e "   → ${target}"

        if [ -d "$target" ]; then
            local agent_count=$(find "$target" -name "*.md" | wc -l | xargs)
            echo -e "${GREEN}✅ Target directory valid:${NC} ${agent_count} agents available"
        else
            echo -e "${RED}❌ Target directory missing:${NC} ${target}"
        fi
    elif [ -d "$global_agents" ]; then
        echo -e "${YELLOW}⚠️  Global agents directory exists but is not a symlink${NC}"
        echo -e "   Run migration to convert to symlink"
    else
        echo -e "${RED}❌ Global agents not found${NC}"
        echo -e "   Run: ln -s ${AGENTS_DIR} ${global_agents}"
    fi
    echo ""
}

# Create custom set
create_custom_set() {
    local set_name="$1"

    if [ -z "$set_name" ]; then
        echo -e "${RED}Error: Set name required${NC}"
        echo "Usage: $0 create <set-name>"
        return 1
    fi

    local custom_dir="${AGENT_SETS_DIR}/custom"
    local set_file="${custom_dir}/${set_name}.json"

    if [ -f "$set_file" ]; then
        echo -e "${RED}Error: Set '${set_name}' already exists${NC}"
        return 1
    fi

    mkdir -p "$custom_dir"

    cat > "$set_file" <<EOF
{
  "name": "${set_name}",
  "description": "Description of ${set_name}",
  "agents": [
    "agent-name-1",
    "agent-name-2"
  ],
  "estimatedTokens": 1500,
  "categories": {
    "coordination": [],
    "implementation": [],
    "research-planning": []
  },
  "notes": "When to use this set"
}
EOF

    echo -e "${GREEN}✅ Created custom set: ${set_file}${NC}"
    echo -e "   Edit the file to customize agents and description"
}

# Usage
usage() {
    cat <<EOF

${GREEN}Usage:${NC}
  $0 list                    List all available agent sets
  $0 show <set-name>         Show details of a specific set
  $0 config <set-name>       Generate config snippet for a set
  $0 merge <set1> <set2>...  Merge multiple sets
  $0 check                   Check current configuration
  $0 verify                  Verify symlink setup
  $0 create <set-name>       Create a custom agent set

${GREEN}Examples:${NC}
  $0 list                    # See all available sets
  $0 show hive-core          # Details of hive-core set
  $0 config rust             # Generate config for rust set
  $0 merge electron rust     # Merge electron and rust sets
  $0 check                   # Check current project config
  $0 verify                  # Verify global symlink setup
  $0 create my-workflow      # Create custom set

EOF
}

# Main
main() {
    local cmd="${1:-help}"
    shift || true

    header

    case "$cmd" in
        list)
            list_sets
            ;;
        show)
            show_set "$@"
            ;;
        config|generate)
            generate_config "$@"
            ;;
        merge)
            merge_sets "$@"
            ;;
        check)
            check_config
            ;;
        verify)
            verify_setup
            ;;
        create)
            create_custom_set "$@"
            ;;
        help|--help|-h)
            usage
            ;;
        *)
            echo -e "${RED}Unknown command: ${cmd}${NC}"
            usage
            exit 1
            ;;
    esac
}

main "$@"
