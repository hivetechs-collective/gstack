# Access-Control Invariant Checklist

A deterministic checklist of the access-control invariants that **every data-mutating endpoint** must satisfy before `/plan-w-team` ships it. Where `shared/owasp-top10-mapping.md` answers _"which OWASP categories apply to this file"_, this file answers _"what must be true of the code on the access-control path."_

**Why this exists:** Broken Access Control is OWASP Top 10 #1 (2021/2025) and dominates the OWASP **API** Security Top 10 (2023) — API1 (BOLA), API3 (BOPLA / mass-assignment), API5 (BFLA). These bug classes hide in **normally-named route files** (`qa-sim.ts`, `jobs.ts`) that no security path-glob matches, so the filename-driven machinery in `owasp-top10-mapping.md` is structurally blind to them. This checklist is content-driven, not path-driven: it is triggered by what the diff _does_ (see the content signals in `shared/owasp-top10-mapping.md` §Content-Signal Triggers), and every item is a **MUST answer**, not an optional prompt.

**Source anchors:** [OWASP API Security Top 10 (2023)](https://owasp.org/API-Security/editions/2023/en/0x11-t10/) · [OWASP Top 10 (2021) A01](https://owasp.org/Top10/A01_2021-Broken_Access_Control/) · [OWASP ASVS v5 — V4 Access Control](https://owasp.org/www-project-application-security-verification-standard/).

**Consumed by:**

- `/plan-w-team/01-specification.md` — the spec-time threat-model block must name which invariants the feature's tokens/fields put in play.
- `/plan-w-team/02-task-breakdown.md` — every paired `N.s` security-review task carries this checklist as its rubric.
- `/plan-w-team/04-fix-first-review.md` §5b (Access-Control Content-Signal Scan) + §5d-ter — `security-gap-analyzer` and `security-expert` MUST answer every invariant for each data-mutating endpoint in the diff; an unanswered or violated invariant on a bypass-token / privilege-field surface is a **gating** Pass-1 CRITICAL, not a retroactive task.
- `/plan-w-team/05-ship.md` §6c-ter — the Access-Control Finding Gate refuses to ship on a confirmed high-severity violation.
- `.claude/agents/research-planning/security-expert.md` — mandatory review step.
- `.claude/agents/research-planning/security-gap-analyzer.md` — finding taxonomy (`invariant:` field).

The write-side counterpart is `shared/secure-by-default.md` — the patterns a builder uses so these invariants hold by construction.

---

## The Five Invariants

For **every** data-mutating endpoint (any handler that performs an `INSERT` / `UPDATE` / `DELETE` / privileged read), the review MUST answer all five. "Cannot tell from the diff" is treated as **not satisfied** (deny-by-default applies to the review too).

| #     | Invariant                                           | OWASP                | The question that MUST be answered                                                                                                                                                         | Default severity if violated          |
| ----- | --------------------------------------------------- | -------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------- |
| INV-1 | **Object ownership (BOLA / IDOR)**                  | API1:2023 · A01      | Is every read/write **by id** scoped to the actor's tenant/owner — i.e. does the `where`/query carry a tenant/owner predicate derived from the **request context**, not from client input? | HIGH                                  |
| INV-2 | **Function / role authorization (BFLA)**            | API5:2023 · A01      | Is the actor's **role** checked for _this specific operation_ — not merely that the actor is authenticated?                                                                                | HIGH                                  |
| INV-3 | **Mass-assignment / privilege-field guard (BOPLA)** | API3:2023 · A01      | Is every privilege-bearing field **un-settable** from untrusted input — enforced by an explicit allow-list (`z.object({...}).strict()` + `.pick()`), never field-spread?                   | HIGH                                  |
| INV-4 | **Bypass / test-token scoping**                     | API1/API5:2023 · A01 | Can a service / QA / bypass-token endpoint **only** touch resources provably flagged test/QA (`isQaUser`, qa-tenant) — and provably **not** mutate real accounts/tenants?                  | HIGH (CRITICAL on real-account write) |
| INV-5 | **Tenant isolation under writes + JOINs**           | API1:2023 · A01      | Does RLS / `withTenantContext` actually apply on the **mutation** path (not only reads), and do JOINs refuse to leak cross-tenant rows?                                                    | HIGH                                  |

A privilege-bearing field (INV-3) is any of: `role`, `platformRole`, `tenantId` / `orgId`, `isQaUser`, `ownerId`, `isAdmin`, `permissions`, `passwordHash`, `balance`, `*Cents`, plus any field the feature's own threat model (Step 1) names. Treat the list as open: a field that grants authority, moves money, or re-parents a record to another tenant is privilege-bearing even if not enumerated here.

---

## Per-Invariant Detail — failing vs required shape

### INV-1 — Object ownership (BOLA / IDOR · API1:2023)

A record fetched or mutated **by id** must be constrained to the actor's tenant/owner. The scoping predicate must come from the authenticated context (`ctx.tenantId`, `ctx.userId`), **never** from the request body (a client can lie about its own `tenantId`).

```ts
// ✗ VIOLATION — by-id query with no tenant/owner predicate (IDOR)
const job = await db.select().from(jobs).where(eq(jobs.id, input.jobId));

// ✓ REQUIRED — id AND context-derived tenant predicate
const job = await db
  .select()
  .from(jobs)
  .where(and(eq(jobs.id, input.jobId), eq(jobs.tenantId, ctx.tenantId)));
```

Detection heuristic: a `where`/`filter` keyed on a record id (`eq(table.id, …)`, `findById`, `WHERE id = $1`) with **no** sibling tenant/owner predicate on the same query. (This is the FIN-15 `assignedTo` bug class — a cross-tenant `users.id` accepted without scoping.)

### INV-2 — Function / role authorization (BFLA · API5:2023)

Authentication ≠ authorization. A handler that performs a privileged operation must assert the actor's **role/capability** for that operation.

```ts
// ✗ VIOLATION — authenticated, but no per-operation role check
export const handler = withAuth(async (ctx, input) => {
  await deleteTenant(input.id);
});

// ✓ REQUIRED — explicit function-level authorization
export const handler = withAuth(async (ctx, input) => {
  assertRole(ctx, "platform_admin"); // BFLA guard for THIS operation
  await deleteTenant(input.id);
});
```

Detection heuristic: a mutating handler reachable without a role/capability assertion, or an admin/destructive operation guarded only by `requireAuth()`.

### INV-3 — Mass-assignment / privilege-field guard (BOPLA · API3:2023)

Privilege-bearing fields must never be settable from untrusted input. Enforce an explicit allow-list — parse with `.strict()` (reject unknown keys) and build the update with `.pick()` of the columns the operation may legitimately change.

```ts
// ✗ VIOLATION — request body spread straight into an UPDATE (mass assignment)
await db
  .update(users)
  .set({ ...body })
  .where(eq(users.id, id));
// also a violation: Object.assign(row, input); db.insert(users).values({ ...req.body });

// ✓ REQUIRED — strict allow-list; privilege fields are NOT in the picked set
const Patch = z
  .object({ displayName: z.string(), avatarUrl: z.string().url() })
  .strict();
const patch = Patch.parse(body); // unknown keys (role, platformRole, …) rejected
await db
  .update(users)
  .set(patch)
  .where(and(eq(users.id, id), eq(users.tenantId, ctx.tenantId)));
```

Detection heuristic: `.set({...x})`, `.values({...x})`, `...req.body`, `...input`, or `Object.assign(row, input)` where `x` derives from request input; or a write to a privilege-bearing field whose value traces to the request body. (This is the `seed-platform-admin` bug class — an existing-user branch overwrote `passwordHash` and escalated `platformRole`.)

### INV-4 — Bypass / test-token scoping

This is the bug that motivated this checklist. An endpoint reachable via a service / QA / bypass token (`QA_SIM_TOKEN`, `*_BYPASS_*`, internal service tokens) must be **provably unable** to touch a real account or tenant. Every mutation under such a token must first assert the target is QA-scoped.

```ts
// ✗ VIOLATION — QA-token endpoint mutates whatever email is passed (account takeover)
//   existing-user branch overwrote passwordHash + escalated platformRole, no isQaUser check.
const user = await findByEmail(body.email);
await db
  .update(users)
  .set({ passwordHash: hash(body.password), platformRole: "admin" })
  .where(eq(users.id, user.id));

// ✓ REQUIRED — assert QA scope before any mutation; refuse real accounts
const user = await findByEmail(body.email);
assertQaScoped(user); // throws 403 unless user.isQaUser === true (and qa-tenant)
await db
  .update(users)
  .set(picked)
  .where(and(eq(users.id, user.id), eq(users.isQaUser, true)));
```

The canonical safe pattern is the `provision-tenant` `is_qa_user` flag: a bypass endpoint may only read/write rows where `is_qa_user = true`, and the predicate is enforced **in the `where` clause** (not only in an `if`), so a TOCTOU race cannot widen it. Codified as `assertQaScoped()` in `shared/secure-by-default.md`.

Detection heuristic: a handler gated by a QA/service/bypass token (env var or header) that performs an `INSERT`/`UPDATE`/`DELETE` whose target is selected by client-supplied identity (email/id) with no `isQaUser` / qa-tenant predicate **in the query**. A real-account write here is **CRITICAL** (account takeover + privilege escalation).

### INV-5 — Tenant isolation under writes + JOINs

RLS / `withTenantContext` must wrap the **mutation** path, not only reads, and JOINs must not surface cross-tenant rows. A migration that adds a table without an RLS policy, or a mutation that runs outside the tenant context wrapper, violates this.

```ts
// ✗ VIOLATION — mutation runs outside the tenant context (RLS not applied to writes)
await rawDb.update(invoices).set(patch).where(eq(invoices.id, id));

// ✓ REQUIRED — mutation inside the tenant-scoped context
await withTenantContext(ctx.tenantId, (tx) =>
  tx.update(invoices).set(patch).where(eq(invoices.id, id)),
);
```

Detection heuristic: a write that bypasses the project's tenant-context wrapper; a new table/migration with no RLS policy; a JOIN across tenant-scoped tables missing a tenant predicate on the joined side.

---

## How each step uses this

- **Step 1 (spec):** if the feature hits any content signal, the threat-model block names which invariants its tokens/fields put in play (e.g. "QA_SIM_TOKEN ⇒ INV-4 in play; writes `platformRole` ⇒ INV-3").
- **Step 2 (`N.s` emission):** the paired `N.s` task carries this checklist as its review rubric. The reviewer fills one row per data-mutating endpoint.
- **Step 5 (`security-gap-analyzer` + `security-expert`):** every data-mutating endpoint in the diff gets all five invariants answered (§5b Access-Control Content-Signal Scan). Unanswered ⇒ not satisfied. A **confirmed** high-severity violation in the diff's own touched code (any of the five invariants — the archetypes being cross-tenant IDOR/INV-1, privilege-field/INV-3, bypass-token/INV-4) is a **gating Pass-1 CRITICAL** — fixed before ship, not deferred (see `04-fix-first-review.md` §5d-ter); severity, not the invariant id, is the gate. Violations in _untouched sibling_ code, and medium/low-severity findings, remain retroactive `N.t` tasks.
- **Step 6 (ship):** the Access-Control Finding Gate (`05-ship.md` §6c-ter) refuses to ship while a confirmed high-severity access-control finding is open (`access_control_high_unresolved` > 0) — a deferral does not clear it.

---

## Worked examples (the two real 2026-06-01 escapes)

| Bug                                                                                                                            | File                                  | Invariant violated                                     | OWASP             | Why the path-glob missed it                 |
| ------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------- | ------------------------------------------------------ | ----------------- | ------------------------------------------- |
| `seed-platform-admin` existing-user branch overwrote `passwordHash` + escalated `platformRole` with no `isQaUser` precondition | `apps/api/src/routes/admin/qa-sim.ts` | INV-4 (bypass-token scoping) + INV-3 (privilege-field) | API3 + API5 / A01 | filename matched no `**/auth/**`-style glob |
| FIN-15 `assignedTo` accepted cross-tenant `users.id` without scoping                                                           | `apps/api/src/routes/jobs.ts`         | INV-1 (object ownership)                               | API1 / A01        | filename matched no security glob           |

Both are caught by the content signals in `shared/owasp-top10-mapping.md` (privilege-field write; bypass token; where-by-id without tenant predicate) → forced `N.s` + this checklist → gating finding.

---

## What this checklist is NOT

- **Not a permission system.** It is a review rubric and a gate signal, not an ACL. Anyone with merge rights can still override it.
- **Not a substitute for `secure-by-default.md`.** This is the verify side; the write side (how the builder makes the invariants hold by construction) lives there.
- **Not exhaustive of all of access control.** It is the high-frequency, high-blast-radius core (BOLA / BFLA / BOPLA / bypass-token / tenant isolation). Insecure _design_ (A04) and business-flow abuse (API6) still need reviewer judgment.
