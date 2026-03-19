# Hook Logs Viewer

View and analyze Claude Code hook logs with statistics.

## Usage

```
/hook-logs [command]
```

## Commands

- `stats` - Show hook statistics (default)
- `security` - Show security events
- `recent [n]` - Show last n log entries (default: 10)
- `clear` - Clear all logs (with confirmation)

## Implementation

```bash
LOG_DIR="${CLAUDE_LOG_DIR:-$HOME/.claude/logs}"
HOOKS_LOG="$LOG_DIR/hooks.jsonl"
SECURITY_LOG="$LOG_DIR/security.jsonl"
SESSION_LOG="$LOG_DIR/sessions.jsonl"

case "${1:-stats}" in
    stats)
        echo "=== Hook Statistics ==="
        if [ -f "$HOOKS_LOG" ]; then
            echo ""
            echo "Total events: $(wc -l < "$HOOKS_LOG" | tr -d ' ')"
            echo ""
            echo "By Hook Type:"
            jq -r '.hook' "$HOOKS_LOG" 2>/dev/null | sort | uniq -c | sort -rn || echo "  (no data)"
            echo ""
            echo "By Decision:"
            jq -r '.decision' "$HOOKS_LOG" 2>/dev/null | sort | uniq -c | sort -rn || echo "  (no data)"
        else
            echo "No hook logs found at $HOOKS_LOG"
        fi
        ;;

    security)
        echo "=== Security Events ==="
        if [ -f "$SECURITY_LOG" ]; then
            echo ""
            echo "Total events: $(wc -l < "$SECURITY_LOG" | tr -d ' ')"
            echo ""
            echo "By Action:"
            jq -r '.action' "$SECURITY_LOG" 2>/dev/null | sort | uniq -c | sort -rn || echo "  (no data)"
            echo ""
            echo "Recent Events:"
            tail -10 "$SECURITY_LOG" | jq -r '"[\(.timestamp)] \(.action): \(.target)"' 2>/dev/null || echo "  (no data)"
        else
            echo "No security logs found at $SECURITY_LOG"
        fi
        ;;

    recent)
        local count="${2:-10}"
        echo "=== Recent Hook Events (last $count) ==="
        if [ -f "$HOOKS_LOG" ]; then
            tail -"$count" "$HOOKS_LOG" | jq -r '"[\(.timestamp)] \(.hook)/\(.tool): \(.decision)"' 2>/dev/null || tail -"$count" "$HOOKS_LOG"
        else
            echo "No hook logs found"
        fi
        ;;

    clear)
        echo "This will delete all hook logs. Are you sure? (y/N)"
        # Note: This command shows the user what would happen
        # Actual clearing should be done manually:
        # rm -f ~/.claude/logs/*.jsonl
        ;;

    *)
        echo "Unknown command: $1"
        echo "Available: stats, security, recent [n], clear"
        ;;
esac
```
