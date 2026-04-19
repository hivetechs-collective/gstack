# Secret Safety — Defense-in-Depth Model for /plan-w-team

Shared reference for the three secret-leak prevention layers and the authoritative pattern catalog. Loaded by `05-ship.md` at the 6a-ter gate and by `pre-commit-quality.sh` indirectly (through the shared scanner).

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
              ▲                       ▲                       ▲
              │ --staged              │ --diff                │ --paths
              │                       │                       │
    ┌─────────┴─────────┐   ┌─────────┴──────────┐  ┌─────────┴──────────┐
    │  Layer 1          │   │  Layer 2           │  │  Layer 3           │
    │  PRE-COMMIT       │   │  SHIP GATE         │  │  SYNC FILTER       │
    │  pre-commit-      │   │  05-ship.md        │  │  sync-to-          │
    │  quality.sh       │   │  §6a-ter           │  │  project.sh        │
    │                   │   │                    │  │  SECRET_GUARD_     │
    │  Blocks commit    │   │  Blocks ship + PR  │  │  FILTERS (rsync    │
    │  with exit 2      │   │  with exit 1       │  │  filename-only     │
    │                   │   │                    │  │  include/exclude)  │
    │  Runs:            │   │  Runs:             │  │                    │
    │  • --staged       │   │  • --staged        │  │  Runs at sync      │
    │                   │   │  • --diff          │  │  time — prevents   │
    │                   │   │    origin/<base>.. │  │  template-         │
    │                   │   │    HEAD            │  │  distribution from │
    │                   │   │                    │  │  leaking secrets   │
    │                   │   │                    │  │  across projects.  │
    └───────────────────┘   └────────────────────┘  └────────────────────┘
```

### Why three layers

Each layer catches leaks the others cannot:

- **Pre-commit** catches secrets before they touch git object storage. Cheap, local, per-developer.
- **Ship gate** catches secrets that slipped through pre-commit (hook disabled, repo cloned without hooks, amend bypass) by scanning both staged content AND the full branch diff. This is where history-rewrite decisions happen.
- **Sync filter** is rsync-level filtering for the claude-pattern distribution itself. It prevents one project's `.env.local` from being copied into another project during a sync — a structurally different failure mode that pattern-matching cannot solve, because the receiving repo has no commit history to scan yet.

Defense in depth means no layer is load-bearing alone. The sync filter exists even though scanners exist; the scanner exists even though filters exist.

## Pattern Catalog

Authoritative list. Order in the source file is display-only; dedup is by `(file:line:name)`.

The table below is **auto-generated** from `.claude/scripts/secret-scan.sh` by `.claude/scripts/secret-doc-sync.sh`. Do not hand-edit between the markers — edit the `PATTERNS=()` array in the scanner and re-run the sync (the pre-commit hook also runs `secret-doc-sync.sh --check` whenever the scanner is staged, so drift is caught at commit time).

<!-- BEGIN AUTO-GENERATED: secret-patterns -->

| Name                 | Pattern (shape)                                                    | Remediation                                                       |
| -------------------- | ------------------------------------------------------------------ | ----------------------------------------------------------------- |
| `aws`                | `AKIA[A-Z0-9]{16}`                                                 | Revoke at AWS IAM console; rotate access keys                     |
| `github-token`       | `gh[pousr]_[a-zA-Z0-9_]{36,}`                                      | Revoke at github.com/settings/tokens                              |
| `anthropic`          | `sk-ant-[a-zA-Z0-9_-]{20,}`                                        | Revoke at console.anthropic.com/settings/keys                     |
| `openai-proj`        | `sk-proj-[A-Za-z0-9_-]{20,}`                                       | Revoke at platform.openai.com/api-keys                            |
| `openai`             | `sk-[A-Za-z0-9]{48,}`                                              | Revoke at platform.openai.com/api-keys                            |
| `stripe-live-secret` | `sk_live_[a-zA-Z0-9]{20,}`                                         | Roll at dashboard.stripe.com/apikeys                              |
| `stripe-test-secret` | `sk_test_[a-zA-Z0-9]{20,}`                                         | Roll at dashboard.stripe.com/test/apikeys                         |
| `stripe-live-pub`    | `pk_live_[a-zA-Z0-9]{20,}`                                         | Stripe publishable key — confirm intent before committing       |
| `slack`              | `xox[baprs]-[A-Za-z0-9-]{10,}`                                     | Revoke at api.slack.com/apps                                      |
| `gitlab-pat`         | `glpat-[A-Za-z0-9_-]{20,}`                                         | Revoke at gitlab.com/-/profile/personal_access_tokens             |
| `azure-conn`         | `DefaultEndpointsProtocol=https;AccountName=`                      | Rotate Azure storage account keys                                 |
| `azure-accountkey`   | `AccountKey=[A-Za-z0-9+/=]{40,}`                                   | Rotate Azure storage account keys                                 |
| `paddle-live`        | `pdl_live_apikey_[a-zA-Z0-9]{20,}`                                 | Revoke at vendors.paddle.com/authentication-v2                    |
| `paddle-sandbox`     | `pdl_sdbx_apikey_[a-zA-Z0-9]{20,}`                                 | Revoke at sandbox-vendors.paddle.com/authentication-v2            |
| `resend`             | `re_[A-Za-z0-9]{20,}`                                              | Revoke at resend.com/api-keys                                     |
| `smtp2go`            | `api-[a-f0-9]{32}`                                                 | Revoke at app.smtp2go.com/settings/                               |
| `jwt`                | `eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}` | JWT in code — if live session/signing token, rotate issuer secret |
| `private-key`        | `-----BEGIN [A-Z ]*PRIVATE KEY-----`                               | Rotate private key; revoke if used in production                  |

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

Rules:

1. **Case-sensitive substring match on the full line** — the marker and the pattern shape must coexist on the same line.
2. **Prefix markers are anchored by intent, not by regex** — the scanner looks for `YOUR_` anywhere on the line, not `^YOUR_`. This catches both `SECRET=YOUR_KEY_HERE` and `# key goes here: YOUR_KEY_HERE`.
3. **The marker must NOT overlap with the match**. Current implementation checks the line, not the tokens specifically, which means `YOUR_sk_live_...` would be suppressed. This is a known low-risk false negative — the attacker path requires prepending a marker to their own credential, which is an absurd self-own.
4. **Comments do not suppress matches.** A live `sk_live_...` inside a Python comment is still a leak because git diff sees it regardless of syntax. If you must keep a revoked key as a test fixture, use the allow-file override (see `05-ship.md §6a-ter`), not a comment.

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
- **The placeholder heuristic is lexical, not semantic.** A line like `secret = retrieve_from_vault()` is correctly suppressed (contains `RETRIEVE_`) but so is the typo `RETRIEVE_sk_live_...`. This is the known false negative from §Placeholder Heuristic rule 3.
- **Binary files are skipped.** The scanner skips files that fail `grep -Iq ''` (binary sniff) or exceed `--max-filesize` (default 1 MB). A secret hidden inside a JPEG EXIF field is not caught.
- **Scanner invocation is the responsibility of the integration point.** `pre-commit-quality.sh` invokes the scanner; if the hook is disabled or skipped, Layer 1 is disabled. The ship gate (Layer 2) is the safety net — do not assume a hook bypass is innocent.

## References

- `.claude/scripts/secret-scan.sh` — scanner implementation and pattern catalog source
- `.claude/hooks/pre-commit-quality.sh` — Layer 1 wiring
- `.claude/commands/plan-w-team/05-ship.md §6a-ter` — Layer 2 gate + allow-file format
- `.claude/scripts/sync-to-project.sh` `SECRET_GUARD_FILTERS` — Layer 3 rsync filters
- `docs/specs/secret-leak-prevention.md` — feature spec with acceptance criteria
