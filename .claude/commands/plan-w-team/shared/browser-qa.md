# Browser-Based QA Integration

For projects with a UI, `/plan-w-team` can leverage gstack's browse binary for real browser testing during Steps 5 (Design Review Lite) and 6 (Ship).

## Prerequisites

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

### Step 5f — Design Review Lite (when FRONTEND scope + browse available)

```
1. $B goto <dev-server-url>
2. $B snapshot -i                    # Map all interactive elements
3. $B screenshot /tmp/review-full.png # Full page evidence
4. $B responsive /tmp/responsive     # Check mobile/tablet/desktop
5. $B console --errors               # Check for JS errors
6. Review screenshots for AI slop patterns
7. Check interaction states: navigate to empty/error/loading states
8. For each fix: screenshot before -> fix code -> screenshot after -> $B snapshot -D to verify
```

### Step 6b — Test Suite with Browser Smoke Test (when browse available)

```
1. Run unit/integration tests normally
2. If dev server available: $B goto <url> -> $B snapshot -i -> verify key elements exist
3. $B console --errors -> fail if uncaught errors
4. Take final screenshot as ship evidence
```

## Graceful Degradation

If the browse binary is not installed or Bun is not available:

- Step 5f Design Review Lite falls back to **code-only review** (read CSS/JSX, no visual verification)
- Step 6b skips browser smoke test (unit/integration tests still run)
- No error — just a note: "Browser QA unavailable, using code-only review"

The browse binary is an enhancement, not a requirement. `/plan-w-team` works fully without it.
