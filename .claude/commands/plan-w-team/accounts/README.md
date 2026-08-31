# /plan-w-team multi-account

Skill-owned, **local-first** multi-Anthropic-account rotation for `/plan-w-team` and for
interactive `claude` sessions. When you hold more than one Claude Max subscription, this
registers the accounts, reads each one's real 5h/7d utilization from Anthropic rate-limit
headers, and routes each fleet lane — and each foreground session — to the account with the most
headroom. With 0–1 active accounts it is **fully dormant**: byte-for-byte the single-account
behavior, no prompts, no probing, no registry writes.

Everything here is self-contained and portable — no business/consumer paths are baked in — so it
travels to every consumer via the standard sync.

## Start here

```bash
# from the repo root (or alias the path below)
ACCT=.claude/commands/plan-w-team/accounts/accounts.sh

bash "$ACCT" setup          # onboard: scaffold a secrets.env if you have none, then import
bash "$ACCT" check          # read-only: what WOULD import + the live status table
bash "$ACCT" status         # live usage table (or a dormant line)
bash "$ACCT" launch         # start `claude` on the optimal account (--pinned L to force one)
bash "$ACCT" which-account  # print only the label a session would run as
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

The `<LABEL>` is the account name (yours to choose). Default search paths:
`~/.config/claude-pwt/secrets.env`, then `~/.config/cleanrev/secrets.env`; override with
`$PWT_SECRETS_ENV` (a `:`-separated path list). Fill a slot by running `claude setup-token` **in a
real terminal** (never inside a Claude Code session) and pasting the `sk-ant-oat…` value, then
re-run `setup`.

## Interactive sessions on the same rotation

Shadow `claude` in your shell rc so every session rides the rotation (recursion-safe — `launch`
uses `os.execvpe`, which bypasses shell functions):

```bash
claude() { command "$HOME/…/accounts/accounts.sh" launch -- claude "$@"; }
```

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
| `session_cred.py`  | interactive-session launcher (`launch` / `which-account`)                    |
| `backend.py`       | coordination seam (`LocalBackend` default; `RemoteBackend` Phase-2 stub)     |

Full operator procedure and the Phase-2 design:
[`docs/operations/pwt-multi-account-onboarding-and-phase2.md`](../../../../docs/operations/pwt-multi-account-onboarding-and-phase2.md).
Test coverage: `tests/skill/cases/pwt-accounts.bats` (AC1–AC11, 46 cases).
