# Reuse-First Rule — Don't Reinvent What Already Exists

This is the canonical statement of `/plan-w-team`'s reuse-first rule. It lives **inside the skill** (a synced artifact) so it travels to consumer repos via `sync-to-project.sh` AND into worktree-isolated builder subagents — it does **not** depend on the user-global `~/.claude/CLAUDE.md` being loaded (H3).

## The rule

Before writing any new **function, helper, utility, constant, enum, module, type, or config value**, GREP the codebase for an existing one and prefer **call / import / extend** over re-implementing.

This is the general case of the TYPE PRESERVATION rule (which is the same idea for TypeScript types). Type duplication causes merge conflicts; function/helper/module duplication causes code bloat and divergent logic that must be fixed in N places. Both are the same anti-pattern at different granularities.

## How to apply (grep-before-write)

```bash
# By exact / near name (adapt to language)
Grep pattern='function <name>|const <name> =|def <name>|fn <name>' glob='**/*.{ts,js,py,rs,go}'
# Existing exported helpers
Grep pattern='export (async )?(function|const) ' glob='**/*.{ts,js}'
# By concept, not just name — near-duplicates hide behind different names
Grep pattern='formatCurrency|slugify|retry|debounce|parseDate'   # whatever your task needs
```

- **Exact match covers it** → `import` and call it. Do not re-declare.
- **Almost covers it** → EXTEND (add a parameter with a default, write a thin wrapper, use `Pick`/`Omit`/`extends` for types) rather than copy-pasting a variant.
- **Genuinely different semantics** → you may build new, but say _why_ in the commit so the deliberate exception is auditable.

## Positive vs negative exemplar

(Per `opus-4-7-practices.md` §7 — literal-minded models calibrate against a concrete good example, not just a prohibition.)

- **Good**: task needs currency formatting → grep finds `formatCurrency()` in `src/util/money.ts` → `import { formatCurrency }` and call it.
- **Anti-pattern**: writing a fresh `function fmtMoney(...)` inline that duplicates the existing helper. This is the reuse-ignored anti-pattern (**+15% WTF**, `shared/self-regulation.md`).

## Where this rule is enforced across the pipeline

| Gate                  | Mechanism                                                                                                                |
| --------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| **Step 0** (scope)    | Premise Q2 "80% of value from what exists?" + cross-feature overlap scan (`00-scope-challenge.md` §0f).                  |
| **Step 1** (spec)     | Mandatory **Existing-Code Survey / Reuse Audit** section + freeze gate (`plan-w-team-reuse-audit-gate.sh`).              |
| **Steps 3-4** (build) | CODE PRESERVATION block inlined in the builder spawn prompt (`03-execute.md`) + this file + `shared/self-regulation.md`. |
| **Step 5** (review)   | Reviewer reuse/duplication remit + `consolidate-into-existing` routing (`04-fix-first-review.md`); opt-in clone scan.    |

The reuse decision is therefore made **on paper at spec time**, **enforced at build time**, and **re-checked at review time** — not left implicit.
