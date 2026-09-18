# Step 7: Post-Ship Documentation

<!-- PWT-T2 Orchestrator Retrofit (2026-05-18)
     Pause sites in this file routed via .claude/scripts/plan-w-team-orchestrator-route.sh
     Classifier: shared/orchestrator-interception.md

     | Call-site label         | Verdict      | Original behavior                              |
     | ----------------------- | ------------ | ---------------------------------------------- |
     | post-ship-docs-target   | orchestrator | Substantive doc update, new section, drift ASK  |

     Safe-fail: if router unavailable, falls through to AskUserQuestion.
     Kill switch: PLAN_W_TEAM_DISABLE_ORCHESTRATOR=1
-->

After shipping, update documentation to reflect what changed. This stage closes the loop between code and prose: where the code has moved ahead of the docs, the prose is brought up to date.

**Code is the new reality only where the change is grounded.** The default assumption — "the code now reflects new reality, so rewrite the docs to match" — holds when the change is backed by a CONFIRMED Grounding Ledger. It does NOT hold unconditionally: a *wrong* implementation is also a change, and blindly rewriting prose to match it would overwrite previously-correct documentation with the bug. So when a doc **contradicts** the shipped diff and the ledger row backing that change is not CONFIRMED, §7a-quater surfaces "implementation may be wrong" and leaves the doc alone instead of rewriting it (2026-07-02 evaluation, recursive-followups row 25).

The stage produces a state artifact `.claude/state/plan-w-team-postship-$SLUG.json` consumed by Step 8 retro §8d. The artifact captures what was audited, what was updated, and what was deliberately deferred — so retro can score documentation hygiene without re-running the audit.

## Board Comment (Auto)

Add a documentation update comment to the board Issue. Fire-and-forget.

```bash
scripts/board.sh comment "<feature-name>" "## Post-Ship Documentation

**Docs updated:**
<list of documentation files updated>

**Cross-doc consistency:** <verified | issues found>
**Deferred items:** <count remaining, or 'none'>

**Completed:** $(date -u +%Y-%m-%dT%H:%M:%SZ)" || true
```

## 7a. Per-File Documentation Audit

For each documentation file (README, ARCHITECTURE, CONTRIBUTING, CLAUDE.md, other .md files), check if the shipped changes made any content stale.

### Discover the candidate set

```bash
SLUG="<feature-slug>"
BASE_REF="origin/${BASE_BRANCH:-main}"

# Files that changed in the feature — narrows audit to docs that *might* be affected.
CHANGED_FILES=$(git diff --name-only "$BASE_REF..HEAD")
echo "$CHANGED_FILES" | head -50

# All docs in the repo (markdown + RST + adoc), excluding vendored content.
ALL_DOCS=$(git ls-files '*.md' '*.rst' '*.adoc' \
  | grep -Ev '^(node_modules|vendor|\.claude/agents|docs/specs)/')

# Audit candidates: every doc that mentions a path, symbol, or command from the diff.
# Build a search pattern from the diff's filenames + new symbols.
#
# The pipeline below is wrapped in `bash -c` because some hosts evaluate this
# block in a zsh subshell where nested $(basename "$p" | sed ...) substitutions
# fail with "command not found" on basename / sed / sort / grep. Forcing bash
# resolves those builtins/PATH lookups consistently across hosts. Inputs are
# passed via env (export ... bash -c) rather than string interpolation so
# multi-line values and special characters round-trip safely. Do not unwrap
# this — the failure mode is silent (zero candidates) on hosts that default
# to zsh subshells.
AUDIT_CANDIDATES=$(export CHANGED_FILES ALL_DOCS; bash -c '
  for path in $CHANGED_FILES; do
    base="$(basename "$path" | sed "s/\.[^.]*$//")"
    [ -n "$base" ] && grep -lF "$base" $ALL_DOCS 2>/dev/null
  done | sort -u
')

echo "Audit candidates ($(echo "$AUDIT_CANDIDATES" | wc -l | tr -d ' ') files):"
echo "$AUDIT_CANDIDATES"
```

### Classify each candidate

| Classification                                          | Action                     | Concrete examples                                                                                                                                            |
| ------------------------------------------------------- | -------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Mechanical update (paths, command names, config keys)   | Auto-update without asking | Version number bump in 3 places; CLI flag rename `--foo` → `--bar`; config key rename in YAML examples; copy a stable config table that already moved        |
| Substantive change (architecture description, workflow) | Route through orchestrator | New auth flow needs README's "How It Works" rewritten; ARCHITECTURE.md sequence diagram now wrong; CONTRIBUTING needs a new step                             |
| New section needed                                      | Route through orchestrator | Brand-new public API needs its own README section; new env var needs a row in `docs/configuration.md`                                                        |
| No change required                                      | Skip silently              | Doc references the changed code only by stable identifier (e.g. "the user service") that still resolves; docs in unrelated module unaffected by this feature |

For substantive changes and new sections, route through the orchestrator instead of pausing for user input:

```bash
# snippet-lint: skip — illustrative orchestrator routing
DOC_DECISION=$(route_orchestrator post-ship-docs-target "$SLUG" \
  "doc_path=$DOC_PATH" \
  "change_type=$CLASSIFICATION" \
  "feature_summary=$FEATURE_SUMMARY" \
  "options=update-tutorial,update-reference,add-section,skip,escalate-to-user")
```

<!-- Original: "ASK before updating" / "ASK before adding" for substantive and
     new-section classifications. Orchestrator decides the doc-rewrite intent
     (tutorial vs reference vs background) autonomously.
     Fall-through: AskUserQuestion if router unavailable. -->

**Why "mechanical" gets auto-update**: zero risk of meaning shift. A path rename is a path rename. **Why "substantive" was previously ASK**: rewording an explanation requires understanding the user's intent for the documentation (tutorial vs reference vs background). The orchestrator can now make this judgment call from the feature context and changed-file evidence.

### Worked example: mechanical vs substantive

> **Mechanical:** v1.4.3 → v1.5.0. README quickstart shows `npm install foo@1.4.3`. Update to `npm install foo@1.5.0`. Three other places mention 1.4.3. Update all four. No prompt needed.
>
> **Substantive:** v1.5.0 introduces a new `--profile` flag that changes how the CLI resolves config. The README's "How It Works" section explains the old (single-profile) behavior. The lead must decide: does the README still target single-profile users (keep), get rewritten as multi-profile-first (substantive change), or grow a sibling section (new section)? Ask the user.

### Length calibration (Opus 5 — REQUIRED, not advisory)

Opus 5 pads written deliverables by default: unrequested summary sections,
restatements of what the section above already said, "further reading" blocks,
and preambles explaining what is about to be explained. This stage is the one
that writes to disk most, so it is where that shows up worst.

**`effort` will not fix this.** Lowering effort changes thinking spend, not
visible output length. Length is a prompting problem — so the budget is stated
here, per classification:

| Classification          | Length budget                                                                                                                                                                  |
| ----------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **Mechanical**          | Change ONLY the stale token. Do not reflow the paragraph, do not "improve" adjacent prose, do not add a note explaining the change. A version bump touches the version string. |
| **Substantive rewrite** | Match the replaced section's length within roughly ±20%. If the rewrite is materially longer, the extra text needs a reason you can state — otherwise cut it.                  |
| **New section**         | One paragraph plus at most one example, unless the spec's AC explicitly asks for more.                                                                                         |

**Never add, unless explicitly requested:** a summary or overview section, a
"further reading" / "see also" block, a table of contents, a changelog entry
inside the doc itself (the CHANGELOG is a separate artifact), or a closing
paragraph restating the opening one.

**The test to apply before writing:** would a reader who already knows this
codebase skip this sentence? If yes, do not write it. Documentation length is
not evidence of documentation quality, and a padded doc costs every future
reader the time it saved you.

## 7a-bis. Net-New Surface Scan (A1/A6/C2 — complements §7a, does NOT replace it)

The §7a audit above greps **existing** docs for a changed file's basename. It is
structurally blind to genuinely-NEW surface: a brand-new script/hook/module/CLI-flag/
env-var that no doc references yet produces **zero candidates** and is silently
skipped. This complementary scan enumerates net-new public surface directly from the
diff (`git diff --diff-filter=A` + added-line symbol/flag/env-var extraction) and
requires each item to map to a doc target OR be explicitly waived.

```bash
SLUG="<feature-slug>"
BASE_REF="origin/${BASE_BRANCH:-main}"
.claude/scripts/plan-w-team-netnew-surface.sh --range "${BASE_REF}..HEAD" --slug "$SLUG"
NETNEW_RC=$?   # 0 = all documented/waived; 1 = UNDOCUMENTED residual; 2 = error
```

What it flags (see `docs/operations/pwt-doc-secret-handling.md` for the full model):

- A **new public file** that no doc references → `UNDOCUMENTED`.
- A **new hook/script** (`.claude/hooks/**`, `.claude/scripts/**`, `scripts/**`) that
  no `docs/operations/*` page names → `UNDOCUMENTED` (gap A6 — this repo documents
  every hook/script under `docs/operations/`; write the page now).
- A **new env var / exported symbol / CLI flag** in added lines that no doc references
  → `UNDOCUMENTED`.

For each `UNDOCUMENTED` item, either (a) add the doc target (a row in the config
reference, a `docs/operations` page, a README section), or (b) record an explicit
waiver in `.claude/state/plan-w-team-docs-waived-$SLUG.txt` (one path/token per line)
when the item legitimately needs no doc. Both the residual count and the waiver list
are persisted in the §7e artifact and consumed by the §7f gate and retro §8d.

**Infra glob touched (C2):** if the diff touches an infra surface from
`shared/governance-tags.md` (`wrangler.toml`, `*.tf`, `**/k8s/**`, …), a
runbook/config-reference update is REQUIRED — the same net-new-surface obligation
applies to infra even when no brand-new file is added. Record the runbook path in the
§7e artifact's `infra_runbook` field (or a waiver).

```bash
# Detect infra-glob touches in the diff (C2):
INFRA_HITS=$(git diff --name-only "${BASE_REF}..HEAD" \
  | grep -Ei '(^|/)(wrangler\.toml|.*\.tf|.*\.tfvars)$|/(k8s|kubernetes|terraform|cloudformation)/' || true)
[ -n "$INFRA_HITS" ] && echo "C2: infra changed — runbook/config-reference update required:" && echo "$INFRA_HITS"
```

## 7a-ter. Secret-Handling Documentation (C1)

If this feature introduced a **new secret-bearing variable** (the §1c credential
signal fired in the spec — a new runtime secret / env var the code reads), it MUST
ship a secret-handling doc deliverable, because nothing else tells an operator the
secret exists, where to set it, or how to rotate it:

1. an **`.env.example` row** (or sample-env entry) for the new variable, with a
   placeholder value (never a real secret — the §6a-ter scan + B1 write-time scan
   enforce this); AND
2. a **provisioning / rotation / never-commit note** in the runbook or config
   reference (`docs/operations/*` or the repo's configuration doc).

Record the deliverable path in the §7e artifact's `secret_handling_doc` field. See
`shared/secret-safety.md §Secret-Handling Documentation Duty` for the checklist. If
the feature introduced no new secret, set the field to `"n/a"`.

## 7a-quater. Doc-vs-Code Conflict Escalation (grounding-gated)

The default of this stage — "code is the new reality, rewrite the prose to match"
(§Overview) — is safe only when the shipped change is **grounded**. A *wrong*
implementation is also a change: if a doc that was previously **correct** contradicts
the diff, and the diff's change is not backed by a CONFIRMED Grounding Ledger row,
then rewriting the doc to match the code would overwrite correct documentation with
the bug. This section catches exactly that case and, when it fires, surfaces
**"implementation may be wrong"** rather than rewriting the doc (recursive-followups
row 25, 2026-07-02 evaluation).

**Deterministic-floor principle** (same split as §7a-bis net-new): the *contradiction*
is a matter of judgment (does this prose actually disagree with the diff?), but the
*grounding verdict* is not — it is read mechanically from the frozen spec's Grounding
Ledger via `plan-w-team-grounding-gate.sh --claims`. The judgment cannot manufacture a
CONFIRMED where the ledger has none.

**Kill-switch contract (the CALLER owns the disabled→untrusted policy).** The `--claims`
accessor is part of the grounding family, so `PLAN_W_TEAM_DISABLE_GROUNDING=1` makes it
exit 0 for *every* ledger — a kill-switched exit 0 is NOT a grounding verdict. This
branch therefore tests `PLAN_W_TEAM_DISABLE_GROUNDING` **itself, FIRST**, and when it is
set treats the doc as **NOT trusted** (`DOC_TRUSTED=0`) — the grounding floor is off, so
grounding *cannot be confirmed*, and the conservative rule applies: do not overwrite the
doc. Reading the mode's exit 0 as "confirmed" while the floor is disabled would be the
one path that lets an ungrounded change quietly overwrite a correct doc, which is exactly
what this section exists to prevent.

**The failure direction is always CONSERVATIVE.** Any uncertainty about grounding —
disabled floor, ASSUMED row, absent/blank ledger, missing spec — resolves to
`DOC_TRUSTED=0` → *do not rewrite the doc*, never to "trust the code."

**Procedure** — for each doc the per-file pass (§7a) would rewrite because it
**contradicts** the diff (not merely lags it — a stale-but-not-contradicted doc is the
ordinary §7a rewrite), compute doc-trust deterministically, then branch:

```bash
# snippet-lint: skip — illustrative; SPEC is the frozen Step-1 spec for this run
DOC_TRUSTED=0
if [ "${PLAN_W_TEAM_DISABLE_GROUNDING:-0}" = "1" ]; then
  DOC_TRUSTED=0   # floor off → cannot confirm grounding → conservative (do not trust code)
else
  # exit 0 = every ledger row CONFIRMED (grounded → code IS new reality)
  # exit ≠0 = any ASSUMED/absent/blank/rowless, or spec-not-found → NOT grounded
  .claude/scripts/plan-w-team-grounding-gate.sh --claims --spec "$SPEC"
  [ $? -eq 0 ] && DOC_TRUSTED=1 || DOC_TRUSTED=0
fi

if [ "$DOC_TRUSTED" -eq 1 ]; then
  echo "§7a-quater: ledger fully CONFIRMED — code is new reality, rewriting doc to match (record in doc_vs_code.confirmed_rewrites)"
  # → proceed with the normal §7a substantive rewrite for this doc
else
  echo "⚠ §7a-quater: doc contradicts the diff, but the change is NOT grounded (ASSUMED/absent, or grounding floor disabled)."
  echo "  IMPLEMENTATION MAY BE WRONG — leaving the doc unchanged. Do NOT rewrite prose to match ungrounded code."
  echo "  Recorded in doc_vs_code.unconfirmed_conflicts; §7f refuses terminal until this is resolved."
  # → DO NOT rewrite this doc; record the conflict and route to the user/orchestrator as an ASK
fi
```

When the escalation fires (`DOC_TRUSTED=0`), the correct resolution is **not** a doc
edit — it is either fixing the implementation so the previously-correct doc holds, or
confirming the ledger row (upgrading ASSUMED→CONFIRMED with real evidence) so the code
genuinely is the new reality. Both are decisions above this stage, which is why §7f
refuses to go terminal while `doc_vs_code.unconfirmed_conflicts` is non-empty.

## 7b. Cross-Document Consistency Check

After per-file updates, verify the same concept is described consistently across all docs. Drift here is the silent killer — README says one thing, ARCHITECTURE says another, CLAUDE.md says a third.

```bash
# Build a set of "concepts" that appear in 2+ docs and check all definitions agree.
# Heuristic: extract H2/H3 headings + first sentence following them across all audited docs.
for doc in $UPDATED_DOCS; do
  awk '/^## |^### /{header=$0; getline body; print FILENAME"\t"header"\t"body}' "$doc"
done | sort -k2 | awk -F'\t' '{
  if ($2 == prev_header && $3 != prev_body) {
    print "POSSIBLE DRIFT: "$2
    print "  "prev_file": "prev_body
    print "  "$1": "$3
  }
  prev_header=$2; prev_body=$3; prev_file=$1
}'
```

For each "POSSIBLE DRIFT" entry, route through the orchestrator for batch assessment:

```bash
# snippet-lint: skip — illustrative orchestrator routing for cross-doc drift
DRIFT_DECISION=$(route_orchestrator post-ship-docs-target "$SLUG" \
  "finding_type=cross-doc-drift" \
  "drift_entries=$DRIFT_ENTRIES" \
  "options=fix-all,fix-selective,escalate-to-user")
```

<!-- Original: Flag every "POSSIBLE DRIFT" entry as ASK.
     Orchestrator handles the batch assessment — resolving false positives
     (legitimate divergence) from true drift autonomously.
     Fall-through: AskUserQuestion with the drift list if router unavailable. -->

The check has false positives (legitimate divergence between, say, a README quickstart and an ARCHITECTURE deep-dive) but every false positive is cheap to dismiss and every true drift is expensive to leave alone.

## 7c. TODOS Cleanup

If the repo maintains a `TODOS.md` (or equivalent backlog file), reconcile it with what shipped:

```bash
TODOS_FILE=$(git ls-files | grep -iE '^(TODOS|TODO|BACKLOG)\.md$' | head -1)
[ -z "$TODOS_FILE" ] && echo "(no TODOS file in repo — skip §7c)" && return 0

# Extract items the spec marked as resolved by this feature.
SPEC="docs/specs/${SLUG}.md"
RESOLVED_IDS=$(awk '/Resolves:|Closes:|Fixes:/{print}' "$SPEC")

# For each resolved item, propose moving from "Open" to "Done" section in TODOS.md.
# Operator confirms each move (these are visible to other contributors).
echo "$RESOLVED_IDS"
```

Beyond the resolved items:

- Move completed items to a "Done" section or remove them
- Flag stale items (open >30 days with no progress)
- Report backlog health: `growing` (more added than closed this sprint), `shrinking`, or `stable`

The backlog-health verdict feeds Step 8 retro §8d.

## 7d. Deferred Items Check

Review the spec's `## Deferred Items` table. For each item:

- If the item was completed during implementation → remove the row from deferred and note in the postship artifact (`closed_during_impl`).
- If still deferred → ensure it exists in `TODOS.md` with full context (item, why deferred, context-needed-to-resume, priority). If missing, add it.
- If the item is no longer relevant (the feature shape made it moot) → remove the row and note `obsolete: <reason>` in the postship artifact.

Any deferred item that **lacks** the context-needed-to-resume column is a documentation defect — fix the spec before shipping the docs update.

## 7e. Persist Post-Ship Artifact (handoff to Step 8)

```bash
ARTIFACT=".claude/state/plan-w-team-postship-$SLUG.json"
mkdir -p .claude/state

cat > "$ARTIFACT" <<EOF
{
  "slug": "$SLUG",
  "completed_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "audit": {
    "candidates_scanned": 0,
    "mechanical_updates": [],
    "substantive_updates": [],
    "new_sections_added": [],
    "stale_flagged": []
  },
  "consistency": {
    "drifts_detected": 0,
    "drifts_resolved": 0,
    "drifts_deferred": []
  },
  "todos": {
    "resolved_in_feature": [],
    "stale_open": 0,
    "backlog_health": "stable"
  },
  "deferred_items": {
    "carried_forward": [],
    "closed_during_impl": [],
    "obsolete": []
  },
  "netnew_surface": {
    "scan_rc": ${NETNEW_RC:-0},
    "undocumented": [],
    "waived": [],
    "infra_runbook": "n/a"
  },
  "secret_handling_doc": "n/a",
  "doc_vs_code": {
    "grounding_disabled": ${PLAN_W_TEAM_DISABLE_GROUNDING:-0},
    "unconfirmed_conflicts": [],
    "confirmed_rewrites": []
  }
}
EOF

echo "✓ post-ship artifact written: $ARTIFACT"
```

Populate the new fields from §7a-bis / §7a-ter before writing:

- `netnew_surface.scan_rc` — exit code of `plan-w-team-netnew-surface.sh` (0 clean, 1 residual).
- `netnew_surface.undocumented` — the list of residual `UNDOCUMENTED` items NOT waived (empty on a clean run). **This is the field retro §8d and the §7f gate key off.**
- `netnew_surface.waived` — items waived via `plan-w-team-docs-waived-$SLUG.txt` (audit trail).
- `netnew_surface.infra_runbook` — runbook/config path updated for a C2 infra change, or `"n/a"`.
- `secret_handling_doc` — `.env.example`/runbook path for a C1 new-secret deliverable, or `"n/a"`.
- `doc_vs_code` — from §7a-quater. `grounding_disabled` mirrors `PLAN_W_TEAM_DISABLE_GROUNDING` (when `1`, the floor is off and every contradiction is treated as untrusted → recorded in `unconfirmed_conflicts`). `confirmed_rewrites` = docs that contradicted the diff and WERE rewritten because `DOC_TRUSTED=1` (`--claims` exit 0, ledger fully CONFIRMED — code IS new reality). `unconfirmed_conflicts` = docs that contradicted the diff and were LEFT UNCHANGED because `DOC_TRUSTED=0` (ASSUMED/absent row, missing spec, or disabled floor — implementation may be wrong). **`unconfirmed_conflicts` is the field the §7f gate keys off.**

Step 8 retro reads this file in §8d to score "documentation hygiene" without re-running the audit. If the artifact is missing, retro scores §8d as `n/a (docs-skipped)` and notes the skip in the friction log.

## 7f. Refusal Conditions

Do **not** mark Step 7 complete if any of the following are true:

- A substantive update was identified but neither the orchestrator nor the user has resolved it
- A `POSSIBLE DRIFT` from §7b is unresolved and not on the deferral list
- A spec deferred item is missing context-needed-to-resume in TODOS.md
- The post-ship artifact (§7e) was not written
- **(A1/A6)** §7a-bis reports residual `UNDOCUMENTED` net-new surface that is neither documented nor waived — i.e. `netnew_surface.undocumented` in the §7e artifact is non-empty. Add the doc target or record an explicit waiver, then re-run the scan. (Soft override: `PLAN_W_TEAM_NETNEW_DISABLE=1` downgrades this to a warning — use only with a recorded reason.)
- **(C1)** The feature introduced a new secret-bearing variable (spec §1c credential signal) but `secret_handling_doc` is `"n/a"` / missing — there is no `.env.example` row + provisioning/rotation note. Write the deliverable (§7a-ter) before completing.
- **(C2)** The diff touched an infra glob (`shared/governance-tags.md`) but `netnew_surface.infra_runbook` is `"n/a"` / missing — no runbook/config-reference update accompanies the infra change.
- **(row 25 / doc-vs-code)** §7a-quater recorded a doc that contradicts the diff whose backing change is not grounded — i.e. `doc_vs_code.unconfirmed_conflicts` in the §7e artifact is non-empty. The implementation may be wrong; the doc was correctly left unrewritten. Resolve by fixing the implementation so the doc holds, or by confirming the ledger row (ASSUMED→CONFIRMED with real evidence) and re-running §7a-quater — not by editing the doc to match ungrounded code. (Soft override: `PLAN_W_TEAM_DOC_VS_CODE_DISABLE=1` downgrades this to a warning — use only with a recorded reason, consistent with `PLAN_W_TEAM_NETNEW_DISABLE`.)

```bash
# §7f net-new / secret-doc / infra refusal check (reads the §7e artifact):
ART=".claude/state/plan-w-team-postship-$SLUG.json"
if [ "${PLAN_W_TEAM_NETNEW_DISABLE:-}" != "1" ] \
   && [ "$(jq -r '.netnew_surface.undocumented | length' "$ART" 2>/dev/null || echo 0)" -gt 0 ]; then
  echo "✗ §7f: net-new surface is UNDOCUMENTED — add docs or waive. See $ART .netnew_surface.undocumented" >&2
  exit 1
fi

# §7f doc-vs-code refusal check (row 25): an unconfirmed doc-vs-code conflict means the
# implementation may be wrong — refuse terminal until the code or the ledger is resolved.
if [ "${PLAN_W_TEAM_DOC_VS_CODE_DISABLE:-}" != "1" ] \
   && [ "$(jq -r '.doc_vs_code.unconfirmed_conflicts | length' "$ART" 2>/dev/null || echo 0)" -gt 0 ]; then
  echo "✗ §7f: doc-vs-code conflict on an ungrounded change — implementation may be wrong." >&2
  echo "  Doc left unchanged (correct). Fix the code or confirm the ledger row; do not rewrite the doc." >&2
  echo "  See $ART .doc_vs_code.unconfirmed_conflicts" >&2
  exit 1
fi
```

Each of these is a known leak point: the doc-debt that "we'll get to it" rarely gets gotten to. Catching it at this stage costs minutes; catching it three sprints later costs a re-investigation.

## End-of-Stage Status Block (PWT-T5)

At the end of this stage, emit a status block for the `/goal` evaluator. This is a one-line invocation; the helper handles all field population (workflow lock, supervisor log, fleet log, escalations).

```bash
.claude/scripts/plan-w-team-surface-status.sh "$SLUG" "post-ship"
```

The stage label `post-ship` is the second argument — see `shared/goal-conditions.md` §Status-Block Schema for the full label list. `/goal` evaluator reads the emitted block to judge whether the pipeline terminal condition is met.

Skip this block entirely when `PLAN_W_TEAM_DISABLE_GOAL=1` (kill switch) — the helper itself is observability and remains safe to call, but invocation here is optional in that mode.
