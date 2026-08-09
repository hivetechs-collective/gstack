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

## Nascent shared abstractions

Grep-before-write above only sees what already exists in the repo at your worktree's fork point. It has no way to see an abstraction that does **not exist yet** — one a sibling builder, working in a different worktree at the same moment, is about to write. Each builder greps, correctly finds nothing, and both write their own version of the same generic helper; the branches merge cleanly into a divergent duplicate that grep-before-write had no way to catch.

`plan-w-team-claim-abstraction.sh` closes this gap with two layers, and the ordering is the whole design:

- **Layer 1 — `verify`. THE GATE.** Diff-driven: reads the run's merged diff, normalizes each newly-added definition's symbol to a concept key, and flags a key defined in more than one new file. Requires **zero builder participation** and works even with no ledger at all — this is what actually blocks ship (`04-fix-first-review.md` §5c-quater).
- **Layer 2 — `claim`/`release`/`list`. ADVISORY early warning.** A builder about to write a plausibly-shared new abstraction claims the concept key first; a CONFLICT response saves it from writing code that Layer 1 would only flag for consolidation later. This layer is optional and voluntary — Layer 1 is what actually holds regardless of compliance (a voluntary-only protocol catches the different-name case only if BOTH builders comply, ~p²; diff-driven detection moves that guarantee to 1).

Builder-facing rule (spawn prompt): the NASCENT ABSTRACTION CLAIM block in `03-execute.md`, mirrored into `team/builder.md` + `team/builder-opus.md`.

## Where this rule is enforced across the pipeline

| Gate                                 | Mechanism                                                                                                                                                                                         |
| ------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Step 0** (scope)                   | Premise Q2 "80% of value from what exists?" + cross-feature overlap scan (`00-scope-challenge.md` §0f).                                                                                           |
| **Step 1** (spec)                    | Mandatory **Existing-Code Survey / Reuse Audit** section + freeze gate (`plan-w-team-reuse-audit-gate.sh`).                                                                                       |
| **Steps 3-4** (build)                | CODE PRESERVATION block inlined in the builder spawn prompt (`03-execute.md`) + this file + `shared/self-regulation.md`.                                                                          |
| **Steps 3-5** (nascent abstractions) | Claim lock (`plan-w-team-claim-abstraction.sh`) — Layer 2 advisory claim in the builder spawn prompt (`03-execute.md`), Layer 1 diff-driven gate at Step 5 (`04-fix-first-review.md` §5c-quater). |
| **Step 5** (review)                  | Reviewer reuse/duplication remit + `consolidate-into-existing` routing (`04-fix-first-review.md`); opt-in clone scan.                                                                             |
| **Step 5** (frozen verdicts)         | **Reuse-verdict re-verification** (`04-fix-first-review.md` §5c-quinquies) — `plan-w-team-reuse-audit-gate.sh --phase review` flags a frozen REUSE/EXTEND target that this run re-implemented anyway, and routes it to `consolidate-into-existing` so it gets FIXED. Advisory; deferrals queue via `plan-w-team-followups.sh add`. |
| **Step 6** (ship)                    | **Re-assertion of the Step-0 80% premise** (`05-ship.md` §6c-quinquies) — the same check re-run at ship, covering code written in later Step-5 fix rounds, recorded as `reuse-verdict-recheck: …` in the ship status block. Never blocks.                                                                                        |

The reuse decision is therefore made **on paper at spec time**, **enforced at build time**, **re-checked at review time**, and **re-asserted at ship time** against what was actually built — not left implicit, and no longer asserted once and never revisited.

**What the last two rungs deliberately do NOT do.** They never flag "the diff does not reference the target". A REUSE verdict frequently means *"this already exists, so we are not building one"* — the most virtuous outcome, and one that leaves no trace in the diff at all. They key instead on the opposite, positive signal: a **newly-added definition** whose concept key collides with a frozen REUSE/EXTEND target. `BUILD-NEW` rows and qualified verdicts like `REUSE (pattern)` are exempt by construction.
