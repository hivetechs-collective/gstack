#!/bin/bash
# Cost Tracker Hook (Stop, async)
# Appends session cost metrics to ~/.claude/metrics/costs.jsonl

set -e

UTILS_DIR="$(cd "$(dirname "$0")/utils" && pwd)"
source "$UTILS_DIR/hook-profile.sh"
hook_gate "stop:cost-tracker" "minimal,standard,strict"

INPUT=$(cat)

# Extract model and session info
MODEL="${CLAUDE_MODEL:-unknown}"
SESSION_ID="${CLAUDE_SESSION_ID:-$(date +%s)}"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Normalize model name for rate lookup
MODEL_LOWER=$(echo "$MODEL" | tr '[:upper:]' '[:lower:]')

# Cost rates per 1M tokens
case "$MODEL_LOWER" in
    *haiku*)  IN_RATE="0.80";  OUT_RATE="4.00" ;;
    *opus*)   IN_RATE="15.00"; OUT_RATE="75.00" ;;
    *)        IN_RATE="3.00";  OUT_RATE="15.00" ;; # default to sonnet
esac

# Try to extract token counts from stdin JSON (may not be present)
INPUT_TOKENS=$(echo "$INPUT" | grep -o '"input_tokens"[[:space:]]*:[[:space:]]*[0-9]*' | head -1 | grep -o '[0-9]*$' || echo "0")
OUTPUT_TOKENS=$(echo "$INPUT" | grep -o '"output_tokens"[[:space:]]*:[[:space:]]*[0-9]*' | head -1 | grep -o '[0-9]*$' || echo "0")

INPUT_TOKENS="${INPUT_TOKENS:-0}"
OUTPUT_TOKENS="${OUTPUT_TOKENS:-0}"

# Calculate estimated cost (using awk for floating point)
COST=$(awk "BEGIN { printf \"%.6f\", ($INPUT_TOKENS / 1000000.0) * $IN_RATE + ($OUTPUT_TOKENS / 1000000.0) * $OUT_RATE }")

# Ensure metrics directory exists
METRICS_DIR="$HOME/.claude/metrics"
mkdir -p "$METRICS_DIR"

# Append JSONL entry
echo "{\"timestamp\":\"$TIMESTAMP\",\"session_id\":\"$SESSION_ID\",\"model\":\"$MODEL\",\"input_tokens\":$INPUT_TOKENS,\"output_tokens\":$OUTPUT_TOKENS,\"estimated_cost_usd\":$COST}" >> "$METRICS_DIR/costs.jsonl"

echo "$INPUT"
