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

- **Status line** — a `👉 next: <email>` nudge appears once a cooler account exists, turning into
  `⚠ switch → <email> (5h N% · 7d N% · Fable N%)` when your current login gets hot. The account is named by its
  **full email** (the registry label is only a fallback when the advisory carries none): labels
  are operator-chosen stems that collide in practice — two accounts on one domain both read as
  `<company>` — and `/login` asks for an email, so the email is the one unambiguous handle. The
  nudge's **color follows the same heat tiers as the `5h` number beside it** (peach from 50%, red
  with `⚠ switch` from 80%), taken over the hottest reading the status line holds — the live plan
  read AND the advisory's cached view of your current account — so it never sits green next to a
  peach or red plan number. Driven by `.claude/scripts/account-advice.sh` off `accounts.sh advise` — a
  machine-wide, login-keyed cache refreshed by a detached bounded singleton (the render never
  waits on the probe), fail-open; see
  [`docs/operations/statusline-usage-reporting.md`](../../../../docs/operations/statusline-usage-reporting.md).
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
| `probe.py`         | usage measurement: one `max_tokens:1` Fable-model probe per account per TTL → 5h/7d + per-window statuses + the LIVE Fable weekly bucket (`7d_oi-*`, `scoped_source: ratelimit-header`); window-checked `plan-usage.sh` sample fallback; `limited_until` on a rejected window; prev-sample burn fields; fail-open cache v2 |
| `selector.py`      | pure lowest-`max(5h%,7d%)` selection with pinning + rotation; `--model`/`--need fable` ranks on `max(5h,7d,Fable)` and excludes Fable-rejected accounts |
| `import_stores.py` | discover/validate/bulk-register saved tokens; `secrets.env` source; scaffold |
| `lane_cred.py`     | spawn-time per-lane token writer (`settings.local.json` env block)           |
| `session_cred.py`  | interactive helpers: `advise` (status-line nudge), `which-account`, `launch` |
| `backend.py`       | coordination seam (`LocalBackend` default; `RemoteBackend` Phase-2 stub)     |

Full operator procedure and the Phase-2 design:
[`docs/operations/pwt-multi-account-onboarding-and-phase2.md`](../../../../docs/operations/pwt-multi-account-onboarding-and-phase2.md).
Test coverage: `tests/skill/cases/pwt-accounts.bats` (AC1–AC13, 54 cases).

## Reset-aware selection (2.45.0)

The selector looks FORWARD, not only at current headroom. Design agreed with the
cleanscale governor session (cleanscale #5266); the governor keeps its own logic in
`account-forest.sh` and reads the same `usage-cache.json` fields. Every rule is additive,
has its own switch, and fails open to the plain "lowest max(5h,7d[,Fable])" ranking on a
missing or stale field. None can admit an account the HOLD/limit exclusions rejected, and a
Fable-shut account stays eligible for `need=any`.

| Rule | What it does | Knobs |
| --- | --- | --- |
| R1 expose | Every `classify` result and `advise` answer carries `fable_next_open` = `{label, at_epoch}`, the earliest future Fable reset among Fable-shut accounts. `advise` also carries `best_scoped_reset` / `current_scoped_reset` and the selector `reason`. | — |
| R2 hold or downgrade | `need=fable` with nothing eligible: `fable_wait` = `hold` when the opening is near, else `downgrade`, plus `recheck_at`. Advisory only. | `PWT_ACCT_FABLE_HOLD_MIN` (45) |
| R3 use it or lose it | Weekly headroom (7d; Fable too under `need=fable`) expiring inside the horizon earns a bounded bonus off the rank score: `headroom × (1 − left/horizon) × 0.25`, capped. The 5h window never earns it. | `PWT_ACCT_EXPIRY_HORIZON_H` (12), `PWT_ACCT_EXPIRY_BONUS_MAX` (15), off: `PWT_ACCT_DISABLE_EXPIRY_BONUS=1` |
| R5 projection | A window whose `*_burn_ppm` carries it to `HOLD_HARD` within the lookahead, and before it resets, sorts with the soft-penalized tier. Still picked when it is the only account. | `PWT_ACCT_PROJECT_MIN` (45), off: `PWT_ACCT_DISABLE_PROJECTION=1` |
| R4 Fable reserve | DEFAULT OFF. Under `need=any`, when exactly one eligible account has Fable headroom and its Fable reset is known and beyond the horizon, it sorts after the other unpenalized accounts. Never when it is the only unpenalized account. | on: `PWT_ACCT_FABLE_RESERVE=1` |

The winning `reason` names the rules that fired: `[expiry-bonus 12.5]`, `[projected-hot]`,
`[soft-penalized]`.
