# OWASP Top 10 Coverage Map

Deterministic file-pattern **and diff-content** → OWASP category → agent → tier-set lookup for `/plan-w-team`. Closed catalog modeled on `shared/governance-tags.md` (deterministic, narrow by design). Two trigger layers: a **file-glob** layer (the Coverage Map below) and a **content-signal** layer (the [§Content-Signal Triggers](#content-signal-triggers-diff-content-not-filename) table) that fires on what the diff _does_ — added because the most damaging bug class, Broken Access Control (OWASP #1), hides in normally-named route files (`qa-sim.ts`, `jobs.ts`) that match no security glob. See `shared/access-control-invariants.md` for the per-endpoint review rubric the content signals feed, and `shared/secure-by-default.md` for the write-side defaults.

**Source lists:** [OWASP Top 10 (2021)](https://owasp.org/Top10/) (web) · [OWASP API Security Top 10 (2023)](https://owasp.org/API-Security/editions/2023/en/0x11-t10/) (API — API1 BOLA, API3 BOPLA/mass-assignment, API5 BFLA).

**Why a closed list:** `/plan-w-team`'s Step 2 (paired-task scoping) and Step 5 (retroactive security-gap analysis) both need a deterministic answer to "which OWASP categories apply to this file" and "which security tiers must cover it." A free-form LLM judgment would re-introduce the failure mode the map is meant to fix (every PR's security scope drifts). A closed list of file-path globs gives every supervisor invocation the same answer.

**Consumed by:**

- `/plan-w-team/02-task-breakdown.md` — Step 2 forward-scoping of paired `N.s` security-review tasks (file globs **and** content signals trigger the paired-task emission)
- `/plan-w-team/04-fix-first-review.md` §5b (Access-Control Content-Signal Scan) + §5d-bis — content signals force a Pass-1 CRITICAL scan; the `security-gap-analyzer` reads this for category attribution
- `/plan-w-team/05-ship.md` §6c-bis (Security Tier Gate) + §6c-ter (Access-Control Finding Gate) — tier union across categories + fail-closed block on a confirmed access-control finding
- `/plan-w-team/01-specification.md` §1c — the spec-time threat-model trigger keys on the same content signals
- `.claude/agents/research-planning/security-gap-analyzer.md` — emits `owasp_category:` / `api_security_category:` fields on each finding referencing this catalog
- `.claude/agents/research-planning/security-expert.md` — the A01 reviewer; consumes the content-signal list + `shared/access-control-invariants.md`

---

## Coverage Map

| OWASP Category                                      | File-pattern globs                                                                                                                                        | Default agent     | Tier set required                   |
| --------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------- | ----------------------------------- |
| **A01: Broken Access Control**                      | `**/auth/**`, `**/rbac/**`, `**/permission*`, `**/middleware/auth*`, `**/policies/**`, `**/acl*`                                                          | `security-expert` | T1 + T2 + T4                        |
| **A02: Cryptographic Failures**                     | `**/crypto*`, `**/hash*`, `**/encrypt*`, `**/cipher*`, `**/sign*`, `**/jwt*`, `**/tls*`, `**/kms*`                                                        | `security-expert` | T1 + T2 + T4                        |
| **A03: Injection**                                  | `**/sql*`, `**/query*`, `**/sanitize*`, `**/validate*`, `**/render*`, `**/template*`, `**/exec*`, `**/shell*`, `**/eval*`                                 | `security-expert` | T1 + T2 + T4 (+ TO2 if parser)      |
| **A04: Insecure Design**                            | (no glob — flagged by reviewer judgment when design lacks threat model)                                                                                   | `security-expert` | T2 (review-only)                    |
| **A05: Security Misconfiguration**                  | `**/config*`, `**/.env*`, `**/wrangler.toml`, `**/*.tf`, `**/*.tfvars`, `**/k8s/**`, `**/kubernetes/**`, `**/docker*`, `**/Dockerfile*`                   | `security-expert` | T1 + T3 + T4                        |
| **A06: Vulnerable and Outdated Components**         | `package.json`, `package-lock.json`, `pnpm-lock.yaml`, `Cargo.toml`, `Cargo.lock`, `requirements.txt`, `Pipfile.lock`, `go.mod`, `go.sum`, `Gemfile.lock` | `security-expert` | T3 (always)                         |
| **A07: Identification and Authentication Failures** | `**/login*`, `**/session*`, `**/jwt*`, `**/oauth*`, `**/mfa*`, `**/password*`, `**/signin*`, `**/signup*`, `**/credential*`                               | `security-expert` | T1 + T2 + T4                        |
| **A08: Software and Data Integrity Failures**       | `**/deserialize*`, `**/parse*`, `**/marshal*`, `**/sign*`, `**/verify*`, `**/checksum*`, `**/sbom*`, `**/release-pipeline*`                               | `security-expert` | T1 + T2 + T4                        |
| **A09: Security Logging and Monitoring Failures**   | `**/log*`, `**/audit*`, `**/telemetry*`, `**/observability/**`, `**/metric*`, `**/trace*`                                                                 | `security-expert` | T1 (review-only)                    |
| **A10: Server-Side Request Forgery (SSRF)**         | `**/fetch*`, `**/request*`, `**/proxy*`, `**/url*`, `**/http*`, `**/webhook*`, `**/redirect*`                                                             | `security-expert` | T1 + T2 + T4 (+ TO1 if user-facing) |

The list is matched via standard glob semantics (`**/` recurses, `*` matches any path segment, `?` matches a single char). Path comparison is case-sensitive on Linux/macOS (filesystem behavior aside).

---

## API Security Top 10 (2023) — Access-Control Categories

The web Top 10 (2021) above maps by file glob. The API Security Top 10 (2023) covers the access-control classes that dominate modern API breaches and that **no filename glob reliably catches** — they live in ordinarily-named route/handler files. These are attributed by the content signals below, not by path.

| API category  | Name                                                                 | Maps to web | Caught by content signal                                                                            |
| ------------- | -------------------------------------------------------------------- | ----------- | --------------------------------------------------------------------------------------------------- |
| **API1:2023** | Broken Object Level Authorization (BOLA / IDOR)                      | A01         | where/query-by-id without a tenant/owner predicate (CS-4)                                           |
| **API3:2023** | Broken Object Property Level Authorization (BOPLA / mass-assignment) | A01         | privilege-bearing field write (CS-1); request-body spread into ORM update/insert (CS-2)             |
| **API5:2023** | Broken Function Level Authorization (BFLA)                           | A01         | privileged operation with no per-operation role check; bypass/QA/service-token-gated handler (CS-3) |

All three roll up to **A01: Broken Access Control** for tier purposes (T1 + T2 + T4) and route to `security-expert`. The per-endpoint review rubric is `shared/access-control-invariants.md` (INV-1…INV-5).

---

## Content-Signal Triggers (diff-content, not filename)

Any of these signals in the diff forces A01 / API-security attribution → a mandatory paired `N.s` security-review task (Step 2), a Pass-1 CRITICAL Access-Control Content-Signal Scan (Step 5 §5b), and the A01 required tier set — **regardless of the filename**. This is the layer that catches the bug class the globs miss.

| #    | Signal                                                 | Match heuristic (illustrative tokens)                                                                                                          | Category   | Invariant |
| ---- | ------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------- | ---------- | --------- |
| CS-1 | **Privilege-bearing field write**                      | assignment to `role`, `platformRole`, `tenantId`/`orgId`, `isQaUser`, `ownerId`, `isAdmin`, `permissions`, `passwordHash`, `balance`, `*Cents` — in either convention (`is_admin`, `password_hash`) and either syntax (`user.isAdmin =`, `user["isAdmin"] =`) | A01 / API3 | INV-3     |
| CS-2 | **Request-body spread into ORM update/insert**         | `.set({ ...body })`, `.values({ ...input })`, `...req.body`, `Object.assign(row, input)`                                                       | A01 / API3 | INV-3     |
| CS-3 | **Service / bypass / QA / admin-token-gated handler**  | `QA_SIM_TOKEN`, `*_BYPASS_*`, a service-token / `SERVICE_TOKEN` / `x-*-bypass` header check gating a mutation                                  | A01 / API5 | INV-4     |
| CS-4 | **Where/query-by-id lacking a tenant/owner predicate** | `where(eq(table.id, …))` (Drizzle) / `where: { id }` (Prisma, TypeORM) / `findById`, `getById` / `WHERE id = $1` in either case — with no sibling tenant/owner predicate | A01 / API1 | INV-1     |

The token lists are illustrative heuristics for a reviewer / `security-gap-analyzer`, not an exhaustive regex — a privilege-bearing field, a body-spread, a bypass token, or an unscoped by-id query counts even when written differently. The **canonical** signal definitions and per-signal failing/required code shapes live in `shared/access-control-invariants.md`; this table is the trigger index. The same four signals (CS-1…CS-4) appear verbatim in `02-task-breakdown.md` (N.s emission), `04-fix-first-review.md` §5b (the scan), and `01-specification.md` §1c (the spec trigger), so forward-scoping, review, and spec-time declaration all agree on what counts.

---

## Union Rule for Multi-Category Files

When a file matches multiple categories (e.g., `src/auth/login.ts` matches A01 + A07), the required tier set is the **union** of all matched tier sets. Example:

- `src/auth/login.ts` → A01 (T1+T2+T4) ∪ A07 (T1+T2+T4) = **T1 + T2 + T4**
- `src/api/proxy-fetch.ts` → A10 (T1+T2+T4+TO1-if-user-facing) ∪ A03 (T1+T2+T4+TO2-if-parser) = **T1 + T2 + T4 + TO1 + TO2** (worst case)

A path matching ONLY A06 (manifest) inherits **just T3** because dep-audit is the only relevant defense for a manifest change.

---

## How Step 2 Uses This (forward scoping)

For each task's `files_touched`, the lead matches each path against the globs in this catalog. If any path matches any category, the task receives a paired `N.s` security-review task in addition to `N.a` (test) and `N.b` (implementation) — per `02-task-breakdown.md` §Paired Task Protocol (security review). **The content-signal layer is a second, filename-independent trigger**: if the task's diff matches any of CS-1…CS-4 above, `N.s` is emitted even when no path matches a glob.

```bash
# Pseudocode (Step 2):
TRIGGER_NS=0
for path in "${FILES_TOUCHED[@]}"; do
  for glob in "${OWASP_GLOBS[@]}"; do
    case "$path" in
      $glob) TRIGGER_NS=1; break 2 ;;
    esac
  done
done
# Content-signal layer: the filename matched nothing, but the DIFF still does
# something access-control-sensitive (CS-1..CS-4) — force N.s regardless of name.
if [ "$TRIGGER_NS" = 0 ] && diff_matches_content_signal "$TASK_DIFF"; then
  TRIGGER_NS=1
fi
if [ "$TRIGGER_NS" = 1 ]; then
  emit_paired_task_ns "$TASK_ID"
fi
```

---

## How Step 5 Uses This (retroactive analysis)

The `security-gap-analyzer` agent consults this map to attribute each finding to an OWASP category. The category determines the required tier set, which Step 5 cross-checks against the Evidence Ledger from `shared/security-tiers.md`. Missing tier coverage on a touched category becomes a high-severity gap.

**Content signals override the skip.** The §Content-Signal Triggers also force the analyzer to run even when NO file matches a glob (overriding the `no-security-surfaces` skip in `04-fix-first-review.md` §5d-bis), AND raise a Pass-1 CRITICAL via the §5b Access-Control Content-Signal Scan. A confirmed high-severity access-control finding on a content-signal surface is **gating** (blocks ship via §6c-ter), not a deferred retroactive `N.t` task — that retroactive lane is reserved for test-coverage gaps in untouched sibling code.

```bash
# Pseudocode (Step 5 §5d-bis):
for finding in "${ANALYZER_FINDINGS[@]}"; do
  CATEGORY=$(get_owasp_category "$finding")
  REQUIRED_TIERS=$(lookup_tier_set "$CATEGORY")
  COVERED_TIERS=$(read_ledger_active_rows)
  MISSING=$(diff_sets "$REQUIRED_TIERS" "$COVERED_TIERS")
  if [ -n "$MISSING" ]; then
    queue_nt_task "$finding" "$MISSING"
  fi
done
```

---

## How Step 6 Uses This (ship gate)

Step 6 §6c-bis Security Tier Gate computes the **union of required tiers** across all touched files matching any OWASP category. The result is compared against the active profile from `.claude/state/security-policy.txt`. If the union exceeds the active profile, the ship gate proposes an upgrade or refuses to ship until the policy is acknowledged.

Step 6 §6c-ter Access-Control Finding Gate is the executable counterpart: it reads the Step-5 review-findings artifact and `exit 1`s if a confirmed high-severity access-control finding (from the content-signal scan) is unresolved. Unlike §6c-bis (which asserts ledger presence against a policy), §6c-ter fails closed on a real finding — a deferral does not satisfy it.

---

## What This Map Is NOT

- **Not a permission system.** Anyone with merge access can still ship a PR labeled with missing tiers. The map is a signal to the supervisor and to humans, not an ACL.
- **Not a security control.** A bad actor with merge rights can bypass it. The map exists to keep good-faith automation from auto-merging into a security foot-gun.
- **Not a substitute for security review.** Categories with `T2 (review-only)` (A04, A09) explicitly require human/agent judgment on design and observability — no glob can detect insecure design.

---

## Adding a Category Pattern

To extend the catalog (e.g., new file-pattern conventions for a specific framework):

1. Add a row or extend an existing row's glob list in the table above.
2. Update `02-task-breakdown.md` Paired Task Protocol (security review) trigger list if the new pattern introduces a new top-level surface.
3. Update `security-gap-analyzer.md` `gap_type` taxonomy if the new pattern requires a new finding type.
4. Add a test in `tests/skill/scenarios/owasp-coverage-map-lookup.bats` asserting the new pattern resolves to the right category + tier set.

Removing a row is a one-way door — any existing repo with `security-policy.txt` referencing that category will see a behavioral change at next ship. Treat removals like a `DO NOT MERGE` change.

---

## Reference Tier-Set Quick Lookup (informational)

| Tier set                      | When you'd see it                                        |
| ----------------------------- | -------------------------------------------------------- |
| T1 + T2 + T4                  | Auth / crypto / injection — the "hard core" security set |
| T1 + T3 + T4                  | Configuration / misconfig surfaces (A05)                 |
| T3 (alone)                    | Manifest-only changes (A06)                              |
| T1 + T2 + T4 + TO1            | User-facing SSRF/XSS — adds ZAP baseline                 |
| T1 + T2 + T4 + TO2            | Parser/protocol code — adds fuzz                         |
| T1 + T2 + T4 + T5 + TO1 + TO2 | High-assurance: parser+crypto in a public service        |

The union rule means the actual tier set for a feature is the strict superset of every category its files match — the table above is a navigational aid, not an alternative source of truth.
