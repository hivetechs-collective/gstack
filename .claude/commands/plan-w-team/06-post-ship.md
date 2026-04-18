# Step 7: Post-Ship Documentation

After shipping, update documentation to reflect what changed. This stage closes the loop between code (which now reflects new reality) and prose (which by default still describes the old reality).

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
AUDIT_CANDIDATES=$(
  for path in $CHANGED_FILES; do
    base="$(basename "$path" | sed 's/\.[^.]*$//')"
    [ -n "$base" ] && grep -lF "$base" $ALL_DOCS 2>/dev/null
  done | sort -u
)

echo "Audit candidates ($(echo "$AUDIT_CANDIDATES" | wc -l | tr -d ' ') files):"
echo "$AUDIT_CANDIDATES"
```

### Classify each candidate

| Classification                                          | Action                     | Concrete examples                                                                                                                                            |
| ------------------------------------------------------- | -------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Mechanical update (paths, command names, config keys)   | Auto-update without asking | Version number bump in 3 places; CLI flag rename `--foo` → `--bar`; config key rename in YAML examples; copy a stable config table that already moved        |
| Substantive change (architecture description, workflow) | ASK before updating        | New auth flow needs README's "How It Works" rewritten; ARCHITECTURE.md sequence diagram now wrong; CONTRIBUTING needs a new step                             |
| New section needed                                      | ASK before adding          | Brand-new public API needs its own README section; new env var needs a row in `docs/configuration.md`                                                        |
| No change required                                      | Skip silently              | Doc references the changed code only by stable identifier (e.g. "the user service") that still resolves; docs in unrelated module unaffected by this feature |

**Why "mechanical" gets auto-update**: zero risk of meaning shift. A path rename is a path rename. **Why "substantive" gets ASK**: rewording an explanation requires understanding the user's intent for the documentation (tutorial vs reference vs background) — a judgment call the lead should make once per substantive change, not per-doc.

### Worked example: mechanical vs substantive

> **Mechanical:** v1.4.3 → v1.5.0. README quickstart shows `npm install foo@1.4.3`. Update to `npm install foo@1.5.0`. Three other places mention 1.4.3. Update all four. No prompt needed.
>
> **Substantive:** v1.5.0 introduces a new `--profile` flag that changes how the CLI resolves config. The README's "How It Works" section explains the old (single-profile) behavior. The lead must decide: does the README still target single-profile users (keep), get rewritten as multi-profile-first (substantive change), or grow a sibling section (new section)? Ask the user.

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

Flag every "POSSIBLE DRIFT" entry as ASK. The check has false positives (legitimate divergence between, say, a README quickstart and an ARCHITECTURE deep-dive) but every false positive is cheap to dismiss and every true drift is expensive to leave alone.

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
  }
}
EOF

echo "✓ post-ship artifact written: $ARTIFACT"
```

Step 8 retro reads this file in §8d to score "documentation hygiene" without re-running the audit. If the artifact is missing, retro scores §8d as `n/a (docs-skipped)` and notes the skip in the friction log.

## 7f. Refusal Conditions

Do **not** mark Step 7 complete if any of the following are true:

- A substantive update was identified but the user has not yet been asked
- A `POSSIBLE DRIFT` from §7b is unresolved and not on the deferral list
- A spec deferred item is missing context-needed-to-resume in TODOS.md
- The post-ship artifact (§7e) was not written

Each of these is a known leak point: the doc-debt that "we'll get to it" rarely gets gotten to. Catching it at this stage costs minutes; catching it three sprints later costs a re-investigation.
