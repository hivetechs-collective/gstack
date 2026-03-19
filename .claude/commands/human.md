# Human Action Queue Management

Manages tasks that require human intervention after all automation attempts have failed.

## Usage

```
/human              # Show current queue with stats
/human complete     # Mark an action as complete
/human add          # Manually add an action item
/human blocked      # Show all tasks blocked by human actions
```

## Command Actions

### Default: Show Queue

Display the current @human_actions.md with live statistics:
- Pending actions count
- Total blocked tasks
- Priority breakdown (Critical/High/Medium/Low)

```bash
pnpm run human:status
```

### Complete Action

Mark a human action as completed:

1. Read @human_actions.md to show pending actions
2. Ask user which action was completed
3. Change `- [ ]` to `- [x]` for that action
4. Run sync to update blocking relationships
5. Report how many tasks are now unblocked

```bash
pnpm run human:complete HA-XXX
```

### Add Action

Manually add a new human action item:

1. Ask for action title
2. Ask for instructions
3. Ask what tasks it blocks (if known)
4. Generate unique ID (HA-XXX)
5. Add to @human_actions.md with proper format

### Show Blocked

Display all tasks in fix_plan.md that are blocked by human actions:

```bash
# Check fix_plan.md for [!] blocked items
grep "^\- \[!\]" fix_plan.md
```

## Integration with Ralph

The human action queue integrates with the development pipeline:

1. **Detection**: Ralph detects when a task requires human intervention
2. **Pre-check**: Ralph MUST try automation first (CLI, Playwright, agents)
3. **Escalation**: Only after automation fails, add to @human_actions.md
4. **Blocking**: Related tasks in fix_plan.md are marked blocked
5. **Completion**: Human marks done, blocked tasks become actionable
6. **Resume**: Ralph automatically picks up newly unblocked tasks

## Automation First (MANDATORY)

Before adding ANY human action, verify these have been tried:

1. **CLI Tools**: wrangler, gh, stripe, neonctl
2. **Environment**: Check .env files for existing secrets
3. **Playwright**: Automate browser dashboards
4. **Agents**: cloudflare-expert, devops-automation-expert, etc.
5. **Documentation**: /docs/guides/setup/ for alternatives

See `/docs/operations/AUTOMATION_CAPABILITIES.md` for full reference.

## File Locations

- **Queue**: `@human_actions.md` (repo root)
- **Script**: `scripts/governance/human-actions.ts`
- **Docs**: `docs/operations/AUTOMATION_CAPABILITIES.md`

## Examples

### Viewing the Queue

```
/human

Output:
# Human Action Queue
**Pending Actions:** 3 | **Total Blocked Tasks:** 47

## 🔴 CRITICAL (Blocking 10+ tasks)
### [HA-001] Enable R2 Storage in Cloudflare Dashboard
...
```

### Completing an Action

```
/human complete

> Which action did you complete?
> HA-001

✅ Marked HA-001 as complete
   Unblocked 23 tasks in fix_plan.md
   Next highest priority: HA-002 (Blocking 12 tasks)
```

### Adding an Action

```
/human add

> Title: Configure Apple Developer Certificate
> Instructions:
>   1. Log into Apple Developer Portal
>   2. Create new Developer ID certificate
>   3. Download and install in Keychain
> Blocked tasks: macOS signing, notarization

✅ Created HA-003: Configure Apple Developer Certificate
   Priority: P1 (Blocking 8 tasks)
```
