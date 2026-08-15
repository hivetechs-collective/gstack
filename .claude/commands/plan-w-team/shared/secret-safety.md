# Secret Safety — Defense-in-Depth Model for /plan-w-team

Shared reference for the four secret-leak prevention layers and the authoritative pattern catalog. Loaded by `05-ship.md` at the 6a-ter gate and by `pre-commit-quality.sh` indirectly (through the shared scanner).

This file is the contract. If you change a pattern, a placeholder rule, or a defense layer, you edit it here and nowhere else.

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         SINGLE SOURCE OF TRUTH                              │
│                   .claude/scripts/secret-scan.sh                            │
│                                                                             │
│  Pattern catalog · Placeholder heuristic · Redaction · Dedup                │
│                                                                             │
│  Modes: --staged | --paths FILE... | --diff RANGE | --json | --help        │
│  Exit:  0 clean · 1 live-shape secret found · 2 bad args / internal error   │
└─────────────────────────────────────────────────────────────────────────────┘
      ▲                  ▲                       ▲                       ▲
      │ --paths          │ --staged              │ --diff                │ --paths
      │                  │                       │                       │
┌─────┴──────────┐ ┌─────┴─────────┐   ┌─────────┴──────────┐  ┌─────────┴──────────┐
│  Layer 0       │ │  Layer 1      │   │  Layer 2           │  │  Layer 3           │
│  WRITE-TIME    │ │  PRE-COMMIT   │   │  SHIP GATE         │  │  SYNC FILTER       │
│  damage-       │ │  pre-commit-  │   │  05-ship.md        │  │  sync-to-          │
│  control.sh    │ │  quality.sh   │   │  §6a-ter           │  │  project.sh        │
│  (PreToolUse)  │ │               │   │                    │  │  SECRET_GUARD_     │
│                │ │  Blocks commit│   │  Blocks ship + PR  │  │  FILTERS (rsync    │
│  BLOCKS the    │ │  with exit 2  │   │  with exit 1       │  │  filename-only     │
│  Write/Edit    │ │               │   │                    │  │  include/exclude)  │
│  before it     │ │  Runs:        │   │  Runs:             │  │                    │
│  reaches disk  │ │  • --staged   │   │  • --staged        │  │  Runs at sync      │
│                │ │               │   │  • --diff          │  │  time — prevents   │
│  check_secret_ │ │               │   │    origin/<base>.. │  │  template-         │
│  content()     │ │               │   │    HEAD            │  │  distribution from │
│                │ │               │   │                    │  │  leaking secrets   │
└────────────────┘ └───────────────┘   └────────────────────┘  └────────────────────┘
```

### Why four layers

Each layer catches leaks the others cannot:

- **Write-time (Layer 0, B1 / 1.33.0)** is the earliest possible interception: the
  `damage-control.sh` PreToolUse hook extracts the content of a `Write` (`content`) or
  `Edit` (`new_string`) call, runs it through the shared scanner, and **blocks the tool
  call outright** — the secret never reaches the working tree, let alone the index. Kill
  switch: `DAMAGE_CONTROL_DISABLE_SECRET_CONTENT=1`. Before 1.33.0 this layer was
  *advertised* (in `03-execute.md` and a `secretDetection:` block in `patterns.yaml`)
  but not implemented — the config had drifted from the scanner and enforced nothing.
- **Pre-commit** catches secrets before they touch git object storage. Cheap, local, per-developer. It also catches anything written while Layer 0 was disabled or bypassed.
- **Ship gate** catches secrets that slipped through pre-commit (hook disabled, repo cloned without hooks, amend bypass) by scanning both staged content AND the full branch diff. This is where history-rewrite decisions happen.
- **Sync filter** is rsync-level filtering for the claude-pattern distribution itself. It prevents one project's `.env.local` from being copied into another project during a sync — a structurally different failure mode that pattern-matching cannot solve, because the receiving repo has no commit history to scan yet.

Defense in depth means no layer is load-bearing alone. The sync filter exists even though scanners exist; the scanner exists even though filters exist; and Layer 0 blocking a write does not excuse the three layers behind it, because a worker can disable a hook but cannot disable the ship gate.

## Vendor / SSO Console Access — Hard Guardrail (REQ-5, SAFETY)

**Workers MUST NEVER navigate to, or attempt an interactive login on, a vendor or
SSO management console.** 2026-05-29 incident: a bg ops/compliance worker, lacking
a programmatic path, drove Playwright to `console.neon.tech` and hit the Keycloak
OAuth login. A worker cannot complete interactive SSO and must not try — that path
leads to credential-stuffing-shaped behavior, hung browser sessions, and at worst a
lockout.

**The rule.** A task that requires **management-plane / vendor-console access is a
`blocked-external` gate**: HALT and escalate to the human (same shape as the
existing one-way-door asks — e.g. Stripe Connect #690, Apple #276). Do **not** open
a browser to it, do **not** retry, do **not** attempt OAuth/SSO.

Non-exhaustive console denylist (navigation or login to any of these = HALT):

- `console.neon.tech`, `console.aws.amazon.com`, `console.cloud.google.com`
- `dashboard.stripe.com`, `dash.cloudflare.com`
- `developer.apple.com` / `appstoreconnect.apple.com`, `play.google.com/console`
- any Keycloak / Okta / Auth0 / Google / Microsoft / GitHub **OAuth/SSO login** page

**The allowed path is programmatic only.** Verification and changes use the
documented programmatic interface — a Postgres connection string, a vendor **API
token from the secrets inventory**, or the prod HTTP API — never an interactive
browser login. If no programmatic credential exists for the task, that absence is
itself the `blocked-external` escalation (the human provisions the token or performs
the console action), not a cue to brute-force the UI.

> Browser automation (Playwright/maestro) remains correct for **the app under
> test** — your own UI on localhost / a preview URL. The guardrail is specifically
> against third-party vendor/SSO **management consoles**.

## CLI Non-Interactive Credential Walls — Hard Guardrail (REQ-6, SAFETY)

§REQ-5 above covers the **browser** vendor/SSO console wall. **§REQ-6 is its CLI
sibling**: a deploy CLI run **non-interactively** (no human at the keyboard) that
hits a credential/token wall. 2026-06-02 cleanscale incident: a deploy hit

> `wrangler` — "In a non-interactive environment, it's necessary to set a
> `CLOUDFLARE_API_TOKEN` environment variable"

and the run **stopped short** — it neither completed the deploy nor raised a proper
operator escalation, and the specific missing secret was never surfaced or
persisted. A worker cannot complete an interactive `wrangler login` (OAuth in the
operator's browser) any more than it can complete an SSO console login, so it must
not pretend the step is done or skip it.

**The rule.** A CLI non-interactive credential/token wall is a `blocked-external`
gate — the SAME shape as §REQ-5. HALT and escalate to the operator. Do **not** mark
the deploy/ship step complete, do **not** silently skip it, do **not** retry into a
loop. The step stays explicitly BLOCKED until the operator provisions the secret
or completes the login.

Non-exhaustive wall-signature catalog (any of these on a deploy CLI = HALT):

- `wrangler` / `gh` / `vercel` / `eas` / `flyctl` / `aws` / `pnpm run deploy`
  emitting: "non-interactive", "set `<PROVIDER>`\_API_TOKEN", "could not
  authenticate", "not authenticated", "login required", "not logged in", "you must
  be logged in", "not logged into any …", "no existing credentials found",
  "run `<provider> login`".

**The real mechanism (not prose).** This guardrail is enforced by three composed
pieces — see [`no-github-actions.md §"Deploy Secret Access" → "Escalate, never skip"`](./no-github-actions.md):

| Piece                                                 | Role                                                                                                                                                                                                          |
| ----------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `.claude/scripts/credential-wall-detect.sh`           | Pure detector: classifies the wall + extracts the EXACT missing secret name (`CLOUDFLARE_API_TOKEN`, `VERCEL_TOKEN`, …).                                                                                      |
| `.claude/hooks/plan-w-team-credential-wall-detect.sh` | PostToolUse / PostToolUseFailure hook: persists `.claude/state/plan-w-team-credwall-<SLUG>.json` (survives compaction) + emits the `USER_ESCALATION_HALT` block (`pending_escalations: ["credential-wall"]`). |
| `.claude/scripts/plan-w-team-credential-wall-gate.sh` | ENFORCING ship gate (`05-ship.md §6a-quinquies`): fails closed while the artifact is unresolved — the step-completeness invariant.                                                                            |

The durable artifact records the missing secret name + the repo's documented
operator action (resolved from `docs/operations/DEPLOY_RUNBOOK.md` when present).
**It never stores a secret value** — only the NAME of the one that is missing.

**The allowed resolution is operator-side, programmatic-or-login.** The operator
provisions the least-privilege token into the headless `0600` `deploy.env` (per
`no-github-actions.md §"Deploy Secret Access"`) OR completes the documented login,
sets `"resolved": true` in the artifact, and re-runs. A worker must not brute-force
the credential into existence. Kill switch (incident only):
`PLAN_W_TEAM_DISABLE_CREDWALL_GUARD=1` disables the detector hook; the gate has no
bypass.

## Pattern Catalog

Authoritative list. Order in the source file is display-only; dedup is by `(file:line:name)`.

The table below is **auto-generated** from `.claude/scripts/secret-scan.sh` by `.claude/scripts/secret-doc-sync.sh`. Do not hand-edit between the markers — edit the `PATTERNS=()` array in the scanner and re-run the sync (the pre-commit hook also runs `secret-doc-sync.sh --check` whenever the scanner is staged, so drift is caught at commit time).

<!-- BEGIN AUTO-GENERATED: secret-patterns -->

| Name                 | Pattern (shape)                                                                                                         | Remediation                                                                                                          |
| -------------------- | ----------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------- |
| `aws`                | `AKIA[A-Z0-9]{16}`                                                                                                      | Revoke at AWS IAM console; rotate access keys                                                                        |
| `github-token`       | `gh[pousr]_[a-zA-Z0-9_]{36,}`                                                                                           | Revoke at github.com/settings/tokens                                                                                 |
| `anthropic`          | `sk-ant-[a-zA-Z0-9_-]{20,}`                                                                                             | Revoke at console.anthropic.com/settings/keys                                                                        |
| `openai-proj`        | `sk-proj-[A-Za-z0-9_-]{20,}`                                                                                            | Revoke at platform.openai.com/api-keys                                                                               |
| `openai`             | `sk-[A-Za-z0-9]{48,}`                                                                                                   | Revoke at platform.openai.com/api-keys                                                                               |
| `stripe-live-secret` | `sk_live_[a-zA-Z0-9]{20,}`                                                                                              | Roll at dashboard.stripe.com/apikeys                                                                                 |
| `stripe-test-secret` | `sk_test_[a-zA-Z0-9]{20,}`                                                                                              | Roll at dashboard.stripe.com/test/apikeys                                                                            |
| `stripe-live-pub`    | `pk_live_[a-zA-Z0-9]{20,}`                                                                                              | Stripe publishable key — confirm intent before committing                                                          |
| `slack`              | `xox[baprs]-[A-Za-z0-9-]{10,}`                                                                                          | Revoke at api.slack.com/apps                                                                                         |
| `discord-webhook`    | `[Dd][Ii][Ss][Cc][Oo][Rr][Dd]([Aa][Pp][Pp])?\.[Cc][Oo][Mm]/api/(v[0-9]{1,2}/)?webhooks/[0-9]{16,21}/[A-Za-z0-9_-]{55,}` | Delete at Server Settings → Integrations → Webhooks                                                              |
| `gitlab-pat`         | `glpat-[A-Za-z0-9_-]{20,}`                                                                                              | Revoke at gitlab.com/-/profile/personal_access_tokens                                                                |
| `azure-conn`         | `DefaultEndpointsProtocol=https;AccountName=`                                                                           | Rotate Azure storage account keys                                                                                    |
| `azure-accountkey`   | `AccountKey=[A-Za-z0-9+/=]{40,}`                                                                                        | Rotate Azure storage account keys                                                                                    |
| `paddle-live`        | `pdl_live_apikey_[a-zA-Z0-9]{20,}`                                                                                      | Revoke at vendors.paddle.com/authentication-v2                                                                       |
| `paddle-sandbox`     | `pdl_sdbx_apikey_[a-zA-Z0-9]{20,}`                                                                                      | Revoke at sandbox-vendors.paddle.com/authentication-v2                                                               |
| `resend`             | `re_[A-Za-z0-9]{20,}`                                                                                                   | Revoke at resend.com/api-keys                                                                                        |
| `smtp2go`            | `api-[a-f0-9]{32}`                                                                                                      | Revoke at app.smtp2go.com/settings/                                                                                  |
| `cloudflare-token`   | `cfut_[A-Za-z0-9]{20,}`                                                                                                 | Roll at dash.cloudflare.com/profile/api-tokens (committed 2026-05-25 in cleanscale #465 — scanner had no CF pattern) |
| `jwt`                | `eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}`                                                      | JWT in code — if live session/signing token, rotate issuer secret                                                  |
| `private-key`        | `-----BEGIN [A-Z ]*PRIVATE KEY-----`                                                                                    | Rotate private key; revoke if used in production                                                                     |

<!-- END AUTO-GENERATED: secret-patterns -->

Patterns are intentionally **shape-based, not entropy-based**. The scanner cannot distinguish a revoked key from a live one — and that is correct. Fail closed on shape is the defense posture. A revoked key checked into public source is still a security failure (it teaches attackers what shapes you use and indicates sloppy hygiene).

## Placeholder Heuristic

A line matching a pattern is suppressed as a placeholder if it also contains any of these markers:

```
YOUR_      TODO_      REPLACE_     FIXME_      CHANGE_
SET_       PLACEHOLDER  GENERATE_  NEED_       STORED_IN_
RETRIEVE_  OPTIONAL_  EXAMPLE_    SAMPLE_     REDACTED
xxxxxxxx   XXXXXXXX   <your-      <YOUR_
```

Rules (**token-adjacency semantics — B3, 1.33.0**; implemented by
`is_placeholder_token()` in `secret-scan.sh`):

1. **The marker must be adjacent to, or contained within, the MATCHED TOKEN** — not
   merely present somewhere on the line. "Contained" means the token itself embeds the
   marker (e.g. a provider prefix followed directly by `EXAMPLE_` and filler).
   "Adjacent" means the marker's nearest occurrence is separated from the token by at
   most `SECRET_SCAN_PLACEHOLDER_GAP` (default **3**) separator characters, so
   `KEY="YOUR_<token>"` still suppresses.
2. **Case-sensitive substring match** — markers are matched literally, and the marker
   and the token must coexist on the same line.
3. **Prefix markers are anchored by intent, not by regex** — the scanner looks for
   `YOUR_` near the token, not `^YOUR_`. This catches both `SECRET=YOUR_KEY_HERE` and
   `# key goes here: YOUR_KEY_HERE`.
4. **A distant marker does NOT suppress.** A real secret on a line whose only marker
   sits in a trailing comment (`API_KEY=<live-token>  # not the EXAMPLE_ one`) IS
   reported. This is the B3 fix: the pre-1.33.0 whole-line heuristic suppressed that
   entire line in **both** enforcing gates — the silent-drop failure the adversarial
   audit recorded as gap B3.
5. **Marker overlap with the token is treated as a placeholder** — a marker prepended
   directly onto a live token still suppresses it (rule 1's "contained" arm). This is a
   known, accepted false negative: the attacker path requires prepending a placeholder
   marker to your own live credential, which is a self-own.
6. **Comments do not suppress matches.** A live payment-provider secret key inside a Python comment is still a leak because git diff sees it regardless of syntax. If you must keep a revoked key as a test fixture, use the allow-file override (see `05-ship.md §6a-ter`), not a comment.

> **Writing about secrets in this repo**: because the B1 write-time scan (below) and
> the ship-gate `--diff` scan both read CONTENT, prose that spells out a literal
> credential shape is itself blocked at write time. Describe shapes structurally, or
> assemble them at runtime via concatenation in test fixtures — never paste a literal
> that matches a catalog pattern. (Verified the hard way during the 2026-08-14
> re-audit: an illustrative literal in this very section tripped the block.)

## How to Add a New Pattern

When a new service issues credentials that could leak (new SaaS provider, new internal credential scheme), add a pattern. Budget ~15 minutes.

### 1. Verify the shape is distinguishable

A good pattern has:

- A literal prefix (`sk_live_`, `AKIA`, `pdl_live_apikey_`) — not just a length-based regex
- A minimum token length that exceeds casual strings (typically `{20,}` or more)
- A character class narrow enough to avoid matching prose (prefer `[A-Za-z0-9_-]` over `.`)

If the provider's credentials have no distinguishing prefix (raw hex, raw base64), the pattern will false-positive on legitimate content. Do NOT add it. Escalate to content-level scanning (e.g., provider-specific webhook signature verification) instead.

### 2. Write the pattern entry

Edit `.claude/scripts/secret-scan.sh`, locate the `PATTERNS=(` array (currently ~line 57), and add one line:

```bash
'<name>|<regex>|<remediation>'
```

- `<name>` — lowercase, hyphen-separated, unique (`paddle-live`, `smtp2go`, `resend`)
- `<regex>` — ERE syntax (the scanner uses `grep -nE`). Anchors optional; the scanner scans per-line.
- `<remediation>` — one-sentence revoke-URL-or-action hint. Must be under 80 chars.

### 3. Write a smoke test

In a scratch directory:

```bash
mkdir /tmp/secret-test && cd /tmp/secret-test

# Positive: the pattern matches a shape-valid sample
printf 'KEY=<sample-matching-your-regex>\n' > leak.env
.claude/scripts/secret-scan.sh --paths leak.env  # expect exit 1

# Placeholder: YOUR_ prefix suppresses the match
printf 'KEY=YOUR_<sample>\n' > template.env
.claude/scripts/secret-scan.sh --paths template.env  # expect exit 0

# Negative: prose that mentions the service must NOT trigger
printf 'We integrate with <service>\n' > docs.md
.claude/scripts/secret-scan.sh --paths docs.md  # expect exit 0
```

All three must pass. If the positive test fails, your regex is wrong. If the placeholder test fails, the line doesn't contain a marker — add one or re-read the heuristic. If the negative test fails, your regex is too broad — tighten the prefix or character class.

### 4. Update this document

Add a row to the Pattern Catalog table above. Keep the table sorted by the service's market-share rough-cut grouping (AWS/GitHub/OpenAI/Anthropic first, then payments, then mail, then generic). Do NOT rely on alphabetical order — the catalog is a reference for humans skimming for the provider they care about.

### 5. Commit atomically

One pattern per commit. Commit message format:

```
feat(secret-scan): add <service> credential pattern

Detects: <regex-prefix>
Rationale: <why now — incident? new service adoption?>
```

A multi-pattern commit hides the rationale and makes bisecting false-positive reports painful.

## History Rewrite (when Layer 2 catches a pre-existing secret)

If `--diff origin/<base>..HEAD` exits 1, a commit on this branch introduced a secret that `--staged` cannot remove. Un-staging will not help. You must rewrite history.

### Single-file, single-commit case

```bash
# snippet-lint: skip — illustrative placeholder syntax, not executable as-is
# Find the offending commit
git log -p --all -S '<literal-token-prefix>' -- <file>

# Interactive rebase back to parent of that commit
git rebase -i <offending-commit>^
# Mark the commit 'edit'; amend without the secret; continue.
```

### Multiple commits or multiple files

Use `git filter-repo` (the modern replacement for filter-branch):

```bash
# Replace every occurrence of a literal token across all history
echo '<literal-token>' > /tmp/strip.txt
git filter-repo --replace-text /tmp/strip.txt
rm /tmp/strip.txt
```

`git filter-repo` is destructive to all refs. After running:

1. Rotate the credential upstream (you cannot undo a leak; rotation is the only mitigation).
2. Force-push (`git push --force-with-lease`) — this requires the repo to allow force-push on the target branch.
3. Notify any collaborators to re-clone. Their existing clones still contain the secret in reflog.
4. File an incident report if this was pushed to a shared/public remote at any point.

### When history cannot be rewritten

If the offending commit is already pushed to a protected branch (production, main with branch protection), rotation is your only option:

1. Rotate the credential upstream immediately.
2. Open an incident ticket documenting the exposure window (first push → rotation timestamp).
3. Audit logs for the affected service for the exposure window.
4. Add an entry to the allow-file to document that this specific shape-shaped string is known-revoked. Include the incident ticket URL.

## Known limitations

Document these here rather than hiding them behind "TODO" comments in the scanner.

- **Entropy-only secrets are out of scope**. If the provider's credential has no distinguishing prefix (raw 32-char base64), the scanner cannot catch it without producing unacceptable false-positive rates. Accept this limitation or use a service-specific detector.
- **The placeholder heuristic is lexical, not semantic.** It is now scoped to the
  matched token (§Placeholder Heuristic rule 1), so a distant marker no longer
  suppresses a real secret. The residual false negative is rule 5's overlap arm: a
  marker prepended directly onto a live token still suppresses it.
- **Binary files are skipped.** The scanner skips files that fail `grep -Iq ''` (binary sniff) or exceed `--max-filesize` (default 1 MB). A secret hidden inside a JPEG EXIF field is not caught.
- **Scanner invocation is the responsibility of the integration point.** `pre-commit-quality.sh` invokes the scanner; if the hook is disabled or skipped, Layer 1 is disabled. The ship gate (Layer 2) is the safety net — do not assume a hook bypass is innocent.

## Secret-Handling Documentation Duty (C1/C2, 1.33.0)

The three scanner layers above prevent a secret VALUE from leaking. They do nothing
about the **operational documentation** a new secret-bearing variable needs — how it
is provisioned, rotated, and kept out of git. Audit gap C1: a feature could introduce
a brand-new `FOO_API_TOKEN`, wire it correctly, pass every scan, and ship with **no
`.env.example` row and no provisioning/rotation note**, leaving the next operator to
reverse-engineer it. C2 is the infra-config sibling: an infra-glob change (the
`governance-tags.md` infra catalog — `wrangler.toml`, `*.tf`, `k8s/**`, …) ships
without a runbook/config-reference update.

### When the duty fires

The duty fires when the **§1c credential signal** trips during specification — i.e.
the feature introduces a NEW secret-bearing env var (a var whose name matches the
secret-bearing heuristic: `*_TOKEN`, `*_KEY`, `*_SECRET`, `*_PASSWORD`,
`*_API_KEY`, `*_CREDENTIAL*`, or a provider-prefixed var like `STRIPE_*`,
`CLOUDFLARE_*`, `AWS_*`). It is the documentation analog of the §6a-ter scan: the
scan stops the value leaking; this duty stops the **knowledge** gap.

### The required deliverable (C1)

When the signal fires, the run MUST ship an operational secret-handling deliverable:

1. **`.env.example` row** — the variable NAME with a placeholder value (a placeholder
   that the §Placeholder Heuristic suppresses, e.g. `FOO_API_TOKEN=YOUR_FOO_TOKEN`),
   so the next operator knows the var exists and what shape it takes.
2. **Provisioning + rotation + never-commit note** — in the repo's runbook
   (`docs/operations/DEPLOY_RUNBOOK.md` when present) or a config reference: where the
   token is obtained, how it is rotated, and that it is never committed (it lives in
   the headless `0600` `deploy.env` per `no-github-actions.md §"Deploy Secret Access"`).

`docs/specs/` does **not** satisfy this — the deliverable is operational
documentation an on-call operator reaches for, not the feature spec.

### The required deliverable (C2)

When the diff touches an infra-glob surface from `governance-tags.md` (Infra config
or Secrets / env wiring rows), the run MUST update a runbook or config reference that
describes the changed surface. This rides the net-new-surface mechanism
(`plan-w-team-netnew-surface.sh` requires a `docs/operations/*` page for new
hooks/scripts; the infra-runbook requirement is its config-surface analog).

### Enforcement

`06-post-ship.md §7f` lists both duties as refusal conditions: Step 7 must not be
marked complete when the §1c credential signal fired but no secret-handling
deliverable is present (C1), or when an infra-glob surface changed without a
runbook/config-reference touch (C2). The signal is recorded in the spec at §1c and
re-checked at post-ship; the duty is auditable in the post-ship artifact
(`secret_handling_doc`, `netnew_surface.infra_runbook`).

> **Enforcement status (verified 2026-08-14, row-12 re-audit) — read this before
> relying on C1/C2 as a gate.** §7f's deterministic check implements the **A1/A6 arm
> only** (`netnew_surface.undocumented`). The **C1 and C2 arms are prose**: bullets
> instructing the lead not to complete Step 7, with no code that refuses. They cannot
> be gated as currently modelled, because `"n/a"` in both artifact fields is ambiguous
> — it means *both* "no credential/infra signal fired, correctly not applicable" *and*
> "signal fired but the deliverable is missing". Making them enforcing requires
> deterministic signal fields (both are derivable from the diff: a new secret-bearing
> env var by name shape, an infra-glob touch by changed path) plus a new enforcing
> gate — a change with fleet-wide blast radius, so it is queued as its own scoped run
> rather than folded into an audit. Until then, treat C1/C2 as a documented duty the
> lead is responsible for, not a backstop that will catch you.

Full operator-facing writeup: [`docs/operations/pwt-doc-secret-handling.md §"Secret-handling documentation duty (C1/C2)"`](../../../docs/operations/pwt-doc-secret-handling.md).

## References

- `.claude/scripts/secret-scan.sh` — scanner implementation and pattern catalog source
- `.claude/hooks/damage-control/damage-control.sh` — Layer 0 wiring (`check_secret_content`)
- `.claude/hooks/pre-commit-quality.sh` — Layer 1 wiring
- `.claude/commands/plan-w-team/05-ship.md §6a-ter` — Layer 2 gate + allow-file format
- `.claude/scripts/sync-to-project.sh` `SECRET_GUARD_FILTERS` — Layer 3 rsync filters
- `docs/specs/secret-leak-prevention.md` — feature spec with acceptance criteria
