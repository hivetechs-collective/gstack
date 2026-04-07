# Browser-Based QA Integration

For projects with a UI, `/plan-w-team` can perform real browser testing during Steps 5 (Design Review Lite) and 6 (Ship) using one of two approaches.

## Approach Selection

| Method                          | When Available                                | Best For                                            |
| ------------------------------- | --------------------------------------------- | --------------------------------------------------- |
| **Playwright MCP** (preferred)  | When `mcp__playwright__*` tools are available | Evaluator agent (Step 4b), programmatic testing, CI |
| **Browse binary** (alternative) | When gstack browse is installed               | Interactive exploration, responsive screenshots     |

The evaluator agent (Step 4b) uses **Playwright MCP exclusively** — it calls tools like `browser_navigate`, `browser_snapshot`, `browser_click`, etc. The browse binary is a separate CLI tool for manual/interactive browser inspection.

If neither is available, browser QA falls back to code-only review (read CSS/JSX, no visual verification).

## Option A: Playwright MCP (Primary)

Available when the Playwright MCP server is connected. No installation needed — it comes with Claude Code's MCP configuration.

### Key Tools

| Tool                       | Purpose                                      |
| -------------------------- | -------------------------------------------- |
| `browser_navigate`         | Navigate to URL                              |
| `browser_snapshot`         | Get accessibility tree with interactive refs |
| `browser_click`            | Click elements                               |
| `browser_fill_form`        | Fill input fields                            |
| `browser_console_messages` | Check for JS errors                          |
| `browser_take_screenshot`  | Visual evidence                              |
| `browser_wait_for`         | Wait for async operations                    |
| `browser_network_requests` | Verify API calls                             |

### Usage in Evaluator (Step 4b)

The evaluator agent uses Playwright MCP tools directly per its Playwright Test Plan criteria. No browse binary needed.

## Option B: Browse Binary (Alternative)

### Prerequisites

The browse binary requires Bun and Playwright Chromium. One-time setup:

```bash
cd ~/.claude/skills/gstack
bun install
bun run build
bunx playwright install chromium
```

This produces `~/.claude/skills/gstack/browse/dist/browse` (~58MB compiled binary).

## How It Works

The browse binary runs a persistent headless Chromium daemon:

- **Architecture**: CLI client -> HTTP request -> Bun HTTP server -> Playwright -> Chromium
- **Cold start**: ~3 seconds (first command). Subsequent commands: ~100-200ms
- **Auto-shutdown**: 30 minutes idle
- **Security**: localhost-only, bearer token auth, random port 10000-60000
- **State file**: `<project>/.gstack/browse.json` (pid, port, token)
- **Isolation**: Each project gets its own browser instance

## Binary Discovery

```bash
# Find browse binary (check project-local first, then global)
_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
B=""
[ -n "$_ROOT" ] && [ -x "$_ROOT/.claude/skills/gstack/browse/dist/browse" ] && B="$_ROOT/.claude/skills/gstack/browse/dist/browse"
[ -z "$B" ] && [ -x ~/.claude/skills/gstack/browse/dist/browse ] && B=~/.claude/skills/gstack/browse/dist/browse
```

If `$B` is empty, browser QA is unavailable — skip browser-dependent steps gracefully.

## Command Reference

### Navigation & Content

```bash
$B goto https://localhost:3000      # Navigate to URL
$B snapshot -i                       # Interactive elements with @e refs
$B snapshot -D                       # Diff against previous snapshot
$B text                              # Cleaned page text
$B console --errors                  # JavaScript errors
$B network                           # Network requests log
```

### Interaction (use @e refs from snapshot)

```bash
$B click @e3                         # Click element
$B fill @e2 "user@example.com"       # Fill input
$B select @e5 "Option B"             # Select dropdown
$B hover @e1                         # Hover element
$B press Enter                       # Press key
$B scroll                            # Scroll to bottom
$B wait "#loading" --networkidle     # Wait for element/network
```

### Visual Evidence

```bash
$B screenshot /tmp/before.png        # Full page screenshot
$B screenshot --viewport /tmp/vp.png # Viewport only
$B screenshot @e3 /tmp/element.png   # Element crop
$B responsive /tmp/layout            # Mobile + tablet + desktop screenshots
$B snapshot -a                        # Annotated screenshot with ref overlays
```

### State & Debugging

```bash
$B cookies                           # All cookies
$B storage                           # localStorage + sessionStorage
$B perf                              # Page load timings
$B is visible "#submit-btn"          # Assert element state
$B status                            # Daemon health check
```

## Snapshot Output Format

The snapshot command parses the accessibility tree into interactive refs:

```
  @e1 [heading] "Welcome" [level=1]
  @e2 [textbox] "Email"
  @e3 [button] "Submit"
  @e4 [link] "Forgot password?"
```

- `@e` refs map to ARIA-accessible interactive elements
- `@c` refs (via `snapshot -C`) map to non-ARIA clickable elements (custom divs with click handlers)
- Refs are cleared on navigation — re-run `snapshot` after page changes
- Stale refs are detected via async count check (~5ms) before use

## Integration Points in /plan-w-team

### Step 4b — Evaluator (Playwright MCP)

The evaluator agent uses Playwright MCP tools directly. No browse binary needed:

```
1. browser_navigate -> <dev-server-url>
2. browser_snapshot -> get interactive element refs
3. browser_click / browser_fill_form -> test functional criteria
4. browser_console_messages -> check for JS errors
5. browser_take_screenshot -> visual evidence of pass/fail
```

### Step 5f — Design Review Lite (when FRONTEND scope)

**With Playwright MCP** (preferred):

```
1. browser_navigate -> <dev-server-url>
2. browser_snapshot -> map all interactive elements
3. browser_take_screenshot -> full page evidence
4. browser_console_messages -> check for JS errors
5. Review screenshots for AI slop patterns
6. Check interaction states: navigate to empty/error/loading states
```

**With browse binary** (if installed):

```
1. $B goto <dev-server-url>
2. $B snapshot -i                    # Map all interactive elements
3. $B screenshot /tmp/review-full.png # Full page evidence
4. $B responsive /tmp/responsive     # Check mobile/tablet/desktop
5. $B console --errors               # Check for JS errors
6. For each fix: screenshot before -> fix code -> screenshot after -> $B snapshot -D to verify
```

### Step 6b — Test Suite with Browser Smoke Test

```
1. Run unit/integration tests normally
2. If dev server available: browser_navigate -> verify key elements exist
3. browser_console_messages -> fail if uncaught errors
4. browser_take_screenshot -> final screenshot as ship evidence
```

## Graceful Degradation

| Available                | Behavior                                                |
| ------------------------ | ------------------------------------------------------- |
| Playwright MCP connected | Full browser QA via MCP tools (preferred)               |
| Browse binary installed  | Full browser QA via CLI (alternative)                   |
| Neither available        | Code-only review (read CSS/JSX, no visual verification) |

Browser QA is an enhancement, not a requirement. `/plan-w-team` works fully without it — just note: "Browser QA unavailable, using code-only review".
