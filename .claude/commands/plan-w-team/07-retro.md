# Step 8: Retro (Optional but Recommended)

<!-- PWT-T2 Orchestrator Retrofit (2026-05-18)
     Pause sites in this file routed via .claude/scripts/plan-w-team-orchestrator-route.sh
     Classifier: shared/orchestrator-interception.md

     | Call-site label             | Verdict      | Original behavior                           |
     | --------------------------- | ------------ | ------------------------------------------- |
     | retro-friction-categorize   | orchestrator | Friction-log category assignment             |

     New section: §8j-bis Orchestrator Decision Health reads the per-SLUG JSONL
     decision log and scores orchestrator decision quality for the retro.

     Safe-fail: if router unavailable, falls through to AskUserQuestion.
     Kill switch: PLAN_W_TEAM_DISABLE_ORCHESTRATOR=1
-->

Quantitative retrospective on the shipped work. Run automatically for features that took >2 hours of builder time, or on demand with `--retro`.

## Pre-Step: Minimal-Retro-on-Exit Trap

Install before any other shell work in this stage. Belt-and-braces fallback that guarantees a retro JSON exists on disk even if the retro shell flow itself dies (e.g., the lead session compacts mid-write, a `jq` failure cascades, the user `kill -9`s the run). The watcher (`pwt-watch.sh`) and the `/goal` evaluator read that JSON; without it, completion notifications degrade to "session finished" with no metrics.

```bash
SLUG="<feature-slug>"
PWT_CURRENT_STAGE="retro"

# Chain with any existing trap rather than replace it (see shared/shell-safety.md).
EXISTING_TRAP=$(trap -p EXIT | sed -E "s/^trap -- '(.*)' EXIT$/\\1/")
MIN_RETRO_CMD=".claude/scripts/plan-w-team-minimal-retro.sh \"\$SLUG\" \"\$PWT_CURRENT_STAGE\" \"retro-early-exit-\$?\""
trap "${EXISTING_TRAP:+${EXISTING_TRAP}; }$MIN_RETRO_CMD" EXIT

# Mark the retro stage as "committed to completing". The cleanup gates in
# §8j-ter (fleet log), §8j-quater (supervisor log + goal state), and §8j-sexies
# (spawn registry) read this. Without the assignment those rm -f calls are
# dead code and per-SLUG state files accumulate forever (observed 2026-05-21:
# ~12 stale plan-w-team-spawned-children-*.jsonl files). If retro exits
# abnormally before reaching the cleanup blocks, the EXIT trap fires
# minimal-retro, which itself invokes child-cleanup.sh — so bg children are
# still stopped on the early-exit path.
RETRO_SUCCESS=1
```

The helper is no-op when a complete retro already exists for the SLUG — `$RETRO_STATE` written by §8h or the §8j completion block takes precedence. The trap only writes when the early-exit path beats the normal completion path to disk.

## Board Comment (Auto)

Add a retro summary as the final comment on the board Issue — this closes the feature's story. Fire-and-forget.

```bash
scripts/board.sh comment "<feature-name>" "## Retrospective

**Commits:** <count> | **Lines:** +<added> / -<removed>
**Sessions:** <count> (<deep/medium/micro breakdown>)
**Fix ratio:** <fixes / total> (<healthy | warning>)
**Test quality:** ★★★/★★/★ across <count> modules
**Self-assessment:** <0-10>/10

### What went well
<1-2 bullet points>

### What to improve
<1-2 bullet points>

**Completed:** $(date -u +%Y-%m-%dT%H:%M:%SZ)" || true
```

## 8a. Gather Metrics

**Invoke the metrics script** — do NOT recall numbers from memory. The script
emits validated JSON with all the fields §8b needs. A retrospective without
this script is unreliable (2026-05-20 holistic-check retro showed three
metrics recalled from memory diverged from git reality by 30%+).

```bash
.claude/scripts/plan-w-team-retro-metrics.sh "$SLUG" | tee /tmp/retro-${SLUG}.json | jq '.'
```

Optional flags: `--base origin/develop` (override default `origin/main`).

The JSON has fields: `commit_count`, `lines_added`, `lines_removed`,
`files_changed`, `commit_type_breakdown` (feat/fix/refactor/test/docs/chore/other),
`fix_ratio`, `ai_assisted_count`, `test_pass_count`, `fleet_stats`.

For ad-hoc inspection alongside the JSON, the raw git commands remain
available:

```bash
# Quick sanity check (not the source of truth — use the script above):
git log --oneline "$(jq -r '.base_ref' /tmp/retro-${SLUG}.json)..HEAD"
git diff --stat "$(jq -r '.base_ref' /tmp/retro-${SLUG}.json)...HEAD"
```

## 8b. Compute and Report

| Metric                  | How                                                                      |
| ----------------------- | ------------------------------------------------------------------------ |
| Commit count            | Count commits in feature range                                           |
| Lines added/removed/net | From diff stat                                                           |
| File churn              | Most-changed files (hotspot analysis)                                    |
| Commit type breakdown   | Count feat/fix/refactor/test/docs prefixes                               |
| Work session detection  | 45-minute gap between commits = new session boundary                     |
| Session classification  | Deep (50+ min), Medium (20-50), Micro (<20)                              |
| AI-assisted ratio       | Count commits with `Co-Authored-By` trailers vs total                    |
| Fix ratio               | fixes / total commits. Flag if >50% ("ship fast, fix fast" anti-pattern) |

## 8c. Quality Signals

| Signal                                      | Threshold | Meaning                                                     |
| ------------------------------------------- | --------- | ----------------------------------------------------------- |
| Fix ratio >50%                              | Warning   | Review process may have gaps                                |
| WTF-likelihood hit >20% during build        | Note      | Builder struggled, investigate why                          |
| >3 reverts during build                     | Warning   | Spec may have been unclear                                  |
| Hotspot with >10 changes                    | Note      | Consider refactoring this file                              |
| Any defect/flaky logged "noted" (not fixed) | **Fail**  | Fix-immediately rule violated (§5-0) — see audit below      |
| GH-Actions build/deploy path introduced     | **Fail**  | No-GH-Actions rule violated (`shared/no-github-actions.md`) |

### Fix-Immediately Compliance Audit (ENFORCING — per §5-0)

Verify the run honored the fix-immediately rule (memory
`feedback_fix_defects_and_flaky_immediately`). Scan the run's review findings and
supervisor log for any defect or flaky test that was logged as merely **"noted"** without
a completed fix→retest→verify-GREEN. Each such item is a **Fail** signal — the rule is
that a defect/flaky is fixed now, never deferred or note-and-advanced.

Also confirm no flaky test was "fixed" by the forbidden means (loosened assertion, retry
wrapper, `.skip`/`xfail`, widened timeout). A flaky repair that did not remove the source
of non-determinism (and pass 100/100) is a Fail.

A Fail here means the workflow shipped against its own governance — record it as a retro
finding and a memory candidate (§8j) so the next run tightens enforcement.

## 8c-bis. Workspace / State Secret Sweep (B2, 1.33.0)

The ship-gate secret scan covers the committed diff, but `.claude/state/*.json`, the
captured test-output log (`plan-w-team-test-output-$SLUG.log`), and other run artifacts
are never scanned — a secret can land there (a tool dumping an env var into a state file,
a stack trace echoing a token into the test log) and sit unscanned. This advisory pass
runs `secret-scan.sh` over the workspace state before retro completes. It SURFACES hits
(so the operator can scrub them) but does not block — the enforcing leak-prevention gates
are the ship-time scans; this is the defense-in-depth backstop the audit (gap B2) asked for.

```bash
SLUG="<feature-slug>"
SECRET_SCANNER=".claude/scripts/secret-scan.sh"
if [ -x "$SECRET_SCANNER" ] && [ "${PLAN_W_TEAM_DISABLE_WORKSPACE_SCAN:-}" != "1" ]; then
  # Scan run state + logs. secret-scan.sh skips binary/oversize (>1 MB) files and reports
  # the skip count (B2 surfaced-skip); placeholder suppression (B3) keeps this low-noise.
  SWEEP_TARGETS=$(ls .claude/state/plan-w-team-*-"$SLUG".json \
                     .claude/state/plan-w-team-test-output-"$SLUG".log 2>/dev/null || true)
  if [ -n "$SWEEP_TARGETS" ]; then
    # shellcheck disable=SC2086
    if "$SECRET_SCANNER" --paths $SWEEP_TARGETS >/tmp/pwt-wssweep.$$ 2>&1; then
      echo "§8c-bis workspace secret sweep: clean"
    else
      echo "⚠ §8c-bis workspace secret sweep FOUND a live secret in run state/logs — scrub before archiving:"
      cat /tmp/pwt-wssweep.$$ >&2
    fi
    rm -f /tmp/pwt-wssweep.$$
  fi
fi
```

Kill switch: `PLAN_W_TEAM_DISABLE_WORKSPACE_SCAN=1`. The >1 MB / binary silent-skip is also
surfaced in the Step-6 ship-gate failure-modes table (`05-ship.md`) so it is no longer a
buried footnote (gap B2).

## 8d. Documentation Hygiene + Streak Tracking

### Documentation Hygiene (Post-Ship Reader — A4, 1.33.0)

**This is the REAL §8d reader for the Step-7 post-ship artifact.** Before 1.33.0 this
section was streak-tracking only, while `06-post-ship.md` claimed retro §8d "consumes
`plan-w-team-postship-$SLUG.json` to score doc hygiene" — a phantom: no reader existed,
and the `handoff` orphan-reader gate false-passed because the reader_grep matched the
writer file's own prose. This block reads the artifact and scores doc hygiene; the
`symmetry-check.sh` A4 fix now requires the reader to live in a non-writer file (here).

```bash
SLUG="<feature-slug>"
POSTSHIP=".claude/state/plan-w-team-postship-${SLUG}.json"
RETRO_STATE=".claude/state/plan-w-team-retro-${SLUG}.json"

if [ ! -f "$POSTSHIP" ]; then
  # A5: post-ship-complete precondition — the artifact MUST exist before retro scores
  # hygiene. A missing artifact means Step 7 did not run (or was skipped); score n/a and
  # note the skip in the friction log rather than silently passing.
  echo "§8d doc-hygiene: n/a (docs-skipped — no post-ship artifact at $POSTSHIP)"
  DOC_HYGIENE_SCORE="null"
else
  # Read the artifact the post-ship stage wrote (the real consumer the registry promises).
  UNDOC=$(jq -r '.netnew_surface.undocumented | length' "$POSTSHIP" 2>/dev/null || echo 0)
  WAIVED=$(jq -r '.netnew_surface.waived | length' "$POSTSHIP" 2>/dev/null || echo 0)
  DRIFTS_DEFERRED=$(jq -r '.consistency.drifts_deferred | length' "$POSTSHIP" 2>/dev/null || echo 0)
  SECRET_DOC=$(jq -r '.secret_handling_doc // "n/a"' "$POSTSHIP" 2>/dev/null || echo "n/a")
  BACKLOG=$(jq -r '.todos.backlog_health // "unknown"' "$POSTSHIP" 2>/dev/null || echo unknown)
  # Score 5 (clean) down to 1 (residual undocumented surface at ship).
  if [ "$UNDOC" -gt 0 ]; then DOC_HYGIENE_SCORE=1
  elif [ "$DRIFTS_DEFERRED" -gt 0 ]; then DOC_HYGIENE_SCORE=3
  else DOC_HYGIENE_SCORE=5; fi
  echo "§8d doc-hygiene: score=$DOC_HYGIENE_SCORE (undocumented=$UNDOC, waived=$WAIVED, drifts_deferred=$DRIFTS_DEFERRED, secret_doc=$SECRET_DOC, backlog=$BACKLOG)"
  # A residual UNDOCUMENTED at ship is a fix-immediately signal (the §7f gate should have
  # caught it) — record it as a retro finding + memory candidate per §8a's fix-now rule.
  if [ "$UNDOC" -gt 0 ]; then
    echo "⚠ §8d: $UNDOC net-new surface item(s) shipped UNDOCUMENTED — investigate why §7f did not block"
  fi
fi
# Persist the score into the retro state for the streak/quality rollup.
if [ -f "$RETRO_STATE" ]; then
  TMP=$(mktemp)
  jq --arg s "$DOC_HYGIENE_SCORE" '.quality_signals.doc_hygiene = ($s | if . == "null" then null else tonumber end)' \
    "$RETRO_STATE" > "$TMP" 2>/dev/null && mv "$TMP" "$RETRO_STATE" || rm -f "$TMP"
fi
```

If the artifact is missing, retro scores §8d doc-hygiene as `n/a (docs-skipped)` and the
A5 precondition note is surfaced — `retro-complete` must not be emitted on a run that was
supposed to produce docs but has no post-ship artifact (see §8 cleanup precondition).

### Streak Tracking

Track across features (persists in task metadata). Read `shared/artifact-storage.md` for streak data format.

- Consecutive features shipped without P0 bugs
- Longest focus session (Deep work)
- Features shipped this week/month

## 8e. Parallel Execution Health

Track worktree and agent coordination metrics:

| Metric                           | How to Measure                            | Warning Threshold |
| -------------------------------- | ----------------------------------------- | ----------------- |
| Stale worktree incidents         | Agents that operated on outdated code     | Any > 0           |
| Shared file merge conflicts      | Manual merge coordination needed          | Any > 0           |
| Context compactions during build | `/compact` or auto-compact triggers       | > 1 per run       |
| Worktrees alive at peak          | Max concurrent worktrees during execution | > 6               |
| Fix agents that duplicated work  | Agents whose changes were superseded      | Any > 0           |
| Expired worktree builders        | Builders lost to context/session expiry   | Any > 0           |
| Sessions to complete             | `--resume` count + 1                      | > 2               |
| Formatter re-read cycles         | "File modified since read" errors         | Any > 0           |

A stale-worktree incident or shared-file conflict means Step 2's conflict detection was incomplete. Expired worktree builders mean the feature was too large for worktree strategy — should have used "lead implements directly" per Step 3. Formatter re-reads mean the pre-edit format sync was skipped.

### Deep-Audit Cost (opt-in — C4 pilot)

When the optional Tier-1 deep-audit breadth sweep ran (`PLAN_W_TEAM_DEEP_AUDIT=1`,
`shared/deep-audit.md`), score whether it earned its token cost. **n/a when the
sweep did not run (the default)** — never blocks retro.

```bash
SLUG="<feature-slug>"
DA_AUDIT=".claude/state/plan-w-team-deep-audit-${SLUG}.jsonl"
if [ ! -f "$DA_AUDIT" ]; then
  echo "Deep-audit: n/a (PLAN_W_TEAM_DEEP_AUDIT not set or no audit ran)"
else
  FINDINGS=$(jq -s 'length' "$DA_AUDIT" 2>/dev/null || echo 0)
  SURFACES=$(jq -rs '[.[].surface] | unique | length' "$DA_AUDIT" 2>/dev/null || echo 0)
  AGENTS=$(jq -rs '[.[].agent_type] | unique | length' "$DA_AUDIT" 2>/dev/null || echo 0)
  CRIT=$(jq -rs '[.[] | select(.severity=="critical")] | length' "$DA_AUDIT" 2>/dev/null || echo 0)
  echo "Deep-audit cost: ${FINDINGS} findings across ${SURFACES} surfaces by ${AGENTS} agents (${CRIT} critical)."
  echo "  → Score 5 when findings>0 and no unaddressed critical; if findings≈0 across"
  echo "    runs the sweep is not earning its cost — keep PLAN_W_TEAM_DEEP_AUDIT default-OFF."
  # Cleanup on a clean retro (mirrors §8j-ter), keep on failure for inspection.
  if [ "${RETRO_SUCCESS:-0}" = "1" ]; then rm -f "$DA_AUDIT"; fi
fi
```

### Retroactive-Coverage Closure & Gap-Analyzer Cost (advisory)

This is the Step-8 consumer the Step-5 handoff promises: the §5c-bis / §5d-bis gap
analyzers queue retroactive-coverage tasks (metadata `retroactive: true`,
`origin: test-gap-analyzer` / `security-gap-analyzer`, plus `owasp_category` on the
security `N.t` tasks), and §5b-pre / §5c-bis / §5d-bis cite this section for their
token costs. Advisory signals only — never a gate, never blocks retro. **n/a when
neither analyzer ran** (the Step 5 status block records the skip reason).

```bash
SLUG="<feature-slug>"
# Pseudocode — use your task tooling (mirrors §8g-bis). The §5c-bis/§5d-bis
# TaskCreate contract tags every queued task with metadata
# { slug: $SLUG, retroactive: true, origin: <analyzer> }.
RETRO_TOTAL=$(TaskList by metadata slug="$SLUG" retroactive=true | wc -l)
RETRO_CLOSED=$(TaskList by metadata slug="$SLUG" retroactive=true status=completed | wc -l)
if [ "$RETRO_TOTAL" -gt 0 ]; then
  echo "Retroactive closure: $RETRO_CLOSED/$RETRO_TOTAL closed before retro"
else
  echo "Retroactive closure: n/a (no retroactive tasks queued this run)"
fi
```

- **Closure rate** (`completed / total`): <100% means Step 5 queued gap tasks that
  did not close before retro — name each open task in the retro narrative and
  confirm it survives in the durable task queue (it must not silently evaporate
  with the run).
- **Per-OWASP-category gap counts**: from the security-gap-analyzer report, count
  `### G<N>` findings per `owasp_category` (the queued `N.t` tasks mirror it in
  metadata) and report `A01=<n> A03=<n> …`. The same category recurring across
  runs is a systemic gap — treat it like §8g's repeated failure categories.

| Token metric                   | Written by                          | Warning threshold     |
| ------------------------------ | ----------------------------------- | --------------------- |
| `pass1_reviewer_tokens`        | §5b-pre Pass-1 fan-out (cumulative) | >40k across reviewers |
| `test_gap_analyzer_tokens`     | §5c-bis test-gap analyzer           | >20k per run          |
| `security_gap_analyzer_tokens` | §5d-bis security-gap analyzer       | >20k per run          |

A threshold breach is a tuning signal — tighten `module_root` to siblings-only,
skip fan-out Slot 3, or (last resort) use the per-run kill switches documented in
Step 5. It is never a cap and never a halt.

## 8f. Hook Friction Log

Track PostToolUse hook interactions that caused workflow friction:

| Metric          | How to Measure                                                                          |
| --------------- | --------------------------------------------------------------------------------------- |
| TS6133 warnings | Count TS6133 "allowed" messages in hook output                                          |
| False blocks    | Edits blocked by hook that required workarounds (combined edits, Write instead of Edit) |
| Real catches    | Type errors the hook caught that would have been bugs                                   |

A high false-block count signals the hook needs tuning. A high real-catch count validates the hook's value. Track both to calibrate.

## 8g. Evaluator Iteration Health

Track evaluator-driven refinement outcomes from Step 4b:

| Metric                  | How to Measure                                | Warning Threshold         |
| ----------------------- | --------------------------------------------- | ------------------------- |
| Verdict                 | PASS / ITERATE (exhausted) / ESCALATE         | ESCALATE = builder stuck  |
| Iterations used         | Actual vs max_iterations from spec            | Hit max without PASS      |
| Functional pass rate    | functional_pass / functional_total            | < 100% at final iteration |
| Quality average         | Mean of quality_scores array                  | < 3 (below adequate)      |
| Failure categories      | Array of failure themes from evaluator report | Same category 2+ features |
| No-progress escalations | ESCALATE due to repeated same failures        | Any > 0                   |

An ESCALATE verdict means the evaluator detected the builder couldn't fix the issue alone — review the spec for unclear requirements or missing design guidance. Repeated failure categories across features signal a systemic gap — check if an instinct was created by `capture-learnings.sh` for compound learning.

## 8g-bis. Scope Stability

Step 2 wrote a scope-lock artifact at `.claude/state/plan-w-team-scope-lock-$SLUG.json`. Compute scope stability:

```bash
LOCK=".claude/state/plan-w-team-scope-lock-$SLUG.json"
UNLOCK=".claude/state/plan-w-team-scope-unlock-$SLUG"

if [ -f "$LOCK" ]; then
  LOCKED=$(jq -r '.task_count' "$LOCK")
  SHIPPED=$(TaskList by spec_path | wc -l)   # pseudocode — use your task tooling
  DRIFT=$((SHIPPED - LOCKED))
  UNLOCK_ACK=$([ -f "$UNLOCK" ] && echo true || echo false)

  # Score: 5 = no drift, 4 = drift with ack, 2 = drift without ack, 1 = lock missing mid-flight
  if [ "$DRIFT" -eq 0 ]; then SCORE=5
  elif [ "$UNLOCK_ACK" = "true" ]; then SCORE=4
  else SCORE=2
  fi
else
  SCORE="n/a"
fi
```

Report in retro: `Scope stability: <score>/5 (locked=<N>, shipped=<N>, drift=<D>, unlock_ack=<bool>)`.

A score <= 2 means tasks were added mid-flight without the user acknowledging scope expansion. This is a process smell — the spec was probably incomplete, or scope creep happened silently. Feeds into 8i self-assessment.

## 8g-ter. Writer↔Reader Symmetry

Step 5 runs `.claude/scripts/plan-w-team-symmetry-check.sh` as an enforcing gate. Re-run it at retro time to score how the run's governance artifacts held up:

```bash
if .claude/scripts/plan-w-team-symmetry-check.sh >/dev/null 2>&1; then
  SYMMETRY_SCORE=5
  SYMMETRY_NOTE="clean"
else
  code=$?
  case "$code" in
    1) SYMMETRY_SCORE=1; SYMMETRY_NOTE="orphan (enforcing artifact with no reader)" ;;
    2) SYMMETRY_SCORE=1; SYMMETRY_NOTE="stale (registry entry with no writer)" ;;
    3) SYMMETRY_SCORE=0; SYMMETRY_NOTE="checker env failure" ;;
    *) SYMMETRY_SCORE=0; SYMMETRY_NOTE="unknown exit $code" ;;
  esac
fi
```

Report in retro: `Writer↔reader symmetry: <SYMMETRY_SCORE>/5 (<SYMMETRY_NOTE>)`.

A score <4 means the run introduced a new state artifact without completing the writer↔reader contract — the exact defect class this gate exists to catch. Feeds §8i self-assessment with category `spec-gap`. Unlike scope-lock drift (where user ack is an escape hatch), symmetry is a pure code-governance property: an orphan is always a real defect, never a legitimate user choice.

## 8h. Untracked Hygiene

Score how well this run handled untracked files. Read the state file written by the Step 5 ship gate:

```bash
SLUG="<feature-slug>"
RETRO_STATE=".claude/state/plan-w-team-retro-$SLUG.json"
BASELINE=".claude/state/plan-w-team-untracked-baseline-$SLUG.txt"

# Degraded-mode sentinel: if the baseline never existed (e.g. --ship-only, --resume,
# or a run that skipped preflight), persist hygiene_skipped: true to the retro JSON
# so downstream readers (friction detector, dashboards) can distinguish "skipped" from
# "scored low". A score of 1 means the gate ran and failed; a missing-baseline run
# should score n/a, not 1.
#
# IMPORTANT: the write is unconditional — RETRO_STATE may not pre-exist on the
# --ship-only and --retro paths (no Step 5 ship-gate hygiene loop ran), and that
# is exactly the case the sentinel exists for. Round 1 had this guarded behind
# `[ -f "$RETRO_STATE" ]`, which silently no-op'd on the most common skip path.
if [ ! -f "$BASELINE" ]; then
  mkdir -p .claude/state
  TMP=$(mktemp "${RETRO_STATE}.tmp.XXXXXX")
  if [ -f "$RETRO_STATE" ]; then
    jq '.untracked_hygiene = {hygiene_skipped: true, reason: "baseline missing at retro time", score: null}' \
      "$RETRO_STATE" > "$TMP"
  else
    jq -n '{untracked_hygiene: {hygiene_skipped: true, reason: "baseline missing at retro time", score: null}}' \
      > "$TMP"
  fi
  mv "$TMP" "$RETRO_STATE"
  echo "Score: n/a (hygiene-skipped — no baseline)"
else
  # Normal path: read untracked_hygiene.resolved counts and deferrals[] from the file
  jq '.untracked_hygiene' "$RETRO_STATE"
fi
```

Report in the retro artifact using this format:

```markdown
### Untracked Hygiene

- Baseline size: <N>
- Classification set: <N> new files
- Resolved: <C> COMMIT / <I> IGNORE / <D> DISCARD / <F> DEFER
- Deferrals: <list each `{path, reason}` or "none">
- .gitignore edits: <count of patterns added, or "none">
- Score: <1-5>
```

Scoring anchors (full rubric in `shared/untracked-hygiene.md`):

| Score | Anchor                                                                                    |
| ----- | ----------------------------------------------------------------------------------------- |
| 1     | Many deferrals without clear reasons; gate skipped without justification                  |
| 2     | Most classified but several DEFER with vague reasons                                      |
| 3     | All classified; 1-2 DEFER with documented reasons; some IGNORE patterns too broad         |
| 4     | All classified; 0-1 DEFER; IGNORE patterns narrow and appropriate                         |
| 5     | Clean run (0 new untracked) OR all COMMIT/IGNORE/DISCARD with narrow, justified decisions |

A hygiene score <4 should feed into 8i self-assessment as a friction point — the workflow missed a classification opportunity or accumulated deferrals.

### Cleanup

At the end of a successful retro (artifact written, all sections complete), delete the baseline file:

```bash
rm -f ".claude/state/plan-w-team-untracked-baseline-$SLUG.txt"
```

Failed runs (retro aborted) leave the baseline intact so `--resume` can read it.

If the Step 5 gate ran in degraded mode (no baseline, e.g. `--ship-only` or `--resume`), report `Score: n/a (hygiene-skipped)` instead of scoring 1 — skipping is not the same as failing. The sentinel block above persists this distinction to `$RETRO_STATE.untracked_hygiene.hygiene_skipped` so the 3-in-30-days friction detector won't false-positive on legitimate skips.

## 8i. Self-Assessment

Rate the overall `/plan-w-team` experience for this feature 0-10. If below 10, note what friction points occurred — this feeds back into improving the workflow itself:

- Where did the spec miss something?
- Where did builders struggle?
- Where did review catch real issues vs generate noise?
- Where did hooks help vs create friction?
- Did untracked hygiene (8h) surface real classification work, or was it noise?
- What would you do differently next time?

Store self-assessment at the path defined in `shared/artifact-storage.md`.

### Trigger: scores below 8 feed back into the workflow

A self-assessment below 8 is not a vent — it is a signal that the workflow itself needs attention. When a score <8 is recorded:

1. **Append the friction point** to `.claude/state/plan-w-team-friction-log.jsonl`. Serialize concurrent retros with a portable mkdir-based atomic lock (flock is not available on macOS by default). Busy-wait because two parallel retros on different features legitimately race here and both must land:

   ```bash
   LOG=".claude/state/plan-w-team-friction-log.jsonl"
   LOCK_DIR=".claude/state/plan-w-team-friction-log.lock"
   mkdir -p .claude/state
   # Build the JSON line with jq to guarantee valid escaping.
   LINE=$(jq -cn \
     --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
     --arg feature "$SLUG" \
     --argjson score "$SELF_ASSESSMENT_SCORE" \
     --arg category "$FRICTION_CATEGORY" \
     --arg note "$FRICTION_NOTE" \
     '{timestamp:$ts, feature:$feature, score:$score, category:$category, note:$note}')
   # mkdir is atomic on POSIX filesystems. Serializes concurrent retros.
   while ! mkdir "$LOCK_DIR" 2>/dev/null; do sleep 0.1; done
   trap 'rm -f "$LOG.tmp.$$"; rmdir "$LOCK_DIR" 2>/dev/null' EXIT
   # Atomic write: build the full new file in a temp, then rename.
   # `>>` can leave a partial line if the process is killed mid-append; rename is atomic on the same filesystem.
   TMP="$LOG.tmp.$$"
   { [ -f "$LOG" ] && cat "$LOG"; printf '%s\n' "$LINE"; } > "$TMP" && mv "$TMP" "$LOG"
   rmdir "$LOCK_DIR"
   trap - EXIT
   ```

   **Why temp+rename instead of `>>`**: an append interrupted by SIGKILL can produce a half-written JSONL line, which silently corrupts every downstream `jq -s` read of the log. `mv` on the same filesystem is atomic — readers see either the old file or the new one, never a torn write.

   If a stale lock dir blocks retros (e.g. after a killed process), remove it: `rmdir .claude/state/plan-w-team-friction-log.lock`.

   `$FRICTION_CATEGORY` must be one of: `spec-gap|builder-struggle|review-noise|hook-friction|hygiene|orchestrator-quality|other`. Reject any other value before the append — unknown categories defeat the 3-in-30-days pattern detection.

   When the friction category is ambiguous, route through the orchestrator for classification:

   ```bash
   # snippet-lint: skip — illustrative orchestrator routing
   FRICTION_CATEGORY=$(route_orchestrator retro-friction-categorize "$SLUG" \
     "friction_note=$FRICTION_NOTE" \
     "score=$SELF_ASSESSMENT_SCORE" \
     "options=spec-gap,builder-struggle,review-noise,hook-friction,hygiene,orchestrator-quality,other" \
     2>/dev/null || echo "other")
   ```

   <!-- Original: Lead manually chose friction category. Orchestrator classifies
        based on the friction note content and taxonomy.
        Fall-through: default to "other" if router unavailable. -->

2. **After 3 entries in the same category** accumulate within 30 days, surface at the next `/plan-w-team` preflight:

   ```
   ⚠ Friction pattern detected: category=<X> (3+ entries in 30d).
     Review .claude/state/plan-w-team-friction-log.jsonl and consider updating
     the relevant stage file before continuing.
   ```

3. **The user can dismiss with `.claude/state/plan-w-team-friction-ack-<category>`** (touch a file with the category name) if the pattern is intentional or already addressed. Dismissals expire after 30 days — chronic friction resurfaces.

This turns "write-only retro prose" into a lightweight feedback loop that updates the workflow without requiring the user to manually cross-reference old retros.

## 8j-bis. Orchestrator Decision Health

Read the per-SLUG decision JSONL to score how well the orchestrator performed during this run. This section was added by PWT-T2 to close the feedback loop between orchestrator decisions and retro assessment.

```bash
SLUG="<feature-slug>"
RETRO_DECISIONS=".claude/state/plan-w-team-orchestrator-decisions-$SLUG.jsonl"

if [ ! -f "$RETRO_DECISIONS" ]; then
  echo "Score: n/a (no orchestrator decisions — likely pre-upgrade SLUG or PLAN_W_TEAM_DISABLE_ORCHESTRATOR=1)"
else
  DECISIONS_TOTAL=$(wc -l < "$RETRO_DECISIONS" | tr -d ' ')
  DECISIONS_ESCALATED=$(grep -c '"escalate-to-user"' "$RETRO_DECISIONS" 2>/dev/null || echo 0)
  DECISIONS_FALLBACK=$(grep -c '"-fallback"' "$RETRO_DECISIONS" 2>/dev/null || echo 0)
  LOW_CONFIDENCE=$(jq -r 'select(.decision.confidence == "low") | .call_site' "$RETRO_DECISIONS" 2>/dev/null | wc -l | tr -d ' ')

  # Per-stage distribution
  DECISIONS_PER_STAGE=$(jq -r '.call_site' "$RETRO_DECISIONS" 2>/dev/null | sort | uniq -c | sort -rn)

  cat <<EOF
### Orchestrator Decision Health

- Decisions total: $DECISIONS_TOTAL
- Decisions escalated to user: $DECISIONS_ESCALATED
- Parse-failure fallbacks: $DECISIONS_FALLBACK
- Low-confidence decisions: $LOW_CONFIDENCE
- Per-stage distribution:
$(echo "$DECISIONS_PER_STAGE" | sed 's/^/  /')

EOF

  # Score: 5 = all decisions made, no fallbacks, no low-confidence
  #        4 = 1-2 fallbacks or low-confidence
  #        3 = 3+ fallbacks or escalations > 30% of total
  #        2 = majority escalated or fallback
  #        1 = orchestrator effectively disabled (all fallback)
  if [ "$DECISIONS_FALLBACK" -eq 0 ] && [ "$LOW_CONFIDENCE" -eq 0 ]; then
    ORCH_SCORE=5
  elif [ "$DECISIONS_FALLBACK" -le 2 ] && [ "$LOW_CONFIDENCE" -le 2 ]; then
    ORCH_SCORE=4
  elif [ "$DECISIONS_ESCALATED" -gt $((DECISIONS_TOTAL / 3)) ]; then
    ORCH_SCORE=3
  elif [ "$DECISIONS_ESCALATED" -gt $((DECISIONS_TOTAL / 2)) ]; then
    ORCH_SCORE=2
  else
    ORCH_SCORE=3
  fi

  echo "Score: $ORCH_SCORE/5"

  # Feed low scores into friction log
  if [ "$ORCH_SCORE" -lt 4 ]; then
    echo "⚠ Orchestrator decision quality below threshold — feeding into friction log"
    # Category: orchestrator-quality
  fi
fi
```

Report in retro: `Orchestrator decision health: <ORCH_SCORE>/5 (total=<N>, escalated=<N>, fallback=<N>, low-confidence=<N>)`.

A score <4 feeds `§8i` friction log with category `orchestrator-quality`. Recurring low scores suggest the classifier table needs rebalancing — review the per-stage distribution to identify which call sites are producing low-confidence or fallback decisions.

## 8j-ter. Fleet Parallelism Health

Read the per-SLUG fleet log to score how well parallelism was achieved during execution. Added by PWT-T3 to close the feedback loop between Step 3-4 spawn decisions and retro assessment.

```bash
SLUG="<feature-slug>"
FLEET_LOG=".claude/state/plan-w-team-fleet-$SLUG.jsonl"
FLEET_INTENT=".claude/state/plan-w-team-fleet-intent-$SLUG.jsonl"

if [ ! -f "$FLEET_LOG" ]; then
  echo "Score: n/a (no fleet log — likely lead-implements-directly run or PLAN_W_TEAM_FLEET_DISABLE=1)"
else
  SUMMARY=$(.claude/scripts/plan-w-team-fleet-query.sh summary "$SLUG")
  SPAWNED=$(echo "$SUMMARY" | jq -r '.spawned')
  COMPLETED=$(echo "$SUMMARY" | jq -r '.completed')
  FAILED=$(echo "$SUMMARY" | jq -r '.failed')
  MAX_CONCURRENT=$(echo "$SUMMARY" | jq -r '.max_concurrent')

  # Total wall-clock seconds from first spawn to last complete event
  FIRST_TS=$(jq -r 'select(.event=="spawn") | .ts' "$FLEET_LOG" | sort | head -1)
  LAST_TS=$(jq -r 'select(.event=="complete") | .ts' "$FLEET_LOG" | sort | tail -1)
  if [ -n "$FIRST_TS" ] && [ -n "$LAST_TS" ]; then
    DURATION_S=$(( $(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$LAST_TS" +%s) - $(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$FIRST_TS" +%s) ))
  else
    DURATION_S=0
  fi

  # Parallelism efficiency: max_concurrent / spawned approximates how
  # batched-vs-streamed the dispatch was. Proper time-weighted ∫concurrent dt
  # would need a finer-grained calculation; this is the MVP heuristic.
  if [ "$SPAWNED" -gt 0 ]; then
    PCT=$(( MAX_CONCURRENT * 100 / SPAWNED ))
  else
    PCT=0
  fi

  cat <<EOF
### Fleet Parallelism Health

- Agents spawned: $SPAWNED
- Agents completed: $COMPLETED
- Errors (hook-detected payload gaps): $FAILED
- Max concurrent: $MAX_CONCURRENT
- Wall-clock duration: ${DURATION_S}s
- Parallelism heuristic: $PCT% (max_concurrent / spawned)

EOF

  # Score: 5 = max_concurrent == spawned (perfect parallel)
  #        4 = >= 75% parallelism
  #        3 = 50-74%
  #        2 = 25-49% (mostly serial)
  #        1 = <25% (batch-wait heavy)
  if [ "$PCT" -ge 95 ]; then
    FLEET_SCORE=5
  elif [ "$PCT" -ge 75 ]; then
    FLEET_SCORE=4
  elif [ "$PCT" -ge 50 ]; then
    FLEET_SCORE=3
  elif [ "$PCT" -ge 25 ]; then
    FLEET_SCORE=2
  else
    FLEET_SCORE=1
  fi

  echo "Score: $FLEET_SCORE/5"

  # Identify tasks that could have spawned earlier (intent-aware analysis,
  # only available when the lead used Pattern B continuous dispatch in 03-execute)
  if [ -f "$FLEET_INTENT" ]; then
    LATE_SPAWNS=$(jq -s '[.[] | select(.event != null)] | length' "$FLEET_INTENT" 2>/dev/null || echo 0)
    [ "$LATE_SPAWNS" -gt 0 ] && echo "Intent sidecar present: $LATE_SPAWNS dispatched tasks (full timing analysis available)"
  fi

  if [ "$FLEET_SCORE" -lt 3 ]; then
    echo "⚠ Parallelism below 50% — consider Pattern B continuous dispatch in 03-execute.md for future runs"
  fi
fi

# Cleanup on successful retro completion (mirrors baseline-file cleanup)
if [ "${RETRO_SUCCESS:-0}" = "1" ]; then
  rm -f "$FLEET_LOG" "$FLEET_INTENT"
fi
```

Report in retro: `Fleet parallelism health: <FLEET_SCORE>/5 (spawned=<N>, max_concurrent=<N>, duration=<N>s)`.

A score <3 suggests batch-fan-out waste. The retro recommendation is Pattern B continuous dispatch (`shared/fleet-manager.md` §Query Subcommand Reference). For lead-implements-directly runs or runs with `PLAN_W_TEAM_FLEET_DISABLE=1`, this section is n/a — no parallelism to measure.

## 8j-quater. Supervisor Decision Health

Read the per-SLUG supervisor-actions JSONL to score how well the persistent supervisor (PWT-T4) performed during this run. Added by PWT-T4 to close the feedback loop between supervisor dispatch decisions and retro assessment. Mirrors §8j-bis (orchestrator) and §8j-ter (fleet) scoring patterns.

```bash
SLUG="<feature-slug>"
SUP_LOG=".claude/state/plan-w-team-supervisor-actions-$SLUG.jsonl"

if [ ! -f "$SUP_LOG" ]; then
  echo "Score: n/a (no supervisor invocation — PLAN_W_TEAM_SUPERVISOR was off or kill switch was on)"
else
  SUP_TOTAL=$(wc -l < "$SUP_LOG" | tr -d ' ')
  SPAWN_DECISIONS=$(grep -c '"event":"spawn_decision"' "$SUP_LOG" 2>/dev/null || echo 0)
  ROUTE_DELEGATIONS=$(grep -c '"event":"route_delegation"' "$SUP_LOG" 2>/dev/null || echo 0)
  ESCALATIONS=$(grep -c '"event":"escalation"' "$SUP_LOG" 2>/dev/null || echo 0)
  LOW_CONFIDENCE_ROUTES=$(jq -r 'select(.event == "route_delegation" and .router_confidence == "low") | .call_site' "$SUP_LOG" 2>/dev/null | wc -l | tr -d ' ')

  STOP_REASON=$(jq -r 'select(.event == "supervisor_stop") | .reason' "$SUP_LOG" 2>/dev/null | tail -1)
  DURATION_S=$(jq -r 'select(.event == "supervisor_stop") | .duration_s' "$SUP_LOG" 2>/dev/null | tail -1)

  cat <<EOF
### Supervisor Decision Health

- Total supervisor actions: $SUP_TOTAL
- Spawn decisions: $SPAWN_DECISIONS
- Route delegations: $ROUTE_DELEGATIONS
- Hard-gate escalations: $ESCALATIONS
- Low-confidence router decisions: $LOW_CONFIDENCE_ROUTES
- Stop reason: $STOP_REASON
- Duration: ${DURATION_S}s

EOF

  # Score: 5 = supervisor ran clean (all-tasks-complete stop, no low-confidence routes,
  #            escalations only on documented hard-gate sites)
  #        4 = 1-2 low-confidence routes; otherwise clean
  #        3 = escalation count > 1 (multiple hard-gates hit in one run) OR 3+ low-confidence
  #        2 = supervisor stopped on error reason
  #        1 = supervisor effectively non-functional (no spawn_decision rows at all)
  if [ "$SPAWN_DECISIONS" -eq 0 ]; then
    SUP_SCORE=1
  elif [[ "$STOP_REASON" == error:* ]]; then
    SUP_SCORE=2
  elif [ "$ESCALATIONS" -gt 1 ] || [ "$LOW_CONFIDENCE_ROUTES" -gt 2 ]; then
    SUP_SCORE=3
  elif [ "$LOW_CONFIDENCE_ROUTES" -ge 1 ]; then
    SUP_SCORE=4
  else
    SUP_SCORE=5
  fi

  echo "Score: $SUP_SCORE/5"

  if [ "$SUP_SCORE" -lt 4 ]; then
    echo "⚠ Supervisor decision quality below threshold — feeding into friction log"
    # Category: supervisor-quality
  fi
fi

# §8j-quinquies reads the /goal terminal state from the goal-state file, but the
# cleanup below deletes it — capture into locals BEFORE the rm -f (see §8j-quinquies).
GOAL_TERMINAL_STATE=$(jq -r '.terminal_state // "n/a"' ".claude/state/plan-w-team-goal-${SLUG}.json" 2>/dev/null || echo "n/a")
GOAL_TERMINAL_REASON=$(jq -r '.terminal_reason // empty' ".claude/state/plan-w-team-goal-${SLUG}.json" 2>/dev/null || echo "")

# Cleanup on successful retro (mirrors §8j-ter fleet cleanup)
if [ "${RETRO_SUCCESS:-0}" = "1" ]; then
  rm -f "$SUP_LOG"
  rm -f ".claude/state/plan-w-team-goal-${SLUG}.json"   # T5b goal evaluator state (idempotent — §8j-quinquies reads the GOAL_TERMINAL_* locals captured above)
  # B4 (1.33.0): remove this run's retired secret-scan allow-file so it cannot mask a
  # real secret at the same path:line in a FUTURE run. (pre-commit-quality.sh's age check
  # is the backstop for abandoned features; this is the clean per-run retirement the
  # "remove retired allow-files in retro" instruction always promised.) Also drop the
  # net-new-surface docs-waiver list — both are per-run curation, not durable state.
  rm -f ".claude/state/plan-w-team-secret-scan-allow-${SLUG}"   # B4 retired allow-file
  rm -f ".claude/state/plan-w-team-docs-waived-${SLUG}.txt"     # A1/A6 per-run waiver
  # SA-2 (2026-06-08): retire this run's credential-wall artifact. The ship gate
  # (6a-quinquies) GLOBS plan-w-team-credwall-*.json and blocks on ANY resolved:false,
  # so a stale/false-positive wall left behind fails the NEXT run's ship gate closed
  # (reproduced live: gate exit=1 on a leftover marker). Reaching retro means we shipped
  # past that gate, so the wall is resolved or moot → safe to remove. Clean this run's
  # slug AND the legacy literal "active" the detector defaults to when no slug is known.
  rm -f ".claude/state/plan-w-team-credwall-${SLUG}.json"       # SA-2 per-run credential-wall marker
  rm -f ".claude/state/plan-w-team-credwall-active.json"        # SA-2 legacy default-slug marker

  # Janitor pass: sweep up leftover SUCCESS goal files — this run's now-shipped
  # state plus any older SUCCESS files from runs whose own retro cleanup never
  # fired. Uses the SINGLE reconciled janitor (plan-w-team-cleanup-stale-goal-states.sh,
  # also called by session-start): it removes ONLY terminal_state=SUCCESS and
  # PRESERVES USER_ESCALATION_HALT / LOW_CONFIDENCE_STREAK / DEAD goal-states for
  # inspection. (Previously this called a second all-terminal cleaner that deleted
  # those escalation/dead states across OTHER runs — a cross-run data-loss bug fixed
  # 2026-06-08 by collapsing to one SUCCESS-only janitor.) Fail-open, idempotent,
  # never blocks retro completion.
  if [ -x .claude/scripts/plan-w-team-cleanup-stale-goal-states.sh ]; then
    .claude/scripts/plan-w-team-cleanup-stale-goal-states.sh --quiet 2>/dev/null || true
  fi

  # Canonical run-manifest + stage-event stream are per-run state — remove them
  # alongside the goal/fleet files. They live in the MAIN checkout, so resolve
  # the path via the helper (retro runs in the worktree). The run's terminal
  # state is already authoritative in the goal-*.json the supervisor read this
  # tick, so nothing is lost. Fail-open.
  if [ -x .claude/scripts/pwt-manifest.sh ]; then
    MANI_PATH="$(.claude/scripts/pwt-manifest.sh path --slug "$SLUG" 2>/dev/null || echo "")"
    if [ -n "$MANI_PATH" ]; then
      rm -f "$MANI_PATH" "$(dirname "$MANI_PATH")/plan-w-team-stage-events-${SLUG}.jsonl" 2>/dev/null || true
    fi
  fi
fi
```

Report in retro: `Supervisor decision health: <SUP_SCORE>/5 (spawns=<N>, delegations=<N>, escalations=<N>, stop=<reason>)`.

A score <4 feeds friction log with category `supervisor-quality`. Recurring low scores suggest the supervisor's system prompt needs refinement — review the action log to identify whether dispatch logic, delegation discipline, or escalation classification was the issue.

## 8j-quinquies. `/goal` Evaluator Health

When `/plan-w-team` was opened with `/goal` at the top (PWT-T5; default unless `PLAN_W_TEAM_DISABLE_GOAL=1`), score how well the evaluator drove the pipeline to a terminal state. Mirrors §8j-bis / §8j-ter / §8j-quater scoring patterns.

```bash
SLUG="<feature-slug>"

# Authoritative terminal state lives in .claude/state/plan-w-team-goal-<SLUG>.json
# (terminal_state / terminal_reason — shared/goal-conditions.md). §8j-quater's
# cleanup deletes that file EARLIER in this stage, so read the locals it captured
# before its rm -f ($GOAL_TERMINAL_STATE / $GOAL_TERMINAL_REASON); fall back to
# the transcript's terminal-state block only if the capture is empty.
#
# If /goal was disabled (PLAN_W_TEAM_DISABLE_GOAL=1) or unavailable
# (pre-2.1.139 Claude Code), report n/a.

if [ "${PLAN_W_TEAM_DISABLE_GOAL:-}" = "1" ]; then
  echo "Score: n/a (PLAN_W_TEAM_DISABLE_GOAL=1 — /goal wrapper skipped)"
else
  # Terminal state is one of: SUCCESS, USER_ESCALATION_HALT, LOW_CONFIDENCE_STREAK
  # (TIME_OR_TURN_CAP was removed by design — no wall-clock or turn caps in the evaluator.)
  # The lead surfaces the terminal reason at retro time by quoting /goal's final reason text.

  cat <<EOF
### /goal Evaluator Health

- Terminal state: ${GOAL_TERMINAL_STATE:-n/a}
- Evaluator reason on terminal turn: ${GOAL_TERMINAL_REASON:-<quote the transcript's terminal-state block>}
- Pipeline duration: <wall-clock — reporting only, NOT a termination signal>

EOF

  # Score: 5 = SUCCESS (clean autonomous run — pipeline reached retro-complete)
  #        3 = USER_ESCALATION_HALT (expected hard-gate; not a failure)
  #        1 = LOW_CONFIDENCE_STREAK (supervisor was confused, evaluator halted)
  #
  # The lead sets GOAL_SCORE manually after reading the terminal reason.
  # Future enhancement: parse /goal's structured output if Anthropic exposes it.

  echo "Score: <GOAL_SCORE>/5"

  if [ "${GOAL_SCORE:-5}" -lt 4 ]; then
    echo "⚠ /goal evaluator health below threshold — feeding into friction log"
    # Category: goal-evaluator-quality
  fi
fi
```

Report in retro: `/goal evaluator health: <GOAL_SCORE>/5 (terminal=<state>, turns=<N>)`.

A score <4 feeds friction log with category `goal-evaluator-quality`. Recurring low scores suggest either:

- The terminal condition in `shared/goal-conditions.md` is too strict (false negatives — evaluator never says yes even when pipeline is done)
- The transcript-surfacing helpers (status block + supervisor summary block) aren't emitting the anchors the condition looks for
- The pipeline is genuinely stuck (real failures the supervisor should have escalated)

Investigate by reading the most recent supervisor-actions log and the final few `status` / `summary` blocks the helper emitted.

## 8j-sexies. Spawned-Children Cleanup

Stop any `claude --bg` children this run spawned. Without this, autonomous launches accumulate background sessions across runs (the 2026-05-20 incident left 19 background agents alive before discovery). Fire-and-forget — failed `claude stop` calls do not block retro completion.

Cleanup runs BEFORE the End-of-Stage Status Block so the `retro-complete` anchor only appears after children are stopped. The cleanup logic lives in a helper script (`.claude/scripts/plan-w-team-child-cleanup.sh`) with its own tests (`plan-w-team-child-cleanup.test.sh`, plus `plan-w-team-child-cleanup-supervisor-mirror.test.sh` for the mirror branch).

**Supervisor-mirror handling**: registry rows with `type=supervisor_mirror` represent origin-chat mirror goal-state files written by `pwt-goal.sh --supervisor-goal`. Cleanup detects these rows and jq-patches the mirror file at the row's `path` field with `terminal_state=SUCCESS`, `terminal_reason="auto-synced from worker retro"`, `terminated_at=<ISO8601>` — instead of invoking `claude stop`. This closes the lifecycle gap where the mirror previously stayed `terminal_state=null` forever after the worker shipped. See `docs/specs/supervisor-mirror-lifecycle.md`.

```bash
SLUG="<feature-slug>"
REGISTRY=".claude/state/plan-w-team-spawned-children-${SLUG}.jsonl"

# Helper emits a single-line JSON document to stdout describing the run.
# It honors PLAN_W_TEAM_DISABLE_CHILD_CLEANUP=1, tolerates missing registries
# and malformed JSONL rows, and never exits non-zero (fail-open).
#
# C8 lineage reconciliation: pass THIS session's own id so the helper also reaps
# children registered under a different slug (pwt-goal registers a spawned
# worker under __pwt_safe_slug(ORIGINAL_REQUEST), which can differ from the
# feature SLUG used here). Resolved from CLAUDE_JOB_DIR's basename; empty when
# unavailable, in which case reconciliation no-ops and only the exact-SLUG
# registry is reaped (no regression). Concurrent-run-safe: only rows whose
# parent_session_id matches this session are touched.
PWT_SELF_SID="${CLAUDE_JOB_DIR##*/}"
CHILD_CLEANUP_JSON=$(PWT_CLEANUP_PARENT_SID="$PWT_SELF_SID" .claude/scripts/plan-w-team-child-cleanup.sh "$SLUG")

# Surface a one-liner for human observation. The helper's full output is
# captured above and persisted to RETRO_STATE below.
SKIPPED=$(printf '%s' "$CHILD_CLEANUP_JSON" | jq -r '.skipped // false')
if [ "$SKIPPED" = "true" ]; then
  REASON=$(printf '%s' "$CHILD_CLEANUP_JSON" | jq -r '.reason // "unknown"')
  echo "✓ child cleanup skipped: $REASON"
else
  STOPPED=$(printf '%s' "$CHILD_CLEANUP_JSON" | jq -r '.stopped // 0')
  NOOP=$(printf '%s' "$CHILD_CLEANUP_JSON" | jq -r '.noop // 0')
  REGISTERED=$(printf '%s' "$CHILD_CLEANUP_JSON" | jq -r '.registered // 0')
  echo "✓ child cleanup: $STOPPED stopped, $NOOP no-op (likely already finished), $REGISTERED total"
fi

# Persist into the retro JSON's quality_signals
RETRO_STATE=".claude/state/plan-w-team-retro-${SLUG}.json"
if [ -f "$RETRO_STATE" ]; then
  TMP=$(mktemp "${RETRO_STATE}.tmp.XXXXXX")
  jq --argjson cleanup "$CHILD_CLEANUP_JSON" \
    '.quality_signals.spawned_children_cleanup = $cleanup' \
    "$RETRO_STATE" > "$TMP" 2>/dev/null && mv "$TMP" "$RETRO_STATE" || rm -f "$TMP"
else
  jq -n --argjson cleanup "$CHILD_CLEANUP_JSON" \
    '{quality_signals:{spawned_children_cleanup:$cleanup}}' \
    > "$RETRO_STATE" 2>/dev/null || true
fi

# Cleanup the registry file on successful retro (mirrors §8j-ter / §8j-quater pattern).
if [ "${RETRO_SUCCESS:-0}" = "1" ]; then
  rm -f "$REGISTRY"
fi
```

**Kill switch:** `PLAN_W_TEAM_DISABLE_CHILD_CLEANUP=1` skips the loop entirely. Useful when:

- Debugging a child session and you want to keep it alive past the parent's retro.
- Running the retro on a SLUG whose children you've already stopped manually.
- A `claude` CLI bug makes `claude stop` hang (escape hatch).

The cleanup is intentionally fire-and-forget: a `claude stop` that fails because the child has already finished is the normal case, not an error. The retro JSON records every attempt so a forensics pass can cross-check against `claude agents` to confirm no orphans survived.

## 8j-septies. Worktree + Companion-Process Cleanup

`§8j-sexies` stops the bg child _sessions_; this block reclaims the _filesystem + processes_ they leave behind. Without it, every run leaves an `agent-<sid>/` worktree dir (node_modules and all) plus a `pane-display.py` spinner and `pwt-watch.sh` watcher running indefinitely — the disk-hygiene gap that motivated `docs/operations/worktree-lifecycle.md`. Runs fire-and-forget; nothing here blocks the `retro-complete` anchor.

This sweep is scoped to THIS run's subagents (`--scope subagents-of-current-run`) plus a companion-process pass. The repo-wide accumulated-debt sweep is the weekly launchd job, not the retro.

```bash
SLUG="<feature-slug>"

# 1. Subagent worktrees of THIS run (safety invariants enforced inside the GC:
#    never touches uncommitted / in-use / non-.claude-worktrees paths).
#    PWT_WORKTREE_GC_IGNORE_LOCKS=1: the run is over, so any lock still held by
#    one of this run's own subagents is stale (its SubagentStop unlock was
#    missed). Real uncommitted work and genuinely-live sessions are still kept —
#    only the orphaned lock signal is disregarded for this scoped sweep.
if [ -x .claude/scripts/plan-w-team-worktree-gc.sh ]; then
  WT_GC_JSON=$(PWT_WORKTREE_GC_IGNORE_LOCKS=1 .claude/scripts/plan-w-team-worktree-gc.sh \
      --scope subagents-of-current-run --execute --json 2>/dev/null || echo '{}')
  WT_REMOVED=$(printf '%s' "$WT_GC_JSON" | jq -r '.totals.removed // 0' 2>/dev/null || echo 0)
  echo "✓ worktree GC (subagents-of-this-run): $WT_REMOVED removed"
fi

# 2. Orphan companion processes (pane-display.py spinners + pwt-watch.sh watchers).
if [ -x .claude/scripts/plan-w-team-companion-gc.sh ]; then
  COMP_GC_JSON=$(.claude/scripts/plan-w-team-companion-gc.sh --execute --json 2>/dev/null || echo '{}')
  COMP_KILLED=$(printf '%s' "$COMP_GC_JSON" | jq -r '.totals.killed // 0' 2>/dev/null || echo 0)
  echo "✓ companion GC: $COMP_KILLED orphan processes reaped"
fi

# Persist both into the retro JSON's quality_signals (advisory, never fatal).
RETRO_STATE=".claude/state/plan-w-team-retro-${SLUG}.json"
if [ -f "$RETRO_STATE" ] && command -v jq >/dev/null 2>&1; then
  TMP=$(mktemp "${RETRO_STATE}.tmp.XXXXXX")
  jq --argjson wt "${WT_GC_JSON:-{}}" --argjson comp "${COMP_GC_JSON:-{}}" \
    '.quality_signals.worktree_gc = $wt | .quality_signals.companion_gc = $comp' \
    "$RETRO_STATE" > "$TMP" 2>/dev/null && mv "$TMP" "$RETRO_STATE" || rm -f "$TMP"
fi
```

**Kill switches:** `PWT_WORKTREE_GC_DISABLE=1` and `PWT_COMPANION_GC_DISABLE=1` each no-op their respective sweep. Both default ON. See `docs/operations/worktree-lifecycle.md` for the full lifecycle contract, the per-merge cleanup path (`§Step 6 ship`), and how to install the weekly accumulated-debt GC.

## 8j-octies. Stage-File Bypass Rate (quality signal — P1)

Counts the `⚠ stage-file-bypass:` markers the lead appended to the run's bypass log (`plan-w-team.md` Fast Path) and records a 1-5 `bypass_rate` signal into the retro JSON. This is the deterministic half of P1: marker _emission_ is still lead-driven (a floor — a silently-skipped Read that never emitted a marker is not caught), but the _counting_ is now real and testable, replacing the previously fictional "retros MAY count" prose. Advisory; never blocks the retro.

```bash
SLUG="<feature-slug>"
RETRO_STATE=".claude/state/plan-w-team-retro-${SLUG}.json"
if [ -x .claude/scripts/plan-w-team-bypass-rate.sh ]; then
  BYPASS_JSON=$(.claude/scripts/plan-w-team-bypass-rate.sh --slug "$SLUG" 2>/dev/null || echo '{"count":0,"score":5,"source":"none"}')
  BYPASS_COUNT=$(printf '%s' "$BYPASS_JSON" | jq -r '.count // 0')
  BYPASS_SCORE=$(printf '%s' "$BYPASS_JSON" | jq -r '.score // 5')
  echo "✓ stage-file-bypass: count=$BYPASS_COUNT score=$BYPASS_SCORE/5"
  if [ -f "$RETRO_STATE" ] && command -v jq >/dev/null 2>&1; then
    TMP=$(mktemp "${RETRO_STATE}.tmp.XXXXXX")
    jq --argjson b "$BYPASS_JSON" '.quality_signals.bypass_rate = $b' \
      "$RETRO_STATE" > "$TMP" 2>/dev/null && mv "$TMP" "$RETRO_STATE" || rm -f "$TMP"
  fi
  # On a successful retro, clear the run's bypass log (mirrors other §8j cleanups).
  if [ "${RETRO_SUCCESS:-0}" = "1" ]; then
    rm -f ".claude/state/plan-w-team-bypass-${SLUG}.log"
  fi
fi
```

A `bypass_rate.score` below 5 means the lead skipped at least one stage-file Read outside the fast path — investigate whether the stage files need consolidation or the fast-path criterion (HOLD + ≤2 tasks) should widen.

## 8j-nonies. Spec Fan-Out Catch-Rate (advisory — C1 pilot)

When the Step-1 multi-angle spec fan-out ran (`PLAN_W_TEAM_SPEC_FANOUT=1`, §1b-pre),
read its advisory record to score whether the fan-out earned its keep. This is the
marginal-catch-rate signal the pilot gathers before the fan-out is promoted to
default-ON. **n/a when the fan-out was off (the default)** — never blocks retro.

```bash
SLUG="<feature-slug>"
FANOUT_STATE=".claude/state/plan-w-team-spec-fanout-${SLUG}.json"
if [ ! -f "$FANOUT_STATE" ]; then
  echo "Spec fan-out score: n/a (fan-out off — default — or no record)"
else
  FOLDED=$(jq -r '.findings_folded // 0' "$FANOUT_STATE" 2>/dev/null || echo 0)
  DEFERRED=$(jq -r '.findings_deferred // 0' "$FANOUT_STATE" 2>/dev/null || echo 0)
  echo "Spec fan-out: ${FOLDED} findings folded pre-freeze, ${DEFERRED} deferred."
  echo "  → If folded≈0 across several runs, the fan-out is not earning its cost;"
  echo "    keep PLAN_W_TEAM_SPEC_FANOUT default-OFF. If consistently >0 on real"
  echo "    requirement/AC gaps, that is the evidence to promote it toward default-ON."
fi
```

## 8j-decies. Recursive-Improvement Capture (EVERY full run — Deliverable 3)

This is the section that makes recursive improvement a **guaranteed property of every
run**, not an optional, remembered-only step. The §8j-bis…octies scorers above capture
SUCCESS-oriented signals, and §8i logs friction _only_ when self-assessment <8 — so a run
that "felt fine" surfaces no struggles, and no section checks this run's best-practice
**adherence against the prior run** to flag a regression. This block closes both gaps. It
runs on **every full run** (not gated on score) and is strictly ADDITIVE — it consumes the
retro JSON the §8j sections already wrote and never mutates their outputs.

Run the capture helper, passing this run's honest self-assessment plus any
weaknesses / struggles / gaps / follow-ups the lead observed (these are the qualitative
signals no scorer can compute — the lead surfaces them from the run's actual experience):

```bash
SLUG="<feature-slug>"
.claude/scripts/plan-w-team-retro-capture.sh --slug "$SLUG" \
  --self-assessment "<0-10 from §8i, or omit to read from retro JSON>" \
  --weakness  "<a real weakness/struggle this run exposed>"   `# repeatable; omit if none` \
  --gap       "<a coverage/spec/process gap this run exposed>" `# repeatable; omit if none` \
  --follow-up "<a concrete next-run improvement>"             `# repeatable; omit if none`
```

The helper:

1. Reads the run's best-practice adherence (`bypass_rate`, `doc_hygiene`, `untracked_hygiene`)
   from the retro JSON and **compares it to the most-recent prior run** (rolling history at
   `.claude/state/plan-w-team-retro-capture-history.jsonl`). Any signal that dropped vs the
   prior run sets `regression_flag: true` and names the regressed signal.
2. Always emits a capture record (empty `weaknesses`/`gaps`/`follow_ups` arrays are valid —
   an honest "no struggles this run" is a real datum, never a skipped block).
3. Turns findings into **queued follow-ups**: each `--follow-up`, plus auto follow-ups for a
   `<8` self-assessment and for any regression, is appended to the durable cross-run queue
   `.claude/state/plan-w-team-recursive-followups.jsonl` (status `open`). This is the
   "informed retro → next run is better" loop — the next run's preflight surfaces these.
4. When self-assessment `<8`, emits `investigate_and_update` — a concrete instruction to
   investigate the lowest signal and update the responsible stage file, **not just a number**
   (the §8i rule, now enforced as a structured field + a queued follow-up).

Persist the capture into the retro JSON for the rollup (advisory; never fatal):

```bash
RETRO_STATE=".claude/state/plan-w-team-retro-${SLUG}.json"
CAPTURE=".claude/state/plan-w-team-retro-capture-${SLUG}.json"
if [ -f "$RETRO_STATE" ] && [ -f "$CAPTURE" ] && command -v jq >/dev/null 2>&1; then
  TMP=$(mktemp "${RETRO_STATE}.tmp.XXXXXX")
  jq --slurpfile c "$CAPTURE" '.quality_signals.recursive_capture = $c[0]' \
    "$RETRO_STATE" > "$TMP" 2>/dev/null && mv "$TMP" "$RETRO_STATE" || rm -f "$TMP"
fi
```

**Mandatory follow-through (not advisory):** if the capture record has `regression_flag: true`
OR `investigate_and_update != null`, the run MUST act on it before emitting `retro-complete` —
either fix it now (preferred, per the fix-immediately rule) or confirm the auto-queued
follow-up is recorded in the cross-run log. A regression in a best-practice signal is the
exact "best-practice regression" the brief asks every retro to catch.

Report in retro:
`Recursive capture: weaknesses=<N> gaps=<N> follow_ups=<N> regression=<bool> self_assessment=<N>`.

**Kill switch:** `PLAN_W_TEAM_DISABLE_RECURSIVE_CAPTURE=1` skips this block (the helper is
observability and stays safe to call; invocation here is optional in that mode).

**Cleanup (per-run vs durable):** on a successful retro, remove only the per-run capture file
— the rolling `*-history.jsonl` and `*-recursive-followups.jsonl` are **cross-run durable**
state (the whole point is to compare against and carry forward), so they are NEVER deleted here.

```bash
if [ "${RETRO_SUCCESS:-0}" = "1" ]; then
  rm -f ".claude/state/plan-w-team-retro-capture-${SLUG}.json"
fi
```

## 8j. Auto-Memory Hints (advisory)

Claude Code 2.1.x ships **Auto Memory** — a per-project memory store at `~/.claude/projects/<project>/memory/` that Claude's memory module manages on its own. The module reads conversation context and decides what's worth persisting. /plan-w-team does **not** write to memory files directly — Claude owns that decision.

What the retro _can_ do is **surface candidate patterns** worth remembering, in the conversation flow that Claude's memory module reads. This sub-step emits 1-2 lines of memory-candidate prose; the module then chooses whether to persist.

### What qualifies as a memory candidate

Pull from §8c quality signals, §8f friction log, §8g evaluator iteration health, and §8i self-assessment notes. The good candidates are **non-obvious, durable, and cross-feature applicable**:

- ✅ A recurring friction mode (e.g., "PostToolUse formatter races with mid-edit reads — Read before re-Edit when the formatter is active") — survives across features.
- ✅ A surprising heuristic that worked (e.g., "Splitting 5 similar implementations into 2 /plan-w-team runs of 2-3 each beat 1 run of 5 every time") — informs future scope decisions.
- ✅ A subtle constraint discovered during build (e.g., "Agent tool's `model` parameter only accepts aliases — full IDs go in agent frontmatter") — easy to forget, costly to relearn.
- ❌ Feature-specific implementation detail (e.g., "the new alerting service uses Redis"). That's in the code and git history.
- ❌ Routine successes ("build passed, tests green"). Not memorable.
- ❌ Anything already documented in CLAUDE.md or a shared/ file. Memory is for what isn't already written down.

### Emission format

Append to the retro narrative — a paragraph headed `### Memory candidates`:

```markdown
### Memory candidates

- **<one-line pattern>** — Why: <reason this pattern emerged>. How to apply: <where this matters next time>.
- **<one-line pattern>** — Why: <…>. How to apply: <…>.
```

Two bullets is the cap. If nothing rises above the bar, write `_(none worth memorializing this run)_` and move on. Pattern-fishing produces noise; the memory module rejects noise on its own, but it wastes the surface.

### Why advisory, not prescriptive

The skill cannot reliably know what is or isn't already in memory — the `~/.claude/projects/<project>/memory/MEMORY.md` index is per-user, not per-repo. Even if the skill could read it, deciding what's worth saving is judgment work the memory module is designed for. /plan-w-team's role is to **surface the signal**; the module decides. If the module ignores the hint, no harm done — the friction log (§8i) and BOARD.md (§Board Comment Auto) remain the skill's authoritative retro outputs.

This sub-step adds zero state files and no enforcement gates. It is pure prose appended to the retro section.

## 8k. Completion Summary Emission

Immediately before the terminal status block, emit the **completion summary** — a structured record of what this run accomplished. The summary aggregates AC PASS/FAIL roll-up, files changed (git diff --stat), commits authored, tests added/modified, ship-readiness verdict, total wall-clock duration, and the **spec-compliance holistic check**. Together these are the canonical archival record of the run.

```bash
.claude/scripts/plan-w-team-completion-summary.sh "$SLUG"
```

The writer:

1. Reads the AC snapshot at `.claude/state/plan-w-team-ac-snapshot-${SLUG}.md` for the **declared** AC list (frozen at Step 1 §1.5; not the live spec).
2. Discovers the worker transcript via `$CLAUDE_TRANSCRIPT_PATH` → `$CLAUDE_PROJECT_DIR/*.jsonl` (last 24h) → `~/.claude/projects/*/*.jsonl` (last 24h) heuristic.
3. Scans the transcript for `AC<N>: PASS` and `AC<N>: FAIL` verdicts (strict format — see `docs/specs/reporting-holistic-check.md` for why looser patterns produce false positives).
4. Computes the **holistic check** outcome (one of `HOLISTIC_CHECK_PASS|FAIL|SKIPPED|UNKNOWN`) and emits the literal anchor in the markdown summary.
5. Reads `git log` + `git diff --shortstat` for files-changed / commits / line-deltas relative to the worktree base.
6. Counts test files modified by extension/path patterns (`.test.*`, `.spec.*`, `.bats`, `_test.go`, `_test.py`).
7. Writes two artifacts atomically:
   - `.claude/state/plan-w-team-completion-${SLUG}.json` (machine-readable, schema versioned via `writer_version`).
   - `.claude/state/plan-w-team-completion-${SLUG}.md` (human-readable; `## Spec Compliance Check` section contains the literal `HOLISTIC_CHECK_*` anchor for downstream grep).

### Why this runs before retro-complete

The summary must appear in the same transcript window as the `stage="retro-complete"` anchor so the run record is self-contained: anyone reading the transcript or grepping the goal-evaluator's window sees both. Placing it after retro-complete would orphan the summary (the `/goal` evaluator would have already cleared the goal state).

### Safety contract

The writer follows the universal `R10` rule for /plan-w-team observability scripts: **never fail the retro**. On any internal error (missing transcript, malformed snapshot, jq unavailable), the writer emits a degraded stub JSON + markdown with `HOLISTIC_CHECK_UNKNOWN` and exits 0. Only a missing SLUG argument (caller-bug) produces a non-zero exit (`2`).

### Kill switch

`PLAN_W_TEAM_DISABLE_COMPLETION_SUMMARY=1` skips the writer entirely. Useful when:

- Iterating on retro-stage behavior and the summary's transcript scan churns noise.
- Recovering from a writer regression that produces malformed output (the artifacts can be regenerated later with the next /plan-w-team run on the SLUG).

```bash
if [ "${PLAN_W_TEAM_DISABLE_COMPLETION_SUMMARY:-}" != "1" ]; then
  .claude/scripts/plan-w-team-completion-summary.sh "$SLUG" || true
fi
```

### Spec compliance & downstream consumers

The completion-summary doc's `## Spec Compliance Check` section is the run's **retrospective** of the same contract enforced live by the `/goal` evaluator's `feature_specific_done_criteria` (Step 1 §1.5 / `shared/goal-conditions.md` §Feature-Specific Done Criteria). The evaluator gates the SUCCESS terminal state _while the run is in flight_; the holistic check audits the same coverage _after the fact_ for the archival record. Any future audit/dashboard tooling that wants to query "what did this run actually accomplish" reads the JSON; any human reading a single run looks at the markdown.

Full design: `docs/specs/reporting-holistic-check.md`.
Writer spec: `docs/specs/retro-completion-summary.md`.

## End-of-Stage Status Block (PWT-T5)

The final action of the retro stage emits the terminal status block — its presence with `stage="retro-complete"` and `workflow_lock="done"` is the SUCCESS anchor the `/goal` evaluator's terminal condition looks for (see `shared/goal-conditions.md` §Terminal-State Reference).

```bash
.claude/scripts/plan-w-team-surface-status.sh "$SLUG" "retro-complete"
```

When this block appears in the transcript, `/goal` evaluator's next turn should return "yes" with `SUCCESS` as the terminal state and clear the goal.

Skip this block entirely when `PLAN_W_TEAM_DISABLE_GOAL=1` (kill switch).
