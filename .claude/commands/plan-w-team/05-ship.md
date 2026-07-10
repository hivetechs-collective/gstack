# Step 6: Ship

<!-- PWT-T2 Orchestrator Retrofit (2026-05-18)
     Pause sites in this file routed via .claude/scripts/plan-w-team-orchestrator-route.sh
     Classifier: shared/orchestrator-interception.md

     | Call-site label               | Verdict      | Original behavior                               |
     | ----------------------------- | ------------ | ----------------------------------------------- |
     | ship-readiness-gate           | orchestrator | Scope-tag crossover heuristic ASK                |
     | version-bump-major-vs-minor   | orchestrator | MINOR/MAJOR version bump decision                |
     | scope-unlock-for-drift        | user         | Mid-flight scope expansion (kept as user)        |
     | push-ack                      | user         | Push confirmation gate (kept as user)            |
     | secret-scan-allow             | user         | Secret scan allowlist (kept as user)             |

     Safe-fail: if router unavailable, falls through to AskUserQuestion.
     Kill switch: PLAN_W_TEAM_DISABLE_ORCHESTRATOR=1
-->

After review passes, execute the ship pipeline.

## 6-0a. Minimal-Retro-on-Exit Trap (MANDATORY — install first)

Every ship-gate `exit 1` below (review-findings missing, scope-lock drift, secret scan failure, credential-wall escalation, test failure, coverage floor breach, access-control finding gate, push-ack missing, push-lock contention) used to terminate the run with no retro JSON on disk. `pwt-watch.sh` then degraded to a bare "session finished" notification with no context, and the `/goal` evaluator had no anchor to evaluate.

Install the trap **before** any other shell work so every subsequent exit path is covered:

```bash
SLUG="<feature-slug>"
PWT_CURRENT_STAGE="ship"

# Chain with any existing trap; do not replace (see shared/shell-safety.md).
# The minimal-retro helper is no-op when a complete retro already exists, so
# this is safe to install even when retros do run normally.
EXISTING_TRAP=$(trap -p EXIT | sed -E "s/^trap -- '(.*)' EXIT$/\\1/")
MIN_RETRO_CMD=".claude/scripts/plan-w-team-minimal-retro.sh \"\$SLUG\" \"\$PWT_CURRENT_STAGE\" \"ship-early-exit-\$?\""
trap "${EXISTING_TRAP:+${EXISTING_TRAP}; }$MIN_RETRO_CMD" EXIT
```

When a later gate uses `exit 1`, the trap fires the helper which writes a minimal `plan-w-team-retro-$SLUG.json` (with `"terminal_state":"EARLY_EXIT"` and `"minimal":true`). The watcher reads it and surfaces a meaningful completion summary citing the gate that blocked.

Later sections of this stage (the push-lock trap chain in §6g, the PR-body cleanup in §6g) ALSO use `trap -p EXIT | sed` to chain. As long as every subsequent `trap … EXIT` follows that pattern (capture, then append), the minimal-retro writer survives intact.

### 6-0a-bis. Deterministic post-push ship-verdict writer (PWT-TERM3 — install with the trap)

Define the ship-verdict writer **here**, alongside the §6-0a trap install, so the helper exists long before push and the End-of-Stage write and the EXIT-trap re-assertion are ONE source of truth. The writer fail-safes: it returns without writing unless `SHIP_PUSH_CONFIRMED=1`, which is set **exclusively** by the post-push-success path in §6g — never by the LLM, never pre-push. This makes the existing post-push ship-verdict write RELIABLE (it lands even if the worker drifts after push and never reaches the End-of-Stage block — the runaway-after-ship gap that PWT-TERM1/TERM2 depended on) WITHOUT minting a false-positive PASS when push failed.

```bash
# PWT-TERM3: deterministic post-push ship-verdict writer + arm flag.
# Attests "every §6 ENFORCING gate passed AND the work was pushed". Written ONLY
# when SHIP_PUSH_CONFIRMED=1 — set exclusively by the post-push-success path below
# (never by the LLM, never pre-push). Idempotent (printf overwrite, fresh ts).
SHIP_PUSH_CONFIRMED=0
__pwt_write_ship_verdict() {
  [ "${SHIP_PUSH_CONFIRMED:-0}" = "1" ] || return 0   # fail-safe: never write pre-push
  local sv=".claude/state/plan-w-team-ship-verdict-${SLUG}.json"
  mkdir -p .claude/state 2>/dev/null || true
  printf '{"slug":"%s","verdict":"PASS","ts":"%s"}\n' \
    "$SLUG" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$sv" 2>/dev/null || true
}
```

## 6-0. Ship Gate: Untracked File Classification (MANDATORY)

**This runs before any commit work.** Load `.claude/commands/plan-w-team/shared/untracked-hygiene.md` if you have not already — it contains the full decision matrix, IGNORE pattern guidance, the DISCARD value-carrier guard, and worked examples for the two real-world cases (parts pipeline, claude-pattern obs-\*.png).

### Compute the classification set

```bash
SLUG="<feature-slug>"  # same slug used in preflight
BASELINE=".claude/state/plan-w-team-untracked-baseline-$SLUG.txt"

if [ ! -f "$BASELINE" ]; then
  echo "⚠ Ship gate skipped: no baseline at $BASELINE"
  echo "  Reason: likely --ship-only or --resume run. Hygiene cannot be verified."
  echo "  Retro will note: hygiene-skipped"
  # Continue ship in degraded mode — do not fail
else
  CURRENT=$(git ls-files --others --exclude-standard | sort)
  CLASSIFICATION_SET=$(echo "$CURRENT" | comm -23 - "$BASELINE")

  if [ -z "$CLASSIFICATION_SET" ]; then
    echo "✓ untracked hygiene: clean (0 new untracked files)"
    # Silent pass, proceed to 6a
  else
    COUNT=$(echo "$CLASSIFICATION_SET" | wc -l | tr -d ' ')
    echo "Ship gate: $COUNT new untracked files need classification"
    echo "$CLASSIFICATION_SET"
    # Enter classification loop below
  fi
fi
```

### Classify every entry

For EACH file in the classification set, pick exactly ONE of: **COMMIT**, **IGNORE**, **DISCARD**, **DEFER**. The decision matrix, guidance, and guard rules live in `shared/untracked-hygiene.md` — do not reinvent them here.

Apply decisions as you go:

- **COMMIT** → `git add <path>`
- **IGNORE** → append the narrowest covering pattern to `.gitignore` (check for duplicates first), stage `.gitignore`, do NOT stage the file
- **DISCARD** → `rm <path>` subject to the value-carrier guard (extensions `.md .txt .json .html .yml .yaml .sql .py .ts .tsx .rs .go` require a second explicit "discard anyway?" confirmation)
- **DEFER** → leave untouched, record `{path, reason}` for Step 8 retro

### Verify and refuse

After applying all decisions, recompute the diff and confirm nothing is left unclassified (except DEFER entries):

```bash
REMAINING=$(git ls-files --others --exclude-standard | sort | comm -23 - "$BASELINE")
# Subtract known DEFER set (tracked in retro state file)
# If REMAINING still has entries not in DEFER set → fail:
```

```
✗ Cannot ship: N untracked files undecided:
  - path/to/file1
  - path/to/file2
Every entry must be COMMIT, IGNORE, DISCARD, or DEFER. Refusing final commit.
```

**Do not proceed to 6a if the gate fails.** Loop back, resolve the remaining entries, and re-verify. DEFER is the escape hatch, not the default — heavy use of DEFER scores poorly in the retro.

### Record the classification summary

Write the summary to `.claude/state/plan-w-team-retro-$SLUG.json` (or append to the existing retro artifact if one exists):

```json
{
  "untracked_hygiene": {
    "baseline_size": 0,
    "classification_set_size": 12,
    "resolved": { "commit": 0, "ignore": 12, "discard": 0, "defer": 0 },
    "gitignore_patterns_added": ["/obs-*.png"],
    "deferrals": []
  }
}
```

Step 8 retro reads this file to score the hygiene dimension.

## Board Update (Auto)

After successful ship (tests pass, committed, pushed), move the feature card to Done and add a ship summary. Fire-and-forget — failures must NOT block the ship.

```bash
scripts/board.sh move "<feature-name>" "Done" || true

# Add ship summary with PR link and test results
scripts/board.sh comment "<feature-name>" "## Shipped

**PR:** <PR URL or 'committed directly to main'>
**Tests:** <pass count> passing, coverage ★★★/★★/★
**Commits:** <count> bisectable commits
**Version:** <version if bumped>
**Shipped:** $(date -u +%Y-%m-%dT%H:%M:%SZ)" || true
```

## 6a. Review Readiness Check

Verify Step 5 review is complete. If not, run it first. Track review completion in task metadata.

When confirming acceptance criteria at ship time, follow the **AC Verification Line Contract** (`04-fix-first-review.md`): one `AC<N>: PASS — <evidence>` line per verified AC — exact form, since the `/goal` evaluator greps `AC<N>:[[:space:]]*PASS`; never emit it for an AC you did not verify.

If the user wants to override a missing review, store the override decision (read `shared/artifact-storage.md` for override persistence format) so re-runs of `/plan-w-team` on the same branch do not re-ask.

### Re-read persisted review findings (ENFORCING)

Step 5 §5h wrote `.claude/state/plan-w-team-review-findings-$SLUG.md` with frontmatter declaring whether every Pass-1 CRITICAL was resolved. Verify the contract before proceeding to any other gate.

```bash
FINDINGS=".claude/state/plan-w-team-review-findings-$SLUG.md"

if [ ! -f "$FINDINGS" ]; then
  cat <<'EOF'
✗ SHIP BLOCKED: no review-findings artifact found.
  Step 5 must have written .claude/state/plan-w-team-review-findings-$SLUG.md
  before Step 6 runs. Either re-run Step 5, or — if you intentionally skipped
  review — write the file by hand and set all_critical_resolved: true
  and access_control_high_unresolved: 0 (the §6c-ter access-control gate keys off it).
EOF
  exit 1
fi

ALL_RESOLVED=$(awk '/^all_critical_resolved:/{print $2}' "$FINDINGS")
CRITICAL_COUNT=$(awk '/^critical_count:/{print $2}' "$FINDINGS")

if [ "$ALL_RESOLVED" != "true" ]; then
  cat <<EOF
✗ SHIP BLOCKED: review findings declare unresolved CRITICAL items.
  $FINDINGS shows critical_count=$CRITICAL_COUNT but all_critical_resolved=$ALL_RESOLVED.
  Resolve each CRITICAL with a "→ resolved in <sha>" marker or "→ DEFERRED" with user ack,
  then re-run Step 5 §5h to refresh the file before retrying ship.
EOF
  exit 1
fi

echo "✓ review findings: $CRITICAL_COUNT critical, all resolved"
```

**Why this gate exists**: prior to this artifact, "review is complete" was a verbal claim that died at session boundaries. A compaction between Step 5 and Step 6 meant Step 6 had no way to verify CRITICALs were addressed and would happily ship a branch with known blockers.

## 6a-bis. Scope Lock Enforcement (ENFORCING GATE)

Step 2 wrote `.claude/state/plan-w-team-scope-lock-$SLUG.json` with the task set at planning time. Before shipping, verify no silent scope expansion occurred.

```bash
LOCK=".claude/state/plan-w-team-scope-lock-$SLUG.json"
UNLOCK=".claude/state/plan-w-team-scope-unlock-$SLUG"

if [ ! -f "$LOCK" ]; then
  echo "⚠ No scope lock at $LOCK (likely --ship-only or pre-lock feature)"
  echo "  Scope drift cannot be verified. Retro will note: scope-unverified"
else
  LOCKED_COUNT=$(jq -r '.task_count' "$LOCK")
  # Count tasks actually shipped in this feature.
  # Three concrete strategies (pick the one your task tooling supports — all read-only, no pseudocode):
  #
  # Strategy A (preferred — works without a task DB): grep commit messages on the feature branch
  # for the locked task IDs. Each task gets at least one commit referencing its ID; count unique IDs.
  BASE_REF="origin/${BASE_BRANCH:-main}"
  LOCKED_IDS=$(jq -r '.tasks[].id' "$LOCK")
  SHIPPED_COUNT=$(
    git log "$BASE_REF..HEAD" --pretty=%B \
      | grep -oE '(task[-_]?[0-9]+|#[0-9]+|T[0-9]+)' \
      | sort -u \
      | grep -cFf <(printf '%s\n' $LOCKED_IDS)
  )
  # Strategy B (if you persist task metadata): list tasks whose metadata.spec_path matches the
  # current spec, e.g. `jq -r '.[] | select(.metadata.spec_path=="'"$SPEC"'") | .id' ~/.claude/tasks/*.json | wc -l`
  # Strategy C (last resort): count commits with the spec slug in the subject line:
  #   git log "$BASE_REF..HEAD" --pretty=%s | grep -cE "(\($SLUG\)|: $SLUG[: ])"
  # Strategy A is preferred because it survives task-DB migration and works on a fresh clone.

  if [ "$SHIPPED_COUNT" -ne "$LOCKED_COUNT" ]; then
    if [ -f "$UNLOCK" ]; then
      echo "✓ Scope expanded from $LOCKED_COUNT → $SHIPPED_COUNT tasks (unlock ack present)"
    else
      cat <<EOF
✗ SHIP BLOCKED: scope drift detected
  Locked at planning: $LOCKED_COUNT tasks
  Shipping now:       $SHIPPED_COUNT tasks
  New tasks added mid-flight — confirm this was intentional.
  To override: touch "$UNLOCK"
EOF
      exit 1
    fi
  fi

  # Verify scoped files — did any task modify files outside its declared scope?
  # (Compares git diff to the locked tasks[].scope tags)
  LOCKED_SCOPES=$(jq -r '.tasks[].scope' "$LOCK" | sort -u)
  # Inspect `git diff --name-only origin/<base>...HEAD` against scope-to-path heuristics
  # (e.g. FRONTEND should not touch src/db/, DATABASE should not touch components/)
  # PWT-T2: Route scope-tag crossover assessment through orchestrator instead of
  # pausing for user ASK. Orchestrator evaluates the heuristic flags and decides
  # whether the crossover is intentional (OK) or suspicious (escalate to user).
  CROSSOVER_FILES=$(git diff --name-only "$BASE_REF..HEAD" | grep -vE "$(echo "$LOCKED_SCOPES" | tr '\n' '|')" || true)
  if [ -n "$CROSSOVER_FILES" ]; then
    CROSSOVER_DECISION=$(route_orchestrator ship-readiness-gate "$SLUG" \
      "crossover_files=$CROSSOVER_FILES" \
      "locked_scopes=$LOCKED_SCOPES" \
      "options=intentional-OK,suspicious-escalate" 2>/dev/null || echo "suspicious-escalate")
    if [ "$CROSSOVER_DECISION" = "suspicious-escalate" ]; then
      echo "⚠ Scope-tag crossover detected — escalating to user for confirmation"
      # Fall through to user ASK for suspicious crossovers
    else
      echo "✓ Scope-tag crossover assessed as intentional by orchestrator"
    fi
  fi
  # Original: Flag any crossover as ASK — do not auto-fail (heuristics have false positives).
fi
```

The gate is **enforcing** on task count drift (exit 1) and **advisory** on scope-tag crossover (ASK prompt). Scope-tag heuristics are too lossy to fail-close on — flag them for the user.

## 6a-ter. Secret Leak Scan (ENFORCING GATE)

Before committing or pushing, scan the about-to-ship content for live-shape credentials. This is the third and final layer of the defense-in-depth model (pre-commit hook → ship gate → sync filter) described in `shared/secret-safety.md`.

The gate runs the shared scanner at `.claude/scripts/secret-scan.sh` in two modes:

1. **`--staged`** — anything currently staged for the final commit
2. **`--diff origin/<base>..HEAD`** — every added line across the feature branch that is about to be pushed

Both must pass. The scanner fails closed on pattern shape — it cannot distinguish a revoked key from a live one, and that is the correct posture.

```bash
SCANNER=".claude/scripts/secret-scan.sh"
BASE_REF="origin/${BASE_BRANCH:-main}"
ALLOW_FILE=".claude/state/plan-w-team-secret-scan-allow-$SLUG"
ALLOW_ARGS=()
[ -f "$ALLOW_FILE" ] && ALLOW_ARGS=(--allow "$ALLOW_FILE")

# Layer 1: staged content
if ! "$SCANNER" "${ALLOW_ARGS[@]}" --staged; then
  echo "✗ Ship gate 6a-ter: live-shape secret(s) detected in staged content."
  echo "  This is fail-closed on pattern shape. If you believe this is a false"
  echo "  positive (for example a test fixture for a revoked key that must"
  echo "  remain in the repo), see 'Override for false positives' below."
  exit 1
fi

# Layer 2: diff range across the branch
if ! "$SCANNER" "${ALLOW_ARGS[@]}" --diff "$BASE_REF..HEAD"; then
  echo "✗ Ship gate 6a-ter: live-shape secret(s) detected in commits $BASE_REF..HEAD."
  echo "  A prior commit on this branch introduced a secret. This is not"
  echo "  fixable by un-staging — git history must be rewritten before push."
  echo "  See shared/secret-safety.md §'History rewrite' for the runbook."
  exit 1
fi
```

### Failure modes and what they mean

| Scanner output                                     | What it means                                                                                                                               | What to do                                                                                                                                                                                                                                                                                                     |
| -------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `LIVE SECRET: <file>:<line>`                       | Pattern-shape match not suppressed by placeholder rules                                                                                     | Remove the value, rotate the credential upstream, re-stage. If test fixture, see override below.                                                                                                                                                                                                               |
| Exit 1 on `--staged` only                          | Secret is in the final commit's staging area                                                                                                | `git reset HEAD <file>` + remediate, then re-stage clean content.                                                                                                                                                                                                                                              |
| Exit 1 on `--diff` only                            | Secret is in an earlier commit on this branch                                                                                               | History rewrite required. Run `git filter-repo --replace-text` or rebase to edit the offending commit. Force-push must be explicit.                                                                                                                                                                            |
| Exit 2                                             | Scanner itself errored (bad args, internal failure)                                                                                         | Read stderr. This is a scanner bug or a bad invocation — do NOT bypass by touching the allow file. Fix the scanner invocation and re-run.                                                                                                                                                                      |
| `SKIP (binary)` / `SKIP (>max-filesize)` on stderr | A staged file was NOT scanned because it is binary or exceeds `--max-filesize` (default 1 MB) — a coverage GAP, not a clean result (gap B2) | The exit code reflects only the files that WERE scanned. A secret hidden in a large/binary blob is invisible here. Confirm the skipped file genuinely carries no secret (manually or with a content-aware tool); the §8c-bis retro workspace sweep re-surfaces persistent skips. Never treat a skip as a pass. |

<!-- PWT-T2: secret-scan-allow is classified as `user` in the orchestrator classifier
     table. This pause site is INTENTIONALLY kept as a user decision because adding
     entries to the secret-scan allowlist is security-critical and audit-required.
     The orchestrator cannot make security exemption decisions. -->

### Override for false positives (documented, rare)

Some test fixtures legitimately embed revoked pattern-shape credentials (for example, a regression test that asserts the scanner still catches a known-revoked Stripe test key). For these, create an allow file naming the exact `file:line:pattern` triples to suppress:

```bash
# .claude/state/plan-w-team-secret-scan-allow-<slug>
# One finding per line, format: path:line:pattern-name
# Every entry MUST carry an inline justification.
tests/fixtures/revoked-stripe.txt:7:stripe-live-secret  # revoked 2026-01-01, kept for regression test
```

**Allow-file comment sanitization (MANDATORY)**: comments inside the allow file must NOT contain literal pattern-shape values — describe them indirectly. Example: write `# AWS-published documentation example access key`, not the same string with the actual key identifier inlined. Reason: the scanner reads the entire allow file when staged, and a literal value in a descriptive comment will match the same pattern as a real leak — blocking the very commit that documents the exception. The justification must convey _why_ the entry is safe, not duplicate the value the entry already references. (This paragraph avoids embedding the literal example for the same reason — older downstream pre-commit hooks are not comment-aware and will block any document quoting the raw token.)

Before bypassing:

1. Rotate the credential upstream anyway (belt and suspenders — shape might still be valid).
2. Add a comment explaining why this file/line is safe to keep — using indirect language only (see sanitization rule above).
3. Re-run the gate with the allow file in place.

The allow file is checked into the repo (it documents intentional exceptions) but the entries must be reviewed during Step 5 Fix-First Review. A reviewer adding entries silently is itself a red flag.

## 6a-quater. Pre-Push Self-Heal + Wedge Recovery (REQ-1/REQ-2 — run before §6b)

The autonomous path self-drives to here then historically **wedged** at the test
gate on two environment issues nothing self-healed (2026-05-29 cleanscale audit:
5 bg workers found idling in `waiting`). Heal them BEFORE §6b so a bg worker
finishes unattended instead of waiting for an operator.

**REQ-1 — proactive self-heal.** Run the preflight before the test gate:

```bash
# (a) node_modules/turbo: a bg LEAD makes its worktree mid-session, so SessionStart
#     can't seed deps (and headless `claude -p` never fires SessionStart). Without
#     node_modules, `turbo`/`make test-all` dies on "turbo: command not found".
# (b) orphaned iOS sim: a booted app-less sim left by a stopped worker false-fails
#     maestro 57/57. Shut booted sims (xcrun simctl) so a fresh one boots with the app.
# The helper does both: worktree-deps-share (or pnpm install --frozen-lockfile) +
# xcrun simctl shutdown. Fail-open; iOS/JS-scoped; kill switches below.
.claude/scripts/plan-w-team-ship-preflight.sh --worktree "$PWD" --json
```

Kill switches: `PWT_SHIP_PREFLIGHT_DISABLE=1`, `PWT_SHIP_DEPS_DISABLE=1`,
`PWT_SHIP_SIM_SHUTDOWN=0`. See `shared/disk-budget.md` siblings / the script header.

**REQ-2 — wedge-recovery retry loop (classify → fix → retry → THEN escalate).**
When §6b below returns non-zero, classify the failure and recover before surfacing:

| Class        | Signal                                                               | Action                                                     |
| ------------ | -------------------------------------------------------------------- | ---------------------------------------------------------- |
| `env-gap`    | `turbo: command not found`, missing workspace bin, no `node_modules` | re-run the preflight (deps leg) + retry §6b once           |
| `sim-orphan` | maestro fails ~all (e.g. 57/57) with a booted sim present            | re-run the preflight (sim leg) + retry §6b once            |
| `real-test`  | genuine assertion/build failures                                     | **surface** via §6-0a retro trap — do NOT retry into green |

Cap: **≤2 total attempts**. Log each classification. A proven `real-test` failure
is NEVER silently retried — only `env-gap`/`sim-orphan` trigger a self-heal retry
(consistent with the fix-defects-immediately rule: heal the environment, never mask
a real failure). After the cap, surface "blocked" through the normal retro path.

## 6a-quinquies. Credential-Wall Escalation Gate (ENFORCING — step-completeness invariant)

A deploy CLI that hit a NON-INTERACTIVE credential/token wall during Step 3
execute or this ship stage (e.g. `wrangler` → "in a non-interactive environment…
set a `CLOUDFLARE_API_TOKEN`", or `gh`/`vercel`/`eas`/`flyctl`/`aws` login walls)
is a `blocked-external` operator escalation — the SAME shape as the browser-console
guardrail in `shared/secret-safety.md §REQ-5`, now extended to CLI token walls by
**§REQ-6**. The `plan-w-team-credential-wall-detect.sh` PostToolUse /
PostToolUseFailure hook persists the EXACT missing secret + the repo's documented
operator action to a durable artifact (`.claude/state/plan-w-team-credwall-<SLUG>.json`,
survives compaction) and emits a `USER_ESCALATION_HALT` block.

This gate is the **step-completeness invariant**: while that artifact is unresolved,
a deploy/ship step blocked on a credential **CANNOT be marked complete and CANNOT
be silently skipped** — the gate FAILS CLOSED. This closes the "stopped short of
the operator step" failure mode from the 2026-06-02 cleanscale report.

```bash
# Fails closed (exit 1) on any unresolved credential-wall artifact; also fails
# closed on a malformed artifact (same posture as §6c-ter). Exit 0 = clear.
if ! .claude/scripts/plan-w-team-credential-wall-gate.sh; then
  # The gate already printed the missing secret + operator action. Do NOT mark
  # the deploy/ship step done; do NOT skip it. Surface the blocked-external
  # USER_ESCALATION_HALT to the operator (pending_escalations: ["credential-wall"])
  # so the /goal evaluator halts for the human to provision the secret.
  exit 1
fi
```

**Resolution (operator):** provision the missing secret per
`shared/no-github-actions.md §"Deploy Secret Access"` (the headless `0600`
`deploy.env` standard) OR complete the documented login (e.g. `wrangler login`),
then set `"resolved": true` in the artifact (or delete it) and re-run the deploy.
The step stays explicitly BLOCKED until then — never "noted and advanced"
(`04-fix-first-review.md §Fix-Immediately`). Kill switch (incident only):
`PLAN_W_TEAM_DISABLE_CREDWALL_GUARD=1` disables the _detector_ hook; the gate
itself has no bypass — that is the point.

## 6b. Run Full Test Suite (ENFORCING GATE — not a prose request)

Detect the project's test framework and run it. **The exit code is the gate.** If any command fails, refuse to ship.

```bash
# Detect test framework based on manifests (handles monorepos by recursing)
run_tests() {
  local rc=0
  if [ -f package.json ] && grep -q '"test"' package.json; then
    npm test || rc=$?
  elif [ -f Cargo.toml ]; then
    cargo test || rc=$?
  elif [ -f pyproject.toml ] || [ -f setup.py ] || [ -f pytest.ini ]; then
    pytest || rc=$?
  elif [ -f go.mod ]; then
    go test ./... || rc=$?
  else
    # Recurse into workspace subdirs (monorepos)
    local found=0
    for manifest in $(find . -maxdepth 3 -name "package.json" -o -name "Cargo.toml" -o -name "pyproject.toml" 2>/dev/null); do
      local dir
      dir=$(dirname "$manifest")
      [ "$dir" = "." ] && continue
      echo "→ running tests in $dir"
      ( cd "$dir" && run_tests ) || rc=$?
      found=1
    done
    if [ "$found" = "0" ]; then
      echo "✗ No test framework detected. Refusing to ship blind."
      return 1
    fi
  fi
  return $rc
}

if ! run_tests; then
  echo "✗ Ship gate 6b: tests failed (exit code non-zero). Refusing to ship."
  echo "  Fix the failures, then re-run /plan-w-team --ship-only."
  exit 1
fi
```

If the browse binary is available and any task has `scope: "FRONTEND"`, read `shared/browser-qa.md` for browser smoke test instructions. **Browser smoke tests are also gates** — a non-zero exit code from the browse binary blocks the ship.

### Fix-Immediately at the ship gate (ENFORCING — per §5-0)

The ship gate enforces the fix-immediately rule (`04-fix-first-review.md` §5-0,
memory `feedback_fix_defects_and_flaky_immediately`): **the ship MUST NOT advance past
a red gate or a merely-"noted" defect/flaky item.**

- A red test/coverage/security/lint gate is fixed now (fix→deploy→retest→verify-GREEN→note)
  — never shipped around. The only exception is a failure **proven pre-existing AND
  non-deterministic** via `git stash → run on clean main → identical failure → stash pop`,
  and even then it is queued for immediate repair, not accepted permanently.
- A flaky test encountered here is repaired by removing non-determinism (mock/stub live
  deps, pin seeds/clock, isolate shared state) and must pass 100/100 — never loosened,
  retried, or `.skip`-ed (the forbidden list in §5-0 applies verbatim).
- Re-read the persisted review findings (§6a): if any defect/flaky was logged as merely
  "noted" without a completed fix, the ship gate refuses — return it to fix-now first.

## 6b-bis. No-GitHub-Actions Drift Detector (git-level defense-in-depth)

> Primary, write-time enforcement is the `block-gh-actions-build.sh` PreToolUse hook
> (audit P9b) — it blocks an Edit/Write that introduces a build/CI/deploy workflow before
> it ever reaches the tree. This §6b-bis check is git-level **defense-in-depth**: it catches
> a workflow introduced outside the Write/Edit path (e.g. a `git apply`, a merge, or a
> pre-hook bypass). It is a defect _detector_ (it `echo`s), not a hard `exit 1` gate — the
> hook is the gate.

GitHub Actions MUST NOT be introduced as a build/CI/deploy path — the canonical path is
the local Makefile + admin-squash-merge (`scripts/Makefile.template`). Full rule and the
exemption list: `shared/no-github-actions.md`. A new GH-Actions build/deploy path in this
run's diff is **off-policy drift treated as a defect** (fix it now per §5-0), not a
"noted" item.

```bash
# Flag NEW .github/workflows/*.yml in this run's diff that run build/test/deploy steps.
# Exempt observers (ci-alert.yml.template, board-auto-add.yml) and pure manual-dispatch
# infra-bootstrap workflows are NOT build/deploy paths — see shared/no-github-actions.md.
NEW_WF=$(git diff --name-only --diff-filter=A "origin/${BASE:-main}...HEAD" 2>/dev/null \
  | grep -E '^\.github/workflows/.*\.ya?ml$' \
  | grep -vE '(ci-alert|board-auto-add)' || true)
if [ -n "$NEW_WF" ]; then
  echo "⚠ no-gh-actions gate: new workflow file(s) introduced this run:"
  echo "$NEW_WF" | sed 's/^/    /'
  echo "  If any runs build/test/lint or a deploy step, it is off-policy drift —"
  echo "  move the gate to the local Makefile path (or .github/workflows-disabled/) and"
  echo "  fix now per §5-0. Observer/alerting-only workflows are exempt; confirm before shipping."
fi
```

This gate is a defect detector, not a hard stop on every workflow file: an
alerting/observer or deliberately-retained manual-dispatch workflow is exempt (apply the
`shared/no-github-actions.md` test — does it build/test/deploy on push/PR/schedule?). A
build/deploy workflow is a defect to fix now.

## 6c. Test Coverage Audit

Rate test quality with stars, not just percentages:

| Rating | Meaning       | Criteria                                    |
| ------ | ------------- | ------------------------------------------- |
| ★★★    | Comprehensive | Behavior + edge cases + error paths covered |
| ★★     | Adequate      | Happy path + basic error cases              |
| ★      | Minimal       | Smoke test or trivial assertions only       |

A module with 90% line coverage but all ★ tests is worse than 60% coverage with ★★★ tests. Flag the distinction.

### Minimum Coverage Gate (ENFORCING)

If the project declares a coverage floor (in `package.json` `jest.coverageThreshold`, `pyproject.toml` `[tool.coverage.report] fail_under`, or `Cargo.toml` metadata `coverage_min`), **run coverage and enforce it**. Do not ship below the declared floor:

```bash
# Example: npm projects with coverage script
if [ -f package.json ] && grep -q '"coverage"' package.json; then
  if ! npm run coverage; then
    echo "✗ Ship gate 6c: coverage below declared floor. Refusing to ship."
    exit 1
  fi
fi
```

If no coverage floor is declared, this gate is skipped (the star-rating audit above is the softer check). Declaring a floor is how a project opts in to strict coverage enforcement.

### Coverage Floor Auto-Default (STE Extension — ENFORCING when no explicit policy)

When the repo declares **no** coverage threshold in any of the standard locations (`package.json` `jest.coverageThreshold`, `pyproject.toml` `[tool.coverage.report] fail_under`, `Cargo.toml` `coverage_min`, etc.), the ship gate **proposes a sensible language-aware default** rather than silently skipping the floor. This closes the 2026-05 retro finding: "feature shipped at 31% coverage on a 4-year-old repo and nobody noticed."

```bash
# snippet-lint: skip — illustrative coverage-floor auto-default
COVERAGE_POLICY=".claude/state/coverage-policy.txt"

# Opt-out: any project can decline the auto-default by writing this single-line file
if grep -qx "no-coverage-floor" "$COVERAGE_POLICY" 2>/dev/null; then
  echo "[coverage-floor] opt-out via $COVERAGE_POLICY — skipping auto-default"
else
  # Detect repo maturity by oldest-commit age (full-clone) or fall back to
  # commit-count (shallow-clone safe). Older = stricter floor.
  if git log --reverse --format=%cd --date=unix 2>/dev/null | head -1 > /tmp/oldest-commit-epoch; then
    OLDEST=$(cat /tmp/oldest-commit-epoch)
    NOW=$(date +%s)
    AGE_DAYS=$(( (NOW - OLDEST) / 86400 ))
  else
    # Shallow clone — assume mature; we cannot tell
    AGE_DAYS=999
  fi

  if [ "$AGE_DAYS" -gt 180 ]; then
    FLOOR=80
    TIER="mature (>6mo git history)"
  else
    FLOOR=60
    TIER="new (<6mo git history)"
  fi

  echo "[coverage-floor] auto-default proposed: ${FLOOR}% (${TIER}, age=${AGE_DAYS}d)"
  echo "[coverage-floor] to opt out:       echo 'no-coverage-floor' > $COVERAGE_POLICY"
  echo "[coverage-floor] to set explicit:  echo 'coverage-floor: <pct>' >> $COVERAGE_POLICY"

  # Measure coverage (best-effort: run the most common coverage commands)
  MEASURED_PCT=""
  if [ -f package.json ] && grep -q '"coverage"' package.json 2>/dev/null; then
    # npm run coverage typically emits text summary with "All files | ... | <pct> | ..."
    MEASURED_PCT=$(npm run coverage 2>&1 | grep -E 'All files' | awk -F'|' '{print $2}' | tr -d ' ' | head -1)
  elif [ -f Cargo.toml ] && command -v cargo-tarpaulin >/dev/null 2>&1; then
    MEASURED_PCT=$(cargo tarpaulin --print-summary 2>&1 | grep -oE '[0-9]+\.[0-9]+%' | head -1 | tr -d '%')
  elif [ -f pyproject.toml ] && command -v coverage >/dev/null 2>&1; then
    coverage report 2>/dev/null
    MEASURED_PCT=$(coverage report 2>/dev/null | tail -1 | awk '{print $NF}' | tr -d '%')
  fi

  if [ -z "$MEASURED_PCT" ]; then
    echo "[coverage-floor] WARNING: coverage runner not detected — auto-default cannot be enforced."
    echo "[coverage-floor]          Skipping floor check. Add a coverage runner to enable enforcement."
    echo "[coverage-floor]          (Recorded in retro 8e under 'coverage_not_measurable: true'.)"
  else
    # Compare measured vs auto-default floor (round MEASURED_PCT down to int for compare)
    MEASURED_INT="${MEASURED_PCT%.*}"
    if [ "${MEASURED_INT:-0}" -lt "$FLOOR" ]; then
      echo "✗ Ship gate 6c (auto-default floor): coverage ${MEASURED_PCT}% < proposed ${FLOOR}% for ${TIER} repo. Refusing to ship."
      echo "  Either improve coverage above ${FLOOR}%, OR opt out with:"
      echo "    echo 'no-coverage-floor' > $COVERAGE_POLICY"
      echo "  OR declare an explicit project floor:"
      echo "    echo 'coverage-floor: <pct>' >> $COVERAGE_POLICY"
      exit 1
    else
      echo "✓ coverage ${MEASURED_PCT}% ≥ auto-default ${FLOOR}% (${TIER})"
    fi
  fi
fi
```

**Why 60% / 80% as the cutoffs**:

- **New repos (<6mo history)**: 60% strikes the balance between "we just started" and "we should have a unit test for every new module." Below 60%, the codebase is effectively untested.
- **Mature repos (>6mo history)**: 80% reflects industry consensus for code that has had time to accumulate test debt — anything lower says "we are not testing, we are debugging in production." See Google SWE Book §11.7 (Test Coverage).

**Why opt-out lives in `.claude/state/coverage-policy.txt`** (not in `package.json` or another project config): the auto-default is an **opinion** of `/plan-w-team`, not the repo's intrinsic policy. Keeping it out of project config files prevents it from accidentally affecting tooling that reads those files. The state file is gitignored by default (per `.gitignore` patterns set in pre-flight) so individual contributors can opt out locally without committing the decision. To make the opt-out repo-wide, the user can add the file to git deliberately.

**Companion policy keys** (`.claude/state/coverage-policy.txt` accepts any of these one-line entries):

- `no-coverage-floor` — opt out of the auto-default entirely.
- `coverage-floor: <pct>` — set an explicit floor (overrides auto-default).
- `mutation-survival-floor: <pct>` — TO2 mutation-survived threshold (default 5%, per Step 2 §TO2 Mutation Default-On for One-Way-Door PRs).

**Cognitive framework**: Error budgets (Google SRE) — read `shared/cognitive-frameworks.md`.

## 6c-bis. Security Tier Gate (Security Review Extension — ENFORCING when no explicit policy)

After the coverage-floor gate, the ship gate consults `.claude/state/security-policy.txt` to determine the active security tier set. If no policy is declared, it **proposes a sensible baseline** (T1+T3+T4) and adds overlays for repo size and user-facing surfaces. This closes the security-rigor gap that the §6c coverage gate closed for test coverage: a feature touching auth/secrets/injection paths should not silently ship without lint scan, dep-audit, and secret-scan evidence.

Tier definitions live in `shared/security-tiers.md`. OWASP file-pattern attribution lives in `shared/owasp-top10-mapping.md`. Both are consulted; this block only enforces the ledger.

```bash
# snippet-lint: skip — illustrative security-floor auto-default
SECURITY_POLICY=".claude/state/security-policy.txt"

# Opt-out: any project can decline the auto-default by writing this single-line file
if grep -qx "no-security-floor" "$SECURITY_POLICY" 2>/dev/null; then
  echo "[security-floor] opt-out via $SECURITY_POLICY — skipping auto-default"
elif grep -qE "^security-tiers:" "$SECURITY_POLICY" 2>/dev/null; then
  EXPLICIT=$(grep -E "^security-tiers:" "$SECURITY_POLICY" | sed 's/^security-tiers:[ ]*//')
  echo "[security-floor] explicit policy: ${EXPLICIT}"
  REQUIRED_TIERS="$EXPLICIT"
else
  # Detect repo size + user-facing surfaces for auto-overlays
  LOC=$(git ls-files | xargs wc -l 2>/dev/null | tail -1 | awk '{print $1}' || echo 0)
  USER_FACING=0
  if git ls-files | grep -qE '(^|/)(routes|api|pages/api|app/api)(/|$)'; then
    USER_FACING=1
  fi

  REQUIRED_TIERS="T1,T3,T4"  # SecBaseline always-on
  TIER_PROFILE="SecBaseline"
  if [ "${LOC:-0}" -gt 5000 ]; then
    REQUIRED_TIERS="${REQUIRED_TIERS},T2"
    TIER_PROFILE="SecStandard"
  fi
  if [ "$USER_FACING" = 1 ]; then
    REQUIRED_TIERS="${REQUIRED_TIERS},TO1"
    TIER_PROFILE="SecHardened"
  fi

  echo "[security-floor] auto-default proposed: ${REQUIRED_TIERS} (${TIER_PROFILE}, LOC=${LOC}, user_facing=${USER_FACING})"
  echo "[security-floor] to opt out:       echo 'no-security-floor' > $SECURITY_POLICY"
  echo "[security-floor] to set explicit:  echo 'security-tiers: T1,T3,T4' >> $SECURITY_POLICY"
fi

# Verify each required tier has evidence in the Security Tier Evidence Ledger
# (the ledger format lives in shared/security-tiers.md). For each required tier,
# the ledger row must be ✅ (passed) or 🚫 (deliberately-skipped with justification).
# A ❌ or ⏳ row on a required tier blocks ship.
#
# In practice the lead runs the active runners and writes evidence rows; this
# block re-asserts they exist before push.
```

### Companion policy keys

`.claude/state/security-policy.txt` accepts any of these one-line entries (joinable; order does not matter):

- `no-security-floor` — opt out of the auto-default entirely. NOT recommended; the baseline T1+T3+T4 is cheap.
- `security-tiers: T1,T3,T4` — explicit tier set. Overrides the auto-default. Comma-separated, no spaces around commas.
- `mandatory-owasp: A01,A02,A03,A07` — explicit Top-10 categories required regardless of file-pattern triggers. Useful for repos with implicit threat models (e.g., "this is a public API; A01+A03+A07 always required even if globs don't match this PR's diff").
- `enable-to1` — opt-in flag for TO1 (OWASP ZAP baseline). Required because ZAP is heavyweight; ship gate will not auto-add TO1 without this acknowledgement even if user-facing surfaces are detected.
- `enable-to2` — opt-in flag for TO2 (fuzz testing). Same reason as `enable-to1`.

### Why opt-out lives in `.claude/state/security-policy.txt`

Same rationale as `coverage-policy.txt` (per §6c Coverage Floor Auto-Default): the auto-default is an **opinion** of `/plan-w-team`, not the repo's intrinsic policy. Keeping it out of `package.json` / `Cargo.toml` etc. prevents the auto-default from accidentally affecting tooling that reads those files. The state file is gitignored by default so individual contributors can opt out locally without committing the decision. To make the opt-out repo-wide, the user can add the file to git deliberately.

### Cognitive framework

This gate borrows from the Bow-tie risk model (see `shared/cognitive-frameworks.md`): T1+T3+T4 covers the most common preventive controls (input-side defenses + dependency hygiene + secret leak prevention); T2 SAST + TO1 ZAP are the detective controls that catch what slipped past the preventive layer.

## 6c-ter. Access-Control Finding Gate (ENFORCING)

Where §6c-bis asserts that a tier _ledger_ exists against a policy, this gate fails closed on a **real, confirmed finding**. Step 5 §5d-ter classifies a confirmed high-severity broken-access-control bug (A01 / API1 BOLA / API3 BOPLA / API5 BFLA) in the diff's own touched code as a Pass-1 CRITICAL and records the open count in the `access_control_high_unresolved` frontmatter key of the review-findings artifact. This gate refuses to ship while that count is non-zero — and, unlike a normal CRITICAL, a `→ DEFERRED` marker does **not** clear it. This is the structural fix for both 2026-06-01 escapes: the `seed-platform-admin` account-takeover (bypass-token / privilege-field) and the `jobs.ts` FIN-15 cross-tenant IDOR (where-by-id without a tenant predicate) — neither of which the path-glob machinery gated.

```bash
FINDINGS=".claude/state/plan-w-team-review-findings-$SLUG.md"

# §6c-ter reads the Step-5 verdict (§5h). §6a already hard-blocks on a missing
# artifact; re-guard here so this gate is self-contained after a compaction.
if [ ! -f "$FINDINGS" ]; then
  echo "✗ Ship gate 6c-ter: no review-findings artifact ($FINDINGS) — run Step 5 §5h first."
  exit 1
fi

# First match only (`exit`) so a stray second column-1 occurrence in the
# LLM-authored body cannot produce a multi-line value. Absent key → empty.
AC_HIGH_UNRESOLVED=$(awk '/^access_control_high_unresolved:/{print $2; exit}' "$FINDINGS")

# Fail CLOSED on a malformed / non-numeric count — a gate whose whole purpose is
# to be un-bypassable must never silently pass on a garbled artifact. An ABSENT
# key (empty) defaults to 0 (back-compat with pre-1.22.0 / hand-authored files,
# which §6a's escape hatch allows); a PRESENT-but-non-numeric value fails closed.
case "$AC_HIGH_UNRESOLVED" in
  "") AC_HIGH_UNRESOLVED=0 ;;
  *[!0-9]*)
    echo "✗ Ship gate 6c-ter: unparseable access_control_high_unresolved value ('$AC_HIGH_UNRESOLVED') — failing closed."
    echo "  Re-run Step 5 §5h to refresh the review-findings artifact with an integer count."
    exit 1 ;;
esac

if [ "$AC_HIGH_UNRESOLVED" -gt 0 ]; then
  echo "✗ Ship gate 6c-ter: $AC_HIGH_UNRESOLVED confirmed high-severity broken-access-control finding(s) unresolved."
  echo "  A01 / API1 BOLA (cross-tenant IDOR) / API3 BOPLA (privilege-field, mass-assignment) /"
  echo "  API5 BFLA (bypass-token) on the diff's own touched code (04-fix-first-review.md §5d-ter)."
  echo "  GATING, not deferrable — a '→ DEFERRED' marker does NOT clear them. Fix each now"
  echo "  (§5-0 fix-immediately), or prove the surface is not exploitable (e.g. QA-scoped via"
  echo "  assertQaScoped — see shared/secure-by-default.md), which downgrades the severity."
  echo "  Then re-run Step 5 §5h to refresh the count before retrying ship."
  exit 1
fi

# ── Deterministic detection backstop (audit P9c) ─────────────────────────────
# The count above is LLM-authored in Step 5 §5b. Re-run the deterministic
# content scanner over the diff: if it flags CS-1..CS-4 signals that Step 5
# recorded as 0, the DETECTION step missed a live A01 (a deterministic gate is
# only as trustworthy as the detection feeding it). Fail CLOSED — this closes
# the GIGO hole where a clean LLM-authored count passes a real bug through.
SCAN_SCRIPT="$(git rev-parse --show-toplevel 2>/dev/null)/.claude/scripts/access-control-content-scan.sh"
if [ -x "$SCAN_SCRIPT" ]; then
  "$SCAN_SCRIPT" --slug "$SLUG" --quiet
  SCAN_RC=$?
  if [ "$SCAN_RC" -eq 3 ] && [ "$AC_HIGH_UNRESOLVED" -eq 0 ]; then
    echo "✗ Ship gate 6c-ter: the deterministic access-control scanner flagged content"
    echo "  signals (CS-1..CS-4) in the diff, but Step 5 recorded"
    echo "  access_control_high_unresolved: 0 — detection missed a signal the scanner caught."
    SUSPECTS_FILE="$(git rev-parse --show-toplevel 2>/dev/null)/.claude/state/plan-w-team-content-signal-suspects-$SLUG.txt"
    [ -f "$SUSPECTS_FILE" ] && sed 's/^/    /' "$SUSPECTS_FILE"
    echo "  Adjudicate each in Step 5 §5b (fix, or prove non-exploitable e.g. QA-scoped via"
    echo "  assertQaScoped), then re-run §5h so the count reflects reality. Fail-closed."
    exit 1
  elif [ "$SCAN_RC" -eq 2 ]; then
    echo "⚠ Ship gate 6c-ter: access-control scanner could not produce a diff to corroborate"
    echo "  the clean count — manually confirm no access-control change shipped unreviewed."
  fi
fi

echo "✓ Ship gate 6c-ter: no unresolved high-severity access-control findings"
```

**No ship-side override.** Every other gate has a `user`-acked escape hatch; this one deliberately does not. A confirmed live access-control exploit cannot be allow-listed at ship time. The only way past is to change the verdict at review (Step 5): fix the finding, or demonstrate it is not exploitable (e.g. the surface is provably QA-scoped via `assertQaScoped`), which downgrades its severity and removes it from `access_control_high_unresolved`. This keeps the override where the evidence is — in the review, not the push.

## 6c-quater. Documentation Ship Gate (A3 — ENFORCING when net-new public surface added)

The secret/coverage/security gates above all refuse a ship that adds _code_ without the matching defense. There was no analog for _documentation_, so net-new public surface (a new script/hook/module, exported symbol, CLI flag, env var) could ship with no CHANGELOG or doc touch at all (audit gap A3). This gate closes that hole. It delegates to a standalone, tested script (same pattern as the access-control and credential-wall gates — a thin wrapper around a script with a `.test.sh` corpus, not embedded bash that can rot):

```bash
# §6c-quater Documentation Ship Gate (A3). Fails closed (exit 1) when the branch
# diff adds net-new public surface AND no CHANGELOG/doc was touched AND no waiver
# covers it. Honors PLAN_W_TEAM_NETNEW_DISABLE=1 (advisory mode). The script
# resolves the range from origin/<base>..HEAD; pass --slug for the waiver lookup.
if ! .claude/scripts/plan-w-team-doc-ship-gate.sh --slug "$SLUG"; then
  echo "✗ Ship gate 6c-quater: net-new public surface added with no CHANGELOG/doc/waiver."
  echo "  Document the new surface (README / config-reference / docs/operations / CHANGELOG),"
  echo "  or record a waiver in .claude/state/plan-w-team-docs-waived-$SLUG.txt, then re-run."
  exit 1
fi
echo "✓ Ship gate 6c-quater: documentation accompanies net-new public surface"
```

This is the ship-time bookend to the post-ship §7a-bis net-new-surface scan: §6c-quater blocks the _push_ of undocumented surface; §7a-bis/§7f block marking _Step 7 complete_ with an undocumented residual. The A2 default doc-coverage AC is the spec-level companion. The gate is advisory (warn-not-block) only when `PLAN_W_TEAM_NETNEW_DISABLE=1` is set — an incident escape hatch, not a routine bypass.

## 6d. Version Bump (if applicable)

| Change Size       | Bump        | Decision                   |
| ----------------- | ----------- | -------------------------- |
| <50 lines changed | MICRO/PATCH | Auto-decided               |
| 50+ lines changed | PATCH       | Auto-decided               |
| New feature/API   | MINOR       | Route through orchestrator |
| Breaking change   | MAJOR       | Route through orchestrator |

For MINOR and MAJOR bumps, route through the orchestrator instead of pausing for user input:

```bash
# snippet-lint: skip — illustrative orchestrator routing
VERSION_DECISION=$(route_orchestrator version-bump-major-vs-minor "$SLUG" \
  "change_size=$LINES_CHANGED" \
  "has_breaking_change=$HAS_BREAKING" \
  "has_new_api=$HAS_NEW_API" \
  "options=PATCH,MINOR,MAJOR")
```

**Concurrent-run safety — rebump from CURRENT main, not the spawn snapshot
(PWT-VERSION-COLLISION).** Once the bump KIND is chosen, derive the new version
number from main's CURRENT `VERSION` at ship time, NOT the `VERSION` captured
when this run started. The helper self-fetches the merge target first
(best-effort `git fetch --quiet origin <base>`; offline / no-remote it silently
falls back to local refs), so no prior fetch/rebase step is required. This is
the difference between two concurrent runs colliding on the same version and
stacking cleanly.

**Scope guard — the rebump helper targets the SYNCED SKILL `VERSION`, so it runs
ONLY for a skill self-ship.** The helper defaults to
`.claude/commands/plan-w-team/VERSION`, which exists in EVERY consumer repo
post-sync — an unguarded invocation in a consumer feature ship would wrongly
bump the synced skill version. Gate it on the ship diff actually touching
`.claude/commands/plan-w-team/`:

```bash
# Reads the authoritative current VERSION on the merge target (origin/main → main →
# working tree; the helper self-fetches it best-effort), applies $VERSION_DECISION,
# and writes the rebumped VERSION file — but ONLY for a skill self-ship.
# pwt-skill-selfship-guard: extracted verbatim by plan-w-team-next-version.test.sh — keep the next two lines intact
SHIP_BASE=$(git merge-base HEAD origin/main 2>/dev/null || git merge-base HEAD main 2>/dev/null || echo HEAD)
SKILL_SELF_SHIP=$(git diff --name-only "$SHIP_BASE" HEAD -- .claude/commands/plan-w-team/ | grep -q . && echo yes || echo skip)
if [ "$SKILL_SELF_SHIP" = "yes" ]; then
  NEXT_VERSION=$(.claude/scripts/plan-w-team-next-version.sh \
    --bump "$(printf '%s' "$VERSION_DECISION" | tr '[:upper:]' '[:lower:]')" --write)
  echo "  rebumped skill VERSION → $NEXT_VERSION (from current main, not spawn snapshot)"
else
  echo "  consumer feature ship → synced skill VERSION left untouched"
fi
```

In the `skip` case (any ship whose diff does NOT touch the skill — i.e. every
consumer-repo feature ship), bump the PROJECT's own version artifact instead,
following the project's existing conventions (`package.json` / `Cargo.toml` /
`pyproject.toml` / `VERSION`), and head the CHANGELOG entry with THAT version.
The synced skill `VERSION` must NEVER be bumped by a consumer feature ship — it
tracks the skill release, not the project.

On the self-ship path, head the new `CHANGELOG.md` entry with `$NEXT_VERSION`
and insert it newest-first.
Rationale + the regression test live in `shared/versioning.md §Concurrent runs`.

<!-- Original: MINOR and MAJOR bumps asked the user. Orchestrator decides based
     on diff classification (breaking changes, new API surface, feature scope).
     Fall-through: AskUserQuestion if router unavailable. -->

## 6e. CHANGELOG Generation

Write entries in **user-facing voice**. Apply the "sell test": would a user reading this think "oh nice, I want to try that"?

- "You can now upload photos directly from your phone" (passes sell test)
- "Refactored internal upload module" (fails sell test — rewrite)

CRITICAL: Never clobber existing CHANGELOG entries. Only add new entries and polish wording of entries from this release.

## 6f. Create Bisectable Commits

If the working tree has multiple logical changes, split into ordered commits:

1. Infrastructure/config changes
2. Models/services
3. Controllers/views
4. Tests
5. VERSION + CHANGELOG + docs

Each commit must compile and pass tests independently.

### Use `-o` for path-scoped commits (avoid grabbing staged drift)

A `git add`/`git commit` pair can accidentally include files that another process staged (editor, watcher, parallel session). Use `git commit -o <pathspec>` to commit **only** the listed paths, ignoring everything else in the index:

```bash
# Commits ONLY src/api/ and tests/ — even if other files are staged
git commit -o src/api/ tests/ -m "feat(api): add rate limiting"
```

This is the pattern Round 4 audit flagged for all stage-file-driven commits. Never rely on `git add .` inside a pipeline. Always name the paths you mean.

## 6g-bis. Tier Evidence Ledger (UI repos only)

Runs only when `.claude/qa-profile.json` exists in the target repo AND the feature contains at least one FRONTEND or TESTS task. Skip for non-UI repos and non-UI features.

Build the ledger by iterating over completed tasks and reading their `tier_evidence` metadata from Step 4 TaskUpdate calls. Tier glyphs are defined in `shared/qa-tiers.md`:

| Glyph | Meaning                                                    |
| ----- | ---------------------------------------------------------- |
| ✅    | Evidence captured; tier enforced and passing.              |
| ❌    | Evidence expected but missing or failing. Blocks merge.    |
| ⏳    | Deferred to a follow-up task — must link to that task.     |
| 🚫    | Not applicable to this feature (justify in the ledger).    |
| N/A   | Tier is above the repo's profile (e.g., T5 on Tier-Light). |

Render the ledger as a fenced block in the PR body, immediately after the ## Summary section:

```
## Tier Evidence Ledger

| Tier                  | Status | Evidence                                                                              |
| --------------------- | ------ | ------------------------------------------------------------------------------------- |
| T1 (smoke)            | ✅     | `tests/e2e/<feature>.smoke.spec.ts` passing in CI run #<run-id>                       |
| T2 (10x stability)    | ✅     | `scripts/run-stability.sh` — 10/10 passes logged at `test-results/stability-<sha>.json` |
| T3 (regression)       | ✅     | Added `tests/e2e/<feature>.spec.ts`; ran full suite locally + CI                      |
| T4 (BDD)              | 🚫     | Not applicable — Tier-Standard profile does not enforce T4.                           |
| T5 (visual)           | N/A    | Tier-Standard profile does not include T5.                                            |
| TO2 (team objectives) | ⏳     | Deferred to task #<n>: "Add accessibility audit for dashboard."                       |
```

**Gate**: if any row is ❌, block the push. Either fix the evidence (rerun §6b tests, add the missing spec) or downgrade to ⏳ with a tracked follow-up task on the board. A PR cannot ship with ❌ in the ledger — that is the entire point of the tier discipline.

For non-UI features on the same repo (e.g., a backend-only PR), omit the ledger entirely. The board still records the PR; only the tier discipline is conditional.

## 6g. Push and Create PR (if on a branch)

### Empty-ship loop-breaker (fail-safe — run FIRST, before the ack gate)

Before arming the push, confirm there is actually something to ship. A worker that
`git reset` away its own work (observed once, worker 5088e5f4, 2026-06-25) can reach
Step 6 with an EMPTY worktree — 0 commits ahead of base, clean tree — and LOOP on
push/retry forever; worse, a no-op `git push` of zero commits would let the post-push
path mint a false-positive `SHIP_PUSH_CONFIRMED` PASS. The guard breaks that loop.

It is **fail-safe by construction**: it HALTS only when it can POSITIVELY confirm
there is nothing to ship (0 commits ahead of `$BASE_REF` AND a clean tracked tree),
and PROCEEDS on a real ship or ANY ambiguity — so it can NEVER block a real ship
(a real ship always has commits ahead of base). Untracked files (e.g. the
permanently-untracked goal-state file) are ignored — they are not pushed.

```bash
# Resolve the same ship base the §6 gates use.
BASE_BRANCH="${BASE_BRANCH:-main}"
BASE_REF="origin/${BASE_BRANCH}"
git rev-parse --verify "$BASE_REF" >/dev/null 2>&1 || BASE_REF="$BASE_BRANCH"

if [ -x .claude/scripts/plan-w-team-empty-ship-guard.sh ]; then
  if ! .claude/scripts/plan-w-team-empty-ship-guard.sh "$BASE_REF" "$SLUG"; then
    echo "✗ Ship gate 6g: empty-ship loop-breaker fired — 0 commits to ship on a clean tree."
    echo "  This is NOT a real ship (no commits ahead of $BASE_REF). Halting instead of"
    echo "  looping push on an empty worktree. Investigate why the worktree is empty"
    echo "  (e.g. a pre-ship reset discarded the work) — do NOT re-run ship blindly."
    # exit 1 is caught by the §6-0a minimal-retro trap → escalation verdict.
    # SHIP_PUSH_CONFIRMED is left 0, so no false-positive PASS is written.
    exit 1
  fi
fi
```

This guard is additive and runs ONLY on the empty-worktree-at-ship path; a normal ship
with commits proceeds straight through to the ack gate below.

### Ack gate — confirm before pushing

<!-- PWT-T2: push-ack is classified as `user` in the orchestrator classifier table.
     This pause site is INTENTIONALLY kept as a user decision because git push is
     an irreversible shared-state action — a true one-way door. -->

`git push` is a shared-state action. Require an explicit acknowledgment file or user confirmation before pushing. This guards against spurious `--ship-only` re-runs pushing partial state.

**Autonomous-run auto-clear (PLAN_W_TEAM_AUTO_APPROVE_PUSH).** A `pwt-goal.sh --worker-only` worker (and the `--launch` path) exports `PLAN_W_TEAM_AUTO_APPROVE_PUSH=1` into the worker env precisely so the push-ack gate clears WITHOUT a human pause — the whole point of an unattended run. Before this was consumed (1.35.0), the var was set but inert: the worker either hand-`touch`ed the ack file (brittle, LLM-dependent) or blocked here and stopped short of ship. Auto-create the ack file when the env signal is present so the autonomous push proceeds deterministically. Interactive runs (var unset) are unchanged — they still require the explicit opt-in.

```bash
ACK_FILE=".claude/state/plan-w-team-ack-$SLUG"
if [ ! -f "$ACK_FILE" ] && [ "${PLAN_W_TEAM_AUTO_APPROVE_PUSH:-0}" = "1" ]; then
  : > "$ACK_FILE"
  echo "✓ push-ack auto-cleared (PLAN_W_TEAM_AUTO_APPROVE_PUSH=1 — autonomous run)"
fi
if [ ! -f "$ACK_FILE" ]; then
  echo "Ship gate 6g: no push acknowledgment."
  echo "Create $ACK_FILE (empty) or confirm with the user before pushing."
  echo "  touch $ACK_FILE    # opt-in once per ship"
  exit 1
fi
```

### mkdir lock — prevent concurrent push races

Parallel `/plan-w-team --ship-only` sessions on the same branch can race. Serialize with an atomic `mkdir` lock — POSIX-ubiquitous, no `flock(1)` dependency (macOS ships without it), no `exec <fd>>` file-descriptor tricks that break under `zsh`:

```bash
PUSH_LOCK_DIR=".claude/state/plan-w-team-push.lock"
mkdir -p .claude/state

# Stale-lock auto-recovery (F-3.1): if the lock dir exists but is older than 30 minutes
# AND its recorded PID is not running, treat it as abandoned and clear it before re-attempting.
# 30 min is generous — the longest legitimate push (LFS, large repo, slow uplink) finishes well under that.
if [ -d "$PUSH_LOCK_DIR" ]; then
  # Portable mtime: stat -f on macOS, stat -c on Linux. `find` is the lowest-common-denominator alt.
  LOCK_AGE_MIN=$(find "$PUSH_LOCK_DIR" -maxdepth 0 -mmin +30 -print 2>/dev/null | wc -l | tr -d ' ')
  HOLDER_PID=$(awk -F= '/^pid=/{print $2}' "$PUSH_LOCK_DIR/holder" 2>/dev/null)
  if [ "$LOCK_AGE_MIN" -gt 0 ] && [ -n "$HOLDER_PID" ] && ! kill -0 "$HOLDER_PID" 2>/dev/null; then
    echo "⚠ stale push lock detected (>30min, holder pid=$HOLDER_PID not running) — clearing"
    rm -f "$PUSH_LOCK_DIR/holder"
    rmdir "$PUSH_LOCK_DIR" 2>/dev/null
  fi
fi

if ! mkdir "$PUSH_LOCK_DIR" 2>/dev/null; then
  HOLDER=$(cat "$PUSH_LOCK_DIR/holder" 2>/dev/null || echo "unknown")
  echo "✗ Another ship is in progress (lock held by $HOLDER). Aborting."
  echo "  If stale, remove: rmdir $PUSH_LOCK_DIR"
  exit 1
fi
# Record holder for diagnostics; release on any exit (success, error, signal).
printf 'pid=%s ts=%s\n' "$$" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$PUSH_LOCK_DIR/holder"
trap 'rm -f "$PUSH_LOCK_DIR/holder"; rmdir "$PUSH_LOCK_DIR" 2>/dev/null' EXIT

# WARNING: any subsequent `trap … EXIT` in this script MUST chain rather than
# replace this handler. Bash `trap CMD EXIT` *replaces* the existing handler
# unconditionally — a naked `trap 'rm -f /tmp/foo' EXIT` later in the script
# silently drops this push-lock cleanup, causing the lock dir to leak until
# the 30-min stale-recovery branch fires on the *next* run. See §"Link PR"
# below for the chain pattern (`trap -p EXIT` capture + append).

git push -u origin "$BRANCH"
PUSH_RC=$?
if [ "$PUSH_RC" -eq 0 ]; then
  SHIP_PUSH_CONFIRMED=1
  # PWT-TERM3: re-assert the earned ship-verdict on any later drift/exit
  # (capture+append idiom, same as §6-0a/§6g). No-op unless armed, so it can
  # never mint a pre-push verdict; appended LAST so it does not clobber the
  # §6-0a minimal-retro writer or the §6g push-lock release.
  EXISTING_TRAP=$(trap -p EXIT | sed -E "s/^trap -- '(.*)' EXIT$/\1/")
  trap "${EXISTING_TRAP:+${EXISTING_TRAP}; }__pwt_write_ship_verdict" EXIT
fi
# Lock released by trap on script exit.
```

`mkdir` is atomic on every POSIX filesystem: it either creates the directory (lock acquired) or fails with `EEXIST` (lock held). Stale locks (>30min + dead holder PID) auto-clear at the top of the block; manual `rmdir` is the escape hatch for younger locks the operator knows are abandoned.

After push succeeds, delete the ack file so the next ship run requires a fresh opt-in:

```bash
rm -f "$ACK_FILE"
```

### Link PR to Board Issue

Use `closes #N` in the PR body to automatically link the PR to the board Issue. When the PR merges, GitHub will close the Issue and the board workflow moves it to Done.

```bash
# Get the issue number from the spec header or board search
ISSUE_NUM=$(grep -o '#[0-9]*' docs/specs/<feature-name>.md | head -1)

# Write the PR body to a file first — avoids shell expansion of any user-authored
# fragments (spec links, issue titles, commit messages) and lets gh read directly.
# See shared/shell-safety.md for why `<<EOF` on LLM-authored content is unsafe.
PR_BODY_FILE=$(mktemp -t plan-w-team-pr-body.XXXXXX)
# Chain cleanup onto the existing push-lock trap — do NOT replace it.
# `trap -p EXIT` returns the existing handler in re-evaluable form (`trap -- 'CMD' EXIT`).
# Strip the wrapper, append our cleanup, set the combined trap.
EXISTING_TRAP=$(trap -p EXIT | sed -E "s/^trap -- '(.*)' EXIT$/\\1/")
trap "${EXISTING_TRAP}; rm -f \"$PR_BODY_FILE\"" EXIT

cat > "$PR_BODY_FILE" <<'EOF'
## Summary
<1-3 bullet points describing what changed>

## Test Plan
- [ ] All unit tests pass
- [ ] Integration tests pass
- [ ] Manual QA verified (if frontend)

EOF

# Append dynamic fields using printf (no shell expansion of PR content)
printf 'Closes %s\n\n---\n**Spec:** docs/specs/%s.md\n**Board:** https://github.com/%s/%s/issues/%s\n\nGenerated with [Claude Code](https://claude.com/claude-code)\n' \
  "$ISSUE_NUM" "$FEATURE_SLUG" "$REPO_OWNER" "$REPO_NAME" "${ISSUE_NUM#\#}" \
  >> "$PR_BODY_FILE"

gh pr create --title "$PR_TITLE" --body-file "$PR_BODY_FILE"
```

The `Closes #N` keyword creates a bidirectional link:

- The PR shows which Issue it resolves
- The Issue shows which PR implements it
- Merging the PR auto-closes the Issue and triggers the board Done workflow

### Apply `DO NOT MERGE` Label on One-Way-Door Surfaces (2026-05-22)

After `gh pr create`, walk the staged diff against the closed list of one-way-door surfaces in [`shared/governance-tags.md`](shared/governance-tags.md). When **any** path matches **any** glob in the catalog, the PR MUST carry the literal `DO NOT MERGE` label. When **no** path matches, the PR MUST NOT carry the label. This is the contract the origin-chat supervisor reads when deciding whether to AUTO-MERGE (`shared/supervisor-protocol.md` §Decision Matrix).

```bash
# Build glob list from shared/governance-tags.md (rough catalog — see file for full set)
GOVERNANCE_GLOBS=(
  '*secret-allow*' '*.secret-allow*'
  '*/billing/*' '*/payments/*' '*stripe*' '*invoice*'
  '*/migrations/*' '*.sql' 'apps/db/schema/*'
  '*wrangler.toml' '*.tf' '*.tfvars' '*/cloudformation/*' '*/terraform/*' '*/k8s/*' '*/kubernetes/*'
  '.env' '.env.*' '*/secrets/*' '*.pem' '*.key' '*.p12' '*.jks'
)

ONE_WAY=0
ONE_WAY_HIT=""
while IFS= read -r path; do
  for glob in "${GOVERNANCE_GLOBS[@]}"; do
    # shellcheck disable=SC2254  # intentional glob match
    case "$path" in
      $glob) ONE_WAY=1; ONE_WAY_HIT="$path (matched $glob)"; break 2 ;;
    esac
  done
done < <(git diff --name-only "origin/$DEFAULT_BRANCH"..."$BRANCH")

if [ "$ONE_WAY" = 1 ]; then
  echo "✓ governance-tags hit: $ONE_WAY_HIT — applying DO NOT MERGE label"
  gh pr edit --add-label "DO NOT MERGE" || true
fi
```

**Rules**:

- **Apply the label** the moment a one-way-door surface is detected. Do not wait for review.
- **Do not apply the label** on reversible PRs. Reversible PRs labeled `DO NOT MERGE` block the supervisor's auto-progression and re-introduce the failure mode (every PR surfaced to user).
- **The label is `DO NOT MERGE` literally** — case-sensitive, three words, spaces (not hyphens). The supervisor's matrix consults this exact string.
- **Adding to or removing from the catalog requires a spec.** See `shared/governance-tags.md` §Adding a Surface.

Mis-labeling — either a missing label on a one-way PR or a spurious label on a reversible PR — is a Pass 1 CRITICAL review item. The Step 5 reviewer re-runs the same `governance-globs` walk to verify.

#### Worker Label Policy (2026-05-22 — clarified)

The `DO NOT MERGE` label has exactly two legitimate worker uses. Any other use is a Pass 1 CRITICAL review item.

1. **One-way-door surface match** (the rule above). Worker detected a path matching `shared/governance-tags.md` in its diff; label MUST be applied; the supervisor's `.claude/scripts/supervisor-merge-gate.sh` will return `recommended_action=SURFACE_TO_USER` regardless of CI mode (matrix row 1).

2. **Supervisor-reviewer pattern** — worker explicitly delegates final review to the supervisor (the human-equivalent reviewer in autonomous-run mode). When using this pattern, the worker MUST:
   - Apply the `DO NOT MERGE` label, AND
   - Add a comment to the PR body explicitly stating the delegation. Format:
     ```
     <!-- supervisor-reviewer-delegation: <one-sentence reason> -->
     ```
     Example: `<!-- supervisor-reviewer-delegation: worker is uncertain whether ESLint config change affects downstream repos; defer to supervisor judgement -->`

The supervisor's merge-gate uses these signals via the matrix:

- **Worker case 1 (one-way door)** → gate returns `SURFACE_TO_USER` regardless of supervisor action (matrix row 1).
- **Worker case 2 (delegation, local-makefile CI)** → gate returns `ADMIN_MERGE` (matrix row 2 — supervisor IS the reviewer).
- **Worker case 2 (delegation, github-actions CI)** → gate returns `SURFACE_TO_USER` (matrix row 3 — a real human is needed to bypass required checks).

**Forbidden uses** of `DO NOT MERGE` (worker MUST NOT apply the label for these):

- "I'm not confident about this code" — that is a review request, not a one-way door. Open the PR without the label; Pass 1/2 review handles it.
- "This is a big PR" — size alone is not a one-way door.
- "This touches user-facing surfaces" — those surfaces are reversible unless they appear in `shared/governance-tags.md`.
- "Just in case" — labels carry merge-gate cost; never apply speculatively.

The Step 5 reviewer enforces this by checking, for any PR carrying `DO NOT MERGE`: either a governance-tag surface matched in the diff, OR a `supervisor-reviewer-delegation:` HTML comment exists in the PR body. Neither present → CRITICAL.

Read `shared/artifact-storage.md` for review log and streak tracking formats.

## 6g-ter. Worker Self-Merge to main (autonomous + reversible only) — Deliverable 2 (1.35.0)

**Why this exists.** Until 1.35.0 the worker pushed its branch + opened a PR and then **stopped**, leaving the merge to the supervisor/human. In an unattended `pwt-goal.sh --worker-only` run there is no separate bg supervisor — the origin chat is the live supervisor — and the 2026-06-07 incident (run `10ac5920`) showed the worker stopping short of ship entirely (the anti-skip anchor was inert; see `pwt-goal.sh` seed-path fix). The end state of a clean autonomous run MUST be **work on `main`, branch + worktree reclaimed, without supervisor hand-merging** (brief Deliverable 2). The worker self-ships.

**This does NOT weaken the human-owned one-way-door gate.** Self-merge fires ONLY for **reversible** PRs (no `DO NOT MERGE` label). A one-way-door surface (governance-tag match, §6g label block above) keeps the label and is surfaced to the human exactly as before — self-merge is skipped for it. And it fires ONLY in autonomous mode (`PLAN_W_TEAM_AUTO_APPROVE_PUSH=1`); interactive runs open the PR and stop, unchanged.

```bash
# Gate 1: autonomous mode only. Interactive runs leave the PR for the human.
if [ "${PLAN_W_TEAM_AUTO_APPROVE_PUSH:-0}" != "1" ]; then
  echo "ℹ self-merge skipped: interactive run (PLAN_W_TEAM_AUTO_APPROVE_PUSH unset) — PR left for review"
elif [ "${PWT_DISABLE_SELF_MERGE:-0}" = "1" ]; then
  echo "ℹ self-merge skipped: PWT_DISABLE_SELF_MERGE=1 (kill switch)"
else
  # Gate 2: reversible only — a DO NOT MERGE label means a one-way-door surface
  # (or explicit supervisor-reviewer delegation). Those stay human-gated.
  PR_LABELS=$(gh pr view --json labels --jq '[.labels[].name] | join(",")' 2>/dev/null || echo "")
  if printf '%s' "$PR_LABELS" | grep -q 'DO NOT MERGE'; then
    echo "⚠ self-merge skipped: PR carries 'DO NOT MERGE' (one-way-door / delegation) — surfaced to human"
  else
    # CI-aware merge form (mirrors supervisor-protocol §CI-Aware Action Hierarchy
    # rows 5-7). A real GitHub Actions build/test/deploy workflow → --auto (GitHub
    # waits for required checks). Local-Makefile / no CI (the no-github-actions.md
    # canonical, and this repo) → --admin (local gates already passed pre-push at
    # §6b). Detection: any workflow YAML with an on: push|pull_request trigger.
    CI_MODE="none"
    if [ -d .github/workflows ]; then
      if grep -rlE '^[[:space:]]*on:|pull_request|[[:space:]]push:' .github/workflows/*.y*ml 2>/dev/null \
         | grep -q .; then
        CI_MODE="github-actions"
      fi
    fi
    if [ "$CI_MODE" = "github-actions" ]; then
      MERGE_FLAGS="--auto --squash --delete-branch"
    else
      MERGE_FLAGS="--admin --squash --delete-branch"
    fi
    echo "→ worker self-merge (reversible, autonomous, ci_mode=$CI_MODE): gh pr merge $MERGE_FLAGS"
    if gh pr merge $MERGE_FLAGS 2>&1; then
      echo "✅ worker self-merged to $DEFAULT_BRANCH (no supervisor hand-merge)"
      # Reclaim the worktree + fast-forward the primary checkout. The helper
      # enforces its own safety invariants (containment, uncommitted/in-use,
      # ff-only) and safe-skips rather than failing — calling it here is safe.
      if [ -x .claude/scripts/plan-w-team-worktree-on-merge.sh ] && [ -n "${WORKTREE_PATH:-}" ]; then
        .claude/scripts/plan-w-team-worktree-on-merge.sh "$WORKTREE_PATH" "$BRANCH" "$SLUG" \
          | jq -r '"✓ post-merge reclaim: " + (.reason // "n/a")' 2>/dev/null || true
      fi
    else
      # Fail-SOFT: do NOT exit 1 (that would trip the §6-0a minimal-retro trap and
      # stop the run short — the very failure mode this fixes). The branch is pushed
      # and the PR is open; surface for the supervisor/human and continue to retro.
      echo "⚠ self-merge did not complete (gh error / protected branch / required checks pending)."
      echo "   The PR is open and pushed — supervisor or human can merge. Continuing to post-ship + retro."
    fi
  fi
fi
```

**Verification (AC5).** A clean reversible autonomous run reaches `✅ worker self-merged to <default>` here, then §6h reclaim leaves the tree on `main`. Verified short of a full multi-hour live run by: (a) the directive is unconditional on the autonomous+reversible path (quoted above); (b) the push-ack auto-clear (§6g) removes the only human pause between green tests and this merge; (c) the existing `plan-w-team-worktree-on-merge.sh` ff-only reclaim is reused, not reinvented.

## 6g-quater. Build-Artifact Hygiene (E7 — reclaim before the worktree lingers)

Once a build worker has **shipped** (PR opened/pushed, tests green) but the worktree
is **awaiting merge** (the common `DO NOT MERGE` flow can hold it for hours/days), the
worktree still holds 100%-regenerable build output — iOS `Pods` + `DerivedData`
(5–9 GB each), Android `.gradle`/`build`, Rust `target/`. That output dominated the
64 GB in the 2026-05-29 ENOSPC incident. The build is done, so it is safe to drop now;
it regenerates on demand if the branch is ever re-run.

```bash
# Reclaim regenerable build artifacts from the SHIPPED worker's worktree (it now
# only needs to survive as a mergeable branch, not as a built tree). Safe: the
# helper refuses any path outside .claude/worktrees/, removes only a fixed
# allowlist of build dirs, and never touches source or the shared node_modules
# symlink. Kill switch: PWT_BUILD_ARTIFACT_CLEAN_DISABLE=1.
if [ -x .claude/scripts/plan-w-team-build-artifact-clean.sh ] \
   && [ "${PWT_BUILD_ARTIFACT_CLEAN_DISABLE:-0}" != "1" ]; then
  .claude/scripts/plan-w-team-build-artifact-clean.sh "$WORKTREE_PATH" --execute --json \
    | jq -r '"✓ build-artifact hygiene: reclaimed " + (.reclaimable_mb|tostring) + " MB"' 2>/dev/null || true
fi
```

This runs on the SHIP path (PR opened), independent of whether the merge has landed —
unlike §6h below, which only fires on a clean merge to remove the whole worktree.

## 6h. Post-Merge Worktree Cleanup (supervisor-only)

When the worker's feature branch has been **merged to the default branch on the parent repo** (clean merge, ship-readiness gate PASS), the supervisor — NOT the worker — reclaims the worker's worktree + branch. The supervisor has the right context: it knows the merge happened and that the worktree is now post-merge garbage.

This step fires ONLY on a clean merge. **Skip cleanup (preserve the worktree)** when any of these hold — the worktree is still needed or its state is unsafe to touch:

- Step 5 review returned FAIL.
- A hard-gate halt is active (`push-ack`, `secret-scan-allow`, `scope-unlock-for-drift`).
- 3-consecutive low-confidence escalation fired.
- The worktree has uncommitted changes, or a live `claude` session still has it as cwd (the helper re-asserts both invariants and safe-skips).
- The PR was opened but NOT yet merged (the common `DO NOT MERGE` flow) — cleanup waits until the actual merge.

```bash
# Supervisor runs this after confirming the merge landed on the default branch.
# WORKTREE_PATH + BRANCH are the worker's, recorded in the run's fleet JSONL.
if [ -x .claude/scripts/plan-w-team-worktree-on-merge.sh ]; then
  ON_MERGE_JSON=$(.claude/scripts/plan-w-team-worktree-on-merge.sh \
      "$WORKTREE_PATH" "$BRANCH" "$SLUG" 2>/dev/null || echo '{}')
  echo "✓ post-merge cleanup: $(printf '%s' "$ON_MERGE_JSON" | jq -r '.reason // "n/a"' 2>/dev/null)"
fi
```

The helper enforces every safety invariant itself (containment to `.claude/worktrees/`, uncommitted check, in-use check, idempotency) and returns `skipped:true` with a `safe-skip:*` reason rather than failing when a guard trips — so wiring it unconditionally on the PASS path is safe. Repo-wide accumulated-debt sweeps are the weekly launchd GC, not this per-merge step. Full contract: `docs/operations/worktree-lifecycle.md`. Kill switch: `PWT_WORKTREE_ON_MERGE_DISABLE=1`.

## End-of-Stage Status Block (PWT-T5)

**Ship-verdict artifact (C3 — deterministic SUCCESS corroboration).** Reaching this point means every §6 ENFORCING gate passed (each `exit 1`s on failure: §6a-ter secret scan, §6a-quinquies credential-wall, §6b test suite, §6c coverage, §6c-bis security tier, §6c-ter access-control). Write a machine-readable ship-verdict that the goal-evaluator **requires** before honoring SUCCESS inside a bg worker — so a worker cannot self-declare the `/goal` done by emitting `retro-complete` transcript text alone, bypassing the ship gate (audit C3, `docs/operations/pwt-principles-enforcement-audit-2026-06-02.md`). Gated on `SHIP_PUSH_CONFIRMED` (set only post-push-success in §6g) and re-asserted by an armed EXIT trap — so it reliably lands even if this block isn't reached (post-push drift), but NEVER lands when push failed:

```bash
# push (and, for reversible runs, self-merge) succeeded → SHIP_PUSH_CONFIRMED=1.
# Single source of truth with the §6g EXIT-trap re-assertion (PWT-TERM3).
__pwt_write_ship_verdict
```

At the end of this stage, emit a status block for the `/goal` evaluator. This is a one-line invocation; the helper handles all field population (workflow lock, supervisor log, fleet log, escalations).

```bash
.claude/scripts/plan-w-team-surface-status.sh "$SLUG" "ship"
```

The stage label `ship` is the second argument — see `shared/goal-conditions.md` §Status-Block Schema for the full label list. `/goal` evaluator reads the emitted block to judge whether the pipeline terminal condition is met.

Skip this block entirely when `PLAN_W_TEAM_DISABLE_GOAL=1` (kill switch) — the helper itself is observability and remains safe to call, but invocation here is optional in that mode.
