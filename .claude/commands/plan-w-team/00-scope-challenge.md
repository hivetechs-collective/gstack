# Step 0: Scope Challenge (Pre-Planning Gate)

Before writing a single line of spec, challenge the premise. This step can kill a bad idea before wasting tokens.

## 0a. Premise Challenge

Ask three questions:

1. Is this the right thing to build? (Bezos: will we regret NOT building this in 10 years?)
2. Can we achieve 80% of the value by leveraging what already exists? (Read existing code first)
3. Does this move us toward our 12-month ideal, or is it a detour?

Map three states:

- **CURRENT**: What exists today (read the relevant code)
- **THIS PLAN**: What the feature description proposes
- **12-MONTH IDEAL**: Where the project should be heading

If THIS PLAN does not move toward 12-MONTH IDEAL, flag it. The lead has **permission to recommend scrapping the plan entirely** — sunk cost bias is the enemy.

## 0b. Taste Calibration

Before planning, identify in the existing codebase:

- 2-3 well-designed patterns (reference points for quality)
- 1-2 poorly-designed patterns (anti-reference points to avoid)

Use these as calibration anchors throughout the spec and review stages.

## 0c. Complexity Smell Check

If the feature description implies:

- Touching >8 files -> flag for extra scrutiny
- Introducing >2 new abstractions (classes, services, modules) -> challenge necessity
- Both -> strongly recommend scope reduction or phased delivery

### Context Budget Gate (MANDATORY)

Estimate the feature's context cost before proceeding:

| Signal                                        | Threshold  | Action                                                 |
| --------------------------------------------- | ---------- | ------------------------------------------------------ |
| Files to change                               | >12        | **MUST split** into separate /plan-w-team runs         |
| New files to create                           | >4         | **MUST split** unless they follow an identical pattern |
| Estimated tasks                               | >5         | **MUST split** — will exhaust context in one session   |
| Repetitive implementations (e.g., 5 monitors) | >3 similar | Split into batches of 2-3 per run                      |

**Why**: The multi-source monitor retro (2026-03) proved that 5 similar implementations + full doc rewrite = 3 compactions and 3 sessions. Splitting "add monitors A+B" then "add monitors C+D+E" would have completed in 2 clean single-session runs instead of 1 painful multi-session run.

When splitting, each phase should be a **self-contained /plan-w-team run** that ships independently — not just a task breakdown within one run. Each phase gets its own spec, its own review, its own ship step.

## 0d. One-Way vs Two-Way Door Labeling

Tag each major design decision in the feature as:

- **Two-way door** (reversible): Move fast, don't over-analyze. Examples: UI layout, variable naming, config defaults
- **One-way door** (irreversible): Scrutinize carefully. Examples: database schema, public API shape, data migration

Two-way doors get standard review. One-way doors get extra validation in Step 5.

## 0e. UI Repo Detection Bridge (UI repos only)

If `.claude/qa-profile.json` exists in the target repo, this feature runs against a QA-scaffolded UI codebase. When the bridge fires, Step 0 carries two additional signals forward:

- **`qa_profile`** — read `.claude/qa-profile.json`'s `profile` field (`light` / `standard` / `full`) and surface it as a scope input. Downstream stages enforce the matching tier set from `shared/qa-tiers.md`.
- **`ui_scope_flag`** — set to `true` whenever the feature's CURRENT→THIS PLAN mapping touches `.tsx`, `.jsx`, `.vue`, `.svelte`, or Angular `@Component` files. Triggers Step 1 UI Tier Profile & Test Plan, Step 2 paired-task protocol, Step 4 UI-TDD builder directive, Step 5 Pass 1 UI checks, and Step 6 Tier Evidence Ledger.

If `.claude/qa-profile.json` is missing on a UI-scope feature, prompt: "UI files detected but `/qa-scaffold` has not been run. Run `/qa-scaffold` first so the tier profile and locator rules are available, or proceed without UI-TDD enforcement? [scaffold/skip]". Default `scaffold` — the friction is intentional.

For non-UI features (backend, infra, docs) or non-scaffolded repos, skip §0e entirely and proceed to `## Output`. The rest of the /plan-w-team pipeline runs unchanged.

## Output

Proceed / Proceed with modifications / Recommend against (with reasoning). If proceeding, carry the taste calibration, door labels, and dream state mapping forward into the spec.

### Worked Example: a feature that failed the challenge

> **Request:** "Build a custom retry queue for SES email sends so we never lose a notification."
>
> **0a Premise:** SES already retries with exponential backoff and emits `Bounce`/`Complaint` events; the loss scenario the user is worried about (transient SMTP failure) is the case SES handles best. **80% of value already exists.**
>
> **0c Complexity:** Custom retry queue = new table, new worker, new dead-letter mailbox, new dashboards. Touches >8 files; 2 new abstractions. **Smell positive.**
>
> **0d Doors:** Schema for the retry queue is one-way; backing it out after launch would require either retaining the old table indefinitely or migrating in-flight messages. **High-risk one-way door for a low-yield feature.**
>
> **Verdict:** Recommend against. Achieve the same goal by (a) subscribing to SES `DeliveryDelayed` events and surfacing them in the existing notifications dashboard, and (b) wiring a 24h-old-bounce alert. Two-way door, ~30 minutes of work, no new infrastructure.

The vignette exists to remind the lead that "Recommend against" is a real outcome, not a theoretical one. Sunk-cost bias and "the user asked for it" are the two failure modes this stage exists to defeat.

**Cognitive frameworks used here**: Inversion reflex (Munger), Essential vs accidental complexity (Brooks), Focus as subtraction (Jobs/Rams), One-way vs two-way doors (Bezos). Read `shared/cognitive-frameworks.md` for full reference.

**Opus 4.7 tip**: Scope challenge is a gate, not a design session — use terse adaptive thinking ("prioritize responding quickly"). See `shared/opus-4-7-practices.md` §2.
