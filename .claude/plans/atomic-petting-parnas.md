# Implementation Plan: IndyDevDan's Agent Teams + Observability Dashboard

## Context

We are implementing the two actively maintained configurations by IndyDevDan (disler):

1. **claude-code-hooks-mastery** (2,935 stars) - Agent team definitions (builder/validator), output styles, plan_w_team command, meta-agent for generating agents
2. **claude-code-hooks-multi-agent-observability** (1,073 stars) - Real-time observability dashboard with Bun server, Vue 3 client, SQLite storage, WebSocket streaming, and send_event.py universal dispatcher

These integrate into our existing claude-pattern infrastructure (150 agents, 13 hooks, 14 commands) without disrupting current functionality. The dual-hook pattern ensures existing bash hooks continue to run while send_event.py dispatches events to the observability server as a second hook command.

## Files to Create/Modify

### Phase 1: Team Agents + Output Styles + Meta-Agent (8 new files)

**1A. Team Agent Definitions**

- `NEW .claude/agents/team/builder.md` - Engineering agent with PostToolUse validation (ruff/ty for Python, tsc for TS)
- `NEW .claude/agents/team/validator.md` - Read-only inspection agent (disallowed: Write, Edit, NotebookEdit)

**1B. Output Styles**

- `NEW .claude/output-styles/ultra-concise.md` - Minimal output, code-only responses
- `NEW .claude/output-styles/markdown-focused.md` - Rich markdown formatting
- `NEW .claude/output-styles/table-based.md` - Tabular data presentation
- `NEW .claude/output-styles/bullet-points.md` - Structured bullet lists

**1C. Meta-Agent**

- `NEW .claude/agents/coordination/meta-agent.md` - Agent that creates other agents by scraping docs and generating proper frontmatter
- `NEW .claude/commands/create-agent.md` - Slash command to invoke meta-agent

### Phase 2: Observability Server + Client (12 new files)

**2A. Server (Bun + SQLite + WebSocket)**

- `NEW apps/observability/server/package.json` - Bun dependencies (bun-types, better-sqlite3)
- `NEW apps/observability/server/src/index.ts` - HTTP POST /events + WebSocket /ws + GET /events, CORS enabled, port 4000
- `NEW apps/observability/server/src/db.ts` - SQLite schema (events table with field promotion), WAL mode, indexes on session_id/hook_type/timestamp

**2B. Client (Vue 3 + Tailwind)**

- `NEW apps/observability/client/package.json` - Vue 3, Tailwind CSS, Vite
- `NEW apps/observability/client/index.html` - Entry HTML
- `NEW apps/observability/client/src/main.ts` - Vue app bootstrap
- `NEW apps/observability/client/src/App.vue` - Root layout with FilterPanel + views
- `NEW apps/observability/client/src/components/EventTimeline.vue` - Real-time event feed with color-coded hook types
- `NEW apps/observability/client/src/components/FilterPanel.vue` - Filter by hook_type, session_id, tool_name, date range
- `NEW apps/observability/client/src/components/LivePulseChart.vue` - Live event rate visualization
- `NEW apps/observability/client/src/composables/useWebSocket.ts` - WebSocket connection with auto-reconnect
- `NEW apps/observability/client/src/composables/useEventColors.ts` - Hook type to color mapping

### Phase 3: Event Dispatcher + Hook Wiring (2 new files, 1 modified)

**3A. Universal Event Dispatcher**

- `NEW .claude/hooks/send_event.py` - UV single-file script (PEP 723) that POSTs hook events to localhost:4000/events. Always exits 0 (non-blocking). Reads hook data from stdin, promotes key fields (tool_name, agent_id, error) to top-level.

**3B. Dual-Hook Wiring**

- `MODIFY .claude/settings.json` - Add send_event.py as second command in each hook array (PreToolUse, PostToolUse, SessionStart, SessionEnd, Stop, SubagentStart, SubagentStop, PreCompact, UserPromptSubmit). Existing hooks remain first; send_event.py dispatches in parallel.

### Phase 4: Plan With Team Command (1 new file)

- `NEW .claude/commands/plan-w-team.md` - Spec-first planning command that: (1) generates a spec doc from user request, (2) creates Task items with dependencies, (3) assigns builder agent for implementation, (4) assigns validator agent for review. Includes Stop hook validation to verify spec completeness.

### Phase 5: Start/Stop Scripts (2 new files)

- `NEW scripts/observability-start.sh` - Starts Bun server + Vite dev server, checks ports, creates SQLite DB if missing
- `NEW scripts/observability-stop.sh` - Gracefully stops both servers

### Phase 6: Integration (3 modified files)

- `MODIFY .gitignore` - Add `apps/observability/server/*.db`, `apps/observability/client/dist/`
- `MODIFY package.json` - Add scripts: `obs:start`, `obs:stop`, `obs:server`, `obs:client`
- `MODIFY CLAUDE.md` - Document agent teams, output styles, observability dashboard, plan-w-team command

## Implementation Details

### Builder Agent (.claude/agents/team/builder.md)

```yaml
---
name: builder
description: Engineering agent that writes production code with validation
model: opus
disallowed_tools: [] # Full access
---
```

- System prompt instructs to write clean, tested code
- PostToolUse hooks automatically validate edits (existing TS/Rust validators + new ruff/ty for Python)
- Follows project conventions from CLAUDE.md

### Validator Agent (.claude/agents/team/validator.md)

```yaml
---
name: validator
description: Read-only code inspector for quality verification
model: opus
disallowed_tools: [Write, Edit, NotebookEdit]
---
```

- Can only read code, run tests, and provide feedback
- Reviews builder's output for correctness, style, security
- Reports issues via Task tools or direct messages

### send_event.py (UV Single-File Script)

```python
# /// script
# dependencies = ["httpx"]
# requires-python = ">=3.11"
# ///
```

- Reads JSON from stdin (hook payload)
- Promotes fields: tool_name, agent_id, error, file_path from nested payload
- POSTs to http://localhost:4000/events
- Always exits 0 (never blocks Claude Code even if server is down)
- Uses httpx for async HTTP

### Observability Server Schema

```sql
CREATE TABLE events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT NOT NULL,
  hook_type TEXT NOT NULL,
  tool_name TEXT,
  agent_id TEXT,
  error TEXT,
  payload TEXT NOT NULL,  -- Full JSON
  timestamp TEXT NOT NULL DEFAULT (datetime('now')),
  CONSTRAINT valid_hook CHECK (hook_type IN (
    'PreToolUse','PostToolUse','SessionStart','SessionEnd',
    'Stop','SubagentStart','SubagentStop','PreCompact',
    'UserPromptSubmit','PermissionRequest'
  ))
);
CREATE INDEX idx_session ON events(session_id);
CREATE INDEX idx_hook_type ON events(hook_type);
CREATE INDEX idx_timestamp ON events(timestamp);
```

### Dual-Hook Wiring Pattern

Each hook type gets send_event.py added as a second command:

```json
{
  "matcher": "Bash",
  "hooks": [
    {
      "type": "command",
      "command": ".claude/hooks/damage-control/damage-control.sh" // existing
    },
    {
      "type": "command",
      "command": "uv run --script .claude/hooks/send_event.py" // NEW - dispatches to observability
    }
  ]
}
```

### Output Styles

Each is a markdown file in `.claude/output-styles/` containing a system prompt modifier:

- **ultra-concise**: "Respond with code only. No explanations unless asked."
- **markdown-focused**: "Use rich markdown: headers, code blocks, tables, bold/italic."
- **table-based**: "Present data in markdown tables wherever possible."
- **bullet-points**: "Structure all responses as hierarchical bullet lists."

## Execution Order

```
Phase 1 ──┐
           ├── (parallel, no dependencies)
Phase 2 ──┘
           │
Phase 3 ───── depends on Phase 2 (server must exist for send_event.py target)
           │
Phase 4 ───── depends on Phase 1A (team agents must exist)
           │
Phase 5 ───── depends on Phase 2 (observability apps must exist)
           │
Phase 6 ───── depends on all above
```

Phases 1 and 2 run in parallel (different file sets, no overlap).
Phases 3-6 are sequential.

## Verification

1. **Team Agents**: Launch Claude Code with `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`, verify builder and validator agents appear in agent list
2. **Output Styles**: Verify files exist at `.claude/output-styles/` and are valid markdown
3. **Observability Server**: Run `npm run obs:start`, verify server responds on port 4000 with `curl http://localhost:4000/events`
4. **Observability Client**: Open http://localhost:5173, verify dashboard loads with empty state
5. **send_event.py**: Run `echo '{"hook_type":"test"}' | uv run --script .claude/hooks/send_event.py`, verify event appears in dashboard
6. **Dual-Hook Integration**: Start a Claude Code session, perform tool calls, verify events stream to dashboard in real-time
7. **plan-w-team**: Run `/plan-w-team "test feature"`, verify it creates spec doc and assigns team agents
8. **Git**: All new files committed with semantic commit messages

## File Count Summary

| Category             | New    | Modified | Total  |
| -------------------- | ------ | -------- | ------ |
| Team Agents          | 2      | 0        | 2      |
| Output Styles        | 4      | 0        | 4      |
| Meta-Agent + Command | 2      | 0        | 2      |
| Observability Server | 3      | 0        | 3      |
| Observability Client | 9      | 0        | 9      |
| Event Dispatcher     | 1      | 0        | 1      |
| Start/Stop Scripts   | 2      | 0        | 2      |
| Integration          | 0      | 3        | 3      |
| **Total**            | **23** | **3**    | **26** |
