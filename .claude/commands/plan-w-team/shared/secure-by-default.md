# Secure-by-Default — Builder Execution Guidance

The defaults a `/plan-w-team` builder applies so access-control code is **correct the first time** — before any reviewer or gate sees it. This is the **write side** of `shared/access-control-invariants.md` (the verify side). Bake these in and the five invariants hold by construction; skip them and the Step 5 review + Step 6 gate will catch it the slow way (or, historically, miss it).

**When this applies:** any task whose implementation hits an access-control content signal (see `shared/owasp-top10-mapping.md` §Content-Signal Triggers) — a privilege-bearing field write, request-body spread into an ORM update/insert, a service/QA/bypass-token-gated handler, or a by-id query. If the task carries a paired `N.s` security-review task, these defaults are mandatory, not advisory.

**Consumed by:**

- `/plan-w-team/03-execute.md` — standing builder context for security-relevant tasks.
- `.claude/agents/team/builder.md` — execution rules.
- `.claude/agents/research-planning/security-expert.md` — the "expected secure shape" a reviewer checks against.

---

## The Six Defaults

### 1. Deny-by-default authorization

Every mutating handler **opens** with an explicit authorization check — role/capability for the operation **and** object ownership for the target. "Authenticated, therefore allowed" is a bug (BFLA). Never rely on an implicit `requireAuth()` as the only gate.

```ts
export const updateJob = withAuth(async (ctx, input) => {
  assertRole(ctx, "dispatcher"); // INV-2 function-level authz
  const job = await loadOwned(jobs, input.id, ctx); // INV-1 ownership-scoped load (throws 404 if cross-tenant)
  // … mutation …
});
```

### 2. Allow-list mutable fields — never spread input

Parse input with `z.object({...}).strict()` so unknown keys are **rejected** (not silently passed), and build the write payload from an explicit `.pick()` of the columns this operation may change. **Never** `.set({...body})`, `.values({...input})`, `...req.body`, or `Object.assign(row, input)`.

```ts
// Allow-list: privilege fields (role, platformRole, tenantId, isQaUser, passwordHash, *Cents) are NOT pickable.
const UpdateJob = z
  .object({
    title: z.string().min(1),
    notes: z.string().optional(),
  })
  .strict(); // INV-3 reject unknown keys

const patch = UpdateJob.parse(input);
await db
  .update(jobs)
  .set(patch)
  .where(and(eq(jobs.id, input.id), eq(jobs.tenantId, ctx.tenantId))); // INV-1 scoped write
```

### 3. Scope every query by tenant/owner

Every by-id read or write carries a tenant/owner predicate **in the `where` clause**, derived from the authenticated context — never from the request body. Use a shared `loadOwned()` helper so the predicate cannot be forgotten.

```ts
// Reusable ownership-scoped loader — the predicate lives in the query, not an if-check.
async function loadOwned<T>(table: T, id: string, ctx: Ctx) {
  const [row] = await db
    .select()
    .from(table)
    .where(and(eq(table.id, id), eq(table.tenantId, ctx.tenantId))); // INV-1 / INV-5
  if (!row) throw new HttpError(404); // 404 not 403 — don't confirm existence cross-tenant
  return row;
}
```

### 4. Privilege-bearing fields are server-set only

`role`, `platformRole`, `tenantId`/`orgId`, `isQaUser`, `ownerId`, `isAdmin`, `permissions`, `passwordHash`, `balance`, `*Cents` (and any field the threat model names) are set by **server logic**, never copied from the request. If a field grants authority, moves money, or re-parents a record, it is not client-settable.

### 5. Bypass / QA / service-token endpoints assert scope first

Any handler reachable via a QA/service/bypass token must, before **any** mutation, assert the target resource is provably test/QA-scoped, and enforce that scope **in the query predicate** (not only in an `if`, which is TOCTOU-racy). Use the shared `assertQaScoped()` helper. This is the `seed-platform-admin` fix.

```ts
// shared/security/assert-qa-scoped.ts  — codify once, reuse everywhere a bypass token reaches.
export function assertQaScoped(resource: {
  isQaUser?: boolean;
  tenantId?: string;
}): void {
  if (resource?.isQaUser !== true || !isQaTenant(resource.tenantId)) {
    throw new HttpError(403, "bypass token may only touch QA-scoped resources");
  }
}

// usage in a QA_SIM_TOKEN handler:
const user = await findByEmail(body.email);
assertQaScoped(user); // refuse real accounts (INV-4)
await db
  .update(users)
  .set(picked)
  .where(and(eq(users.id, user.id), eq(users.isQaUser, true))); // scope ALSO in the predicate
```

The canonical reference is the `provision-tenant` `is_qa_user` pattern: bypass paths read/write only `is_qa_user = true` rows, with the flag enforced in the SQL `where`, so no race or mass-assignment can widen the blast radius.

### 6. Tenant context wraps writes, not just reads

Run mutations inside the project's tenant-context wrapper (`withTenantContext`, RLS session var) so isolation applies to the **write** path. New tables ship with an RLS policy in the same migration.

---

## Quick self-check before you mark an access-control task done

1. Does every by-id read/write have a tenant/owner predicate in the `where`? (INV-1)
2. Is there a role/capability check for this operation, not just auth? (INV-2)
3. Is the write payload an allow-listed `.pick()` — with `.strict()` parsing — and no field-spread? (INV-3)
4. If a bypass/QA/service token reaches this handler, does `assertQaScoped()` run before any mutation, with the QA scope **also** in the predicate? (INV-4)
5. Does the mutation run inside the tenant context, and do new tables have RLS? (INV-5)

If any answer is "no" or "not sure", it is not done — fix it now (per `04-fix-first-review.md` §5-0 fix-immediately). These map 1:1 to the invariants in `shared/access-control-invariants.md`; the reviewer and the ship gate check the same five.
