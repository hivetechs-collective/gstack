# `/ci-alert-setup` — Install CI failure alerting in this repo

**Purpose:** Guide per-repo installation of the `ci-alert.yml` workflow distributed by `claude-pattern`. Pick a notification provider, configure the repo secret, install the workflow, and smoke-test it. One-time per-repo activity.

**Why separate from sync:** `sync-to-project.sh` drops the template at `scripts/ci-alert.yml.template` but deliberately does NOT install it into `.github/workflows/` — that would silently activate CI alerting on every sync, and would conflict with per-repo provider choices. This command is the explicit activation step.

See [`docs/ci-alerting.md`](../../../docs/ci-alerting.md) for architecture and [`docs/ci-alerting-providers.md`](../../../docs/ci-alerting-providers.md) for detailed provider setup.

---

## Invocation

```
/ci-alert-setup
```

No arguments. Steps run sequentially; a failed step halts the flow with a clear recovery action. Re-invoking after completion offers a refresh path (rotate secrets / reinstall template) without duplicating the workflow file.

---

## Tool Permissions

All tools used are covered by the base allow-list in `.claude/settings.json` — no per-project configuration needed. See [`.claude/docs/SKILL_PERMISSION_CONVENTION.md`](../../docs/SKILL_PERMISSION_CONVENTION.md) for the convention.

| Tool    | Use                                                                                |
| ------- | ---------------------------------------------------------------------------------- |
| `Read`  | Inspect `scripts/ci-alert.yml.template`, existing `.github/workflows/ci-alert.yml` |
| `Write` | Install `.github/workflows/ci-alert.yml` when first activating                     |
| `Bash`  | `gh secret list/set`, `cp`, `mv`, `git status`, `gh workflow run`, `gh run list`   |

**State & output paths touched:**

- `.github/workflows/ci-alert.yml` — the installed workflow (copied from the template)
- Repo secrets — `CI_ALERT_DISCORD_WEBHOOK` | `CI_ALERT_NTFY_TOPIC` | `PUSHOVER_USER_KEY` + `PUSHOVER_APP_TOKEN`
- `scripts/ci-alert.yml.template` — read only (the source template shipped by sync)

---

## Step pipeline

| Step                           | Purpose                                                                                                                             |
| ------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------- |
| **1. Verify template present** | Confirm `scripts/ci-alert.yml.template` exists (indicates sync ran). If missing, point to sync command.                             |
| **2. Detect existing install** | Check for `.github/workflows/ci-alert.yml`. If present, offer refresh (keep / rotate secret / reinstall) instead of linear install. |
| **3. Pick provider**           | Present decision tree (Discord / ntfy / Pushover / issue-only) with inline trade-offs. User picks one.                              |
| **4. Acquire provider secret** | Walk user through obtaining webhook URL / topic name / app credentials for the chosen provider.                                     |
| **5. Set secret via gh CLI**   | Run `gh secret set <NAME>` for the chosen provider.                                                                                 |
| **6. Install workflow**        | Copy template to `.github/workflows/ci-alert.yml`. Commit and push prompted separately.                                             |
| **7. Smoke test**              | Force a failure on a test workflow (or dispatch one) and verify the notification + issue arrive.                                    |

---

## Step 1 — Verify template present

Check `scripts/ci-alert.yml.template` exists. If missing:

```bash
ls scripts/ci-alert.yml.template
```

**Not found?** The repo hasn't been synced from `claude-pattern` yet, or the sync is older than this feature. Run:

```bash
# From claude-pattern repo
./.claude/scripts/sync-to-project.sh <path-to-this-repo>
```

Then re-run `/ci-alert-setup`.

---

## Step 2 — Detect existing install

```bash
ls .github/workflows/ci-alert.yml 2>/dev/null
```

**If already installed:** offer three refresh options and skip ahead:

1. **Keep as-is** — no changes; exit.
2. **Rotate secret only** — skip to Step 5 with the existing provider.
3. **Full reinstall** — back up existing file to `.github/workflows/ci-alert.yml.backup-<UTC>`, then continue from Step 3 (may switch providers).

**If not installed:** continue to Step 3.

---

## Step 3 — Pick a provider

Decision tree (inline summary; full comparison in [`docs/ci-alerting.md`](../../../docs/ci-alerting.md#provider-comparison)):

| Provider     | Cost            | Push quality                 | Pick this if…                                                          |
| ------------ | --------------- | ---------------------------- | ---------------------------------------------------------------------- |
| **Discord**  | Free            | Rich embed, mobile + desktop | You want the default. No account setup friction beyond having Discord. |
| **ntfy.sh**  | Free            | Plain text, mobile + desktop | You want the lightest-weight path, no account, privacy-friendly.       |
| **Pushover** | $5 per platform | Purpose-built critical alert | You need iOS "bypass quiet hours" priority and unified alert inbox.    |
| issue-only   | Free            | No push                      | You only want the issue-tracking side; don't want interrupts.          |

Precedence if multiple secrets are set: Discord → ntfy → Pushover → issue-only. To switch providers later: set the new secret, delete the old one.

---

## Step 4 — Acquire provider secret

Per-provider steps (condensed — full walkthrough in [`docs/ci-alerting-providers.md`](../../../docs/ci-alerting-providers.md)):

### Discord

1. Discord server → channel → gear icon → **Integrations** → **Webhooks** → **New Webhook**.
2. Copy the Webhook URL (`https://discord.com/api/webhooks/<id>/<token>`).

### ntfy.sh

1. Pick an unguessable topic name (e.g., `ci-j3kq9x-myrepo-alerts`). Topics are public on the free tier.
2. Install the ntfy app (iOS / Android / web) and subscribe to your topic.

### Pushover

1. Sign up at pushover.net; install the app ($5 per platform after 30-day trial).
2. Copy your **User Key** from the dashboard.
3. Create an application at pushover.net/apps/build; copy the **API Token**.

### Issue-only

No secret needed. Skip to Step 6.

---

## Step 5 — Set the repo secret

Run the command matching your chosen provider (replace `<value>` with the credential from Step 4):

```bash
# Discord
gh secret set CI_ALERT_DISCORD_WEBHOOK --body "<webhook-url>"

# ntfy
gh secret set CI_ALERT_NTFY_TOPIC --body "<topic-name>"

# Pushover (both required)
gh secret set PUSHOVER_USER_KEY --body "<user-key>"
gh secret set PUSHOVER_APP_TOKEN --body "<app-token>"
```

Verify:

```bash
gh secret list
```

The secret name should appear with a recent "Updated" timestamp. Values are never shown.

---

## Step 6 — Install the workflow

Copy the template into place:

```bash
mkdir -p .github/workflows
cp scripts/ci-alert.yml.template .github/workflows/ci-alert.yml
```

Commit and push:

```bash
git add .github/workflows/ci-alert.yml
git commit -m "feat(ci): install ci-alert workflow (failure visibility + auto-triage)"
git push
```

The workflow activates on the next completed run of any other workflow in the repo.

---

## Step 7 — Smoke test

Verify the full pipeline end-to-end. Two options:

### Option A — Break a real workflow (recommended)

1. Pick a cheap workflow (e.g., a linter job). Add an intentional failure:
   ```bash
   git checkout -b ci-alert-smoke-test
   # Edit .github/workflows/<some-workflow>.yml — add `exit 1` to the first step
   git commit -am "test(ci): intentional failure to smoke-test ci-alert"
   git push -u origin ci-alert-smoke-test
   ```
2. Wait ~30-60 seconds for the workflow to run and fail.
3. Verify:
   - Your configured provider shows an alert with a clickable run URL.
   - Repo Issues tab shows a new issue `CI Red: <workflow-name>` labeled `ci-red`.
4. Revert:
   ```bash
   git revert HEAD
   git push
   ```
5. Verify the green run closes the issue with a `Resolved by <sha>` comment.
6. Clean up: `git checkout main && git branch -D ci-alert-smoke-test` and delete the remote branch.

### Option B — Dispatch a test workflow (no repo changes)

If your repo has a `workflow_dispatch`-triggerable workflow that can be toggled to fail via input, use:

```bash
gh workflow run <workflow-name>.yml -f fail=true  # or whatever your input is named
gh run watch
```

Verify the same alert + issue + resolution behavior on green.

---

## Success criteria

- [ ] `.github/workflows/ci-alert.yml` exists and is committed.
- [ ] `gh secret list` shows the chosen provider's secret(s), OR user explicitly chose issue-only mode.
- [ ] Smoke test produced a notification + a labeled issue + an auto-close on recovery.
- [ ] `ci-red` label exists in the repo (auto-created on first failure).

## Troubleshooting

See [`docs/ci-alerting.md`](../../../docs/ci-alerting.md#troubleshooting) for the full troubleshooting section. Top issues:

- **403 on issue create** → enable "Read and write permissions" in Settings → Actions → General.
- **No push despite secret** → check the ci-red issue for a `⚠️ Notification push failed` comment; rotate the secret if revoked.
- **Infinite loop** → verify `name: CI Alert` at top of file matches the self-skip guard string.

---

## Related

- [`docs/ci-alerting.md`](../../../docs/ci-alerting.md) — architecture, verification checklist, troubleshooting catalog
- [`docs/ci-alerting-providers.md`](../../../docs/ci-alerting-providers.md) — per-provider setup reference
- [`docs/specs/ci-failure-visibility.md`](../../../docs/specs/ci-failure-visibility.md) — full feature spec with deferred items
