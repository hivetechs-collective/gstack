---
description: Show currently blocked features awaiting executive review
allowed-tools: Read
---

Display blocked features from project configuration.

1. **Read project configuration:**
   - `.claude/project.json` - check features array for status="blocked"

2. **If project.json exists, format output:**

| Feature | ID | Status | Path |
|---------|-----|--------|------|

3. **If review-status.md exists:**
   - Read `/docs/review-status.md` or `/docs/governance/review-status.md`
   - Show review dates and days remaining

4. **Highlight:**
   - Features that are blocked
   - Reviews within 7 days
   - Reviews past their date (may be unblocked - verify status)

Remind: Blocked features CANNOT be implemented until marked as "unblocked"
in `.claude/project.json` or the corresponding review is completed.
