---
description: Load token-optimized project context (use at session start)
allowed-tools: Read
---

Load the project context for efficient agent operation.

1. **Check for project configuration:**
   - Read `.claude/project.json` for project settings
   - Note project name, phase, and features

2. **Load master context if available:**
   - Check for `/docs/agent-context/MASTER_CONTEXT.md`
   - Or `/docs/ARCHITECTURE.md`
   - Or `README.md`

3. **Internalize key information:**
   - Project overview and tech stack
   - Current phase and target date
   - Implementation status (what's built vs empty)
   - Blocked vs unblocked features
   - Architecture decisions
   - File placement rules and naming conventions

After loading, confirm: "Context loaded. Ready for development."

Then briefly state:
- Project name and current phase
- Number of blocked vs unblocked features
- Most urgent next step (from TODO.md if available)
