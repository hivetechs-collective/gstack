# Claude Code Analytics API

## Overview

The Claude Code Analytics API provides programmatic access to daily aggregated
usage metrics for Claude Code users, enabling organizations to analyze developer
productivity and build custom dashboards.

## Purpose

- Track developer productivity metrics
- Monitor tool usage and acceptance rates
- Analyze cost and token usage by Claude model
- Export data for custom reporting
- Build internal dashboards and analytics

## Authentication

Requires an Admin API key (starts with `sk-ant-admin...`).

**Important**: Only available for organization members with admin role.

### Getting an Admin API Key

1. Log in to the [Anthropic Console](https://console.anthropic.com/)
2. Navigate to API Keys section
3. Create a new Admin API key
4. Store securely in environment variable

```bash
export ADMIN_API_KEY="sk-ant-admin-..."
```

## Endpoint

```
GET /v1/organizations/usage_report/claude_code
```

## Request Parameters

| Parameter     | Type    | Required | Description                               |
| ------------- | ------- | -------- | ----------------------------------------- |
| `starting_at` | string  | Yes      | UTC date in YYYY-MM-DD format             |
| `limit`       | integer | No       | Records per page (default: 20, max: 1000) |
| `page`        | string  | No       | Opaque cursor token for pagination        |

## Available Metrics

### Dimensions

- **Date**: UTC date of the usage
- **Actor**: User or API key identifier
- **Organization ID**: Your organization identifier
- **Customer Type**: Account type classification
- **Terminal Type**: Terminal environment used

### Core Productivity Metrics

| Metric                  | Description                        |
| ----------------------- | ---------------------------------- |
| `number_of_sessions`    | Total Claude Code sessions started |
| `lines_added`           | Total lines of code added          |
| `lines_removed`         | Total lines of code removed        |
| `commits_created`       | Git commits made during sessions   |
| `pull_requests_created` | PRs created during sessions        |

### Tool Action Metrics

Acceptance and rejection rates for:

| Tool                  | Metrics Available                                          |
| --------------------- | ---------------------------------------------------------- |
| **Edit Tool**         | `edit_tool_accepted`, `edit_tool_rejected`                 |
| **MultiEdit Tool**    | `multiedit_tool_accepted`, `multiedit_tool_rejected`       |
| **Write Tool**        | `write_tool_accepted`, `write_tool_rejected`               |
| **NotebookEdit Tool** | `notebookedit_tool_accepted`, `notebookedit_tool_rejected` |

### Model Breakdown

For each Claude model used:

| Metric                        | Description                                  |
| ----------------------------- | -------------------------------------------- |
| `model`                       | Model identifier (e.g., `claude-sonnet-4-5`) |
| `input_tokens`                | Total input tokens consumed                  |
| `output_tokens`               | Total output tokens generated                |
| `cache_creation_input_tokens` | Tokens used for cache creation               |
| `cache_read_input_tokens`     | Tokens read from cache                       |
| `estimated_cost`              | Approximate USD cost                         |

## Example Request

### cURL

```bash
curl "https://api.anthropic.com/v1/organizations/usage_report/claude_code?\
starting_at=2025-09-08&\
limit=20" \
  --header "anthropic-version: 2023-06-01" \
  --header "x-api-key: $ADMIN_API_KEY"
```

### TypeScript

```typescript
import Anthropic from '@anthropic-ai/sdk';

const client = new Anthropic({
  apiKey: process.env.ADMIN_API_KEY,
});

const report = await client.organizations.usageReport.claudeCode({
  starting_at: '2025-09-08',
  limit: 100,
});

for (const entry of report.data) {
  console.log(`Date: ${entry.date}`);
  console.log(`Sessions: ${entry.number_of_sessions}`);
  console.log(`Lines Added: ${entry.lines_added}`);
  console.log(`Commits: ${entry.commits_created}`);

  for (const model of entry.model_breakdown) {
    console.log(`  ${model.model}: $${model.estimated_cost}`);
  }
}
```

### Python

```python
import anthropic

client = anthropic.Anthropic(api_key=os.environ["ADMIN_API_KEY"])

report = client.organizations.usage_report.claude_code(
    starting_at="2025-09-08",
    limit=100
)

for entry in report.data:
    print(f"Date: {entry.date}")
    print(f"Sessions: {entry.number_of_sessions}")
    print(f"Lines Added: {entry.lines_added}")
    print(f"Commits: {entry.commits_created}")

    for model in entry.model_breakdown:
        print(f"  {model.model}: ${model.estimated_cost}")
```

## Response Structure

```json
{
  "data": [
    {
      "date": "2025-09-08",
      "actor": "user-id-123",
      "organization_id": "org-abc",
      "customer_type": "enterprise",
      "terminal_type": "vscode",
      "number_of_sessions": 15,
      "lines_added": 1250,
      "lines_removed": 320,
      "commits_created": 8,
      "pull_requests_created": 2,
      "edit_tool_accepted": 45,
      "edit_tool_rejected": 3,
      "multiedit_tool_accepted": 12,
      "multiedit_tool_rejected": 1,
      "write_tool_accepted": 8,
      "write_tool_rejected": 0,
      "notebookedit_tool_accepted": 0,
      "notebookedit_tool_rejected": 0,
      "model_breakdown": [
        {
          "model": "claude-sonnet-4-5",
          "input_tokens": 125000,
          "output_tokens": 45000,
          "cache_creation_input_tokens": 15000,
          "cache_read_input_tokens": 80000,
          "estimated_cost": 1.245
        }
      ]
    }
  ],
  "has_more": true,
  "next_page": "eyJhZnRlciI6IjIwMjUtMDktMDgifQ=="
}
```

## Pagination

```typescript
async function fetchAllUsageData(startDate: string) {
  const allData = [];
  let page: string | undefined;

  do {
    const report = await client.organizations.usageReport.claudeCode({
      starting_at: startDate,
      limit: 1000,
      page,
    });

    allData.push(...report.data);
    page = report.has_more ? report.next_page : undefined;
  } while (page);

  return allData;
}

const allUsage = await fetchAllUsageData('2025-01-01');
console.log(`Fetched ${allUsage.length} usage records`);
```

## Analytics Examples

### 1. Daily Productivity Dashboard

```typescript
interface DailyStats {
  date: string;
  sessions: number;
  linesChanged: number;
  commits: number;
  prs: number;
  cost: number;
}

async function getDailyProductivity(startDate: string): Promise<DailyStats[]> {
  const report = await client.organizations.usageReport.claudeCode({
    starting_at: startDate,
    limit: 1000,
  });

  const dailyStats = new Map<string, DailyStats>();

  for (const entry of report.data) {
    const existing = dailyStats.get(entry.date) || {
      date: entry.date,
      sessions: 0,
      linesChanged: 0,
      commits: 0,
      prs: 0,
      cost: 0,
    };

    existing.sessions += entry.number_of_sessions;
    existing.linesChanged += entry.lines_added + entry.lines_removed;
    existing.commits += entry.commits_created;
    existing.prs += entry.pull_requests_created;
    existing.cost += entry.model_breakdown.reduce(
      (sum, m) => sum + m.estimated_cost,
      0
    );

    dailyStats.set(entry.date, existing);
  }

  return Array.from(dailyStats.values());
}

const stats = await getDailyProductivity('2025-09-01');
for (const day of stats) {
  console.log(
    `${day.date}: ${day.sessions} sessions, ${day.linesChanged} lines, $${day.cost.toFixed(2)}`
  );
}
```

### 2. Tool Acceptance Analysis

```typescript
interface ToolStats {
  tool: string;
  accepted: number;
  rejected: number;
  acceptanceRate: number;
}

function analyzeToolAcceptance(data: any[]): ToolStats[] {
  const tools = [
    {
      name: 'Edit',
      acceptedKey: 'edit_tool_accepted',
      rejectedKey: 'edit_tool_rejected',
    },
    {
      name: 'MultiEdit',
      acceptedKey: 'multiedit_tool_accepted',
      rejectedKey: 'multiedit_tool_rejected',
    },
    {
      name: 'Write',
      acceptedKey: 'write_tool_accepted',
      rejectedKey: 'write_tool_rejected',
    },
    {
      name: 'NotebookEdit',
      acceptedKey: 'notebookedit_tool_accepted',
      rejectedKey: 'notebookedit_tool_rejected',
    },
  ];

  return tools.map((tool) => {
    const accepted = data.reduce(
      (sum, entry) => sum + (entry[tool.acceptedKey] || 0),
      0
    );
    const rejected = data.reduce(
      (sum, entry) => sum + (entry[tool.rejectedKey] || 0),
      0
    );
    const total = accepted + rejected;

    return {
      tool: tool.name,
      accepted,
      rejected,
      acceptanceRate: total > 0 ? (accepted / total) * 100 : 0,
    };
  });
}

const toolStats = analyzeToolAcceptance(allUsage);
for (const stat of toolStats) {
  console.log(
    `${stat.tool}: ${stat.acceptanceRate.toFixed(1)}% acceptance (${stat.accepted}/${stat.accepted + stat.rejected})`
  );
}
```

### 3. Cost by Model Analysis

```typescript
interface ModelCost {
  model: string;
  totalCost: number;
  inputTokens: number;
  outputTokens: number;
  cacheHitRate: number;
}

function analyzeModelCosts(data: any[]): ModelCost[] {
  const modelStats = new Map<string, ModelCost>();

  for (const entry of data) {
    for (const model of entry.model_breakdown) {
      const existing = modelStats.get(model.model) || {
        model: model.model,
        totalCost: 0,
        inputTokens: 0,
        outputTokens: 0,
        cacheHitRate: 0,
      };

      existing.totalCost += model.estimated_cost;
      existing.inputTokens += model.input_tokens;
      existing.outputTokens += model.output_tokens;

      const totalInput =
        model.input_tokens + (model.cache_read_input_tokens || 0);
      existing.cacheHitRate =
        totalInput > 0
          ? ((model.cache_read_input_tokens || 0) / totalInput) * 100
          : 0;

      modelStats.set(model.model, existing);
    }
  }

  return Array.from(modelStats.values());
}

const modelCosts = analyzeModelCosts(allUsage);
for (const model of modelCosts) {
  console.log(`${model.model}:`);
  console.log(`  Cost: $${model.totalCost.toFixed(2)}`);
  console.log(
    `  Tokens: ${model.inputTokens.toLocaleString()} in, ${model.outputTokens.toLocaleString()} out`
  );
  console.log(`  Cache Hit Rate: ${model.cacheHitRate.toFixed(1)}%`);
}
```

## Key Limitations

1. **Data Latency**: Usage data available with up to 1-hour delay
2. **No Real-time**: Not suitable for real-time monitoring
3. **1st Party Only**: Only tracks Claude API (1st party) usage
4. **Admin Only**: Requires admin API key

## Common Use Cases

1. **Executive Dashboards**: Track org-wide developer productivity
2. **Cost Attribution**: Allocate costs by team or project
3. **ROI Analysis**: Measure productivity gains vs costs
4. **Tool Optimization**: Identify which tools developers accept/reject
5. **Usage Trends**: Spot patterns in developer workflows

## Best Practices

1. **Cache Data**: Store analytics locally to minimize API calls
2. **Batch Requests**: Use maximum limit (1000) for efficiency
3. **Aggregate Daily**: Process data in daily batches
4. **Monitor Costs**: Track API costs against usage patterns
5. **Secure Keys**: Protect admin API keys carefully
6. **Automate Reporting**: Schedule periodic data exports

## Related Documentation

- [Cost Tracking](./cost-tracking.md)
- [TypeScript SDK Reference](./typescript.md)
- [Python SDK Reference](./python.md)
- [Messages Examples](./messages-examples.md)
