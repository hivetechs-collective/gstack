---
description: Run all governance checks (stubs, deadlines, inventory)
allowed-tools: Bash, Read
---

Run the complete governance check suite:

1. **Scan for stub format compliance:**

```bash
npm run scan:stubs || pnpm run scan:stubs
```

2. **Check for approaching/overdue deadlines:**

```bash
npm run check:deadlines || pnpm run check:deadlines
```

3. **Verify code inventory is current:**

```bash
npm run inventory:check || pnpm run inventory:check
```

If scripts are not available, report:
- "Governance scripts not configured"
- Suggest running `npm install` or checking package.json

Summarize findings with:
- Total stubs found (valid vs invalid)
- Any approaching deadlines (within 7 days)
- Any overdue deadlines
- Inventory sync status

If any issues found, provide specific remediation steps.

Note: Governance scripts are in `scripts/governance/`. Configure them in
package.json for this project.
