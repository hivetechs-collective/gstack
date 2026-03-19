# Claude Agent SDK Cost Tracking

**Last Updated**: 2025-10-17 **Source**:
https://docs.claude.com/en/api/agent-sdk/cost-tracking

## Overview

The Claude Agent SDK provides detailed token usage information for tracking
costs and billing. All messages with the same `id` field report identical usage
and you should only charge users once per step.

## Key Concepts

**Steps and Messages**: A step represents a single request/response cycle, while
messages are individual communications within that step (text, tool uses, tool
results).

**Usage Reporting**: Token consumption data attaches to assistant messages. The
system tracks:

- `input_tokens`: Base tokens processed
- `output_tokens`: Tokens generated in responses
- `cache_creation_input_tokens`: Tokens used creating cache entries
- `cache_read_input_tokens`: Tokens read from cache
- `total_cost_usd`: Total cost (only in result messages)

## Important Rules

1. **Deduplication**: Messages sharing the same ID contain identical usage
   data—charge only once per unique ID
2. **Per-Step Charging**: Bill users once per conversation step, not per
   individual message
3. **Cumulative Usage**: The final result message contains total usage from all
   steps

## Implementation Example

```typescript
class CostTracker {
  private processedIds = new Set<string>();
  private totalUsage = {
    inputTokens: 0,
    outputTokens: 0,
    cacheCreationTokens: 0,
    cacheReadTokens: 0,
    totalCostUSD: 0,
  };

  trackMessage(message: any) {
    if (message.id && !this.processedIds.has(message.id)) {
      this.processedIds.add(message.id);

      if (message.usage) {
        this.totalUsage.inputTokens += message.usage.input_tokens || 0;
        this.totalUsage.outputTokens += message.usage.output_tokens || 0;
        this.totalUsage.cacheCreationTokens +=
          message.usage.cache_creation_input_tokens || 0;
        this.totalUsage.cacheReadTokens +=
          message.usage.cache_read_input_tokens || 0;
      }

      if (message.type === 'result' && message.total_cost_usd) {
        this.totalUsage.totalCostUSD = message.total_cost_usd;
      }
    }
  }

  getUsage() {
    return this.totalUsage;
  }
}
```

## Edge Cases

**Token Discrepancies**: When `output_tokens` values differ for same-ID
messages, use the highest value and verify against `total_cost_usd`.

**Cache Tracking**: Separately monitor cache creation and read tokens for
accurate cost attribution.

## Best Practices

- Implement message ID deduplication
- Monitor final result messages for authoritative usage data
- Log all usage for auditing
- Handle partial usage if conversations fail
- Accumulate usage during streaming responses

## Related Documentation

- [TypeScript SDK Reference](./typescript.md)
- [Python SDK Reference](./python.md)
- [Sessions](./sessions.md)
