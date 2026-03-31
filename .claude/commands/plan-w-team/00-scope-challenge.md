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

## Output

Proceed / Proceed with modifications / Recommend against (with reasoning). If proceeding, carry the taste calibration, door labels, and dream state mapping forward into the spec.

**Cognitive frameworks used here**: Inversion reflex (Munger), Essential vs accidental complexity (Brooks), Focus as subtraction (Jobs/Rams), One-way vs two-way doors (Bezos). Read `shared/cognitive-frameworks.md` for full reference.
