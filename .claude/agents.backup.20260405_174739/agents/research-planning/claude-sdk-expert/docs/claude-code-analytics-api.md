# Claude Code Analytics API Documentation

**Last Updated**: 2025-10-17 **Source**:
https://docs.claude.com/en/api/claude-code-analytics-api

## Overview

The Claude Code Analytics Admin API enables organizations to programmatically
access daily aggregated usage metrics for Claude Code users. This tool supports
developer productivity analysis, tool usage monitoring, cost tracking, and
custom reporting.

## Key Requirements

**Admin API Key Required**: Endpoints require an Admin API key (prefix:
`sk-ant-admin...`), distinct from standard API keys. Only organization admins
can provision these through the Claude Console.

## Core Endpoint

**Base URL**:
`https://api.anthropic.com/v1/organizations/usage_report/claude_code`

### Request Parameters

| Parameter     | Type    | Required | Details                                             |
| ------------- | ------- | -------- | --------------------------------------------------- |
| `starting_at` | string  | Yes      | UTC date (YYYY-MM-DD format) for single-day metrics |
| `limit`       | integer | No       | Records per page (default: 20, max: 1000)           |
| `page`        | string  | No       | Opaque cursor token for pagination                  |

## Available Metrics

### Dimensions

- **date**: RFC 3339 UTC timestamp
- **actor**: User or API key identifier
- **organization_id**: Organization UUID
- **customer_type**: Account classification (api or subscription)
- **terminal_type**: Environment type (vscode, iTerm.app, tmux, etc.)

### Core Productivity Metrics

- Sessions initiated
- Lines of code added/removed
- Git commits created
- Pull requests generated

### Tool Action Metrics

Acceptance/rejection rates for:

- Edit tool
- Write tool
- NotebookEdit tool
- Multi-edit tool

### Model Breakdown

Per-model data including:

- Input/output token counts
- Cache read/creation tokens
- Estimated costs in USD

## Example Request

```bash
curl "https://api.anthropic.com/v1/organizations/usage_report/claude_code?starting_at=2025-09-08&limit=20"   --header "anthropic-version: 2023-06-01"   --header "x-api-key: $ADMIN_API_KEY"
```

## Response Structure

Responses contain user-level daily records with nested metrics, pagination
indicators (`has_more`, `next_page`), and detailed usage breakdowns per model.

## Related Documentation

- [Cost Tracking](./cost-tracking.md)
- [TypeScript SDK Reference](./typescript.md)
- [Python SDK Reference](./python.md)
