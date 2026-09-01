# /plan-w-team multi-account

Skill-owned, **local-first** multi-Anthropic-account rotation for `/plan-w-team` fleet lanes,
plus an **advisory** picker for interactive `claude` sessions. When you hold more than one Claude
Max subscription, this registers the accounts, reads each one's real 5h/7d utilization from
Anthropic rate-limit headers, and routes each fleet lane to the account with the most headroom.
Interactive sessions can't be auto-switched (Claude Code ties foreground identity to the keychain
`/login`, which an env token cannot override — see below), so for those it simply TELLS you which
account to move to. With 0–1 active accounts it is **fully dormant**: byte-for-byte the
single-account behavior, no prompts, no probing, no registry writes.

Everything here is self-contained and portable — no business/consumer paths are baked in — so it
travels to every consumer via the standard sync.

## Start here

```bash
# from the repo root (or alias the path below)
ACCT=.claude/commands/plan-w-team/accounts/accounts.sh

bash "$ACCT" setup          # onboard: scaffold a secrets.env if you have none, then import
bash "$ACCT" check          # read-only: what WOULD import + the live status table
bash "$ACCT" status         # live usage table (or a dormant line)
bash "$ACCT" advise         # JSON: which account to MOVE TO (drives the status-line nudge)
bash "$ACCT" which-account  # print only the label the fleet WOULD run as
bash "$ACCT" launch         # run a command with the optimal-account token in its ENV
```

`setup` (alias `authorize`) is the entry point for a new operator. It scaffolds a `0600`
`secrets.env` template if none exists, then discovers, validates, and bulk-registers every saved
token — idempotently.

## The token source — `secrets.env`

The primary store (scanned first) is a `0600` env file of setup-tokens:

```bash
# ~/.config/claude-pwt/secrets.env   (mode 0600)
CLAUDE_MAX_SETUP_TOKEN_<LABEL>=sk-ant-oat-…
CLAUDE_MAX_EMAIL_<LABEL>=you@example.com          # optional
ACCOUNT_FAILOVER_ORDER="label1 label2 …"          # optional
```

The `<LABEL>` is the account name (yours to choose). Default search path:
`~/.config/claude-pwt/secrets.env`; point `$PWT_SECRETS_ENV` (a `:`-separated path list) at a
store you keep elsewhere. Fill a slot by running `claude setup-token` **in a
real terminal** (never inside a Claude Code session) and pasting the `sk-ant-oat…` value, then
re-run `setup`.

## Interactive sessions — advisory, not auto-switched

Interactive Claude Code ties a session's account identity (status line, `/usage`, Remote Control,
`~/.claude.json`) to the **keychain `/login`**. A `CLAUDE_CODE_OAUTH_TOKEN` env token only redirects
model requests — it can't change that identity, and setting it actually breaks Remote Control
(2026-08-31 finding). So foreground rotation is **advisory**: the tooling tells you which account
has the most headroom and you switch with `/login`.

Two surfaces deliver the advice (both fail open — silent when dormant or single-account):

- **Status line** — a `👉 next: <label>` nudge appears once a cooler account exists, turning into
  `⚠ switch → <label> (5h/7d%)` when your current login gets hot. Driven by
  `.claude/scripts/account-advice.sh` (local cache + bounded + fail-open) off `accounts.sh advise`.
- **`claude-account`** — a shell function (claude-pattern's managed shell) that prints the full
  status table plus the recommended account and the exact `/login` step. Run it any time.

`launch` still exists for scripted/headless use (it execs a command with the optimal-account token
in its ENV), but shadowing interactive `claude` with it does NOT switch the account and is no longer
recommended.

## Security

Tokens are read from `0600` files into memory only — never printed, logged, or placed on argv.
They reach a child only via the `CLAUDE_CODE_OAUTH_TOKEN` env var (or a `0600` file). The registry
refuses to load on loose perms or a symlink. `accounts.sh` refuses to mint a token when
`CLAUDECODE` is set.

## Modules

| File               | Role                                                                         |
| ------------------ | ---------------------------------------------------------------------------- |
| `accounts.sh`      | operator CLI (headless, bash 3.2) — the only entry point you run             |
| `lib.sh`           | shared shell helpers (path/perms/dormancy/python resolution)                 |
| `registry.py`      | durable identity store (`accounts.json`, `0600`, `flock`, `O_NOFOLLOW`)      |
| `probe.py`         | usage measurement (rate-limit header parse + fail-open cache)                |
| `selector.py`      | pure lowest-`max(5h%,7d%)` selection with pinning + rotation                 |
| `import_stores.py` | discover/validate/bulk-register saved tokens; `secrets.env` source; scaffold |
| `lane_cred.py`     | spawn-time per-lane token writer (`settings.local.json` env block)           |
| `session_cred.py`  | interactive helpers: `advise` (status-line nudge), `which-account`, `launch` |
| `backend.py`       | coordination seam (`LocalBackend` default; `RemoteBackend` Phase-2 stub)     |

Full operator procedure and the Phase-2 design:
[`docs/operations/pwt-multi-account-onboarding-and-phase2.md`](../../../../docs/operations/pwt-multi-account-onboarding-and-phase2.md).
Test coverage: `tests/skill/cases/pwt-accounts.bats` (AC1–AC13, 54 cases).
