#!/bin/bash
# Agent Switcher v2 - Fixed to copy only needed agent files
# Usage: agents-switch <project-name>

# Path to pattern repository
PATTERN_REPO="/Users/veronelazio/Developer/Private/claude-pattern"
GLOBAL_SETTINGS="$HOME/.claude/settings.json"

# Function to show available agent sets
agents-list() {
  echo "📋 Available Agent Sets:"
  echo ""

  # Standard sets
  echo "Standard Sets:"
  ls -1 "$PATTERN_REPO/.claude/agent-sets/"*.json 2>/dev/null | while read file; do
    name=$(basename "$file" .json)
    desc=$(jq -r '.description' "$file" 2>/dev/null || echo "No description")
    tokens=$(jq -r '.estimatedTokens' "$file" 2>/dev/null || echo "?")
    count=$(jq -r '.agents | length' "$file" 2>/dev/null || echo "?")
    echo "  • $name ($count agents, ~${tokens} tokens)"
    echo "    └─ $desc"
  done

  echo ""
  echo "Custom Sets:"
  ls -1 "$PATTERN_REPO/.claude/agent-sets/custom/"*.json 2>/dev/null | while read file; do
    name=$(basename "$file" .json)
    desc=$(jq -r '.description' "$file" 2>/dev/null || echo "No description")
    tokens=$(jq -r '.estimatedTokens' "$file" 2>/dev/null || echo "?")
    count=$(jq -r '.agents | length' "$file" 2>/dev/null || echo "?")
    echo "  • $name ($count agents, ~${tokens} tokens)"
    echo "    └─ $desc"
  done

  echo ""
  echo "💡 Usage: agents-switch <set-name>"
  echo "   Example: agents-switch hive-core"
}

# Function to show detailed info about an agent set
agents-show() {
  local set_name="$1"

  if [ -z "$set_name" ]; then
    echo "❌ Error: Please specify an agent set name"
    echo "Usage: agents-show <set-name>"
    return 1
  fi

  # Try standard sets first
  local set_file="$PATTERN_REPO/.claude/agent-sets/$set_name.json"

  # If not found, try custom sets
  if [ ! -f "$set_file" ]; then
    set_file="$PATTERN_REPO/.claude/agent-sets/custom/$set_name.json"
  fi

  if [ ! -f "$set_file" ]; then
    echo "❌ Error: Agent set '$set_name' not found"
    echo "Run 'agents-list' to see available sets"
    return 1
  fi

  echo "📊 Agent Set: $set_name"
  echo ""
  echo "Description: $(jq -r '.description' "$set_file")"
  echo "Estimated Tokens: $(jq -r '.estimatedTokens' "$set_file")"
  echo "Agent Count: $(jq -r '.agents | length' "$set_file")"
  echo ""
  echo "Agents:"
  jq -r '.agents[]' "$set_file" | while read agent; do
    echo "  • $agent"
  done
  echo ""
  echo "Notes: $(jq -r '.notes' "$set_file")"
}

# Function to switch agent sets
agents-switch() {
  local set_name="$1"

  if [ -z "$set_name" ]; then
    echo "❌ Error: Please specify an agent set name"
    echo "Usage: agents-switch <set-name>"
    echo ""
    agents-list
    return 1
  fi

  # Try standard sets first
  local set_file="$PATTERN_REPO/.claude/agent-sets/$set_name.json"

  # If not found, try custom sets
  if [ ! -f "$set_file" ]; then
    set_file="$PATTERN_REPO/.claude/agent-sets/custom/$set_name.json"
  fi

  if [ ! -f "$set_file" ]; then
    echo "❌ Error: Agent set '$set_name' not found"
    echo "Run 'agents-list' to see available sets"
    return 1
  fi

  # Backup current settings
  cp "$GLOBAL_SETTINGS" "$GLOBAL_SETTINGS.backup.$(date +%Y%m%d-%H%M%S)"

  # Extract agent list from set file
  local agents=$(jq -r '.agents' "$set_file")

  # Update settings.json using jq
  local temp_file=$(mktemp)
  jq --argjson agents "$agents" '.agentDescriptions.enabled = $agents' "$GLOBAL_SETTINGS" > "$temp_file"
  mv "$temp_file" "$GLOBAL_SETTINGS"

  # CRITICAL FIX: Copy only the needed agent files (not all 174!)
  echo "📦 Copying agent files..."

  # Ensure agents directory exists
  mkdir -p ~/.claude/agents

  # Clear existing agent markdown files
  rm -f ~/.claude/agents/*.md 2>/dev/null

  # Copy each needed agent file from pattern repo
  local copied=0
  local missing=0

  jq -r '.agents[]' "$set_file" | while read agent; do
    # Search for agent file in pattern repo subdirectories
    local agent_file=$(find "$PATTERN_REPO/.claude/agents" -name "${agent}.md" -type f 2>/dev/null | head -1)

    if [ -n "$agent_file" ] && [ -f "$agent_file" ]; then
      cp "$agent_file" ~/.claude/agents/
      echo "  ✓ $agent"
    else
      echo "  ⚠️  Not found: ${agent}.md"
    fi
  done

  # Count final result
  local final_count=$(ls ~/.claude/agents/*.md 2>/dev/null | wc -l | tr -d ' ')

  echo ""
  echo "✅ Switched to agent set: $set_name"
  echo "📊 Enabled $(jq -r '.agents | length' "$set_file") agents (~$(jq -r '.estimatedTokens' "$set_file") tokens)"
  echo "📁 Copied $final_count agent files to ~/.claude/agents/"
  echo ""
  echo "🔄 IMPORTANT: Restart Claude Code to apply changes"
  echo ""
}

# Function to check current agent configuration
agents-current() {
  echo "📊 Current Agent Configuration:"
  echo ""

  local count=$(jq -r '.agentDescriptions.enabled | length' "$GLOBAL_SETTINGS" 2>/dev/null || echo "0")
  local file_count=$(ls ~/.claude/agents/*.md 2>/dev/null | wc -l | tr -d ' ')

  echo "Enabled in settings.json: $count"
  echo "Agent files in ~/.claude/agents/: $file_count"
  echo ""

  if [ "$count" -gt 0 ]; then
    jq -r '.agentDescriptions.enabled[]' "$GLOBAL_SETTINGS" | while read agent; do
      # Check if agent file exists
      if [ -f ~/.claude/agents/${agent}.md ]; then
        echo "  ✓ $agent"
      else
        echo "  ✗ $agent (file missing!)"
      fi
    done
  else
    echo "  (No agents enabled)"
  fi

  echo ""
  echo "💡 Run 'agents-list' to see available agent sets"
  echo "💡 Run 'agents-switch <set-name>' to change agent set"

  if [ "$count" -ne "$file_count" ]; then
    echo ""
    echo "⚠️  WARNING: Mismatch between enabled agents ($count) and agent files ($file_count)"
    echo "   This may cause the token warning. Run 'agents-switch <set-name>' to fix."
  fi
}

# Quick shortcuts for common projects
agents-hive() {
  agents-switch hive-core
}

agents-website() {
  agents-switch hivetechs-website
}
