# plan-w-team — Known Issues & Upgrade Backlog

Durable, version-controlled record of observed defects and workarounds for the
`/plan-w-team` skill. This is the canonical reference so findings are not lost in
a session's ephemeral memory. When a fix ships, move the entry to "Resolved" with
the version and bump `VERSION` + `CHANGELOG.md`.

> Provenance: consolidated 2026-08-30 during the all-surfaces BDD-gap greening
> campaign (cleanrev), which exercised the autonomous bg-worker fleet hard across
> two machines and surfaced the items below.

## Open

_(none)_

## Resolved

### KI-8 — non-push halts were invisible in `--worker-only` mode; now fire a proactive operator alert (fixed v2.31.0)

- **Was:** when a `--worker-only` (or bare `/goal`) run hit a NON-push halt (`secret-scan-allow`, `scope-unlock-for-drift`, or a 3-consecutive-low-confidence escalation), there was no proactive operator signal — the halt surfaced only to the `/goal` daemon's pending-question state and `terminal_state` in the goal-state file. `--worker-only` is now the primary autonomous mode and has NO bg supervisor, so for an unattended run that was a silent dead-end. The only proactive notify (macOS `osascript`) lived exclusively in the legacy `--launch` bg-supervisor path. KI-5 removed the push-ack halt from auto-push mode (it auto-approves); this closed the residual for the halts that legitimately DO pause.
- **Fix:** worker-side halt-notify directive in `pwt-goal.sh`. The `AUTO_PUSH=1` branch of `__PWT_PUSH_HALT_DIRECTIVE` now instructs the worker, upon reaching ANY halt, to FIRST fire a best-effort operator alert before pausing — preferring the `PushNotification` tool, else a local desktop notification (macOS `osascript` display-notification, else `notify-send`) naming the halt reason, wrapped so a missing channel never fails the run (`|| true`). This reaches exactly the unattended modes (`--worker-only`/`--launch`/`--supervisor-goal`/`--auto-push` all arm `AUTO_PUSH=1`). The `AUTO_PUSH=0` (bare `/goal`) block stays BYTE-IDENTICAL — an attended paste needs no proactive notify, and the K4/K5 golden guard stays green. Prompt-directive design (the halt occurs inside the worker's `/goal` session after `pwt-goal.sh` has exited, so the launcher cannot fire the alert itself — it must instruct the worker). No change to push authority (push stays a user-owned grant) or to any halt condition. Tests: `pwt-goal-intent.test.sh` K6 (--auto-push carries the directive) + K7 (bare omits it), EXPECTED_PASS 35 → 37.

### KI-7 — a worktree-consumed gating hook, uncommitted, was silently ignored in a fresh worktree (fixed v2.30.1)

- **Was:** `git worktree add … HEAD` checks out the COMMITTED HEAD, so the spawned bg worker runs the WORKTREE's copy of every gating hook — never the working-tree copy in the main checkout. An operator who edited a gating hook (e.g. armed the F7 completeness gate in `plan-w-team-goal-evaluator.sh`) but had NOT committed it got the OLD hook inside the worktree, and the change silently no-opped — an "armed" gate that never fires. The specific F7-evaluator case that surfaced this was already closed at `2c650c7` (v2.22.0, the completeness gate landed committed), but ANY worktree-run gating hook had the same blind spot.
- **Fix:** spawn-time drift warning in `pwt-goal.sh`. Right after the `--worktree` flag is decided (and only when worktree isolation is active), the launcher checks whether any worktree-consumed gating hook (`plan-w-team-goal-evaluator.sh`, `plan-w-team-lane-guard.sh`, `plan-w-team-lane-context.sh`) differs from HEAD in the main checkout (`git status --porcelain` non-empty ⇒ modified / staged-not-committed / untracked). If any do, it prints a LOUD warning naming each dirty hook and explaining the worker will use HEAD's committed copy. Advisory only — never aborts (the operator may have committed elsewhere or want HEAD's copy). Fail-open SILENT when the root is not a git repo, so test sandboxes and non-git checkouts never false-fire. Kill switch `PWT_DISABLE_WORKTREE_HOOK_DIRTY_WARN=1`. Tests: `pwt-goal-worktree-hook-dirty.test.sh` (9/9).

### KI-4 — steer/resume lost the launch-time auto-push posture; now persisted + restored (fixed v2.28.0)

- **Was:** `pwt-steer.sh` rebuilt the resume launch env with a HARDCODED `__pwt_build_launch_env 0`, so a resumed lane silently lost `PLAN_W_TEAM_AUTO_APPROVE_PUSH=1` and dead-ended at the push-ack pause — the push posture the original autonomous spawn was granted (`--worker-only`/`--launch`/`--supervisor-goal`/`--auto-push` all set `AUTO_PUSH=1`) never reached the resumed worker unless the operator hand-passed `--env PLAN_W_TEAM_AUTO_APPROVE_PUSH=1` on every steer.
- **Fix:** persist the posture and restore it automatically (reuse-first). The `pwt-goal.sh` seed now records `auto_push` (0/1) at all three seed sites (jq writer, no-jq printf fallback, supervisor-goal mirror). `pwt-steer.sh` reads `.auto_push` back and feeds the SAME shared `__pwt_build_launch_env` builder instead of the hardcoded `0`; a fallback arm restores the push var even when the launch-env lib is unreadable. The build was hoisted above the `--dry-run` branch so dry-run prints the REAL resume env. Operator `--env` is still appended AFTER (explicit override wins, so `land.sh resume` is unaffected). Additive goal-state field — no reader or golden perturbed; `__pwt_build_launch_env` unchanged so the launch-env parity + K1–K5 prompt goldens hold. `pwt-resume.sh` delegates through `land.sh`→`pwt-steer`, inheriting the fix. Kill switch `PWT_DISABLE_STEER_AUTOPUSH_RESTORE=1`. Tests: `pwt-steer.test.sh` T25a–e (124/124) + `pwt-goal-worker-only.test.sh` KI-4 seed cases (12/12).

### KI-3 — steer refused an 8-char bg handle; now auto-resolves handle→UUID (fixed v2.27.0)

- **Was:** `pwt-steer.sh` read the worker sid from the goal-state, but a `--bg` spawn only prints (and the seed persists) the 8-char process handle (`backgrounded · aabbccdd`). `--resume` needs the 36-char UUID, so steer dead-ended at the W6 refuse — the worker was alive and `working` but unsteerable without hand-resolving the UUID from `claude agents --json`.
- **Fix:** handle→UUID auto-resolve in `pwt-steer.sh` before the W6 refuse. A unique live bg session whose `sessionId` starts with the handle upgrades the sid (via `claude-agents-extended.sh --json --bg-only`); 0/>1 matches, an unqueryable registry, or a non-handle value fail-open to the refuse (never resume a stranger). Kill switch `PWT_DISABLE_STEER_SID_RESOLVE=1`. Writer-side "persist full UUID" was deliberately NOT added — it would add a registry round-trip to every spawn's hot path and break 6+ call-count tests for zero correctness gain once steer auto-resolves. Tests: `pwt-steer.test.sh` T24a–d + T2 reconciled (116/116).

### KI-2 — a flag after the positional goal silently degraded to print mode (fixed v2.26.0)

- **Was:** `pwt-goal.sh "<goal>" --worker-only` (flag AFTER the goal) printed the assembled `/goal` prompt and exited 0 WITHOUT spawning — no worktree, no worker, no error. The arg-parse `*)` arm did `REQUEST="$*"; break`, swallowing the trailing `--worker-only` into the request string; `LAUNCH`/`WORKER_ONLY` stayed 0 and the script fell back to print-for-manual-paste mode. Operators had to know to always put flags FIRST.
- **Fix:** guarded positional parse in `pwt-goal.sh`. The `*)` arm takes `$1` as the goal head, then scans the remaining argv: an option-shaped trailing token (starts with `-`) is a misplacement → loud error naming the token + guidance (flags before the goal, or end options with `--`) + **exit 2**, mirroring the outer `-*)` arm. Non-flag trailing words are appended so an UNQUOTED multi-word goal still assembles; `--` still force-terminates option parsing for a goal that begins with `-`. exit 2 is distinct from the pre-goal unknown-option exit 1. Flags-first invocations are unchanged. Tests: `pwt-goal-worker-only.test.sh` KI-2 cases (10/10); golden K1–K5 + heredoc-size stay green.

### KI-6 — lane-guard false-positives on copy-family SOURCE operands (fixed v2.25.0)

- **Was:** the PreToolUse lane guard (PWT-LANE1) treated `cp`/`rsync`/`ln`/`install` as "mutators" and denied the call if ANY operand — including the SOURCE — resolved inside the lane repo. A bound supervisor copying OUT of the repo (`cp $REPO/src/x /tmp/…`, `rsync $REPO/ /tmp/backup/`) was blocked, forcing operators to prefix `PLAN_W_TEAM_DISABLE_LANE_GUARD=1` and disable the whole guard.
- **Fix:** copy-family / destructive split in `plan-w-team-lane-guard.sh`. A copy-family verb only WRITES its destination, so the mutator token-check now relaxes for a PURE copy-family command — checking ONLY the destination (final) operand and skipping in-repo sources. The relaxation is deliberately narrow: it applies ONLY with NO destructive verb (`mv`/`rm`/`truncate`/`dd`/`shred`/`unlink`), NO `-t`/`--target-directory` form, and NO command separator / pipe / substitution; every other shape reverts to the strict all-operand check, so copying INTO the repo — including a repo write hidden behind an out-of-repo final token — still DENIES. `COPY_ONLY=0` is byte-identical to the prior guard; D10 protected-artifact denials unchanged. Lane-guard is a governance-tagged one-way-door surface. Tests: `plan-w-team-lane-guard.bats` KI-6 twins 75–81 (81/81).

### KI-5 — push-ack "halt" wording alarmed operators; auto-push is mode-dependent (fixed v2.24.0)

- **Was:** the printed `/goal` contract listed push-ack as a halt regardless of mode, even though every autonomous spawn (`--launch`/`--worker-only`/`--supervisor-goal`/`--auto-push`) sets `PLAN_W_TEAM_AUTO_APPROVE_PUSH=1` so push-ack auto-approves and never halts — the run advertised a halt it would not take, reading as "it will wait on me."
- **Fix:** mode-conditional halt contract in `pwt-goal.sh` (`__PWT_PUSH_HALT_DIRECTIVE` / `__PWT_HALT_INLINE`, gated on `AUTO_PUSH`). Under auto-push the goal text states push AUTO-APPROVES and lists only the genuine halts (secret-scan-allow, scope-unlock-for-drift, 3-consecutive low-confidence); a bare `/goal` paste keeps the push-ack halt line because it truly pauses. Byte-identical for `AUTO_PUSH=0` (golden guard stays green). Auto-push confirmed ALREADY the default for every spawn mode — the fix corrects the contract to match, without changing push authority (push stays a user-owned grant). Residual halt-visibility gap tracked as [[KI-8]]. Tests: `pwt-goal-intent.test.sh` K1–K5.

### KI-1 — bg daemon pinned every `--bg` worker to its startup account (#1703) (fixed v2.23.0)

- **Was:** the bg-session daemon reads auth ONCE at startup, so an autonomous `--bg` lane inherited the daemon's (possibly stale) account and died 15–23 min in — looked like a stall (`waiting`, zero writes, `terminal_state` null). A per-invocation token was IGNORED by an already-running daemon.
- **Fix:** new opt-in env `PWT_LANE_SETTINGS_RESOLVER=<executable>` in `pwt-goal.sh`. When set and no explicit `--lane-settings-json`/`PWT_LANE_SETTINGS_JSON` was given, the bg-spawn path calls it as `<resolver> <lane-slug> <worktree-name>` and drops the per-lane `settings.local.json` it names (mode 0600) BEFORE the worker's first API call, so each lane authenticates with its own account independent of the daemon. Repo-specific and byte-for-byte no-op when unset (works in any repo; the generic skill never handles a token). Fail-closed: a resolver that errors/prints nothing aborts the spawn rather than falling back to the daemon account. Kill switch `PWT_DISABLE_LANE_SETTINGS_RESOLVER=1`.

### KI-R1 — enumerated-universe scope-collapse → false SUCCESS (fixed v2.22.0)

- **Was:** a "for each of N" goal reached terminal SUCCESS after covering ~19 of 359 because `feature_specific_done_criteria` measured completion against the criteria array's OWN length.
- **Fix:** F7 completeness gate — opt-in goal-state `completeness_gate {label,file,jq|grep_count,max_remaining}`; the evaluator re-measures REMAINING from the SSoT live at every terminal anchor and VETOES SUCCESS while remaining > max. Kill switch `PWT_DISABLE_COMPLETENESS_GATE=1`.
